import 'package:flutter_test/flutter_test.dart';
import 'package:ke_equalizer/ke_equalizer.dart';
import 'package:ke_equalizer/ke_equalizer_method_channel.dart';
import 'package:ke_equalizer/ke_equalizer_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class MockKeEqualizerPlatform
    with MockPlatformInterfaceMixin
    implements KeEqualizerPlatform {
  @override
  Future<String?> getPlatformVersion() => Future.value('42');

  @override
  Future<KeEqualizerCapabilities> getCapabilities() {
    return Future.value(
      const KeEqualizerCapabilities(
        supportsPlaybackEqualizer: true,
        supportsToneAnalysis: true,
        supportsRecording: true,
        supportsPresets: true,
        platform: 'test',
        bandCount: 1,
      ),
    );
  }

  @override
  Future<KeEqualizerState> load(KeAudioSource source) {
    return Future.value(_state);
  }

  @override
  Future<void> pause() async {}

  @override
  Future<void> play() async {}

  @override
  Future<KeEqualizerState> setBandGain({
    required int bandIndex,
    required double gainDb,
  }) {
    return Future.value(_state);
  }

  @override
  Future<KeEqualizerState> setPreset(int presetIndex) {
    return Future.value(_state);
  }

  @override
  Future<void> startToneAnalysis({
    required int bandCount,
    required int sampleRate,
  }) async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> stopToneAnalysis() async {}

  @override
  Future<void> startRecording({
    required String filePath,
    int sampleRate = 44100,
  }) async {}

  @override
  Future<String?> stopRecording() async => '/tmp/test.m4a';

  @override
  Stream<KeToneFrame> get toneFrames => const Stream<KeToneFrame>.empty();
}

const _state = KeEqualizerState(
  capabilities: KeEqualizerCapabilities(
    supportsPlaybackEqualizer: true,
    supportsToneAnalysis: true,
    supportsRecording: true,
    supportsPresets: true,
    platform: 'test',
    bandCount: 1,
  ),
  bands: <KeEqualizerBand>[
    KeEqualizerBand(
      index: 0,
      centerFrequencyHz: 100,
      gainDb: 0,
      minGainDb: -15,
      maxGainDb: 15,
    ),
  ],
  presets: <KeEqualizerPreset>[KeEqualizerPreset(index: 0, name: 'Normal')],
);

void main() {
  final KeEqualizerPlatform initialPlatform = KeEqualizerPlatform.instance;

  test('$MethodChannelKeEqualizer is the default instance', () {
    expect(initialPlatform, isInstanceOf<MethodChannelKeEqualizer>());
  });

  test('getPlatformVersion', () async {
    KeEqualizer keEqualizerPlugin = KeEqualizer();
    MockKeEqualizerPlatform fakePlatform = MockKeEqualizerPlatform();
    KeEqualizerPlatform.instance = fakePlatform;

    expect(await keEqualizerPlugin.getPlatformVersion(), '42');
  });

  test('getCapabilities', () async {
    KeEqualizer keEqualizerPlugin = KeEqualizer();
    MockKeEqualizerPlatform fakePlatform = MockKeEqualizerPlatform();
    KeEqualizerPlatform.instance = fakePlatform;

    final capabilities = await keEqualizerPlugin.getCapabilities();

    expect(capabilities.supportsPlaybackEqualizer, isTrue);
    expect(capabilities.platform, 'test');
  });
}
