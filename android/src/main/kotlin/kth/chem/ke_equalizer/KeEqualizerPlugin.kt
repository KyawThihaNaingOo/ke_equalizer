package kth.chem.ke_equalizer

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import android.content.res.AssetManager
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaPlayer
import android.media.MediaRecorder
import android.media.audiofx.Equalizer
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import io.flutter.plugin.common.PluginRegistry
import java.io.File
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin
import kotlin.math.sqrt

/** KeEqualizerPlugin */
class KeEqualizerPlugin :
    FlutterPlugin,
    MethodCallHandler,
    EventChannel.StreamHandler,
    ActivityAware,
    PluginRegistry.RequestPermissionsResultListener {
    private lateinit var channel: MethodChannel
    private lateinit var eventChannel: EventChannel
    private lateinit var context: Context
    private lateinit var assetManager: AssetManager
    private var flutterAssets: FlutterPlugin.FlutterAssets? = null
    private var activityBinding: ActivityPluginBinding? = null
    private var activity: Activity? = null
    private var mediaPlayer: MediaPlayer? = null
    private var equalizer: Equalizer? = null
    private var eventSink: EventChannel.EventSink? = null
    private var audioRecord: AudioRecord? = null
    private var mediaRecorder: MediaRecorder? = null
    private var recordingPath: String? = null
    private var toneThread: Thread? = null
    private var toneRunning = false
    private var pendingToneResult: Result? = null
    private var pendingToneBandCount = 8
    private var pendingToneSampleRate = 44100
    private var pendingRecordingResult: Result? = null
    private var pendingRecordingPath: String? = null
    private var pendingRecordingSampleRate = 44100
    private val mainHandler by lazy { Handler(Looper.getMainLooper()) }

    override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        context = flutterPluginBinding.applicationContext
        assetManager = flutterPluginBinding.applicationContext.assets
        flutterAssets = flutterPluginBinding.flutterAssets
        channel = MethodChannel(flutterPluginBinding.binaryMessenger, "ke_equalizer")
        channel.setMethodCallHandler(this)
        eventChannel = EventChannel(flutterPluginBinding.binaryMessenger, "ke_equalizer/tone")
        eventChannel.setStreamHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            "getPlatformVersion" -> result.success("Android ${android.os.Build.VERSION.RELEASE}")
            "getCapabilities" -> result.success(capabilitiesMap())
            "load" -> load(call, result)
            "play" -> {
                mediaPlayer?.start()
                result.success(null)
            }
            "pause" -> {
                mediaPlayer?.pause()
                result.success(null)
            }
            "stop" -> {
                mediaPlayer?.pause()
                mediaPlayer?.seekTo(0)
                result.success(null)
            }
            "setBandGain" -> setBandGain(call, result)
            "setPreset" -> setPreset(call, result)
            "startToneAnalysis" -> startToneAnalysis(call, result)
            "stopToneAnalysis" -> {
                stopToneAnalysis()
                result.success(null)
            }
            "startRecording" -> startRecording(call, result)
            "stopRecording" -> result.success(stopRecording())
            else -> result.notImplemented()
        }
    }

    private fun load(call: MethodCall, result: Result) {
        val type = call.argument<String>("type")
        val value = call.argument<String>("value")
        if (type == null || value == null) {
            result.error("invalid_source", "Audio source requires type and value.", null)
            return
        }

        try {
            releasePlayback()
            val player = MediaPlayer()
            player.setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                    .build()
            )

            when (type) {
                "asset" -> {
                    val assetKey = flutterAssets?.getAssetFilePathByName(value) ?: value
                    val afd = assetManager.openFd(assetKey)
                    afd.use {
                        player.setDataSource(it.fileDescriptor, it.startOffset, it.length)
                    }
                }
                "file" -> player.setDataSource(value)
                "url" -> player.setDataSource(value)
                else -> {
                    result.error("unsupported_source", "Unsupported source type: $type.", null)
                    return
                }
            }

            player.isLooping = true
            player.prepare()
            mediaPlayer = player
            equalizer = Equalizer(0, player.audioSessionId).also { it.enabled = true }
            result.success(stateMap())
        } catch (error: Exception) {
            releasePlayback()
            result.error("load_failed", error.message, null)
        }
    }

    private fun setBandGain(call: MethodCall, result: Result) {
        val eq = equalizer
        if (eq == null) {
            result.error("not_loaded", "Load audio before changing equalizer bands.", null)
            return
        }

        val bandIndex = call.argument<Int>("bandIndex")
        val gainDb = call.argument<Double>("gainDb")
        if (bandIndex == null || gainDb == null || bandIndex < 0 || bandIndex >= eq.numberOfBands) {
            result.error("invalid_band", "Band index or gain is invalid.", null)
            return
        }

        val range = eq.bandLevelRange
        val level = (gainDb * 100).toInt().coerceIn(range[0].toInt(), range[1].toInt())
        eq.setBandLevel(bandIndex.toShort(), level.toShort())
        result.success(stateMap())
    }

    private fun setPreset(call: MethodCall, result: Result) {
        val eq = equalizer
        if (eq == null) {
            result.error("not_loaded", "Load audio before applying presets.", null)
            return
        }

        val presetIndex = call.argument<Int>("presetIndex")
        if (presetIndex == null || presetIndex < 0 || presetIndex >= eq.numberOfPresets) {
            result.error("invalid_preset", "Preset index is invalid.", null)
            return
        }

        eq.usePreset(presetIndex.toShort())
        result.success(stateMap(presetIndex))
    }

    private fun startToneAnalysis(call: MethodCall, result: Result) {
        val bandCount = call.argument<Int>("bandCount") ?: 8
        val sampleRate = call.argument<Int>("sampleRate") ?: 44100
        pendingToneBandCount = bandCount.coerceIn(4, 16)
        pendingToneSampleRate = sampleRate.coerceIn(8000, 48000)

        if (context.checkSelfPermission(Manifest.permission.RECORD_AUDIO) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            val currentActivity = activity
            if (currentActivity == null) {
                result.error("permission_required", "Microphone permission is required.", null)
                return
            }
            pendingToneResult = result
            currentActivity.requestPermissions(
                arrayOf(Manifest.permission.RECORD_AUDIO),
                RECORD_AUDIO_REQUEST
            )
            return
        }

        startToneAnalysisInternal(result)
    }

    private fun startToneAnalysisInternal(result: Result?) {
        if (toneRunning) {
            result?.success(null)
            return
        }

        val channelConfig = AudioFormat.CHANNEL_IN_MONO
        val audioFormat = AudioFormat.ENCODING_PCM_16BIT
        val minBufferSize = AudioRecord.getMinBufferSize(
            pendingToneSampleRate,
            channelConfig,
            audioFormat
        )

        if (minBufferSize <= 0) {
            result?.error("audio_record_unavailable", "AudioRecord is not available.", null)
            return
        }

        try {
            val record = AudioRecord(
                MediaRecorder.AudioSource.MIC,
                pendingToneSampleRate,
                channelConfig,
                audioFormat,
                max(minBufferSize, 2048)
            )

            if (record.state != AudioRecord.STATE_INITIALIZED) {
                record.release()
                result?.error("audio_record_unavailable", "AudioRecord failed to initialize.", null)
                return
            }

            audioRecord = record
            toneRunning = true
            toneThread = Thread {
                runToneLoop(record, pendingToneBandCount, pendingToneSampleRate)
            }.also {
                it.name = "KeEqualizerToneAnalysis"
                it.start()
            }
            result?.success(null)
        } catch (error: SecurityException) {
            result?.error("permission_required", error.message, null)
        } catch (error: Exception) {
            result?.error("tone_start_failed", error.message, null)
        }
    }

    private fun runToneLoop(record: AudioRecord, bandCount: Int, sampleRate: Int) {
        val readSize = 1024
        val buffer = ShortArray(readSize)
        val centerFrequencies = DoubleArray(bandCount) { index ->
            val minHz = 90.0
            val maxHz = min(8000.0, sampleRate / 2.0)
            minHz * Math.pow(maxHz / minHz, index.toDouble() / max(1, bandCount - 1).toDouble())
        }

        try {
            record.startRecording()
            while (toneRunning) {
                val read = record.read(buffer, 0, buffer.size)
                if (read <= 0) continue

                var sumSquares = 0.0
                for (index in 0 until read) {
                    val sample = buffer[index] / 32768.0
                    sumSquares += sample * sample
                }
                val rms = sqrt(sumSquares / read)
                val amplitude = (rms * 6.0).coerceIn(0.0, 1.0)
                val bands = centerFrequencies.map { frequency ->
                    normalizedEnergy(buffer, read, sampleRate, frequency)
                }

                val payload = mapOf(
                    "amplitude" to amplitude,
                    "bands" to bands,
                    "timestampMillis" to System.currentTimeMillis()
                )
                mainHandler.post { eventSink?.success(payload) }
            }
        } finally {
            try {
                if (record.recordingState == AudioRecord.RECORDSTATE_RECORDING) {
                    record.stop()
                }
            } catch (_: Exception) {
            }
            record.release()
        }
    }

    private fun normalizedEnergy(
        buffer: ShortArray,
        read: Int,
        sampleRate: Int,
        frequency: Double
    ): Double {
        var real = 0.0
        var imaginary = 0.0
        val step = 2.0 * PI * frequency / sampleRate
        for (index in 0 until read) {
            val sample = buffer[index] / 32768.0
            real += sample * cos(step * index)
            imaginary -= sample * sin(step * index)
        }
        val magnitude = sqrt(real * real + imaginary * imaginary) / read
        return (magnitude * 18.0).coerceIn(0.0, 1.0)
    }

    private fun stopToneAnalysis() {
        toneRunning = false
        toneThread?.join(250)
        toneThread = null
        audioRecord = null
    }

    private fun startRecording(call: MethodCall, result: Result) {
        val filePath = call.argument<String>("filePath")
        if (filePath.isNullOrBlank()) {
            result.error("invalid_file_path", "Recording requires a non-empty filePath.", null)
            return
        }

        val sampleRate = (call.argument<Int>("sampleRate") ?: 44100).coerceIn(8000, 48000)
        if (context.checkSelfPermission(Manifest.permission.RECORD_AUDIO) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            val currentActivity = activity
            if (currentActivity == null) {
                result.error("permission_required", "Microphone permission is required.", null)
                return
            }
            pendingRecordingResult = result
            pendingRecordingPath = filePath
            pendingRecordingSampleRate = sampleRate
            currentActivity.requestPermissions(
                arrayOf(Manifest.permission.RECORD_AUDIO),
                RECORD_AUDIO_REQUEST
            )
            return
        }

        startRecordingInternal(filePath, sampleRate, result)
    }

    private fun startRecordingInternal(filePath: String, sampleRate: Int, result: Result?) {
        if (mediaRecorder != null) {
            result?.error("already_recording", "Recording is already running.", null)
            return
        }

        try {
            val file = File(filePath)
            file.parentFile?.mkdirs()

            val recorder = MediaRecorder().apply {
                setAudioSource(MediaRecorder.AudioSource.MIC)
                setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
                setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
                setAudioSamplingRate(sampleRate)
                setAudioEncodingBitRate(128000)
                setOutputFile(file.absolutePath)
                prepare()
                start()
            }

            mediaRecorder = recorder
            recordingPath = file.absolutePath
            result?.success(null)
        } catch (error: SecurityException) {
            result?.error("permission_required", error.message, null)
        } catch (error: Exception) {
            releaseRecorder()
            result?.error("recording_start_failed", error.message, null)
        }
    }

    private fun stopRecording(): String? {
        val path = recordingPath
        val recorder = mediaRecorder ?: return path

        try {
            recorder.stop()
        } catch (_: Exception) {
        } finally {
            releaseRecorder()
        }

        return path
    }

    private fun releaseRecorder() {
        try {
            mediaRecorder?.reset()
        } catch (_: Exception) {
        }
        try {
            mediaRecorder?.release()
        } catch (_: Exception) {
        }
        mediaRecorder = null
        recordingPath = null
    }

    private fun capabilitiesMap(): Map<String, Any?> {
        val range = equalizer?.bandLevelRange
        return mapOf(
            "supportsPlaybackEqualizer" to true,
            "supportsToneAnalysis" to true,
            "supportsRecording" to true,
            "supportsPresets" to true,
            "platform" to "android",
            "bandCount" to (equalizer?.numberOfBands?.toInt() ?: 0),
            "minGainDb" to ((range?.get(0)?.toDouble() ?: -1500.0) / 100.0),
            "maxGainDb" to ((range?.get(1)?.toDouble() ?: 1500.0) / 100.0)
        )
    }

    private fun stateMap(currentPresetIndex: Int? = null): Map<String, Any?> {
        val eq = equalizer
        val range = eq?.bandLevelRange
        val minGain = ((range?.get(0)?.toDouble() ?: -1500.0) / 100.0)
        val maxGain = ((range?.get(1)?.toDouble() ?: 1500.0) / 100.0)
        val bandCount = eq?.numberOfBands?.toInt() ?: 0
        val bands = (0 until bandCount).map { index ->
            val shortIndex = index.toShort()
            mapOf(
                "index" to index,
                "centerFrequencyHz" to ((eq?.getCenterFreq(shortIndex)?.toDouble() ?: 0.0) / 1000.0),
                "gainDb" to ((eq?.getBandLevel(shortIndex)?.toDouble() ?: 0.0) / 100.0),
                "minGainDb" to minGain,
                "maxGainDb" to maxGain
            )
        }
        val presetCount = eq?.numberOfPresets?.toInt() ?: 0
        val presets = (0 until presetCount).map { index ->
            mapOf(
                "index" to index,
                "name" to (eq?.getPresetName(index.toShort()) ?: "Preset ${index + 1}")
            )
        }

        return mapOf(
            "capabilities" to capabilitiesMap(),
            "bands" to bands,
            "presets" to presets,
            "currentPresetIndex" to currentPresetIndex,
            "isPlaying" to (mediaPlayer?.isPlaying == true)
        )
    }

    private fun releasePlayback() {
        equalizer?.release()
        equalizer = null
        mediaPlayer?.release()
        mediaPlayer = null
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activityBinding = binding
        activity = binding.activity
        binding.addRequestPermissionsResultListener(this)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        activityBinding?.removeRequestPermissionsResultListener(this)
        activityBinding = null
        activity = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        onAttachedToActivity(binding)
    }

    override fun onDetachedFromActivity() {
        activityBinding?.removeRequestPermissionsResultListener(this)
        activityBinding = null
        activity = null
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ): Boolean {
        if (requestCode != RECORD_AUDIO_REQUEST) return false

        val result = pendingToneResult
        val recordingResult = pendingRecordingResult
        pendingToneResult = null
        pendingRecordingResult = null
        if (grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED) {
            if (result != null) {
                startToneAnalysisInternal(result)
            }
            if (recordingResult != null) {
                startRecordingInternal(
                    pendingRecordingPath ?: "",
                    pendingRecordingSampleRate,
                    recordingResult
                )
            }
        } else {
            result?.error("permission_denied", "Microphone permission was denied.", null)
            recordingResult?.error("permission_denied", "Microphone permission was denied.", null)
        }
        pendingRecordingPath = null
        return true
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
        stopToneAnalysis()
        stopRecording()
        releasePlayback()
    }

    private companion object {
        const val RECORD_AUDIO_REQUEST = 9417
    }
}
