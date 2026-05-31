import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'ke_equalizer_platform_interface.dart';
import 'src/ke_equalizer_models.dart';

/// An implementation of [KeEqualizerPlatform] that uses method channels.
class MethodChannelKeEqualizer extends KeEqualizerPlatform {
  /// The method channel used to interact with the native platform.
  @visibleForTesting
  final methodChannel = const MethodChannel('ke_equalizer');

  @visibleForTesting
  final eventChannel = const EventChannel('ke_equalizer/tone');

  Stream<KeToneFrame>? _toneFrames;

  @override
  Future<String?> getPlatformVersion() async {
    final version = await methodChannel.invokeMethod<String>(
      'getPlatformVersion',
    );
    return version;
  }

  @override
  Future<KeEqualizerCapabilities> getCapabilities() async {
    try {
      final result = await methodChannel.invokeMapMethod<Object?, Object?>(
        'getCapabilities',
      );
      return KeEqualizerCapabilities.fromMap(result ?? <Object?, Object?>{});
    } on MissingPluginException {
      return KeEqualizerCapabilities.unsupported(defaultTargetPlatform.name);
    }
  }

  @override
  Future<KeEqualizerState> load(KeAudioSource source) async {
    final result = await methodChannel.invokeMapMethod<Object?, Object?>(
      'load',
      source.toMap(),
    );
    return KeEqualizerState.fromMap(result ?? <Object?, Object?>{});
  }

  @override
  Future<void> play() {
    return methodChannel.invokeMethod<void>('play');
  }

  @override
  Future<void> pause() {
    return methodChannel.invokeMethod<void>('pause');
  }

  @override
  Future<void> stop() {
    return methodChannel.invokeMethod<void>('stop');
  }

  @override
  Future<KeEqualizerState> setBandGain({
    required int bandIndex,
    required double gainDb,
  }) async {
    final result = await methodChannel.invokeMapMethod<Object?, Object?>(
      'setBandGain',
      <String, Object?>{'bandIndex': bandIndex, 'gainDb': gainDb},
    );
    return KeEqualizerState.fromMap(result ?? <Object?, Object?>{});
  }

  @override
  Future<KeEqualizerState> setPreset(int presetIndex) async {
    final result = await methodChannel.invokeMapMethod<Object?, Object?>(
      'setPreset',
      <String, Object?>{'presetIndex': presetIndex},
    );
    return KeEqualizerState.fromMap(result ?? <Object?, Object?>{});
  }

  @override
  Future<void> startToneAnalysis({
    required int bandCount,
    required int sampleRate,
  }) {
    return methodChannel.invokeMethod<void>(
      'startToneAnalysis',
      <String, Object?>{'bandCount': bandCount, 'sampleRate': sampleRate},
    );
  }

  @override
  Future<void> stopToneAnalysis() {
    return methodChannel.invokeMethod<void>('stopToneAnalysis');
  }

  @override
  Future<void> startRecording({
    required String filePath,
    int sampleRate = 44100,
  }) {
    return methodChannel.invokeMethod<void>('startRecording', <String, Object?>{
      'filePath': filePath,
      'sampleRate': sampleRate,
    });
  }

  @override
  Future<String?> stopRecording() {
    return methodChannel.invokeMethod<String>('stopRecording');
  }

  @override
  Stream<KeToneFrame> get toneFrames {
    return _toneFrames ??= eventChannel.receiveBroadcastStream().map((event) {
      if (event is Map<Object?, Object?>) {
        return KeToneFrame.fromMap(event);
      }
      return KeToneFrame.silent();
    });
  }
}
