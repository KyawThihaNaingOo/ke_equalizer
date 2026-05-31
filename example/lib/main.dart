import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ke_equalizer/ke_equalizer.dart';
import 'package:path_provider/path_provider.dart';

const _toneAnalysisBandCount = 32;
const _recorderBarCount = 72;
const _bgColor = Color(0xFF071114);
const _subtleColor = Color(0xFF9AB0B8);
const _borderColor = Color(0xFF1E3340);

void main() => runApp(const ProviderScope(child: MyApp()));

// ── State ─────────────────────────────────────────────────────────────────────

class AppState {
  const AppState({
    this.loading = true,
    this.micActive = false,
    this.recordingActive = false,
    this.saveAfterMicStop = false,
    this.capabilities,
    this.equalizerState,
    this.status,
    this.recordingPath,
  });

  final bool loading;
  final bool micActive;
  final bool recordingActive;
  final bool saveAfterMicStop;
  final KeEqualizerCapabilities? capabilities;
  final KeEqualizerState? equalizerState;
  final String? status;
  final String? recordingPath;

  AppState copyWith({
    bool? loading,
    bool? micActive,
    bool? recordingActive,
    bool? saveAfterMicStop,
    KeEqualizerCapabilities? capabilities,
    KeEqualizerState? equalizerState,
    String? status,
    String? recordingPath,
  }) => AppState(
    loading: loading ?? this.loading,
    micActive: micActive ?? this.micActive,
    recordingActive: recordingActive ?? this.recordingActive,
    saveAfterMicStop: saveAfterMicStop ?? this.saveAfterMicStop,
    capabilities: capabilities ?? this.capabilities,
    equalizerState: equalizerState ?? this.equalizerState,
    status: status ?? this.status,
    recordingPath: recordingPath ?? this.recordingPath,
  );
}

// ── Notifier ──────────────────────────────────────────────────────────────────

class AppNotifier extends Notifier<AppState> {
  late final KeEqualizer _equalizer;

  @override
  AppState build() {
    _equalizer = KeEqualizer();
    ref.onDispose(() {
      unawaited(_equalizer.stopToneAnalysis());
      unawaited(_equalizer.stopRecording());
      unawaited(_equalizer.stop());
    });
    Future.microtask(_initialize);
    return const AppState();
  }

  Future<void> _initialize() async {
    try {
      final capabilities = await _equalizer.getCapabilities();
      KeEqualizerState? equalizerState;
      String status;
      if (capabilities.supportsPlaybackEqualizer) {
        try {
          equalizerState = await _equalizer.load(
            KeAudioSource.asset('assets/demo_tone.wav'),
          );
          status = 'Demo tone loaded';
        } on PlatformException catch (e) {
          status = e.message ?? e.code;
        }
      } else {
        status = 'Playback not supported on ${capabilities.platform}';
      }
      state = state.copyWith(
        loading: false,
        capabilities: capabilities,
        equalizerState: equalizerState,
        status: status,
      );
    } on PlatformException catch (e) {
      state = state.copyWith(loading: false, status: e.message ?? e.code);
    }
  }

  Future<void> playPause() async {
    final eq = state.equalizerState;
    if (eq == null) return;
    if (eq.isPlaying) {
      await _equalizer.pause();
    } else {
      await _equalizer.play();
    }
    state = state.copyWith(
      equalizerState: KeEqualizerState(
        capabilities: eq.capabilities,
        bands: eq.bands,
        presets: eq.presets,
        currentPresetIndex: eq.currentPresetIndex,
        isPlaying: !eq.isPlaying,
      ),
      status: eq.isPlaying ? 'Paused' : 'Playing',
    );
  }

  Future<void> toggleMic() async {
    try {
      if (state.micActive) {
        await _equalizer.stopToneAnalysis();
        if (state.saveAfterMicStop && state.recordingActive) {
          final path = await _equalizer.stopRecording();
          state = state.copyWith(
            micActive: false,
            recordingActive: false,
            recordingPath: path ?? state.recordingPath,
            status: path == null ? 'Microphone stopped' : 'Saved: $path',
          );
          return;
        }
        state = state.copyWith(micActive: false, status: 'Microphone stopped');
      } else {
        await _equalizer.startToneAnalysis(bandCount: _toneAnalysisBandCount);
        if (state.saveAfterMicStop) {
          final directory = await getApplicationDocumentsDirectory();
          final timestamp = DateTime.now().millisecondsSinceEpoch;
          final filePath =
              '${directory.path}/ke_equalizer_recording_$timestamp.m4a';
          await _equalizer.startRecording(filePath: filePath);
          state = state.copyWith(
            micActive: true,
            recordingActive: true,
            recordingPath: filePath,
            status: 'Listening + recording',
          );
          return;
        }
        state = state.copyWith(micActive: true, status: 'Listening to microphone');
      }
    } on PlatformException catch (e) {
      state = state.copyWith(status: e.message ?? e.code);
    }
  }

  Future<void> setBand(KeEqualizerBand band) async {
    final previous = state.equalizerState;
    if (previous == null) return;
    state = state.copyWith(
      equalizerState: KeEqualizerState(
        capabilities: previous.capabilities,
        bands: previous.bands
            .map((b) => b.index == band.index ? band : b)
            .toList(growable: false),
        presets: previous.presets,
        currentPresetIndex: null,
        isPlaying: previous.isPlaying,
      ),
    );
    try {
      final updated = await _equalizer.setBandGain(
        bandIndex: band.index,
        gainDb: band.gainDb,
      );
      state = state.copyWith(equalizerState: updated);
    } on PlatformException catch (e) {
      state = state.copyWith(equalizerState: previous, status: e.message ?? e.code);
    }
  }

  Future<void> setPreset(KeEqualizerPreset preset) async {
    try {
      final updated = await _equalizer.setPreset(preset.index);
      state = state.copyWith(
        equalizerState: updated,
        status: 'Preset: ${preset.name}',
      );
    } on PlatformException catch (e) {
      state = state.copyWith(status: e.message ?? e.code);
    }
  }

  void setSaveAfterMicStop(bool value) =>
      state = state.copyWith(saveAfterMicStop: value);

  Stream<KeToneFrame> get toneFrames => _equalizer.toneFrames;
}

final appProvider = NotifierProvider<AppNotifier, AppState>(AppNotifier.new);

// ── App ───────────────────────────────────────────────────────────────────────

class MyApp extends ConsumerWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(appProvider);
    final notifier = ref.read(appProvider.notifier);

    final toneStream = state.capabilities?.supportsToneAnalysis == true
        ? notifier.toneFrames
        : const Stream<KeToneFrame>.empty();

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF28D394),
          brightness: Brightness.dark,
        ),
        scaffoldBackgroundColor: _bgColor,
        useMaterial3: true,
        appBarTheme: const AppBarTheme(
          backgroundColor: _bgColor,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
        ),
        tabBarTheme: const TabBarThemeData(
          dividerColor: _borderColor,
          labelColor: Color(0xFF29D39A),
          unselectedLabelColor: _subtleColor,
        ),
      ),
      home: state.loading
          ? const Scaffold(body: Center(child: CircularProgressIndicator()))
          : DefaultTabController(
              length: 2,
              child: Scaffold(
                appBar: AppBar(
                  title: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      const Text(
                        'KE Equalizer',
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
                          fontSize: 20,
                        ),
                      ),
                      if (state.status != null)
                        Text(
                          state.status!,
                          style: const TextStyle(
                            fontSize: 12,
                            color: _subtleColor,
                          ),
                        ),
                    ],
                  ),
                  bottom: const TabBar(
                    tabs: <Tab>[
                      Tab(
                        icon: Icon(Icons.equalizer_rounded),
                        text: 'Equalizer',
                      ),
                      Tab(icon: Icon(Icons.mic_rounded), text: 'Analyzer'),
                    ],
                  ),
                ),
                body: TabBarView(
                  children: <Widget>[
                    _EqualizerTab(
                      state: state.equalizerState,
                      capabilities: state.capabilities,
                      toneFrames: notifier.toneFrames,
                      onPlayPause: notifier.playPause,
                      onBandChanged: notifier.setBand,
                      onPresetSelected: notifier.setPreset,
                    ),
                    _AnalyzerTab(
                      micActive: state.micActive,
                      recordingActive: state.recordingActive,
                      saveAfterMicStop: state.saveAfterMicStop,
                      canUseMic: state.capabilities?.supportsToneAnalysis == true,
                      canRecord: state.capabilities?.supportsRecording == true,
                      recordingPath: state.recordingPath,
                      toneFrames: toneStream,
                      onToggleMic: notifier.toggleMic,
                      onSaveAfterMicStopChanged: notifier.setSaveAfterMicStop,
                    ),
                  ],
                ),
              ),
            ),
    );
  }
}

class _EqualizerTab extends StatelessWidget {
  const _EqualizerTab({
    required this.state,
    required this.capabilities,
    required this.toneFrames,
    required this.onPlayPause,
    required this.onBandChanged,
    required this.onPresetSelected,
  });

  final KeEqualizerState? state;
  final KeEqualizerCapabilities? capabilities;
  final Stream<KeToneFrame> toneFrames;
  final VoidCallback onPlayPause;
  final ValueChanged<KeEqualizerBand> onBandChanged;
  final ValueChanged<KeEqualizerPreset> onPresetSelected;

  @override
  Widget build(BuildContext context) {
    final bands = state?.bands ?? <KeEqualizerBand>[];
    final presets = state?.presets ?? <KeEqualizerPreset>[];
    final isPlaying = state?.isPlaying == true;
    final canPlay = state != null;
    final platform =
        capabilities?.platform ??
        state?.capabilities.platform ??
        'this platform';
    final supportsEQ =
        capabilities?.supportsPlaybackEqualizer ??
        state?.capabilities.supportsPlaybackEqualizer ??
        false;

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
      children: <Widget>[
        SizedBox(
          height: 96,
          child: KeEqualizerVisualizer(
            toneFrames: isPlaying
                ? toneFrames
                : const Stream<KeToneFrame>.empty(),
            style: KeVisualizerStyle.equalizer,
            barCount: 8,
            minBarHeightFactor: 0.06,
            peakDecay: 0.035,
            peakHeight: 5,
          ),
        ),
        const SizedBox(height: 16),
        SizedBox(height: 120, child: _EqCurveDisplay(bands: bands)),
        const SizedBox(height: 20),
        FilledButton.icon(
          onPressed: canPlay ? onPlayPause : null,
          icon: Icon(
            isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
          ),
          label: Text(isPlaying ? 'Pause' : 'Play'),
        ),
        if (presets.isNotEmpty) ...<Widget>[
          const SizedBox(height: 16),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: <Widget>[
                for (final preset in presets)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(preset.name),
                      selected: preset.index == state?.currentPresetIndex,
                      onSelected: (_) => onPresetSelected(preset),
                    ),
                  ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 24),
        if (bands.isNotEmpty)
          KeEqualizerControls(bands: bands, onBandChanged: onBandChanged)
        else
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              border: Border.all(color: _borderColor),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              supportsEQ
                  ? 'Equalizer controls will appear after audio loads on $platform.'
                  : 'Playback equalizer is not supported on $platform.',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
      ],
    );
  }
}

// ── EQ frequency response curve ──────────────────────────────────────────────

class _EqCurveDisplay extends StatelessWidget {
  const _EqCurveDisplay({required this.bands});
  final List<KeEqualizerBand> bands;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _EqCurvePainter(bands: bands),
      child: const SizedBox.expand(),
    );
  }
}

class _EqCurvePainter extends CustomPainter {
  const _EqCurvePainter({required this.bands});
  final List<KeEqualizerBand> bands;

  static const _activeColor = Color(0xFF29D39A);
  static const _idleColor = Color(0xFF315164);

  double _xFor(int index, double width) {
    if (bands.length <= 1) return width / 2;
    final padding = width * 0.06;
    return padding + (index / (bands.length - 1)) * (width - padding * 2);
  }

  double _yFor(double gainDb, double height) {
    final maxDb = bands.isEmpty ? 15.0 : bands.first.maxGainDb;
    return height / 2 - (gainDb / maxDb) * (height * 0.42);
  }

  @override
  void paint(Canvas canvas, Size size) {
    // background
    canvas.drawRRect(
      RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(8)),
      Paint()..color = _bgColor,
    );

    final centerY = size.height / 2;

    // dB grid lines
    for (final db in <double>[-12, -6, 0, 6, 12]) {
      final y = _yFor(db, size.height);
      canvas.drawLine(
        Offset(0, y),
        Offset(size.width, y),
        Paint()
          ..color = db == 0
              ? _idleColor.withValues(alpha: 0.55)
              : _idleColor.withValues(alpha: 0.20)
          ..strokeWidth = db == 0 ? 1.5 : 1.0,
      );
    }

    // dB labels on right
    final labelStyle = TextStyle(
      color: _idleColor.withValues(alpha: 0.6),
      fontSize: 9,
    );
    for (final db in <double>[-12, 0, 12]) {
      final y = _yFor(db, size.height);
      final span = TextSpan(
        text: db > 0 ? '+${db.toInt()}' : '${db.toInt()}',
        style: labelStyle,
      );
      final tp = TextPainter(text: span, textDirection: TextDirection.ltr)
        ..layout();
      tp.paint(canvas, Offset(size.width - tp.width - 4, y - tp.height / 2));
    }

    if (bands.isEmpty) return;

    // Band points
    final pts = List<Offset>.generate(
      bands.length,
      (i) => Offset(_xFor(i, size.width), _yFor(bands[i].gainDb, size.height)),
    );

    // Extend curve to edges at same gain as first/last band
    final all = <Offset>[
      Offset(0, pts.first.dy),
      ...pts,
      Offset(size.width, pts.last.dy),
    ];

    // Smooth path using midpoint quadratic bezier
    final curve = Path()..moveTo(all[0].dx, all[0].dy);
    for (var i = 0; i < all.length - 1; i++) {
      final mid = Offset(
        (all[i].dx + all[i + 1].dx) / 2,
        (all[i].dy + all[i + 1].dy) / 2,
      );
      if (i == 0) {
        curve.lineTo(mid.dx, mid.dy);
      } else {
        curve.quadraticBezierTo(all[i].dx, all[i].dy, mid.dx, mid.dy);
      }
    }
    curve.lineTo(all.last.dx, all.last.dy);

    // Fill between curve and 0dB line
    canvas.drawPath(
      Path.from(curve)
        ..lineTo(size.width, centerY)
        ..lineTo(0, centerY)
        ..close(),
      Paint()
        ..color = _activeColor.withValues(alpha: 0.10)
        ..style = PaintingStyle.fill,
    );

    // Curve stroke
    canvas.drawPath(
      curve,
      Paint()
        ..color = _activeColor.withValues(alpha: 0.90)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );

    // Band dots
    for (final p in pts) {
      canvas.drawCircle(p, 5.0, Paint()..color = _bgColor);
      canvas.drawCircle(p, 3.5, Paint()..color = _activeColor);
    }
  }

  @override
  bool shouldRepaint(covariant _EqCurvePainter old) {
    if (old.bands.length != bands.length) return true;
    for (var i = 0; i < bands.length; i++) {
      if (old.bands[i].gainDb != bands[i].gainDb) return true;
    }
    return false;
  }
}

class _AnalyzerTab extends StatelessWidget {
  const _AnalyzerTab({
    required this.micActive,
    required this.recordingActive,
    required this.saveAfterMicStop,
    required this.canUseMic,
    required this.canRecord,
    required this.recordingPath,
    required this.toneFrames,
    required this.onToggleMic,
    required this.onSaveAfterMicStopChanged,
  });

  final bool micActive;
  final bool recordingActive;
  final bool saveAfterMicStop;
  final bool canUseMic;
  final bool canRecord;
  final String? recordingPath;
  final Stream<KeToneFrame> toneFrames;
  final VoidCallback onToggleMic;
  final ValueChanged<bool> onSaveAfterMicStopChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          SizedBox(
            height: 200,
            child: KeEqualizerVisualizer(
              toneFrames: toneFrames,
              style: KeVisualizerStyle.soundRecorder,
              barCount: _recorderBarCount,
              minBarHeightFactor: 0.03,
              peakDecay: 0.010,
              playheadPosition: 0.5,
            ),
          ),
          const SizedBox(height: 32),
          if (canUseMic) ...<Widget>[
            FilledButton.icon(
              onPressed: onToggleMic,
              icon: Icon(micActive ? Icons.mic_off_rounded : Icons.mic_rounded),
              label: Text(micActive ? 'Stop Microphone' : 'Start Microphone'),
              style: FilledButton.styleFrom(
                backgroundColor: micActive ? Colors.red.shade700 : null,
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 14,
                ),
              ),
            ),
            CheckboxListTile(
              value: saveAfterMicStop,
              onChanged: micActive
                  ? null
                  : (v) => onSaveAfterMicStopChanged(v ?? false),
              title: const Text('Save after Microphone Stop'),
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              dense: true,
            ),
            const SizedBox(height: 12),
            Text(
              recordingActive
                  ? saveAfterMicStop
                        ? 'Recording — tap Stop Microphone to save'
                        : 'Recording microphone audio'
                  : micActive
                  ? 'Listening — speak or play audio near the microphone'
                  : recordingPath == null
                  ? 'Tap to start microphone frequency analysis'
                  : 'Last saved: $recordingPath',
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: _subtleColor),
            ),
          ] else
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                border: Border.all(color: _borderColor),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Text(
                'Microphone analysis is not supported on this platform.',
              ),
            ),
        ],
      ),
    );
  }
}
