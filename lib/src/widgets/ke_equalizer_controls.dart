import 'package:flutter/material.dart';

import '../ke_equalizer_models.dart';

class KeEqualizerControls extends StatelessWidget {
  const KeEqualizerControls({
    super.key,
    required this.bands,
    required this.onBandChanged,
    this.enabled = true,
    this.activeColor,
  });

  final List<KeEqualizerBand> bands;
  final ValueChanged<KeEqualizerBand> onBandChanged;
  final bool enabled;
  final Color? activeColor;

  @override
  Widget build(BuildContext context) {
    final color = activeColor ?? Theme.of(context).colorScheme.primary;

    if (bands.isEmpty) {
      return const SizedBox.shrink();
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 420;

        return Wrap(
          spacing: compact ? 10 : 14,
          runSpacing: 12,
          alignment: WrapAlignment.center,
          children: <Widget>[
            for (final band in bands)
              SizedBox(
                width: compact ? 44 : 54,
                height: compact ? 188 : 218,
                child: Column(
                  children: <Widget>[
                    Expanded(
                      child: RotatedBox(
                        quarterTurns: -1,
                        child: SliderTheme(
                          data: SliderTheme.of(context).copyWith(
                            activeTrackColor: color,
                            thumbColor: color,
                            trackHeight: 5,
                          ),
                          child: Slider(
                            value: band.gainDb.clamp(
                              band.minGainDb,
                              band.maxGainDb,
                            ),
                            min: band.minGainDb,
                            max: band.maxGainDb,
                            onChanged: enabled
                                ? (value) => onBandChanged(
                                    band.copyWith(gainDb: value),
                                  )
                                : null,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _formatFrequency(band.centerFrequencyHz),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                    Text(
                      '${band.gainDb.toStringAsFixed(1)} dB',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }

  String _formatFrequency(double value) {
    if (value >= 1000) {
      return '${(value / 1000).toStringAsFixed(value >= 10000 ? 0 : 1)}k';
    }
    return value.toStringAsFixed(0);
  }
}
