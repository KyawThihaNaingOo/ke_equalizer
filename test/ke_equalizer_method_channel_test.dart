import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ke_equalizer/ke_equalizer.dart';
import 'package:ke_equalizer/ke_equalizer_method_channel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  MethodChannelKeEqualizer platform = MethodChannelKeEqualizer();
  const MethodChannel channel = MethodChannel('ke_equalizer');

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
          switch (methodCall.method) {
            case 'getPlatformVersion':
              return '42';
            case 'getCapabilities':
              return <String, Object?>{
                'supportsPlaybackEqualizer': true,
                'supportsToneAnalysis': true,
                'supportsRecording': true,
                'supportsPresets': true,
                'platform': 'test',
                'bandCount': 2,
                'minGainDb': -12.0,
                'maxGainDb': 12.0,
              };
            case 'load':
            case 'setBandGain':
            case 'setPreset':
              return <String, Object?>{
                'capabilities': <String, Object?>{
                  'supportsPlaybackEqualizer': true,
                  'supportsToneAnalysis': true,
                  'supportsRecording': true,
                  'supportsPresets': true,
                  'platform': 'test',
                  'bandCount': 1,
                },
                'bands': <Object?>[
                  <String, Object?>{
                    'index': 0,
                    'centerFrequencyHz': 100.0,
                    'gainDb': 0.0,
                    'minGainDb': -12.0,
                    'maxGainDb': 12.0,
                  },
                ],
                'presets': <Object?>[
                  <String, Object?>{'index': 0, 'name': 'Normal'},
                ],
                'isPlaying': false,
              };
            case 'startRecording':
              return null;
            case 'stopRecording':
              return '/tmp/test.m4a';
          }
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('getPlatformVersion', () async {
    expect(await platform.getPlatformVersion(), '42');
  });

  test('getCapabilities', () async {
    final capabilities = await platform.getCapabilities();

    expect(capabilities.supportsToneAnalysis, isTrue);
    expect(capabilities.supportsRecording, isTrue);
    expect(capabilities.bandCount, 2);
  });

  test('load parses equalizer state', () async {
    final state = await platform.load(
      KeAudioSource.asset('assets/demo_tone.wav'),
    );

    expect(state.bands.single.centerFrequencyHz, 100);
    expect(state.presets.single.name, 'Normal');
  });

  test('recording methods call native channel', () async {
    await platform.startRecording(filePath: '/tmp/test.m4a');

    expect(await platform.stopRecording(), '/tmp/test.m4a');
  });
}
