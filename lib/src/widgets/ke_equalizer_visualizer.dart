import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../ke_equalizer_models.dart';

enum KeVisualizerStyle { equalizer, soundRecorder }

class KeEqualizerVisualizer extends StatefulWidget {
  const KeEqualizerVisualizer({
    super.key,
    required this.toneFrames,
    this.style = KeVisualizerStyle.equalizer,
    this.barCount = 8,
    this.minBarHeightFactor = 0.08,
    this.barRadius = 6,
    this.activeColor = const Color(0xFF29D39A),
    this.idleColor = const Color(0xFF315164),
    this.peakColor = const Color(0xFFF8D66D),
    this.backgroundColor = const Color(0xFF071114),
    this.showPeaks = true,
    this.peakDecay = 0.08,
    this.peakHeight = 4,
    this.duration = const Duration(milliseconds: 120),
    this.playheadPosition = 0.5,
  });

  final Stream<KeToneFrame> toneFrames;
  final KeVisualizerStyle style;
  final int barCount;
  final double minBarHeightFactor;
  final double barRadius;
  final Color activeColor;
  final Color idleColor;
  final Color peakColor;
  final Color backgroundColor;
  final bool showPeaks;
  final double peakDecay;
  final double peakHeight;
  final Duration duration;

  /// Fraction of the width where the playhead sits (soundRecorder only).
  /// 0.5 = centre. Bars scroll left past this point; right side stays idle.
  final double playheadPosition;

  @override
  State<KeEqualizerVisualizer> createState() => _KeEqualizerVisualizerState();
}

class _KeEqualizerVisualizerState extends State<KeEqualizerVisualizer> {
  KeToneFrame? _latestFrame;
  List<double> _peakLevels = const <double>[];
  List<double> _recorderLevels = const <double>[];

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<KeToneFrame>(
      stream: widget.toneFrames,
      initialData:
          _latestFrame ?? KeToneFrame.silent(bandCount: widget.barCount),
      builder: (context, snapshot) {
        final frame =
            snapshot.data ?? KeToneFrame.silent(bandCount: widget.barCount);
        _latestFrame = frame;
        if (widget.style == KeVisualizerStyle.soundRecorder) {
          _updateRecorderPeaks(frame);
        } else {
          _updateEqualizerPeaks(frame);
        }

        return TweenAnimationBuilder<double>(
          tween: Tween<double>(begin: 0, end: frame.amplitude),
          duration: widget.duration,
          curve: Curves.easeOutCubic,
          builder: (context, amplitude, child) {
            return CustomPaint(
              painter: _KeEqualizerPainter(
                bands: frame.bands,
                barCount: widget.barCount,
                style: widget.style,
                amplitude: amplitude,
                minBarHeightFactor: widget.minBarHeightFactor,
                barRadius: widget.barRadius,
                activeColor: widget.activeColor,
                idleColor: widget.idleColor,
                peakColor: widget.peakColor,
                backgroundColor: widget.backgroundColor,
                peakLevels: _peakLevels,
                recorderLevels: _recorderLevels,
                showPeaks: widget.showPeaks,
                peakHeight: widget.peakHeight,
                playheadPosition: widget.playheadPosition,
              ),
              child: child,
            );
          },
          child: const SizedBox.expand(),
        );
      },
    );
  }

  void _updateEqualizerPeaks(KeToneFrame frame) {
    if (_peakLevels.length != widget.barCount) {
      _peakLevels = List<double>.filled(widget.barCount, 0);
    }

    final nextPeaks = List<double>.of(_peakLevels);
    for (var index = 0; index < widget.barCount; index++) {
      final rawLevel = index < frame.bands.length
          ? frame.bands[index]
          : frame.amplitude;
      final shapedLevel = (rawLevel * 0.78 + frame.amplitude * 0.22).clamp(
        0.0,
        1.0,
      );
      if (shapedLevel >= nextPeaks[index]) {
        nextPeaks[index] = shapedLevel;
      } else {
        nextPeaks[index] = math.max(0, nextPeaks[index] - widget.peakDecay);
      }
    }
    _peakLevels = nextPeaks;
  }

  void _updateRecorderPeaks(KeToneFrame frame) {
    if (_recorderLevels.length != widget.barCount) {
      _recorderLevels = List<double>.filled(widget.barCount, 0);
      _peakLevels = List<double>.filled(widget.barCount, 0);
    }

    final maxBand = frame.bands.isEmpty ? 0.0 : frame.bands.reduce(math.max);
    final level = (frame.amplitude * 0.68 + maxBand * 0.32).clamp(0.0, 1.0);
    final shapedLevel = Curves.easeOutCubic.transform(level);
    final history = List<double>.of(_recorderLevels)
      ..removeAt(0)
      ..add(shapedLevel);
    final peaks = List<double>.of(_peakLevels)
      ..removeAt(0)
      ..add(shapedLevel);

    for (var index = 0; index < peaks.length - 1; index++) {
      peaks[index] = math.max(0, peaks[index] - widget.peakDecay * 0.72);
    }

    _recorderLevels = history;
    _peakLevels = peaks;
  }
}

class _KeEqualizerPainter extends CustomPainter {
  const _KeEqualizerPainter({
    required this.bands,
    required this.barCount,
    required this.style,
    required this.amplitude,
    required this.minBarHeightFactor,
    required this.barRadius,
    required this.activeColor,
    required this.idleColor,
    required this.peakColor,
    required this.backgroundColor,
    required this.peakLevels,
    required this.recorderLevels,
    required this.showPeaks,
    required this.peakHeight,
    required this.playheadPosition,
  });

  final List<double> bands;
  final int barCount;
  final KeVisualizerStyle style;
  final double amplitude;
  final double minBarHeightFactor;
  final double barRadius;
  final Color activeColor;
  final Color idleColor;
  final Color peakColor;
  final Color backgroundColor;
  final List<double> peakLevels;
  final List<double> recorderLevels;
  final bool showPeaks;
  final double peakHeight;
  final double playheadPosition;

  @override
  void paint(Canvas canvas, Size size) {
    final background = Paint()..color = backgroundColor;
    canvas.drawRRect(
      RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(8)),
      background,
    );

    if (barCount <= 0 || size.width <= 0 || size.height <= 0) return;

    final gap = math.max(2.0, size.width * 0.012);
    final barWidth = math.max(
      2.0,
      (size.width - gap * (barCount - 1)) / barCount,
    );
    final paint = Paint();

    if (style == KeVisualizerStyle.soundRecorder) {
      _paintSoundRecorder(canvas, size, barWidth, gap, paint);
      return;
    }

    for (var index = 0; index < barCount; index++) {
      final rawLevel = index < bands.length ? bands[index] : amplitude;
      final shapedLevel = (rawLevel * 0.78 + amplitude * 0.22).clamp(0.0, 1.0);
      final heightFactor =
          minBarHeightFactor +
          (1 - minBarHeightFactor) * Curves.easeOut.transform(shapedLevel);
      final barHeight = size.height * heightFactor;
      final left = index * (barWidth + gap);
      final top = (size.height - barHeight) / 2;
      final colorT = (0.2 + shapedLevel * 0.8).clamp(0.0, 1.0);
      paint.color = Color.lerp(idleColor, activeColor, colorT)!;

      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(left, top, barWidth, barHeight),
          Radius.circular(barRadius),
        ),
        paint,
      );

      if (showPeaks && index < peakLevels.length) {
        final peakLevel = peakLevels[index].clamp(0.0, 1.0);
        final peakHeightFactor =
            minBarHeightFactor +
            (1 - minBarHeightFactor) * Curves.easeOut.transform(peakLevel);
        final peakBarHeight = size.height * peakHeightFactor;
        final peakTop = (size.height - peakBarHeight) / 2;
        final peakBottom = peakTop + peakBarHeight;
        final markerHeight = math.min(
          peakHeight,
          math.max(2.0, barWidth * 0.5),
        );
        paint.color = peakColor.withValues(alpha: 0.72 + peakLevel * 0.28);
        // top peak marker
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(left, peakTop, barWidth, markerHeight),
            Radius.circular(markerHeight / 2),
          ),
          paint,
        );
        // bottom peak marker (bars grow from centre, so mirror it)
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(
              left,
              peakBottom - markerHeight,
              barWidth,
              markerHeight,
            ),
            Radius.circular(markerHeight / 2),
          ),
          paint,
        );
      }
    }
  }

  void _paintSoundRecorder(
    Canvas canvas,
    Size size,
    double barWidth,
    double gap,
    Paint paint,
  ) {
    final centerY = size.height / 2;
    final playheadX = size.width * playheadPosition.clamp(0.1, 0.9);
    final maxHalfHeight = size.height * 0.44;
    final minHalfHeight = size.height * minBarHeightFactor * 0.5;
    final visualBarWidth = math.max(2.0, barWidth * 0.72);
    final inset = (barWidth - visualBarWidth) / 2;
    final step = barWidth + gap;

    // ── centre baseline ──────────────────────────────────────────────────────
    canvas.drawLine(
      Offset(0, centerY),
      Offset(size.width, centerY),
      Paint()
        ..color = idleColor.withValues(alpha: 0.22)
        ..strokeWidth = 1,
    );

    // ── idle bars to the RIGHT of the playhead (future / silence) ────────────
    var rightX = playheadX + step;
    while (rightX + visualBarWidth <= size.width) {
      paint.color = idleColor.withValues(alpha: 0.14);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(
            rightX + inset,
            centerY - minHalfHeight,
            visualBarWidth,
            minHalfHeight * 2,
          ),
          Radius.circular(barRadius),
        ),
        paint,
      );
      rightX += step;
    }

    // ── recorded bars anchored at playhead, scrolling left ───────────────────
    // recorderLevels[barCount-1] = newest sample → drawn AT playheadX
    // recorderLevels[barCount-2] = one step older  → drawn one step left
    for (var i = 0; i < barCount; i++) {
      final stepsFromPlayhead = barCount - 1 - i; // 0 = newest
      final left = playheadX - stepsFromPlayhead * step;

      if (left + barWidth < 0) continue; // scrolled off the left edge
      if (left > playheadX) continue; // never draw past playhead

      final level = i < recorderLevels.length
          ? recorderLevels[i].clamp(0.0, 1.0)
          : 0.0;
      final peakLevel = i < peakLevels.length
          ? peakLevels[i].clamp(0.0, 1.0)
          : level;

      final halfHeight = minHalfHeight + maxHalfHeight * level;
      final peakHalfHeight = minHalfHeight + maxHalfHeight * peakLevel;
      final colorT = (0.25 + level * 0.75).clamp(0.0, 1.0);

      // peak shadow
      if (showPeaks && peakLevel > level) {
        paint.color = peakColor.withValues(alpha: 0.15 + peakLevel * 0.20);
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(
              left + inset,
              centerY - peakHalfHeight,
              visualBarWidth,
              peakHalfHeight * 2,
            ),
            Radius.circular(barRadius),
          ),
          paint,
        );
      }

      // main bar (grows symmetrically from centre)
      paint.color = Color.lerp(idleColor, activeColor, colorT)!;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(
            left + inset,
            centerY - halfHeight,
            visualBarWidth,
            halfHeight * 2,
          ),
          Radius.circular(barRadius),
        ),
        paint,
      );

      // peak markers — top and bottom
      if (showPeaks && peakLevel > 0.10) {
        final markerH = math.min(
          peakHeight,
          math.max(2.0, visualBarWidth * 0.5),
        );
        paint.color = peakColor.withValues(alpha: 0.55 + peakLevel * 0.40);
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(
              left + inset,
              centerY - peakHalfHeight,
              visualBarWidth,
              markerH,
            ),
            Radius.circular(markerH / 2),
          ),
          paint,
        );
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(
              left + inset,
              centerY + peakHalfHeight - markerH,
              visualBarWidth,
              markerH,
            ),
            Radius.circular(markerH / 2),
          ),
          paint,
        );
      }
    }

    // ── playhead cursor ───────────────────────────────────────────────────────
    canvas.drawLine(
      Offset(playheadX, 0),
      Offset(playheadX, size.height),
      Paint()
        ..color = activeColor.withValues(alpha: 0.85)
        ..strokeWidth = 2.0,
    );
    // dot at centre of playhead
    canvas.drawCircle(
      Offset(playheadX, centerY),
      4.5,
      Paint()..color = activeColor,
    );
  }

  @override
  bool shouldRepaint(covariant _KeEqualizerPainter oldDelegate) {
    return oldDelegate.bands != bands ||
        oldDelegate.amplitude != amplitude ||
        oldDelegate.barCount != barCount ||
        oldDelegate.style != style ||
        oldDelegate.activeColor != activeColor ||
        oldDelegate.idleColor != idleColor ||
        oldDelegate.peakColor != peakColor ||
        oldDelegate.peakLevels != peakLevels ||
        oldDelegate.recorderLevels != recorderLevels ||
        oldDelegate.showPeaks != showPeaks ||
        oldDelegate.backgroundColor != backgroundColor ||
        oldDelegate.playheadPosition != playheadPosition;
  }
}
