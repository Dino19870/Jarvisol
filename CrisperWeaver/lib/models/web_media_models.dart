/// Modèles de données pour le sous-système Web Media (yt-dlp).
/// Totalement indépendant des modèles ASR et Documents existants.
library;

class WebMediaChapter {
  final String title;
  final double startTime;
  final double endTime;

  const WebMediaChapter({
    required this.title,
    required this.startTime,
    required this.endTime,
  });

  factory WebMediaChapter.fromJson(Map<String, dynamic> json) {
    return WebMediaChapter(
      title: json['title'] as String? ?? 'Sans titre',
      startTime: (json['start_time'] as num?)?.toDouble() ?? 0.0,
      endTime: (json['end_time'] as num?)?.toDouble() ?? 0.0,
    );
  }

  Map<String, dynamic> toJson() => {
        'title': title,
        'start_time': startTime,
        'end_time': endTime,
      };
}

class WebMediaSubtitleTrack {
  final String langCode;
  final String langName;
  final String ext;
  final String url;
  final bool isAuto;

  const WebMediaSubtitleTrack({
    required this.langCode,
    required this.langName,
    required this.ext,
    required this.url,
    this.isAuto = false,
  });

  factory WebMediaSubtitleTrack.fromJson(String code, Map<String, dynamic> json, {bool isAuto = false}) {
    return WebMediaSubtitleTrack(
      langCode: code,
      langName: json['name'] as String? ?? code,
      ext: json['ext'] as String? ?? 'vtt',
      url: json['url'] as String? ?? '',
      isAuto: isAuto,
    );
  }

  Map<String, dynamic> toJson() => {
        'lang_code': langCode,
        'lang_name': langName,
        'ext': ext,
        'url': url,
        'is_auto': isAuto,
      };
}

class WebMediaFormat {
  final String formatId;
  final String ext;
  final String? resolution;
  final String? note;
  final int? filesize;
  final double? tbr;
  final String? vcodec;
  final String? acodec;

  const WebMediaFormat({
    required this.formatId,
    required this.ext,
    this.resolution,
    this.note,
    this.filesize,
    this.tbr,
    this.vcodec,
    this.acodec,
  });

  bool get isAudioOnly => vcodec == 'none' && acodec != 'none';
  bool get hasVideo => vcodec != 'none';

  factory WebMediaFormat.fromJson(Map<String, dynamic> json) {
    return WebMediaFormat(
      formatId: json['format_id'] as String? ?? '',
      ext: json['ext'] as String? ?? '',
      resolution: json['resolution'] as String?,
      note: json['format_note'] as String?,
      filesize: json['filesize'] as int? ?? json['filesize_approx'] as int?,
      tbr: (json['tbr'] as num?)?.toDouble(),
      vcodec: json['vcodec'] as String?,
      acodec: json['acodec'] as String?,
    );
  }
}

class WebMediaComment {
  final String id;
  final String author;
  final String text;
  final int? timestamp;
  final int? likeCount;

  const WebMediaComment({
    required this.id,
    required this.author,
    required this.text,
    this.timestamp,
    this.likeCount,
  });

  factory WebMediaComment.fromJson(Map<String, dynamic> json) {
    return WebMediaComment(
      id: json['id'] as String? ?? '',
      author: json['author'] as String? ?? json['author_id'] as String? ?? 'Anonyme',
      text: json['text'] as String? ?? '',
      timestamp: json['timestamp'] as int?,
      likeCount: json['like_count'] as int?,
    );
  }
}

class WebMediaPlaylistItem {
  final String id;
  final String url;
  final String title;
  final double? duration;
  final String? uploader;
  bool isSelected;

  WebMediaPlaylistItem({
    required this.id,
    required this.url,
    required this.title,
    this.duration,
    this.uploader,
    this.isSelected = true,
  });

  factory WebMediaPlaylistItem.fromJson(Map<String, dynamic> json) {
    final videoId = json['id'] as String? ?? '';
    final url = json['url'] as String? ??
        (videoId.isNotEmpty ? 'https://www.youtube.com/watch?v=$videoId' : '');
    return WebMediaPlaylistItem(
      id: videoId,
      url: url,
      title: json['title'] as String? ?? 'Vidéo sans titre',
      duration: (json['duration'] as num?)?.toDouble(),
      uploader: json['uploader'] as String?,
      isSelected: true,
    );
  }
}

class WebMediaMetadata {
  final String url;
  final String extractor;
  final String id;
  final String title;
  final String description;
  final String uploader;
  final String channel;
  final String uploadDate;
  final double duration;
  final String? thumbnail;
  final List<WebMediaChapter> chapters;
  final List<WebMediaSubtitleTrack> subtitles;
  final List<WebMediaSubtitleTrack> automaticCaptions;
  final String liveStatus; // 'is_live', 'was_live', 'not_live'
  final String? playlistTitle;
  final int? playlistIndex;
  final List<WebMediaFormat> formats;
  final bool isPlaylist;
  final List<WebMediaPlaylistItem> playlistEntries;

  const WebMediaMetadata({
    required this.url,
    required this.extractor,
    required this.id,
    required this.title,
    required this.description,
    required this.uploader,
    required this.channel,
    required this.uploadDate,
    required this.duration,
    this.thumbnail,
    this.chapters = const [],
    this.subtitles = const [],
    this.automaticCaptions = const [],
    this.liveStatus = 'not_live',
    this.playlistTitle,
    this.playlistIndex,
    this.formats = const [],
    this.isPlaylist = false,
    this.playlistEntries = const [],
  });

  bool get isLive => liveStatus == 'is_live';
  bool get hasSubtitles => subtitles.isNotEmpty || automaticCaptions.isNotEmpty;
  bool get hasChapters => chapters.isNotEmpty;

  List<WebMediaSubtitleTrack> get allSubtitleTracks => [...subtitles, ...automaticCaptions];

  WebMediaSubtitleTrack? selectPreferredSubtitleTrack({
    String preferredLang = 'fr',
    bool allowAuto = true,
  }) {
    final pref = preferredLang.toLowerCase();
    // 1. Piste humaine dans la langue préférée
    for (final s in subtitles) {
      final code = s.langCode.toLowerCase();
      if (code == pref || code.startsWith('$pref-') || code.startsWith('${pref}_')) {
        return s;
      }
    }
    // 2. Piste humaine en anglais
    for (final s in subtitles) {
      final code = s.langCode.toLowerCase();
      if (code == 'en' || code.startsWith('en-') || code.startsWith('en_')) {
        return s;
      }
    }
    // 3. Première piste humaine disponible
    if (subtitles.isNotEmpty) {
      return subtitles.first;
    }
    // 4. Piste automatique dans la langue préférée
    if (allowAuto) {
      for (final s in automaticCaptions) {
        final code = s.langCode.toLowerCase();
        if (code == pref || code.startsWith('$pref-') || code.startsWith('${pref}_')) {
          return s;
        }
      }
      // 5. Piste automatique en anglais
      for (final s in automaticCaptions) {
        final code = s.langCode.toLowerCase();
        if (code == 'en' || code.startsWith('en-') || code.startsWith('en_')) {
          return s;
        }
      }
      // 6. Première piste auto disponible
      if (automaticCaptions.isNotEmpty) {
        return automaticCaptions.first;
      }
    }
    return null;
  }

  factory WebMediaMetadata.fromJson(String originalUrl, Map<String, dynamic> json) {
    final type = json['_type'] as String?;
    final isPlaylistType = type == 'playlist' || json['entries'] is List;

    // Parse chapters
    final rawChapters = json['chapters'] as List<dynamic>? ?? [];
    final parsedChapters = rawChapters
        .whereType<Map<String, dynamic>>()
        .map((c) => WebMediaChapter.fromJson(c))
        .toList();

    // Parse subtitles
    final List<WebMediaSubtitleTrack> subs = [];
    final rawSubs = (json['subtitles'] as Map?)?.cast<dynamic, dynamic>() ?? {};
    rawSubs.forEach((code, list) {
      if (list is List && list.isNotEmpty && list.first is Map) {
        final itemMap = (list.first as Map).cast<String, dynamic>();
        subs.add(WebMediaSubtitleTrack.fromJson(code.toString(), itemMap, isAuto: false));
      }
    });

    // Parse automatic captions
    final List<WebMediaSubtitleTrack> autoSubs = [];
    final rawAuto = (json['automatic_captions'] as Map?)?.cast<dynamic, dynamic>() ?? {};
    rawAuto.forEach((code, list) {
      if (list is List && list.isNotEmpty && list.first is Map) {
        final itemMap = (list.first as Map).cast<String, dynamic>();
        autoSubs.add(WebMediaSubtitleTrack.fromJson(code.toString(), itemMap, isAuto: true));
      }
    });

    // Parse formats
    final rawFormats = json['formats'] as List<dynamic>? ?? [];
    final parsedFormats = rawFormats
        .whereType<Map<String, dynamic>>()
        .map((f) => WebMediaFormat.fromJson(f))
        .toList();

    // Parse playlist entries if present
    final List<WebMediaPlaylistItem> entries = [];
    if (json['entries'] is List) {
      for (final e in (json['entries'] as List)) {
        if (e is Map<String, dynamic>) {
          entries.add(WebMediaPlaylistItem.fromJson(e));
        }
      }
    }

    String live = 'not_live';
    if (json['is_live'] == true) {
      live = 'is_live';
    } else if (json['was_live'] == true) {
      live = 'was_live';
    }

    return WebMediaMetadata(
      url: json['webpage_url'] as String? ?? originalUrl,
      extractor: json['extractor'] as String? ?? 'generic',
      id: json['id'] as String? ?? '',
      title: json['title'] as String? ?? json['fulltitle'] as String? ?? 'Média sans titre',
      description: json['description'] as String? ?? '',
      uploader: json['uploader'] as String? ?? json['uploader_id'] as String? ?? '',
      channel: json['channel'] as String? ?? json['uploader'] as String? ?? '',
      uploadDate: json['upload_date'] as String? ?? '',
      duration: (json['duration'] as num?)?.toDouble() ?? 0.0,
      thumbnail: json['thumbnail'] as String?,
      chapters: parsedChapters,
      subtitles: subs,
      automaticCaptions: autoSubs,
      liveStatus: live,
      playlistTitle: json['playlist_title'] as String? ?? (isPlaylistType ? json['title'] as String? : null),
      playlistIndex: json['playlist_index'] as int?,
      formats: parsedFormats,
      isPlaylist: isPlaylistType,
      playlistEntries: entries,
    );
  }
}

class WebMediaProbeResult {
  final bool isAvailable;
  final String? version;
  final String? ytdlpPath;
  final String? ffmpegPath;
  final String? jsRuntimePath;
  final String? errorMessage;

  const WebMediaProbeResult({
    required this.isAvailable,
    this.version,
    this.ytdlpPath,
    this.ffmpegPath,
    this.jsRuntimePath,
    this.errorMessage,
  });
}

// ── Modèles de Recherche Web Media (REQ-POST-001) ──

enum WebMediaResultType {
  video,
  playlist,
  live,
  unknown,
}

class WebMediaSearchResult {
  final String id;
  final String url;
  final String title;
  final String? uploader;
  final String? channel;
  final double? duration;
  final String? durationString;
  final String? thumbnailUrl;
  final String? description;
  final String extractor;
  final String? uploadDate;
  final int? timestamp;
  final int? releaseTimestamp;
  final int? viewCount;
  final WebMediaResultType mediaType;

  const WebMediaSearchResult({
    required this.id,
    required this.url,
    required this.title,
    this.uploader,
    this.channel,
    this.duration,
    this.durationString,
    this.thumbnailUrl,
    this.description,
    this.extractor = 'youtube',
    this.uploadDate,
    this.timestamp,
    this.releaseTimestamp,
    this.viewCount,
    this.mediaType = WebMediaResultType.video,
  });

  /// Extrait / résumé textuel issu des métadonnées existantes.
  /// Normalise les espaces et retours à la ligne, sans balises HTML et sans appel LLM.
  String? get summaryText {
    final d = description;
    if (d == null || d.trim().isEmpty) return null;
    final stripped = d.replaceAll(RegExp(r'<[^>]*>'), '');
    final normalized = stripped.replaceAll(RegExp(r'\s+'), ' ').trim();
    return normalized.isNotEmpty ? normalized : null;
  }

  static String? _formatDate(DateTime dt) {
    const months = [
      'janvier', 'février', 'mars', 'avril', 'mai', 'juin',
      'juillet', 'août', 'septembre', 'octobre', 'novembre', 'décembre'
    ];
    if (dt.month < 1 || dt.month > 12) return null;
    final mName = months[dt.month - 1];
    return 'Publié le ${dt.day} $mName ${dt.year}';
  }

  static DateTime? _parseUploadDate(String? raw) {
    if (raw == null) return null;
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;

    // YYYYMMDD (8 chiffres)
    if (RegExp(r'^\d{8}$').hasMatch(trimmed)) {
      final y = int.tryParse(trimmed.substring(0, 4));
      final m = int.tryParse(trimmed.substring(4, 6));
      final d = int.tryParse(trimmed.substring(6, 8));
      if (y != null && m != null && d != null && m >= 1 && m <= 12 && d >= 1 && d <= 31) {
        return DateTime(y, m, d);
      }
    }

    // YYYY-MM-DD ou ISO
    final parsed = DateTime.tryParse(trimmed);
    if (parsed != null && parsed.year > 1970 && parsed.year < 2100) {
      return parsed;
    }
    return null;
  }

  /// Date de publication formatée en français selon la priorité stricte :
  /// 1. upload_date si présent et valide
  /// 2. timestamp si présent et cohérent
  /// 3. release_timestamp uniquement si sa sémantique correspond
  /// Renvoie null si aucune date n'est disponible ou fiable (jamais inventée).
  String? get formattedPublicationDate {
    // 1. upload_date
    final dtFromUpload = _parseUploadDate(uploadDate);
    if (dtFromUpload != null) {
      return _formatDate(dtFromUpload);
    }

    // 2. timestamp (secondes epoch)
    if (timestamp != null && timestamp! > 0) {
      try {
        final dt = DateTime.fromMillisecondsSinceEpoch(timestamp! * 1000, isUtc: true);
        if (dt.year > 1970 && dt.year < 2100) {
          return _formatDate(dt);
        }
      } catch (_) {}
    }

    // 3. release_timestamp
    if (releaseTimestamp != null && releaseTimestamp! > 0) {
      try {
        final dt = DateTime.fromMillisecondsSinceEpoch(releaseTimestamp! * 1000, isUtc: true);
        if (dt.year > 1970 && dt.year < 2100) {
          return _formatDate(dt);
        }
      } catch (_) {}
    }

    return null;
  }

  /// État d'affichage de la date : formatée ou neutre 'Date indisponible'.
  String get publicationDateDisplay => formattedPublicationDate ?? 'Date indisponible';

  factory WebMediaSearchResult.fromJson(Map<String, dynamic> json) {
    final id = json['id']?.toString() ?? '';
    final rawUrl = json['url']?.toString() ?? json['webpage_url']?.toString();
    final canonicalUrl = (rawUrl != null && rawUrl.isNotEmpty)
        ? rawUrl
        : (id.isNotEmpty ? 'https://www.youtube.com/watch?v=$id' : '');

    // Récupération de la miniature
    String? thumb;
    if (json['thumbnail'] is String && (json['thumbnail'] as String).isNotEmpty) {
      thumb = json['thumbnail'] as String;
    } else if (json['thumbnails'] is List && (json['thumbnails'] as List).isNotEmpty) {
      final thumbs = json['thumbnails'] as List;
      for (final t in thumbs.reversed) {
        if (t is Map && t['url'] is String && (t['url'] as String).isNotEmpty) {
          thumb = t['url'] as String;
          break;
        }
      }
    }

    // Détection du type
    WebMediaResultType type = WebMediaResultType.video;
    final liveStatus = json['live_status']?.toString();
    final entryType = json['_type']?.toString();
    if (liveStatus == 'is_live' || json['is_live'] == true) {
      type = WebMediaResultType.live;
    } else if (entryType == 'playlist' || (json['playlist_count'] != null && entryType != 'url')) {
      type = WebMediaResultType.playlist;
    }

    return WebMediaSearchResult(
      id: id,
      url: canonicalUrl,
      title: json['title']?.toString() ?? 'Média sans titre',
      uploader: json['uploader']?.toString() ?? json['channel']?.toString(),
      channel: json['channel']?.toString() ?? json['uploader']?.toString(),
      duration: (json['duration'] as num?)?.toDouble(),
      durationString: json['duration_string']?.toString(),
      thumbnailUrl: thumb,
      description: json['description']?.toString(),
      extractor: json['extractor']?.toString() ?? json['ie_key']?.toString() ?? 'youtube',
      uploadDate: json['upload_date']?.toString() ?? json['release_year']?.toString(),
      timestamp: (json['timestamp'] as num?)?.toInt(),
      releaseTimestamp: (json['release_timestamp'] as num?)?.toInt(),
      viewCount: json['view_count'] as int?,
      mediaType: type,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'url': url,
        'title': title,
        'uploader': uploader,
        'channel': channel,
        'duration': duration,
        'duration_string': durationString,
        'thumbnail_url': thumbnailUrl,
        'description': description,
        'extractor': extractor,
        'upload_date': uploadDate,
        'timestamp': timestamp,
        'release_timestamp': releaseTimestamp,
        'view_count': viewCount,
        'media_type': mediaType.name,
      };
}

/// Filtre local et sémantique des caractères génériques (*, ?) pour la recherche Web Media.
class WebMediaWildcardMatcher {
  static bool hasWildcards(String pattern) {
    return pattern.contains('*') || pattern.contains('?');
  }

  /// Dérive une requête textuelle propre pour le provider distant (sans symboles génériques).
  static String extractBaseQuery(String pattern) {
    final clean = pattern.replaceAll('*', ' ').replaceAll('?', ' ').trim();
    final tokens = clean.split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();
    return tokens.join(' ');
  }

  /// Compile le pattern en expression régulière insensible à la casse.
  static RegExp? buildRegex(String pattern) {
    final trimmed = pattern.trim();
    if (trimmed.isEmpty) return null;
    final buf = StringBuffer();
    for (int i = 0; i < trimmed.length; i++) {
      final char = trimmed[i];
      if (char == '*') {
        buf.write('.*');
      } else if (char == '?') {
        buf.write(r'[^\s]');
      } else {
        buf.write(RegExp.escape(char));
      }
    }
    return RegExp(buf.toString(), caseSensitive: false);
  }

  /// Vérifie si un résultat correspond au pattern wildcard (Priorités : titre, chaîne/auteur, description).
  static bool matches(String pattern, WebMediaSearchResult item) {
    if (!hasWildcards(pattern)) {
      final q = pattern.toLowerCase().trim();
      if (q.isEmpty) return true;
      if (item.title.toLowerCase().contains(q)) return true;
      if ((item.channel ?? '').toLowerCase().contains(q)) return true;
      if ((item.uploader ?? '').toLowerCase().contains(q)) return true;
      if ((item.description ?? '').toLowerCase().contains(q)) return true;
      return false;
    }

    final rx = buildRegex(pattern);
    if (rx == null) return true;

    // Priorité 1 : Titre
    if (rx.hasMatch(item.title)) return true;

    // Priorité 2 : Chaîne / Uploader
    if (item.channel != null && rx.hasMatch(item.channel!)) return true;
    if (item.uploader != null && rx.hasMatch(item.uploader!)) return true;

    // Priorité 3 : Description
    if (item.description != null && rx.hasMatch(item.description!)) return true;

    return false;
  }
}

