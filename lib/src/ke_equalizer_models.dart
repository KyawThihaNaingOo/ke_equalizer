enum KeAudioSourceType { asset, file, url }

class KeAudioSource {
  const KeAudioSource._({required this.type, required this.value});

  factory KeAudioSource.asset(String assetName) {
    return KeAudioSource._(type: KeAudioSourceType.asset, value: assetName);
  }

  factory KeAudioSource.file(String path) {
    return KeAudioSource._(type: KeAudioSourceType.file, value: path);
  }

  factory KeAudioSource.url(String url) {
    return KeAudioSource._(type: KeAudioSourceType.url, value: url);
  }

  final KeAudioSourceType type;
  final String value;

  Map<String, Object?> toMap() {
    return <String, Object?>{'type': type.name, 'value': value};
  }
}

class KeEqualizerCapabilities {
  const KeEqualizerCapabilities({
    required this.supportsPlaybackEqualizer,
    required this.supportsToneAnalysis,
    required this.supportsRecording,
    required this.supportsPresets,
    required this.platform,
    this.bandCount = 0,
    this.minGainDb = -15,
    this.maxGainDb = 15,
  });

  factory KeEqualizerCapabilities.unsupported([String platform = 'unknown']) {
    return KeEqualizerCapabilities(
      supportsPlaybackEqualizer: false,
      supportsToneAnalysis: false,
      supportsRecording: false,
      supportsPresets: false,
      platform: platform,
    );
  }

  factory KeEqualizerCapabilities.fromMap(Map<Object?, Object?> map) {
    return KeEqualizerCapabilities(
      supportsPlaybackEqualizer: map['supportsPlaybackEqualizer'] == true,
      supportsToneAnalysis: map['supportsToneAnalysis'] == true,
      supportsRecording: map['supportsRecording'] == true,
      supportsPresets: map['supportsPresets'] == true,
      platform: (map['platform'] as String?) ?? 'unknown',
      bandCount: (map['bandCount'] as num?)?.toInt() ?? 0,
      minGainDb: (map['minGainDb'] as num?)?.toDouble() ?? -15,
      maxGainDb: (map['maxGainDb'] as num?)?.toDouble() ?? 15,
    );
  }

  final bool supportsPlaybackEqualizer;
  final bool supportsToneAnalysis;
  final bool supportsRecording;
  final bool supportsPresets;
  final String platform;
  final int bandCount;
  final double minGainDb;
  final double maxGainDb;
}

class KeEqualizerBand {
  const KeEqualizerBand({
    required this.index,
    required this.centerFrequencyHz,
    required this.gainDb,
    required this.minGainDb,
    required this.maxGainDb,
  });

  factory KeEqualizerBand.fromMap(Map<Object?, Object?> map) {
    return KeEqualizerBand(
      index: (map['index'] as num).toInt(),
      centerFrequencyHz: (map['centerFrequencyHz'] as num).toDouble(),
      gainDb: (map['gainDb'] as num).toDouble(),
      minGainDb: (map['minGainDb'] as num).toDouble(),
      maxGainDb: (map['maxGainDb'] as num).toDouble(),
    );
  }

  final int index;
  final double centerFrequencyHz;
  final double gainDb;
  final double minGainDb;
  final double maxGainDb;

  KeEqualizerBand copyWith({double? gainDb}) {
    return KeEqualizerBand(
      index: index,
      centerFrequencyHz: centerFrequencyHz,
      gainDb: gainDb ?? this.gainDb,
      minGainDb: minGainDb,
      maxGainDb: maxGainDb,
    );
  }
}

class KeEqualizerPreset {
  const KeEqualizerPreset({required this.index, required this.name});

  factory KeEqualizerPreset.fromMap(Map<Object?, Object?> map) {
    return KeEqualizerPreset(
      index: (map['index'] as num).toInt(),
      name: (map['name'] as String?) ?? 'Preset',
    );
  }

  final int index;
  final String name;
}

class KeEqualizerState {
  const KeEqualizerState({
    required this.capabilities,
    required this.bands,
    required this.presets,
    this.currentPresetIndex,
    this.isPlaying = false,
  });

  factory KeEqualizerState.empty([String platform = 'unknown']) {
    return KeEqualizerState(
      capabilities: KeEqualizerCapabilities.unsupported(platform),
      bands: const <KeEqualizerBand>[],
      presets: const <KeEqualizerPreset>[],
    );
  }

  factory KeEqualizerState.fromMap(Map<Object?, Object?> map) {
    final bands = (map['bands'] as List<Object?>? ?? const <Object?>[])
        .whereType<Map<Object?, Object?>>()
        .map(KeEqualizerBand.fromMap)
        .toList(growable: false);
    final presets = (map['presets'] as List<Object?>? ?? const <Object?>[])
        .whereType<Map<Object?, Object?>>()
        .map(KeEqualizerPreset.fromMap)
        .toList(growable: false);

    return KeEqualizerState(
      capabilities: KeEqualizerCapabilities.fromMap(
        (map['capabilities'] as Map<Object?, Object?>?) ?? <Object?, Object?>{},
      ),
      bands: bands,
      presets: presets,
      currentPresetIndex: (map['currentPresetIndex'] as num?)?.toInt(),
      isPlaying: map['isPlaying'] == true,
    );
  }

  final KeEqualizerCapabilities capabilities;
  final List<KeEqualizerBand> bands;
  final List<KeEqualizerPreset> presets;
  final int? currentPresetIndex;
  final bool isPlaying;
}

class KeToneFrame {
  const KeToneFrame({
    required this.amplitude,
    required this.bands,
    required this.timestamp,
  });

  factory KeToneFrame.silent({int bandCount = 8}) {
    return KeToneFrame(
      amplitude: 0,
      bands: List<double>.filled(bandCount, 0),
      timestamp: DateTime.now(),
    );
  }

  factory KeToneFrame.fromMap(Map<Object?, Object?> map) {
    return KeToneFrame(
      amplitude: ((map['amplitude'] as num?)?.toDouble() ?? 0)
          .clamp(0, 1)
          .toDouble(),
      bands: (map['bands'] as List<Object?>? ?? const <Object?>[])
          .whereType<num>()
          .map((value) => value.toDouble().clamp(0, 1).toDouble())
          .toList(growable: false),
      timestamp: DateTime.fromMillisecondsSinceEpoch(
        (map['timestampMillis'] as num?)?.toInt() ??
            DateTime.now().millisecondsSinceEpoch,
      ),
    );
  }

  final double amplitude;
  final List<double> bands;
  final DateTime timestamp;
}
