// In order to *not* need this ignore, consider extracting the "web" version
// of your plugin as a separate package, instead of inlining it in the same
// package as the core of your plugin.
// ignore: avoid_web_libraries_in_flutter

import 'package:flutter_web_plugins/flutter_web_plugins.dart';
import 'package:web/web.dart' as web;

import 'ke_equalizer_platform_interface.dart';
import 'src/ke_equalizer_models.dart';

/// A web implementation of the KeEqualizerPlatform of the KeEqualizer plugin.
class KeEqualizerWeb extends KeEqualizerPlatform {
  /// Constructs a KeEqualizerWeb
  KeEqualizerWeb();

  static void registerWith(Registrar registrar) {
    KeEqualizerPlatform.instance = KeEqualizerWeb();
  }

  /// Returns a [String] containing the version of the platform.
  @override
  Future<String?> getPlatformVersion() async {
    final version = web.window.navigator.userAgent;
    return version;
  }

  @override
  Future<KeEqualizerCapabilities> getCapabilities() async {
    return const KeEqualizerCapabilities(
      supportsPlaybackEqualizer: false,
      supportsToneAnalysis: false,
      supportsRecording: false,
      supportsPresets: false,
      platform: 'web',
    );
  }

  @override
  Future<KeEqualizerState> load(KeAudioSource source) async {
    return KeEqualizerState.empty('web');
  }

  @override
  Future<void> play() async {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> stop() async {}

  @override
  Future<KeEqualizerState> setBandGain({
    required int bandIndex,
    required double gainDb,
  }) async {
    return KeEqualizerState.empty('web');
  }

  @override
  Future<KeEqualizerState> setPreset(int presetIndex) async {
    return KeEqualizerState.empty('web');
  }

  @override
  Future<void> startToneAnalysis({
    required int bandCount,
    required int sampleRate,
  }) async {}

  @override
  Future<void> stopToneAnalysis() async {}

  @override
  Future<void> startRecording({
    required String filePath,
    int sampleRate = 44100,
  }) async {
    throw UnsupportedError('Recording is not supported on web.');
  }

  @override
  Future<String?> stopRecording() async {
    return null;
  }

  @override
  Stream<KeToneFrame> get toneFrames => const Stream<KeToneFrame>.empty();
}
