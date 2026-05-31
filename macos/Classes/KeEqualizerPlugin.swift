import AVFoundation
import Cocoa
import FlutterMacOS

class MicrophoneAccessManager {
  func requestMicrophoneAccess() async -> Bool {
    let status = AVCaptureDevice.authorizationStatus(for: .audio)

    switch status {
    case .authorized:
      return true
    case .notDetermined:
      await MainActor.run {
        NSApplication.shared.activate(ignoringOtherApps: true)
      }
      return await AVCaptureDevice.requestAccess(for: .audio)
    case .denied, .restricted:
      return false
    @unknown default:
      return false
    }
  }
}

public class KeEqualizerPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
  private static let centerFrequencies: [Float] = [
    60, 170, 310, 600, 1000, 3000, 6000, 12000,
  ]

  private static let presets: [(name: String, gains: [Float])] = [
    ("Flat", [0, 0, 0, 0, 0, 0, 0, 0]),
    ("Bass Boost", [7, 5, 3, 1, 0, -1, -2, -2]),
    ("Treble Boost", [-2, -2, -1, 0, 1, 3, 5, 7]),
    ("Vocal", [-3, -2, 1, 4, 5, 3, 0, -2]),
    ("Rock", [5, 3, -2, -3, 1, 3, 5, 4]),
    ("Electronic", [6, 4, 1, 0, -2, 2, 5, 6]),
  ]

  private let registrar: FlutterPluginRegistrar
  private var playbackEngine: AVAudioEngine?
  private var playerNode: AVAudioPlayerNode?
  private var equalizer: AVAudioUnitEQ?
  private var playbackFile: AVAudioFile?
  private var downloadedFileURL: URL?
  private var bandGains = Array(repeating: Float(0), count: centerFrequencies.count)
  private var currentPresetIndex: Int?
  private var shouldLoopPlayback = false

  private let microphoneAccessManager = MicrophoneAccessManager()
  private var inputEngine: AVAudioEngine?
  private var audioRecorder: AVAudioRecorder?
  private var recordingURL: URL?
  private var eventSink: FlutterEventSink?
  private var toneBandCount = 8
  private var toneSampleRate = 44100.0

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "ke_equalizer", binaryMessenger: registrar.messenger)
    let eventChannel = FlutterEventChannel(name: "ke_equalizer/tone", binaryMessenger: registrar.messenger)
    let instance = KeEqualizerPlugin(registrar: registrar)
    registrar.addMethodCallDelegate(instance, channel: channel)
    eventChannel.setStreamHandler(instance)
  }

  init(registrar: FlutterPluginRegistrar) {
    self.registrar = registrar
    super.init()
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "getPlatformVersion":
      result("macOS " + ProcessInfo.processInfo.operatingSystemVersionString)
    case "getCapabilities":
      result(capabilitiesMap())
    case "load":
      load(call, result: result)
    case "play":
      play(result: result)
    case "pause":
      playerNode?.pause()
      result(nil)
    case "stop":
      stopPlayback(resetPosition: true)
      result(nil)
    case "setBandGain":
      setBandGain(call, result: result)
    case "setPreset":
      setPreset(call, result: result)
    case "startToneAnalysis":
      startToneAnalysis(call, result: result)
    case "stopToneAnalysis":
      stopToneAnalysis()
      result(nil)
    case "startRecording":
      startRecording(call, result: result)
    case "stopRecording":
      result(stopRecording())
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func load(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let arguments = call.arguments as? [String: Any],
      let type = arguments["type"] as? String,
      let value = arguments["value"] as? String
    else {
      result(FlutterError(code: "invalid_source", message: "Audio source requires type and value.", details: nil))
      return
    }

    do {
      releasePlayback()
      let sourceURL = try resolveAudioURL(type: type, value: value)
      let file = try AVAudioFile(forReading: sourceURL)
      let engine = AVAudioEngine()
      let player = AVAudioPlayerNode()
      let eq = AVAudioUnitEQ(numberOfBands: Self.centerFrequencies.count)

      configureEqualizer(eq)
      engine.attach(player)
      engine.attach(eq)
      engine.connect(player, to: eq, format: file.processingFormat)
      engine.connect(eq, to: engine.mainMixerNode, format: file.processingFormat)
      installPlaybackMeter(on: eq, format: file.processingFormat)
      engine.prepare()
      try engine.start()

      playbackEngine = engine
      playerNode = player
      equalizer = eq
      playbackFile = file
      shouldLoopPlayback = true
      schedulePlaybackLoop()
      result(stateMap())
    } catch {
      releasePlayback()
      result(FlutterError(code: "load_failed", message: error.localizedDescription, details: nil))
    }
  }

  private func resolveAudioURL(type: String, value: String) throws -> URL {
    switch type {
    case "asset":
      let lookupKey = registrar.lookupKey(forAsset: value)
      let appFrameworkResources = Bundle.main.privateFrameworksPath
        .map { "\($0)/App.framework/Resources" }
      let candidates = [
        value,
        "flutter_assets/\(value)",
        Bundle.main.path(forResource: lookupKey, ofType: nil),
        Bundle.main.resourcePath.map { "\($0)/\(lookupKey)" },
        appFrameworkResources.map { "\($0)/\(lookupKey)" },
        appFrameworkResources.map { "\($0)/flutter_assets/\(lookupKey)" },
        appFrameworkResources.map { "\($0)/\(value)" },
        appFrameworkResources.map { "\($0)/flutter_assets/\(value)" },
      ]

      for candidate in candidates {
        guard let path = candidate else {
          continue
        }
        if FileManager.default.fileExists(atPath: path) {
          return URL(fileURLWithPath: path)
        }
        if let bundlePath = Bundle.main.path(forResource: path, ofType: nil) {
          return URL(fileURLWithPath: bundlePath)
        }
      }
      throw KeEqualizerError.assetNotFound(value)
    case "file":
      return URL(fileURLWithPath: value)
    case "url":
      guard let url = URL(string: value) else {
        throw KeEqualizerError.invalidURL(value)
      }
      if url.isFileURL {
        return url
      }
      let data = try Data(contentsOf: url)
      let fileName = url.lastPathComponent.isEmpty ? UUID().uuidString : url.lastPathComponent
      let destination = FileManager.default.temporaryDirectory
        .appendingPathComponent("ke_equalizer_\(UUID().uuidString)_\(fileName)")
      try data.write(to: destination, options: .atomic)
      downloadedFileURL = destination
      return destination
    default:
      throw KeEqualizerError.unsupportedSource(type)
    }
  }

  private func configureEqualizer(_ eq: AVAudioUnitEQ) {
    for (index, band) in eq.bands.enumerated() {
      band.filterType = .parametric
      band.frequency = Self.centerFrequencies[index]
      band.bandwidth = 1.0
      band.gain = bandGains[index]
      band.bypass = false
    }
    eq.globalGain = 0
  }

  private func installPlaybackMeter(on node: AVAudioNode, format: AVAudioFormat) {
    let sampleRate = format.sampleRate > 0 ? format.sampleRate : 44100.0
    let centerFrequencies = Self.centerFrequencies.map(Double.init)
    node.removeTap(onBus: 0)
    node.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
      guard self?.playerNode?.isPlaying == true else {
        return
      }
      self?.publishToneFrame(
        buffer: buffer,
        sampleRate: sampleRate,
        centerFrequencies: centerFrequencies
      )
    }
  }

  private func schedulePlaybackLoop() {
    guard shouldLoopPlayback, let player = playerNode, let file = playbackFile else {
      return
    }

    player.scheduleFile(file, at: nil) { [weak self] in
      DispatchQueue.main.async {
        guard let self = self, self.shouldLoopPlayback else {
          return
        }
        self.schedulePlaybackLoop()
        if self.playerNode?.isPlaying == true {
          self.playerNode?.play()
        }
      }
    }
  }

  private func play(result: @escaping FlutterResult) {
    guard let engine = playbackEngine, let player = playerNode else {
      result(FlutterError(code: "not_loaded", message: "Load audio before playback.", details: nil))
      return
    }

    do {
      if !engine.isRunning {
        try engine.start()
      }
      player.play()
      result(nil)
    } catch {
      result(FlutterError(code: "play_failed", message: error.localizedDescription, details: nil))
    }
  }

  private func setBandGain(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard equalizer != nil else {
      result(FlutterError(code: "not_loaded", message: "Load audio before changing equalizer bands.", details: nil))
      return
    }

    guard let arguments = call.arguments as? [String: Any],
      let bandIndex = arguments["bandIndex"] as? Int,
      let gainDb = arguments["gainDb"] as? Double,
      bandIndex >= 0,
      bandIndex < bandGains.count
    else {
      result(FlutterError(code: "invalid_band", message: "Band index or gain is invalid.", details: nil))
      return
    }

    let clampedGain = Float(gainDb).clamped(to: -15...15)
    bandGains[bandIndex] = clampedGain
    equalizer?.bands[bandIndex].gain = clampedGain
    currentPresetIndex = nil
    result(stateMap())
  }

  private func setPreset(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard equalizer != nil else {
      result(FlutterError(code: "not_loaded", message: "Load audio before applying presets.", details: nil))
      return
    }

    guard let arguments = call.arguments as? [String: Any],
      let presetIndex = arguments["presetIndex"] as? Int,
      presetIndex >= 0,
      presetIndex < Self.presets.count
    else {
      result(FlutterError(code: "invalid_preset", message: "Preset index is invalid.", details: nil))
      return
    }

    bandGains = Self.presets[presetIndex].gains
    for (index, gain) in bandGains.enumerated() {
      equalizer?.bands[index].gain = gain
    }
    currentPresetIndex = presetIndex
    result(stateMap())
  }

  private func startToneAnalysis(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let arguments = call.arguments as? [String: Any]
    toneBandCount = (arguments?["bandCount"] as? Int ?? 8).clamped(to: 4...16)
    toneSampleRate = Double((arguments?["sampleRate"] as? Int ?? 44100).clamped(to: 8000...48000))

    Task { [weak self] in
      guard let self = self else {
        return
      }

      let granted = await self.microphoneAccessManager.requestMicrophoneAccess()
      await MainActor.run {
        if granted {
          self.startToneAnalysisInternal(result: result)
        } else {
          result(FlutterError(code: "permission_denied", message: "Microphone permission was denied.", details: nil))
        }
      }
    }
  }

  private func startToneAnalysisInternal(result: @escaping FlutterResult) {
    if inputEngine?.isRunning == true {
      result(nil)
      return
    }

    let engine = AVAudioEngine()
    let input = engine.inputNode
    let format = input.inputFormat(forBus: 0)
    let sampleRate = format.sampleRate > 0 ? format.sampleRate : toneSampleRate
    let bandCount = toneBandCount
    let centerFrequencies = toneFrequencies(bandCount: bandCount, sampleRate: sampleRate)

    input.removeTap(onBus: 0)
    input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
      self?.publishToneFrame(buffer: buffer, sampleRate: sampleRate, centerFrequencies: centerFrequencies)
    }

    do {
      engine.prepare()
      try engine.start()
      inputEngine = engine
      result(nil)
    } catch {
      input.removeTap(onBus: 0)
      result(FlutterError(code: "tone_start_failed", message: error.localizedDescription, details: nil))
    }
  }

  private func publishToneFrame(
    buffer: AVAudioPCMBuffer,
    sampleRate: Double,
    centerFrequencies: [Double]
  ) {
    guard let channelData = buffer.floatChannelData, buffer.frameLength > 0 else {
      return
    }

    let frameCount = Int(buffer.frameLength)
    let samples = channelData[0]
    var sumSquares = 0.0
    for index in 0..<frameCount {
      let sample = Double(samples[index])
      sumSquares += sample * sample
    }

    let rms = sqrt(sumSquares / Double(frameCount))
    let amplitude = min(max(rms * 6.0, 0.0), 1.0)
    let bands = centerFrequencies.map { frequency in
      normalizedEnergy(samples: samples, frameCount: frameCount, sampleRate: sampleRate, frequency: frequency)
    }
    let payload: [String: Any] = [
      "amplitude": amplitude,
      "bands": bands,
      "timestampMillis": Int(Date().timeIntervalSince1970 * 1000),
    ]

    DispatchQueue.main.async { [weak self] in
      self?.eventSink?(payload)
    }
  }

  private func normalizedEnergy(
    samples: UnsafePointer<Float>,
    frameCount: Int,
    sampleRate: Double,
    frequency: Double
  ) -> Double {
    var real = 0.0
    var imaginary = 0.0
    let step = 2.0 * Double.pi * frequency / sampleRate
    for index in 0..<frameCount {
      let sample = Double(samples[index])
      real += sample * cos(step * Double(index))
      imaginary -= sample * sin(step * Double(index))
    }
    let magnitude = sqrt(real * real + imaginary * imaginary) / Double(frameCount)
    return min(max(magnitude * 18.0, 0.0), 1.0)
  }

  private func toneFrequencies(bandCount: Int, sampleRate: Double) -> [Double] {
    let minHz = 90.0
    let maxHz = min(8000.0, sampleRate / 2.0)
    return (0..<bandCount).map { index in
      minHz * pow(maxHz / minHz, Double(index) / Double(max(1, bandCount - 1)))
    }
  }

  private func stopToneAnalysis() {
    inputEngine?.inputNode.removeTap(onBus: 0)
    inputEngine?.stop()
    inputEngine = nil
  }

  private func startRecording(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let arguments = call.arguments as? [String: Any],
      let filePath = arguments["filePath"] as? String,
      !filePath.isEmpty
    else {
      result(FlutterError(code: "invalid_file_path", message: "Recording requires a non-empty filePath.", details: nil))
      return
    }

    let sampleRate = Double((arguments["sampleRate"] as? Int ?? 44100).clamped(to: 8000...48000))
    Task { [weak self] in
      guard let self = self else {
        return
      }

      let granted = await self.microphoneAccessManager.requestMicrophoneAccess()
      await MainActor.run {
        if granted {
          self.startRecordingInternal(filePath: filePath, sampleRate: sampleRate, result: result)
        } else {
          result(FlutterError(code: "permission_denied", message: "Microphone permission was denied.", details: nil))
        }
      }
    }
  }

  private func startRecordingInternal(filePath: String, sampleRate: Double, result: @escaping FlutterResult) {
    guard audioRecorder == nil else {
      result(FlutterError(code: "already_recording", message: "Recording is already running.", details: nil))
      return
    }

    do {
      let url = URL(fileURLWithPath: filePath)
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      let settings: [String: Any] = [
        AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
        AVSampleRateKey: sampleRate,
        AVNumberOfChannelsKey: 1,
        AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
      ]
      let recorder = try AVAudioRecorder(url: url, settings: settings)
      recorder.prepareToRecord()
      guard recorder.record() else {
        result(FlutterError(code: "recording_start_failed", message: "AVAudioRecorder failed to start.", details: nil))
        return
      }
      audioRecorder = recorder
      recordingURL = url
      result(nil)
    } catch {
      stopRecording()
      result(FlutterError(code: "recording_start_failed", message: error.localizedDescription, details: nil))
    }
  }

  @discardableResult
  private func stopRecording() -> String? {
    let path = recordingURL?.path
    audioRecorder?.stop()
    audioRecorder = nil
    recordingURL = nil
    return path
  }

  private func stopPlayback(resetPosition: Bool) {
    guard let player = playerNode else {
      return
    }
    player.stop()
    if resetPosition {
      schedulePlaybackLoop()
    }
  }

  private func releasePlayback() {
    shouldLoopPlayback = false
    playerNode?.stop()
    playbackEngine?.stop()
    playbackEngine = nil
    playerNode = nil
    equalizer = nil
    playbackFile = nil
    currentPresetIndex = nil
    bandGains = Array(repeating: Float(0), count: Self.centerFrequencies.count)

    if let downloadedFileURL = downloadedFileURL {
      try? FileManager.default.removeItem(at: downloadedFileURL)
      self.downloadedFileURL = nil
    }
  }

  private func capabilitiesMap() -> [String: Any] {
    [
      "supportsPlaybackEqualizer": true,
      "supportsToneAnalysis": true,
      "supportsRecording": true,
      "supportsPresets": true,
      "platform": "macos",
      "bandCount": Self.centerFrequencies.count,
      "minGainDb": -15.0,
      "maxGainDb": 15.0,
    ]
  }

  private func stateMap() -> [String: Any] {
    let bands = Self.centerFrequencies.enumerated().map { index, frequency in
      [
        "index": index,
        "centerFrequencyHz": Double(frequency),
        "gainDb": Double(bandGains[index]),
        "minGainDb": -15.0,
        "maxGainDb": 15.0,
      ] as [String: Any]
    }

    let presets = Self.presets.enumerated().map { index, preset in
      [
        "index": index,
        "name": preset.name,
      ] as [String: Any]
    }

    return [
      "capabilities": capabilitiesMap(),
      "bands": bands,
      "presets": presets,
      "currentPresetIndex": currentPresetIndex as Any,
      "isPlaying": playerNode?.isPlaying == true,
    ]
  }

  public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    eventSink = events
    return nil
  }

  public func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    return nil
  }

  deinit {
    stopToneAnalysis()
    stopRecording()
    releasePlayback()
  }
}

private enum KeEqualizerError: LocalizedError {
  case assetNotFound(String)
  case invalidURL(String)
  case unsupportedSource(String)

  var errorDescription: String? {
    switch self {
    case .assetNotFound(let asset):
      return "Audio asset was not found: \(asset)."
    case .invalidURL(let value):
      return "Audio URL is invalid: \(value)."
    case .unsupportedSource(let type):
      return "Unsupported source type: \(type)."
    }
  }
}

private extension Comparable {
  func clamped(to limits: ClosedRange<Self>) -> Self {
    min(max(self, limits.lowerBound), limits.upperBound)
  }
}
