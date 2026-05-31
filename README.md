# ke_equalizer

A Flutter plugin for native audio playback equalizer controls and live microphone/audio analysis.

The package exposes one Dart API across platforms:

- load and play an audio source
- read available equalizer capabilities
- adjust per-band gain
- apply presets
- stream tone-analysis frames for visualizers
- save microphone recordings to a caller-provided file path
- use ready-made equalizer controls and visualizer widgets

## Platform Support

| Platform | Playback EQ | Presets | Mic analyzer | Recorder save | Playback meter | Native backend |
| --- | --- | --- | --- | --- | --- | --- |
| Android | Yes | Yes | Yes | Yes | No | `MediaPlayer`, `Equalizer`, `AudioRecord`, `MediaRecorder` |
| iOS | Yes | Yes | Yes | Yes | Yes | `AVAudioEngine`, `AVAudioUnitEQ`, `AVAudioRecorder` |
| macOS | Yes | Yes | Yes | Yes | Yes | `AVAudioEngine`, `AVAudioUnitEQ`, `AVAudioRecorder` |
| Linux | Yes | Yes | Yes | No | No | GStreamer |
| Windows | No | No | Yes | No | No | WinMM microphone capture |
| Web | No | No | No | No | No | Stub implementation |

Always call `getCapabilities()` before showing native controls. The support matrix can change by OS/device/audio backend availability.

## Install

Add the package to your app:

```yaml
dependencies:
  ke_equalizer:
    path: ../ke_equalizer
```

For a published package, replace the path dependency with the package version.

## Platform Setup

### Android

For microphone analyzer support, add microphone permission to `android/app/src/main/AndroidManifest.xml`:

```xml
<uses-permission android:name="android.permission.RECORD_AUDIO" />
```

The plugin requests runtime microphone permission when `startToneAnalysis()` is called.

### iOS

No third-party audio library is required. The plugin links Apple's system
`AVFoundation.framework` through its podspec.

For microphone analyzer support, add this to `ios/Runner/Info.plist`:

```xml
<key>NSMicrophoneUsageDescription</key>
<string>Microphone access is used for live tone analysis.</string>
```

### macOS

No third-party audio library is required. The plugin links Apple's system
`AVFoundation.framework` through its podspec. You only need Xcode command line
tools and the normal Flutter macOS toolchain.

For microphone analyzer support, add this to `macos/Runner/Info.plist`:

```xml
<key>NSMicrophoneUsageDescription</key>
<string>Microphone access is used for live tone analysis.</string>
```

If your macOS app is sandboxed, add audio input entitlement:

```xml
<key>com.apple.security.device.audio-input</key>
<true/>
```

If you load audio from remote URLs in a sandboxed macOS app, also add:

```xml
<key>com.apple.security.network.client</key>
<true/>
```

### Linux

Linux uses GStreamer. Install development and runtime packages before building.

Ubuntu/Debian:

```sh
sudo apt install libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev \
  gstreamer1.0-plugins-base gstreamer1.0-plugins-good gstreamer1.0-libav
```

The Linux implementation uses:

- `playbin` for playback
- `equalizer-10bands` for EQ
- `autoaudiosrc` and `appsink` for microphone analysis

### Windows

Windows currently supports microphone analysis only. Playback EQ is not implemented.

Make sure microphone access is enabled in Windows privacy settings:

```text
Settings > Privacy & security > Microphone
```

### Web

The web implementation is a safe stub. It reports unsupported capabilities and returns empty streams/states.

## Basic Usage

```dart
import 'package:ke_equalizer/ke_equalizer.dart';

final equalizer = KeEqualizer();

Future<void> setup() async {
  final capabilities = await equalizer.getCapabilities();

  if (capabilities.supportsPlaybackEqualizer) {
    final state = await equalizer.load(
      KeAudioSource.asset('assets/song.mp3'),
    );

    await equalizer.play();

    final firstBand = state.bands.first;
    await equalizer.setBandGain(
      bandIndex: firstBand.index,
      gainDb: 4.0,
    );
  }

  if (capabilities.supportsToneAnalysis) {
    await equalizer.startToneAnalysis(bandCount: 16);
  }
}
```

## Audio Sources

```dart
KeAudioSource.asset('assets/song.mp3');
KeAudioSource.file('/absolute/path/song.mp3');
KeAudioSource.url('https://example.com/song.mp3');
```

Declare Flutter assets in your app `pubspec.yaml`:

```yaml
flutter:
  assets:
    - assets/song.mp3
```

## Equalizer UI

Use `KeEqualizerControls` with the bands returned from `load()`, `setBandGain()`, or `setPreset()`.

```dart
KeEqualizerControls(
  bands: state.bands,
  onBandChanged: (band) async {
    state = await equalizer.setBandGain(
      bandIndex: band.index,
      gainDb: band.gainDb,
    );
  },
)
```

Presets are returned in `KeEqualizerState.presets`:

```dart
for (final preset in state.presets) {
  // Show preset.name in your UI.
}

state = await equalizer.setPreset(preset.index);
```

## Visualizer

The analyzer stream emits `KeToneFrame` values:

```dart
Stream<KeToneFrame> frames = equalizer.toneFrames;
```

Use the built-in visualizer:

```dart
KeEqualizerVisualizer(
  toneFrames: equalizer.toneFrames,
  style: KeVisualizerStyle.soundRecorder,
  barCount: 72,
)
```

For playback meters on iOS/macOS, the same stream also receives frames while plugin-managed audio is playing. On Android/Linux/Windows, use microphone analysis for visualizer input.

## Recorder Save

Use `startRecording()` with an app-writable file path, then call
`stopRecording()` to finalize the file. Android, iOS, and macOS save AAC audio
in an MPEG-4/M4A container, so use a `.m4a` file extension.

```dart
final capabilities = await equalizer.getCapabilities();
if (capabilities.supportsRecording) {
  await equalizer.startRecording(
    filePath: '/path/to/recording.m4a',
  );

  // Later:
  final savedPath = await equalizer.stopRecording();
}
```

The plugin does not choose storage locations. Use your app's documents/cache
directory and pass the absolute path to `startRecording()`.

## Recommended App Flow

```dart
final equalizer = KeEqualizer();
KeEqualizerCapabilities? capabilities;
KeEqualizerState? state;

Future<void> initialize() async {
  capabilities = await equalizer.getCapabilities();

  if (capabilities!.supportsPlaybackEqualizer) {
    state = await equalizer.load(KeAudioSource.asset('assets/song.mp3'));
  }
}

Future<void> disposeEqualizer() async {
  await equalizer.stopToneAnalysis();
  await equalizer.stop();
}
```

In Flutter widgets, call `disposeEqualizer()` from `State.dispose()` using `unawaited(...)` if you do not need to await cleanup.

## Error Handling

Native methods throw `PlatformException` for invalid or unavailable operations.

Common codes:

- `invalid_source`: missing or malformed source arguments
- `unsupported_source`: unsupported source type
- `load_failed`: audio source could not be loaded
- `not_loaded`: playback/EQ method called before `load()`
- `invalid_band`: band index or gain is invalid
- `invalid_preset`: preset index is invalid
- `permission_denied`: microphone permission denied
- `audio_record_unavailable`: microphone backend unavailable
- `tone_start_failed`: analyzer backend failed to start

Example:

```dart
try {
  await equalizer.startToneAnalysis();
} on PlatformException catch (error) {
  debugPrint(error.message ?? error.code);
}
```

## Example App

Run the included example:

```sh
cd example
flutter run -d macos
flutter run -d ios
flutter run -d android
flutter run -d linux
flutter run -d windows
```

Use a full rebuild after native code changes. Hot reload does not reload native plugin code.

## macOS Release DMG

The example app can be packaged as a macOS release `.app` and installer-style
DMG. The DMG layout is defined in `example/macos/appdmg.json`.

Install `appdmg` once:

```sh
npm install -g appdmg
```

Build the release app:

```sh
cd example
flutter build macos --release
```

Create the DMG:

```sh
appdmg macos/appdmg.json build/macos/Build/Products/Release/KE-Equalizer-Example.dmg
```

Output files:

```text
example/build/macos/Build/Products/Release/KE Equalizer Example.app
example/build/macos/Build/Products/Release/KE-Equalizer-Example.dmg
```

The release app must keep these macOS microphone settings:

- `NSMicrophoneUsageDescription` in `example/macos/Runner/Info.plist`
- `com.apple.security.device.audio-input` in `example/macos/Runner/Release.entitlements`

To verify the generated release app:

```sh
plutil -p "build/macos/Build/Products/Release/KE Equalizer Example.app/Contents/Info.plist"
codesign -d --entitlements - "build/macos/Build/Products/Release/KE Equalizer Example.app"
hdiutil imageinfo build/macos/Build/Products/Release/KE-Equalizer-Example.dmg
```

## Development Notes

Run shared Dart checks:

```sh
flutter analyze
flutter test
```

Platform native builds must be verified on their own OS:

- Android: Android SDK/device or emulator
- iOS/macOS: Xcode on macOS
- Linux: Linux with GStreamer dev packages
- Windows: Visual Studio C++ toolchain on Windows

## Current Limitations

- Windows playback equalizer is not implemented yet.
- Web is unsupported by design and returns empty state/streams.
- Android playback visualizer frames are not emitted from plugin-managed playback; use microphone analysis for visualization.
- Linux playback meter frames are not emitted from playback; use microphone analysis for visualization.
- Linux requires GStreamer plugins available at runtime for the audio formats you load.
