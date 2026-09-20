// lib/models/audiobook_models.dart — data models for multi-voice audiobook creation.

import 'dart:convert';

/// Status of an individual line or chapter rendering.
enum AudiobookRenderStatus {
  idle,
  casting,
  synthesizing,
  ready,
  error,
}

/// Character speaker definition.
class AudiobookSpeaker {
  final String id;
  final String name;
  final String voiceModelName; // e.g. 'kokoro-voice-ff_siwis', 'qwen3-ethan', etc.
  final String role; // 'narrator', 'male', 'female', 'child', 'custom'
  final double speed; // default 1.0
  final double pitch; // default 1.0
  final double volume; // default 1.0
  final String? presetName;
  final String? customVoiceWavPath;
  final String? customVoiceRefText;

  const AudiobookSpeaker({
    required this.id,
    required this.name,
    required this.voiceModelName,
    this.role = 'narrator',
    this.speed = 1.0,
    this.pitch = 1.0,
    this.volume = 1.0,
    this.presetName,
    this.customVoiceWavPath,
    this.customVoiceRefText,
  });

  AudiobookSpeaker copyWith({
    String? id,
    String? name,
    String? voiceModelName,
    String? role,
    double? speed,
    double? pitch,
    double? volume,
    String? presetName,
    String? customVoiceWavPath,
    String? customVoiceRefText,
  }) {
    return AudiobookSpeaker(
      id: id ?? this.id,
      name: name ?? this.name,
      voiceModelName: voiceModelName ?? this.voiceModelName,
      role: role ?? this.role,
      speed: speed ?? this.speed,
      pitch: pitch ?? this.pitch,
      volume: volume ?? this.volume,
      presetName: presetName ?? this.presetName,
      customVoiceWavPath: customVoiceWavPath ?? this.customVoiceWavPath,
      customVoiceRefText: customVoiceRefText ?? this.customVoiceRefText,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'voiceModelName': voiceModelName,
        'role': role,
        'speed': speed,
        'pitch': pitch,
        'volume': volume,
        'presetName': presetName,
        'customVoiceWavPath': customVoiceWavPath,
        'customVoiceRefText': customVoiceRefText,
      };

  factory AudiobookSpeaker.fromJson(Map<String, dynamic> json) =>
      AudiobookSpeaker(
        id: json['id'] as String? ?? 'narrator',
        name: json['name'] as String? ?? 'Narrateur',
        voiceModelName: json['voiceModelName'] as String? ?? 'kokoro-voice-ff_siwis',
        role: json['role'] as String? ?? 'narrator',
        speed: (json['speed'] as num?)?.toDouble() ?? 1.0,
        pitch: (json['pitch'] as num?)?.toDouble() ?? 1.0,
        volume: (json['volume'] as num?)?.toDouble() ?? 1.0,
        presetName: json['presetName'] as String?,
        customVoiceWavPath: json['customVoiceWavPath'] as String?,
        customVoiceRefText: json['customVoiceRefText'] as String?,
      );
}

/// A reusable saved voice tuning preset.
class VoicePreset {
  final String id;
  final String name;
  final String voiceModelName;
  final double speed;
  final double pitch;
  final double volume;

  const VoicePreset({
    required this.id,
    required this.name,
    required this.voiceModelName,
    this.speed = 1.0,
    this.pitch = 1.0,
    this.volume = 1.0,
  });

  VoicePreset copyWith({
    String? id,
    String? name,
    String? voiceModelName,
    double? speed,
    double? pitch,
    double? volume,
  }) {
    return VoicePreset(
      id: id ?? this.id,
      name: name ?? this.name,
      voiceModelName: voiceModelName ?? this.voiceModelName,
      speed: speed ?? this.speed,
      pitch: pitch ?? this.pitch,
      volume: volume ?? this.volume,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'voiceModelName': voiceModelName,
        'speed': speed,
        'pitch': pitch,
        'volume': volume,
      };

  factory VoicePreset.fromJson(Map<String, dynamic> json) => VoicePreset(
        id: json['id'] as String? ?? '',
        name: json['name'] as String? ?? 'Preset',
        voiceModelName: json['voiceModelName'] as String? ?? 'kokoro-voice-ff_siwis',
        speed: (json['speed'] as num?)?.toDouble() ?? 1.0,
        pitch: (json['pitch'] as num?)?.toDouble() ?? 1.0,
        volume: (json['volume'] as num?)?.toDouble() ?? 1.0,
      );

  static const List<VoicePreset> defaultPresets = [
    VoicePreset(
      id: 'narrator_standard',
      name: '📖 Narrateur Posé (Oncle Fu - 1.0x)',
      voiceModelName: 'qwen3-uncle_fu',
      speed: 1.0,
      pitch: 1.0,
      volume: 1.0,
    ),
    VoicePreset(
      id: 'narrator_slow_deep',
      name: '🎙️ Narrateur Grave & Profond (Eric - 0.92x)',
      voiceModelName: 'qwen3-eric',
      speed: 0.92,
      pitch: 0.92,
      volume: 1.0,
    ),
    VoicePreset(
      id: 'male_deep_hero',
      name: '👨 Héros Homme Dynamique (Ryan - 1.05x)',
      voiceModelName: 'qwen3-ryan',
      speed: 1.05,
      pitch: 0.95,
      volume: 1.0,
    ),
    VoicePreset(
      id: 'female_soft_heroine',
      name: '👩 Héroïne Douce & Expressive (Vivian - 0.98x)',
      voiceModelName: 'qwen3-vivian',
      speed: 0.98,
      pitch: 1.05,
      volume: 1.0,
    ),
    VoicePreset(
      id: 'female_warm_story',
      name: '👩 Conteuse Chaleureuse (Anna - 0.95x)',
      voiceModelName: 'qwen3-ono_anna',
      speed: 0.95,
      pitch: 1.0,
      volume: 1.0,
    ),
  ];
}

/// Character-level style span (color, highlight, bold, italic) applied cleanly without embedding markup tags into the text.
class AudiobookStyleSpan {
  final int start;
  final int end;
  final String? colorHex;
  final String? highlightHex;
  final bool isBold;
  final bool isItalic;

  const AudiobookStyleSpan({
    required this.start,
    required this.end,
    this.colorHex,
    this.highlightHex,
    this.isBold = false,
    this.isItalic = false,
  });

  AudiobookStyleSpan copyWith({
    int? start,
    int? end,
    String? colorHex,
    String? highlightHex,
    bool? isBold,
    bool? isItalic,
  }) {
    return AudiobookStyleSpan(
      start: start ?? this.start,
      end: end ?? this.end,
      colorHex: colorHex ?? this.colorHex,
      highlightHex: highlightHex ?? this.highlightHex,
      isBold: isBold ?? this.isBold,
      isItalic: isItalic ?? this.isItalic,
    );
  }

  Map<String, dynamic> toJson() => {
        'start': start,
        'end': end,
        'colorHex': colorHex,
        'highlightHex': highlightHex,
        'isBold': isBold,
        'isItalic': isItalic,
      };

  factory AudiobookStyleSpan.fromJson(Map<String, dynamic> json) =>
      AudiobookStyleSpan(
        start: (json['start'] as num?)?.toInt() ?? 0,
        end: (json['end'] as num?)?.toInt() ?? 0,
        colorHex: json['colorHex'] as String?,
        highlightHex: json['highlightHex'] as String?,
        isBold: json['isBold'] as bool? ?? false,
        isItalic: json['isItalic'] as bool? ?? false,
      );
}

/// A single spoken line or narrative sentence.
class AudiobookLine {
  final String id;
  final String speakerId;
  final String speakerName;
  final String text;
  final String? audioFilePath;
  final double durationSeconds;
  final AudiobookRenderStatus status;
  final String? errorMessage;
  final String? colorHex;
  final String? highlightHex;
  final List<AudiobookStyleSpan> styleSpans;

  const AudiobookLine({
    required this.id,
    required this.speakerId,
    required this.speakerName,
    required this.text,
    this.audioFilePath,
    this.durationSeconds = 0.0,
    this.status = AudiobookRenderStatus.idle,
    this.errorMessage,
    this.colorHex,
    this.highlightHex,
    this.styleSpans = const [],
  });

  AudiobookLine copyWith({
    String? id,
    String? speakerId,
    String? speakerName,
    String? text,
    String? audioFilePath,
    double? durationSeconds,
    AudiobookRenderStatus? status,
    String? errorMessage,
    String? colorHex,
    String? highlightHex,
    List<AudiobookStyleSpan>? styleSpans,
  }) {
    return AudiobookLine(
      id: id ?? this.id,
      speakerId: speakerId ?? this.speakerId,
      speakerName: speakerName ?? this.speakerName,
      text: text ?? this.text,
      audioFilePath: audioFilePath ?? this.audioFilePath,
      durationSeconds: durationSeconds ?? this.durationSeconds,
      status: status ?? this.status,
      errorMessage: errorMessage ?? this.errorMessage,
      colorHex: colorHex ?? this.colorHex,
      highlightHex: highlightHex ?? this.highlightHex,
      styleSpans: styleSpans ?? this.styleSpans,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'speakerId': speakerId,
        'speakerName': speakerName,
        'text': text,
        'audioFilePath': audioFilePath,
        'durationSeconds': durationSeconds,
        'status': status.name,
        'errorMessage': errorMessage,
        'colorHex': colorHex,
        'highlightHex': highlightHex,
        'styleSpans': styleSpans.map((s) => s.toJson()).toList(),
      };

  factory AudiobookLine.fromJson(Map<String, dynamic> json) => AudiobookLine(
        id: json['id'] as String? ?? '',
        speakerId: json['speakerId'] as String? ?? 'narrator',
        speakerName: json['speakerName'] as String? ?? 'Narrateur',
        text: json['text'] as String? ?? '',
        audioFilePath: json['audioFilePath'] as String?,
        durationSeconds: (json['durationSeconds'] as num?)?.toDouble() ?? 0.0,
        status: AudiobookRenderStatus.values.firstWhere(
          (e) => e.name == json['status'],
          orElse: () => AudiobookRenderStatus.idle,
        ),
        errorMessage: json['errorMessage'] as String?,
        colorHex: json['colorHex'] as String?,
        highlightHex: json['highlightHex'] as String?,
        styleSpans: (json['styleSpans'] as List<dynamic>?)
                ?.map((s) => AudiobookStyleSpan.fromJson(s as Map<String, dynamic>))
                .toList() ??
            const [],
      );
}

/// A chapter in an audiobook project.
class AudiobookChapter {
  final String id;
  final int index;
  final String title;
  final String rawText;
  final List<AudiobookLine> lines;
  final String? audioFilePath;
  final AudiobookRenderStatus status;
  final double progress; // 0.0 to 1.0
  final String? errorMessage;

  const AudiobookChapter({
    required this.id,
    required this.index,
    required this.title,
    required this.rawText,
    this.lines = const [],
    this.audioFilePath,
    this.status = AudiobookRenderStatus.idle,
    this.progress = 0.0,
    this.errorMessage,
  });

  int get wordCount =>
      rawText.split(RegExp(r'\s+')).where((w) => w.trim().isNotEmpty).length;

  /// Estimated duration in minutes (average 150 words per minute).
  int get estimatedDurationMinutes => (wordCount / 150.0).ceil();

  AudiobookChapter copyWith({
    String? id,
    int? index,
    String? title,
    String? rawText,
    List<AudiobookLine>? lines,
    String? audioFilePath,
    AudiobookRenderStatus? status,
    double? progress,
    String? errorMessage,
  }) {
    return AudiobookChapter(
      id: id ?? this.id,
      index: index ?? this.index,
      title: title ?? this.title,
      rawText: rawText ?? this.rawText,
      lines: lines ?? this.lines,
      audioFilePath: audioFilePath ?? this.audioFilePath,
      status: status ?? this.status,
      progress: progress ?? this.progress,
      errorMessage: errorMessage ?? this.errorMessage,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'index': index,
        'title': title,
        'rawText': rawText,
        'lines': lines.map((l) => l.toJson()).toList(),
        'audioFilePath': audioFilePath,
        'status': status.name,
        'progress': progress,
        'errorMessage': errorMessage,
      };

  factory AudiobookChapter.fromJson(Map<String, dynamic> json) =>
      AudiobookChapter(
        id: json['id'] as String? ?? '',
        index: json['index'] as int? ?? 0,
        title: json['title'] as String? ?? '',
        rawText: json['rawText'] as String? ?? '',
        lines: (json['lines'] as List<dynamic>?)
                ?.map((e) => AudiobookLine.fromJson(e as Map<String, dynamic>))
                .toList() ??
            const [],
        audioFilePath: json['audioFilePath'] as String?,
        status: AudiobookRenderStatus.values.firstWhere(
          (e) => e.name == json['status'],
          orElse: () => AudiobookRenderStatus.idle,
        ),
        progress: (json['progress'] as num?)?.toDouble() ?? 0.0,
        errorMessage: json['errorMessage'] as String?,
      );
}

/// An entire audiobook project.
class AudiobookProject {
  final String id;
  final String title;
  final String author;
  final String sourcePath;
  final List<AudiobookChapter> chapters;
  final Map<String, AudiobookSpeaker> speakers;
  final DateTime createdAt;

  const AudiobookProject({
    required this.id,
    required this.title,
    required this.author,
    required this.sourcePath,
    this.chapters = const [],
    this.speakers = const {},
    required this.createdAt,
  });

  int get totalWords => chapters.fold(0, (sum, c) => sum + c.wordCount);
  int get totalEstimatedMinutes =>
      chapters.fold(0, (sum, c) => sum + c.estimatedDurationMinutes);

  AudiobookProject copyWith({
    String? id,
    String? title,
    String? author,
    String? sourcePath,
    List<AudiobookChapter>? chapters,
    Map<String, AudiobookSpeaker>? speakers,
    DateTime? createdAt,
  }) {
    return AudiobookProject(
      id: id ?? this.id,
      title: title ?? this.title,
      author: author ?? this.author,
      sourcePath: sourcePath ?? this.sourcePath,
      chapters: chapters ?? this.chapters,
      speakers: speakers ?? this.speakers,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'author': author,
        'sourcePath': sourcePath,
        'chapters': chapters.map((c) => c.toJson()).toList(),
        'speakers':
            speakers.map((k, v) => MapEntry(k, v.toJson())),
        'createdAt': createdAt.toIso8601String(),
      };

  factory AudiobookProject.fromJson(Map<String, dynamic> json) =>
      AudiobookProject(
        id: json['id'] as String? ?? '',
        title: json['title'] as String? ?? 'Sans titre',
        author: json['author'] as String? ?? 'Auteur inconnu',
        sourcePath: json['sourcePath'] as String? ?? '',
        chapters: (json['chapters'] as List<dynamic>?)
                ?.map((e) =>
                    AudiobookChapter.fromJson(e as Map<String, dynamic>))
                .toList() ??
            const [],
        speakers: (json['speakers'] as Map<String, dynamic>?)?.map(
              (k, v) => MapEntry(
                  k, AudiobookSpeaker.fromJson(v as Map<String, dynamic>)),
            ) ??
            const {},
        createdAt: json['createdAt'] != null
            ? DateTime.tryParse(json['createdAt'] as String) ?? DateTime.now()
            : DateTime.now(),
      );
}
