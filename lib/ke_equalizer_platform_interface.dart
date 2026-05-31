import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'ke_equalizer_method_channel.dart';
import 'src/ke_equalizer_models.dart';

abstract class KeEqualizerPlatform extends PlatformInterface {
  /// Constructs a KeEqualizerPlatform.
  KeEqualizerPlatform() : super(token: _token);

  static final Object _token = Object();

  static KeEqualizerPlatform _instance = MethodChannelKeEqualizer();

  /// The default instance of [KeEqualizerPlatform] to use.
  ///
  /// Defaults to [MethodChannelKeEqualizer].
  static KeEqualizerPlatform get instance => _instance;

  /// Platform-specific implementations should set this with their own
  /// platform-specific class that extends [KeEqualizerPlatform] when
  /// they register themselves.
  static set instance(KeEqualizerPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  Future<String?> getPlatformVersion() {
    throw UnimplementedError('platformVersion() has not been implemented.');
  }

  Future<KeEqualizerCapabilities> getCapabilities() {
    throw UnimplementedError('getCapabilities() has not been implemented.');
  }

  Future<KeEqualizerState> load(KeAudioSource source) {
    throw UnimplementedError('load() has not been implemented.');
  }

  Future<void> play() {
    throw UnimplementedError('play() has not been implemented.');
  }

  Future<void> pause() {
    throw UnimplementedError('pause() has not been implemented.');
  }

  Future<void> stop() {
    throw UnimplementedError('stop() has not been implemented.');
  }

  Future<KeEqualizerState> setBandGain({
    required int bandIndex,
    required double gainDb,
  }) {
    throw UnimplementedError('setBandGain() has not been implemented.');
  }

  Future<KeEqualizerState> setPreset(int presetIndex) {
    throw UnimplementedError('setPreset() has not been implemented.');
  }

  Future<void> startToneAnalysis({
    required int bandCount,
    required int sampleRate,
  }) {
    throw UnimplementedError('startToneAnalysis() has not been implemented.');
  }

  Future<void> stopToneAnalysis() {
    throw UnimplementedError('stopToneAnalysis() has not been implemented.');
  }

  Future<void> startRecording({
    required String filePath,
    int sampleRate = 44100,
  }) {
    throw UnimplementedError('startRecording() has not been implemented.');
  }

  Future<String?> stopRecording() {
    throw UnimplementedError('stopRecording() has not been implemented.');
  }

  Stream<KeToneFrame> get toneFrames {
    throw UnimplementedError('toneFrames has not been implemented.');
  }
}
