import 'ke_equalizer_platform_interface.dart';
import 'src/ke_equalizer_models.dart';

export 'src/ke_equalizer_models.dart';
export 'src/widgets/ke_equalizer_controls.dart';
export 'src/widgets/ke_equalizer_visualizer.dart';

class KeEqualizer {
  Future<String?> getPlatformVersion() {
    return KeEqualizerPlatform.instance.getPlatformVersion();
  }

  Future<KeEqualizerCapabilities> getCapabilities() {
    return KeEqualizerPlatform.instance.getCapabilities();
  }

  Future<KeEqualizerState> load(KeAudioSource source) {
    return KeEqualizerPlatform.instance.load(source);
  }

  Future<void> play() {
    return KeEqualizerPlatform.instance.play();
  }

  Future<void> pause() {
    return KeEqualizerPlatform.instance.pause();
  }

  Future<void> stop() {
    return KeEqualizerPlatform.instance.stop();
  }

  Future<KeEqualizerState> setBandGain({
    required int bandIndex,
    required double gainDb,
  }) {
    return KeEqualizerPlatform.instance.setBandGain(
      bandIndex: bandIndex,
      gainDb: gainDb,
    );
  }

  Future<KeEqualizerState> setPreset(int presetIndex) {
    return KeEqualizerPlatform.instance.setPreset(presetIndex);
  }

  Future<void> startToneAnalysis({int bandCount = 8, int sampleRate = 44100}) {
    return KeEqualizerPlatform.instance.startToneAnalysis(
      bandCount: bandCount,
      sampleRate: sampleRate,
    );
  }

  Future<void> stopToneAnalysis() {
    return KeEqualizerPlatform.instance.stopToneAnalysis();
  }

  Future<void> startRecording({
    required String filePath,
    int sampleRate = 44100,
  }) {
    return KeEqualizerPlatform.instance.startRecording(
      filePath: filePath,
      sampleRate: sampleRate,
    );
  }

  Future<String?> stopRecording() {
    return KeEqualizerPlatform.instance.stopRecording();
  }

  Stream<KeToneFrame> get toneFrames {
    return KeEqualizerPlatform.instance.toneFrames;
  }
}
