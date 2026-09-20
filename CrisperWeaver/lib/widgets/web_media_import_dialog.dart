import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/web_media_models.dart';
import '../services/batch_queue_service.dart';
import '../services/settings_service.dart';
import '../services/web_media_service.dart';
import '../utils/transcript_parsers.dart';

class WebMediaImportDialog extends ConsumerStatefulWidget {
  final String? initialUrl;
  final void Function(File audioFile, WebMediaMetadata metadata)? onTranscribeAudio;
  final void Function(String textContent, WebMediaMetadata metadata, String sourceTitle)? onImportDocument;

  const WebMediaImportDialog({
    super.key,
    this.initialUrl,
    this.onTranscribeAudio,
    this.onImportDocument,
  });

  static Future<void> show(
    BuildContext context, {
    String? initialUrl,
    void Function(File audioFile, WebMediaMetadata metadata)? onTranscribeAudio,
    void Function(String textContent, WebMediaMetadata metadata, String sourceTitle)? onImportDocument,
  }) {
    return showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => WebMediaImportDialog(
        initialUrl: initialUrl,
        onTranscribeAudio: onTranscribeAudio,
        onImportDocument: onImportDocument,
      ),
    );
  }

  @override
  ConsumerState<WebMediaImportDialog> createState() => _WebMediaImportDialogState();
}

enum WebMediaDialogMode { search, directUrl }

class _WebMediaImportDialogState extends ConsumerState<WebMediaImportDialog> {
  late TextEditingController _urlController;
  late TextEditingController _searchController;
  late WebMediaDialogMode _mode;

  bool _isAnalyzing = false;
  bool _isSearching = false;
  bool _hasSearched = false;
  bool _isActionRunning = false;
  double _actionProgress = 0.0;
  String? _statusMessage;
  String? _errorMessage;

  WebMediaMetadata? _metadata;
  List<WebMediaPlaylistItem> _playlistItems = [];
  WebMediaSubtitleTrack? _selectedSubtitleTrack;

  List<WebMediaSearchResult> _searchResults = [];
  WebMediaSearchResult? _selectedSearchResult;
  int _currentSearchLimit = WebMediaService.defaultSearchLimit;
  bool _isLoadingMore = false;
  bool _hasReachedEnd = false;

  late ScrollController _scrollController;
  double _savedScrollOffset = 0.0;

  WebMediaCancellationToken? _currentCancelToken;

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController();
    _urlController = TextEditingController(text: widget.initialUrl ?? '');
    _searchController = TextEditingController();
    _mode = (widget.initialUrl != null && widget.initialUrl!.trim().isNotEmpty)
        ? WebMediaDialogMode.directUrl
        : WebMediaDialogMode.search;

    if (widget.initialUrl != null && widget.initialUrl!.trim().isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _analyzeUrl();
      });
    }
  }

  @override
  void dispose() {
    _currentCancelToken?.cancel();
    _scrollController.dispose();
    _urlController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  String _formatDuration(double seconds) {
    if (seconds <= 0) return 'Inconnue';
    final d = Duration(seconds: seconds.round());
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60);
    if (h > 0) {
      return '${h}h ${m.toString().padLeft(2, '0')}m ${s.toString().padLeft(2, '0')}s';
    }
    return '${m}m ${s.toString().padLeft(2, '0')}s';
  }

  String _formatUploadDate(String dateStr) {
    final clean = dateStr.trim();
    if (clean.length == 8 && int.tryParse(clean) != null) {
      final y = clean.substring(0, 4);
      final m = clean.substring(4, 6);
      final d = clean.substring(6, 8);
      return '$d/$m/$y';
    }
    return clean;
  }

  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data?.text != null && data!.text!.trim().isNotEmpty) {
      setState(() {
        _urlController.text = data.text!.trim();
      });
      _analyzeUrl();
    }
  }

  Future<void> _performSearch() async {
    final query = _searchController.text.trim();
    if (query.isEmpty) {
      setState(() {
        _errorMessage = 'Veuillez saisir un terme de recherche.';
      });
      return;
    }

    final webService = ref.read(webMediaServiceProvider);
    final probe = await webService.probe();
    if (!probe.isAvailable) {
      setState(() {
        _errorMessage = probe.errorMessage ?? 'Le sous-système yt-dlp est indisponible.';
      });
      return;
    }

    setState(() {
      _isSearching = true;
      _isLoadingMore = false;
      _hasReachedEnd = false;
      _currentSearchLimit = WebMediaService.defaultSearchLimit;
      _errorMessage = null;
      _statusMessage = 'Recherche de médias : "$query"...';
      _searchResults = [];
      _hasSearched = true;
      _selectedSearchResult = null;
      _metadata = null;
    });

    _currentCancelToken = WebMediaCancellationToken();

    try {
      final results = await webService.searchMedia(
        query,
        limit: _currentSearchLimit,
        cancelToken: _currentCancelToken,
      );

      setState(() {
        _searchResults = results;
        _isSearching = false;
        _statusMessage = null;
        if (results.length < _currentSearchLimit || results.length >= WebMediaService.maxSearchLimit) {
          _hasReachedEnd = true;
        }
      });
    } on CancellationException {
      setState(() {
        _isSearching = false;
        _statusMessage = 'Recherche annulée.';
      });
    } catch (e) {
      setState(() {
        _isSearching = false;
        _errorMessage = 'Erreur lors de la recherche : $e';
        _statusMessage = null;
      });
    }
  }

  Future<void> _loadMoreResults() async {
    if (_isLoadingMore || _isSearching || _hasReachedEnd) return;
    final query = _searchController.text.trim();
    if (query.isEmpty) return;

    final nextLimit = (_currentSearchLimit + WebMediaService.searchLimitIncrement)
        .clamp(1, WebMediaService.maxSearchLimit);
    if (nextLimit <= _currentSearchLimit) {
      setState(() => _hasReachedEnd = true);
      return;
    }

    setState(() {
      _isLoadingMore = true;
      _statusMessage = 'Chargement de résultats supplémentaires...';
    });

    final webService = ref.read(webMediaServiceProvider);
    _currentCancelToken = WebMediaCancellationToken();

    try {
      final fetched = await webService.searchMedia(
        query,
        limit: nextLimit,
        cancelToken: _currentCancelToken,
      );

      // Déduplication par id/url en conservant l'ordre et l'existant
      final existingKeys = _searchResults.map((r) => r.id.isNotEmpty ? r.id : r.url).toSet();
      final newItems = fetched.where((r) {
        final key = r.id.isNotEmpty ? r.id : r.url;
        return !existingKeys.contains(key);
      }).toList();

      setState(() {
        _currentSearchLimit = nextLimit;
        _searchResults = [..._searchResults, ...newItems];
        _isLoadingMore = false;
        _statusMessage = null;
        if (newItems.isEmpty || fetched.length < nextLimit || nextLimit >= WebMediaService.maxSearchLimit) {
          _hasReachedEnd = true;
        }
      });
    } on CancellationException {
      setState(() {
        _isLoadingMore = false;
        _statusMessage = 'Chargement annulé.';
      });
    } catch (e) {
      setState(() {
        _isLoadingMore = false;
        _errorMessage = 'Erreur lors du chargement supplémentaire : $e';
        _statusMessage = null;
      });
    }
  }

  void _selectSearchResult(WebMediaSearchResult item) {
    if (_isAnalyzing) return;
    if (_scrollController.hasClients) {
      _savedScrollOffset = _scrollController.offset;
    }
    setState(() {
      _selectedSearchResult = item;
      _urlController.text = item.url;
    });
    _analyzeUrl(item.url);
  }

  void _returnToSearchResults() {
    setState(() {
      _metadata = null;
      _selectedSearchResult = null;
      _errorMessage = null;
      _statusMessage = null;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients && _savedScrollOffset > 0) {
        _scrollController.jumpTo(_savedScrollOffset.clamp(0.0, _scrollController.position.maxScrollExtent));
      }
    });
  }

  Future<void> _analyzeUrl([String? urlOverride]) async {
    final rawUrl = (urlOverride ?? _urlController.text).trim();
    if (rawUrl.isEmpty) {
      setState(() {
        _errorMessage = 'Veuillez saisir ou coller une URL Web.';
      });
      return;
    }

    final webService = ref.read(webMediaServiceProvider);
    final probe = await webService.probe();
    if (!probe.isAvailable) {
      setState(() {
        _errorMessage = probe.errorMessage ?? 'Le sous-système yt-dlp est indisponible.';
      });
      return;
    }

    setState(() {
      _isAnalyzing = true;
      _errorMessage = null;
      if (_mode != WebMediaDialogMode.search || _selectedSearchResult == null) {
        _statusMessage = 'Analyse de l\'URL avec yt-dlp...';
      } else {
        _statusMessage = null;
      }
      _metadata = null;
      _playlistItems = [];
    });

    _currentCancelToken = WebMediaCancellationToken();

    try {
      final isPlaylistUrl = rawUrl.contains('playlist?list=') || rawUrl.contains('/playlist');
      final meta = await webService.getMetadata(
        rawUrl,
        includePlaylist: isPlaylistUrl,
        cancelToken: _currentCancelToken,
      );

      List<WebMediaPlaylistItem> items = [];
      if (meta.isPlaylist) {
        items = meta.playlistEntries;
        if (items.isEmpty) {
          items = await webService.enumeratePlaylist(rawUrl, cancelToken: _currentCancelToken);
        }
      }

      final prefLang = ref.read(settingsServiceProvider).defaultLanguage.split('-').first.toLowerCase();
      final defaultTrack = meta.selectPreferredSubtitleTrack(preferredLang: prefLang);

      setState(() {
        _metadata = meta;
        _playlistItems = items;
        _selectedSubtitleTrack = defaultTrack;
        _isAnalyzing = false;
        _statusMessage = null;
      });
    } catch (e) {
      setState(() {
        _isAnalyzing = false;
        _errorMessage = 'Erreur d\'analyse : $e';
        _statusMessage = null;
      });
    }
  }

  Future<void> _transcribeAudio() async {
    if (_metadata == null) return;
    final webService = ref.read(webMediaServiceProvider);

    setState(() {
      _isActionRunning = true;
      _actionProgress = 0.05;
      _statusMessage = 'Téléchargement de l\'audio pour transcription...';
      _errorMessage = null;
    });

    _currentCancelToken = WebMediaCancellationToken();

    try {
      final audioFile = await webService.downloadAudio(
        _metadata!.url,
        onProgress: (prog, status) {
          if (mounted) {
            setState(() {
              _actionProgress = prog;
              _statusMessage = status;
            });
          }
        },
        cancelToken: _currentCancelToken,
      );

      if (mounted) {
        Navigator.of(context).pop();
        widget.onTranscribeAudio?.call(audioFile, _metadata!);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isActionRunning = false;
          _errorMessage = 'Échec de téléchargement audio : $e';
        });
      }
    }
  }

  Future<void> _importSubtitlesAsDocument() async {
    if (_metadata == null) return;
    final track = _selectedSubtitleTrack ?? _metadata!.selectPreferredSubtitleTrack();
    if (track == null) {
      setState(() {
        _errorMessage = 'Aucune piste de sous-titres disponible pour cette vidéo. Vous pouvez utiliser "Transcrire l\'audio (ASR)" pour générer une transcription locale.';
      });
      return;
    }

    final webService = ref.read(webMediaServiceProvider);

    setState(() {
      _isActionRunning = true;
      _statusMessage = 'Récupération des sous-titres [${track.isAuto ? "Auto" : "Humain"}] (${track.langName})...';
      _errorMessage = null;
    });

    _currentCancelToken = WebMediaCancellationToken();

    try {
      final subFile = await webService.downloadSubtitles(
        _metadata!.url,
        langCode: track.langCode,
        autoCaptions: track.isAuto,
        onProgress: (status) {
          if (mounted) {
            setState(() {
              _statusMessage = 'Sous-titres (${track.langCode}) : $status';
            });
          }
        },
        cancelToken: _currentCancelToken,
      );

      if (subFile == null || !subFile.existsSync()) {
        setState(() {
          _isActionRunning = false;
          _errorMessage = 'Aucun sous-titre trouvé pour la piste "${track.langName}" (${track.langCode}). Vous pouvez tenter une autre langue ou lancer "Transcrire l\'audio (ASR)".';
        });
        return;
      }

      final rawContent = await subFile.readAsString();
      final formattedDoc = _formatSubtitleDocument(
        metadata: _metadata!,
        track: track,
        rawContent: rawContent,
      );
      final title = '${_metadata!.title} [Sous-titres ${track.langCode.toUpperCase()}]';

      if (mounted) {
        Navigator.of(context).pop();
        widget.onImportDocument?.call(formattedDoc, _metadata!, title);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isActionRunning = false;
          if (e is CancellationException) {
            _statusMessage = 'Récupération des sous-titres annulée.';
          } else {
            _errorMessage = 'Impossible de récupérer les sous-titres : $e';
          }
        });
      }
    }
  }

  String _formatSubtitleDocument({
    required WebMediaMetadata metadata,
    required WebMediaSubtitleTrack track,
    required String rawContent,
  }) {
    final parsed = rawContent.contains('-->') ? TranscriptParsers.parseSrt(rawContent) : null;
    final buffer = StringBuffer();
    buffer.writeln('# ${metadata.title}');
    buffer.writeln('');
    buffer.writeln('- **URL source :** ${metadata.url}');
    buffer.writeln('- **Auteur / Chaîne :** ${metadata.channel.isNotEmpty ? metadata.channel : metadata.uploader}');
    buffer.writeln('- **Durée :** ${_formatDuration(metadata.duration)}');
    buffer.writeln('- **Piste de sous-titres :** ${track.langName} (${track.langCode}) — [${track.isAuto ? "AUTOMATIQUE" : "HUMAIN"}]');
    if (metadata.hasChapters) {
      buffer.writeln('\n### Chapitres');
      for (final ch in metadata.chapters) {
        buffer.writeln('- `${_formatDuration(ch.startTime)}` : ${ch.title}');
      }
    }
    buffer.writeln('\n---\n### Transcription des sous-titres\n');
    if (parsed != null && parsed.segments.isNotEmpty) {
      for (final seg in parsed.segments) {
        final start = _formatDuration(seg.startTime);
        buffer.writeln('`[$start]` ${seg.text}');
      }
    } else {
      buffer.writeln(rawContent);
    }
    return buffer.toString();
  }

  Future<void> _downloadAudioFile() async {
    if (_metadata == null) return;
    final webService = ref.read(webMediaServiceProvider);

    setState(() {
      _isActionRunning = true;
      _actionProgress = 0.05;
      _statusMessage = 'Téléchargement et conversion audio...';
      _errorMessage = null;
    });

    _currentCancelToken = WebMediaCancellationToken();

    try {
      final tempAudio = await webService.downloadAudio(
        _metadata!.url,
        onProgress: (prog, status) {
          if (mounted) {
            setState(() {
              _actionProgress = prog;
              _statusMessage = status;
            });
          }
        },
        cancelToken: _currentCancelToken,
      );

      final audioBytes = await tempAudio.readAsBytes();
      final defaultName = '${_metadata!.id}_audio.mp3';
      final savePath = await FilePicker.saveFile(
        dialogTitle: 'Enregistrer l\'audio extrait',
        fileName: defaultName,
        type: FileType.custom,
        allowedExtensions: const ['mp3', 'm4a', 'wav'],
        bytes: audioBytes,
        lockParentWindow: true,
      );

      if (savePath != null && mounted) {
        setState(() {
          _isActionRunning = false;
          _statusMessage = 'Fichier audio enregistré : $savePath';
        });
      } else if (mounted) {
        setState(() {
          _isActionRunning = false;
          _statusMessage = 'Téléchargement terminé (fichier temporaire prêt).';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isActionRunning = false;
          _errorMessage = 'Erreur lors du téléchargement audio : $e';
        });
      }
    }
  }

  Future<void> _downloadVideoFile() async {
    if (_metadata == null) return;
    final webService = ref.read(webMediaServiceProvider);

    setState(() {
      _isActionRunning = true;
      _actionProgress = 0.05;
      _statusMessage = 'Téléchargement de la vidéo...';
      _errorMessage = null;
    });

    _currentCancelToken = WebMediaCancellationToken();

    try {
      final tempVideo = await webService.downloadVideo(
        _metadata!.url,
        onProgress: (prog, status) {
          if (mounted) {
            setState(() {
              _actionProgress = prog;
              _statusMessage = status;
            });
          }
        },
        cancelToken: _currentCancelToken,
      );

      final videoBytes = await tempVideo.readAsBytes();
      final defaultName = '${_metadata!.id}_video.mp4';
      final savePath = await FilePicker.saveFile(
        dialogTitle: 'Enregistrer la vidéo',
        fileName: defaultName,
        type: FileType.custom,
        allowedExtensions: const ['mp4', 'mkv'],
        bytes: videoBytes,
        lockParentWindow: true,
      );

      if (savePath != null && mounted) {
        setState(() {
          _isActionRunning = false;
          _statusMessage = 'Fichier vidéo enregistré : $savePath';
        });
      } else if (mounted) {
        setState(() {
          _isActionRunning = false;
          _statusMessage = 'Téléchargement terminé (fichier temporaire prêt).';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isActionRunning = false;
          _errorMessage = 'Erreur lors du téléchargement vidéo : $e';
        });
      }
    }
  }

  Future<void> _addToBatchQueue() async {
    if (_metadata == null) return;
    final webService = ref.read(webMediaServiceProvider);
    final batchNotifier = ref.read(batchQueueProvider.notifier);

    setState(() {
      _isActionRunning = true;
      _statusMessage = 'Préparation et mise en file d\'attente Batch...';
    });

    try {
      if (_metadata!.isPlaylist && _playlistItems.isNotEmpty) {
        final selected = _playlistItems.where((it) => it.isSelected).toList();
        if (selected.isEmpty) {
          setState(() {
            _isActionRunning = false;
            _errorMessage = 'Veuillez cocher au moins une vidéo de la playlist.';
          });
          return;
        }

        int added = 0;
        for (final item in selected) {
          final audioFile = await webService.downloadAudio(
            item.url,
            keepInDownloads: true,
          );
          batchNotifier.enqueue(audioFile.path);
          added++;
        }

        if (mounted) {
          Navigator.of(context).pop();
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('$added piste(s) de la playlist ajoutée(s) à la Batch Queue !')),
          );
        }
      } else {
        final audioFile = await webService.downloadAudio(
          _metadata!.url,
          keepInDownloads: true,
        );
        batchNotifier.enqueue(audioFile.path);

        if (mounted) {
          Navigator.of(context).pop();
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Audio "${_metadata!.title}" ajouté à la Batch Queue !')),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isActionRunning = false;
          _errorMessage = 'Erreur d\'ajout à la Batch Queue : $e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 800, maxHeight: 750),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // En-tête
              Row(
                children: [
                  const Icon(Icons.public, color: Colors.blueAccent, size: 28),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Importer un Média Web (yt-dlp)',
                          style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
                        ),
                        Text(
                          'YouTube, Vimeo, Twitch, SoundCloud et 1000+ plateformes compatibles',
                          style: theme.textTheme.bodySmall?.copyWith(color: isDark ? Colors.white60 : Colors.black54),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              // Sélecteur de mode (Recherche vs URL Directe)
              if (_metadata == null) ...[
                SegmentedButton<WebMediaDialogMode>(
                  segments: const [
                    ButtonSegment<WebMediaDialogMode>(
                      value: WebMediaDialogMode.search,
                      icon: Icon(Icons.search),
                      label: Text('Recherche de médias'),
                    ),
                    ButtonSegment<WebMediaDialogMode>(
                      value: WebMediaDialogMode.directUrl,
                      icon: Icon(Icons.link),
                      label: Text('Import direct par URL'),
                    ),
                  ],
                  selected: {_mode},
                  onSelectionChanged: (newSelection) {
                    setState(() {
                      _mode = newSelection.first;
                      _errorMessage = null;
                      _statusMessage = null;
                    });
                  },
                ),
                const SizedBox(height: 14),
              ],

              // Barre de saisie selon le mode
              if (_metadata == null && _mode == WebMediaDialogMode.search)
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _searchController,
                        decoration: InputDecoration(
                          hintText: 'Rechercher un média (titre, artiste, * ou ? autorisés)...',
                          prefixIcon: const Icon(Icons.search),
                          suffixIcon: _searchController.text.isNotEmpty
                              ? IconButton(
                                  icon: const Icon(Icons.clear),
                                  onPressed: () {
                                    setState(() {
                                      _searchController.clear();
                                      _searchResults = [];
                                      _hasSearched = false;
                                    });
                                  },
                                )
                              : null,
                          border: const OutlineInputBorder(),
                          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                        ),
                        onChanged: (_) => setState(() {}),
                        onSubmitted: (_) => _performSearch(),
                      ),
                    ),
                    const SizedBox(width: 8),
                    ElevatedButton.icon(
                      icon: _isSearching
                          ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                          : const Icon(Icons.search),
                      label: const Text('Rechercher'),
                      onPressed: _isSearching ? null : _performSearch,
                    ),
                  ],
                )
              else if (_metadata == null && _mode == WebMediaDialogMode.directUrl)
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _urlController,
                        decoration: const InputDecoration(
                          hintText: 'Collez une URL (ex: https://www.youtube.com/watch?v=...)',
                          prefixIcon: Icon(Icons.link),
                          border: OutlineInputBorder(),
                          contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                        ),
                        onSubmitted: (_) => _analyzeUrl(),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton.filledTonal(
                      icon: const Icon(Icons.paste),
                      tooltip: 'Coller depuis le presse-papier',
                      onPressed: _pasteFromClipboard,
                    ),
                    const SizedBox(width: 8),
                    ElevatedButton.icon(
                      icon: _isAnalyzing
                          ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                          : const Icon(Icons.arrow_forward),
                      label: const Text('Analyser'),
                      onPressed: _isAnalyzing ? null : () => _analyzeUrl(),
                    ),
                  ],
                )
              else if (_metadata != null && _selectedSearchResult != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Row(
                    children: [
                      OutlinedButton.icon(
                        icon: const Icon(Icons.arrow_back, size: 16),
                        label: const Text('Retour aux résultats de recherche'),
                        onPressed: _returnToSearchResults,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          'Résultat sélectionné : ${_selectedSearchResult!.title}',
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 12, color: isDark ? Colors.white60 : Colors.black54),
                        ),
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: 12),

              // Statut et Progression
              if (_isActionRunning) ...[
                Row(
                  children: [
                    Expanded(
                      child: LinearProgressIndicator(value: _actionProgress > 0 ? _actionProgress : null),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.redAccent,
                        side: const BorderSide(color: Colors.redAccent),
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        visualDensity: VisualDensity.compact,
                      ),
                      icon: const Icon(Icons.cancel, size: 14),
                      label: const Text('Annuler', style: TextStyle(fontSize: 12)),
                      onPressed: () {
                        _currentCancelToken?.cancel();
                        setState(() {
                          _isActionRunning = false;
                          _statusMessage = 'Opération annulée.';
                        });
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 8),
              ],
              if (_statusMessage != null)
                Container(
                  padding: const EdgeInsets.all(8),
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(
                    color: Colors.blue.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.blueAccent.withValues(alpha: 0.3)),
                  ),
                  child: Text(_statusMessage!, style: const TextStyle(fontSize: 12, color: Colors.blueAccent)),
                ),
              if (_errorMessage != null)
                Container(
                  padding: const EdgeInsets.all(8),
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(
                    color: Colors.red.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.redAccent.withValues(alpha: 0.3)),
                  ),
                  child: Text(_errorMessage!, style: const TextStyle(fontSize: 12, color: Colors.redAccent)),
                ),

              // Contenu principal (Résultats de recherche / Attente / Métadonnées analysées)
              Expanded(
                child: _metadata == null
                    ? (_mode == WebMediaDialogMode.search
                        ? (_isSearching
                            ? Center(
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const CircularProgressIndicator(),
                                    const SizedBox(height: 16),
                                    const Text('Recherche de médias en cours...'),
                                    const SizedBox(height: 12),
                                    OutlinedButton.icon(
                                      style: OutlinedButton.styleFrom(foregroundColor: Colors.redAccent),
                                      icon: const Icon(Icons.cancel, size: 14),
                                      label: const Text('Annuler la recherche'),
                                      onPressed: () {
                                        _currentCancelToken?.cancel();
                                        setState(() {
                                          _isSearching = false;
                                          _statusMessage = 'Recherche annulée.';
                                        });
                                      },
                                    ),
                                  ],
                                ),
                              )
                            : _searchResults.isNotEmpty
                                ? Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Padding(
                                        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                                        child: Row(
                                          children: [
                                            Text(
                                              '${_searchResults.length} résultats affichés',
                                              style: TextStyle(
                                                fontSize: 12,
                                                fontWeight: FontWeight.w600,
                                                color: isDark ? Colors.white70 : Colors.black87,
                                              ),
                                            ),
                                            const Spacer(),
                                            if (_isLoadingMore)
                                              const SizedBox(
                                                width: 14,
                                                height: 14,
                                                child: CircularProgressIndicator(strokeWidth: 2),
                                              ),
                                          ],
                                        ),
                                      ),
                                      Expanded(
                                        child: ListView.separated(
                                          controller: _scrollController,
                                          key: const PageStorageKey<String>('web_media_search_list'),
                                          itemCount: _searchResults.length +
                                              ((!_hasReachedEnd && _searchResults.length < WebMediaService.maxSearchLimit)
                                                  ? 1
                                                  : 0),
                                          separatorBuilder: (_, __) => const SizedBox(height: 8),
                                          itemBuilder: (context, index) {
                                            if (index == _searchResults.length) {
                                              return Padding(
                                                padding: const EdgeInsets.symmetric(vertical: 8),
                                                child: Center(
                                                  child: OutlinedButton.icon(
                                                    icon: _isLoadingMore
                                                        ? const SizedBox(
                                                            width: 14,
                                                            height: 14,
                                                            child: CircularProgressIndicator(strokeWidth: 2),
                                                          )
                                                        : const Icon(Icons.add, size: 16),
                                                    label: Text(_isLoadingMore ? 'Chargement...' : 'Afficher plus'),
                                                    onPressed: _isLoadingMore ? null : _loadMoreResults,
                                                  ),
                                                ),
                                              );
                                            }
                                            final item = _searchResults[index];
                                            final isSelectedAndAnalyzing = _isAnalyzing && _selectedSearchResult?.url == item.url;
                                            return Card(
                                              elevation: 1,
                                              margin: EdgeInsets.zero,
                                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                              child: InkWell(
                                                borderRadius: BorderRadius.circular(10),
                                                onTap: _isAnalyzing ? null : () => _selectSearchResult(item),
                                                child: Padding(
                                                  padding: const EdgeInsets.all(10),
                                                  child: Row(
                                                    crossAxisAlignment: CrossAxisAlignment.start,
                                                    children: [
                                                      // Miniature avec badge durée
                                                      Stack(
                                                        children: [
                                                          ClipRRect(
                                                            borderRadius: BorderRadius.circular(6),
                                                            child: item.thumbnailUrl != null && item.thumbnailUrl!.isNotEmpty
                                                                ? Image.network(
                                                                    item.thumbnailUrl!,
                                                                    width: 110,
                                                                    height: 65,
                                                                    fit: BoxFit.cover,
                                                                    errorBuilder: (_, __, ___) => Container(
                                                                      width: 110,
                                                                      height: 65,
                                                                      color: isDark ? Colors.grey.shade800 : Colors.grey.shade300,
                                                                      child: const Icon(Icons.broken_image, size: 24, color: Colors.grey),
                                                                    ),
                                                                  )
                                                                : Container(
                                                                    width: 110,
                                                                    height: 65,
                                                                    color: Colors.indigo.withValues(alpha: 0.2),
                                                                    child: const Icon(Icons.music_video, color: Colors.indigoAccent),
                                                                  ),
                                                          ),
                                                          if (item.duration != null && item.duration! > 0)
                                                            Positioned(
                                                              bottom: 3,
                                                              right: 3,
                                                              child: Container(
                                                                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                                                                decoration: BoxDecoration(
                                                                  color: Colors.black.withValues(alpha: 0.8),
                                                                  borderRadius: BorderRadius.circular(3),
                                                                ),
                                                                child: Text(
                                                                  _formatDuration(item.duration!),
                                                                  style: const TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.bold),
                                                                ),
                                                              ),
                                                            ),
                                                        ],
                                                      ),
                                                      const SizedBox(width: 12),
                                                      // Détails
                                                      Expanded(
                                                        child: Column(
                                                          crossAxisAlignment: CrossAxisAlignment.start,
                                                          children: [
                                                            Text(
                                                              item.title,
                                                              maxLines: 2,
                                                              overflow: TextOverflow.ellipsis,
                                                              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                                                            ),
                                                            const SizedBox(height: 3),
                                                            Text(
                                                              item.channel ?? item.uploader ?? '',
                                                              maxLines: 1,
                                                              overflow: TextOverflow.ellipsis,
                                                              style: TextStyle(fontSize: 11, color: isDark ? Colors.white70 : Colors.black54),
                                                            ),
                                                            if (item.summaryText != null && item.summaryText!.isNotEmpty) ...[
                                                              const SizedBox(height: 3),
                                                              Text(
                                                                item.summaryText!,
                                                                maxLines: 2,
                                                                overflow: TextOverflow.ellipsis,
                                                                style: TextStyle(
                                                                  fontSize: 11,
                                                                  color: isDark ? Colors.white60 : Colors.black87,
                                                                  height: 1.25,
                                                                ),
                                                              ),
                                                            ],
                                                            const SizedBox(height: 4),
                                                            Wrap(
                                                              crossAxisAlignment: WrapCrossAlignment.center,
                                                              spacing: 8,
                                                              runSpacing: 4,
                                                              children: [
                                                                Chip(
                                                                  label: Text(
                                                                    item.mediaType == WebMediaResultType.playlist
                                                                        ? 'PLAYLIST'
                                                                        : item.mediaType == WebMediaResultType.live
                                                                            ? 'DIRECT'
                                                                            : 'VIDÉO',
                                                                  ),
                                                                  visualDensity: VisualDensity.compact,
                                                                  labelStyle: const TextStyle(fontSize: 9, fontWeight: FontWeight.bold),
                                                                  padding: EdgeInsets.zero,
                                                                ),
                                                                if (item.viewCount != null && item.viewCount! > 0)
                                                                  Text(
                                                                    '${item.viewCount} vues',
                                                                    style: TextStyle(fontSize: 10, color: isDark ? Colors.white38 : Colors.black38),
                                                                  ),
                                                                Row(
                                                                  mainAxisSize: MainAxisSize.min,
                                                                  children: [
                                                                    Icon(Icons.calendar_today, size: 10, color: isDark ? Colors.white38 : Colors.black38),
                                                                    const SizedBox(width: 3),
                                                                    Text(
                                                                      item.formattedPublicationDate ?? 'Date indisponible',
                                                                      style: TextStyle(fontSize: 10, color: isDark ? Colors.white38 : Colors.black38),
                                                                    ),
                                                                  ],
                                                                ),
                                                              ],
                                                            ),
                                                            if (isSelectedAndAnalyzing) ...[
                                                              const SizedBox(height: 6),
                                                              Container(
                                                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                                                decoration: BoxDecoration(
                                                                  color: Colors.blue.withValues(alpha: 0.12),
                                                                  borderRadius: BorderRadius.circular(6),
                                                                  border: Border.all(color: Colors.blueAccent.withValues(alpha: 0.4)),
                                                                ),
                                                                child: const Row(
                                                                  mainAxisSize: MainAxisSize.min,
                                                                  children: [
                                                                    SizedBox(
                                                                      width: 12,
                                                                      height: 12,
                                                                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.blueAccent),
                                                                    ),
                                                                    SizedBox(width: 8),
                                                                    Text(
                                                                      'Analyse du média sélectionné...',
                                                                      style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Colors.blueAccent),
                                                                    ),
                                                                  ],
                                                                ),
                                                              ),
                                                            ],
                                                          ],
                                                        ),
                                                      ),
                                                      const SizedBox(width: 8),
                                                      IconButton.filledTonal(
                                                        icon: isSelectedAndAnalyzing
                                                            ? const SizedBox(
                                                                width: 18,
                                                                height: 18,
                                                                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                                                              )
                                                            : const Icon(Icons.arrow_forward, size: 18),
                                                        tooltip: _isAnalyzing ? 'Analyse en cours...' : 'Choisir ce média',
                                                        onPressed: _isAnalyzing ? null : () => _selectSearchResult(item),
                                                      ),
                                                    ],
                                                  ),
                                                ),
                                              ),
                                            );
                                          },
                                        ),
                                      ),
                                    ],
                                  )
                                : Center(
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(
                                          _hasSearched ? Icons.search_off : Icons.travel_explore,
                                          size: 56,
                                          color: isDark ? Colors.white24 : Colors.black26,
                                        ),
                                        const SizedBox(height: 12),
                                        Text(
                                          _hasSearched
                                              ? 'Aucun résultat trouvé pour « ${_searchController.text} »'
                                              : 'Recherche de médias Web',
                                          style: theme.textTheme.titleMedium,
                                        ),
                                        const SizedBox(height: 4),
                                        Text(
                                          _hasSearched
                                              ? 'Essayez avec d\'autres mots-clés ou ajustez vos jokers (*, ?).'
                                              : 'Saisissez des mots-clés ou des motifs avec jokers (* et ?) puis cliquez sur Rechercher.',
                                          style: TextStyle(color: isDark ? Colors.white38 : Colors.black38, fontSize: 12),
                                        ),
                                      ],
                                    ),
                                  ))
                        : Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.video_library_outlined, size: 64, color: isDark ? Colors.white24 : Colors.black26),
                                const SizedBox(height: 12),
                                Text(
                                  'Entrez une URL pour afficher les métadonnées et actions disponibles.',
                                  style: TextStyle(color: isDark ? Colors.white38 : Colors.black38),
                                ),
                              ],
                            ),
                          ))
                    : SingleChildScrollView(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            // Carte Aperçu Média
                            Card(
                              elevation: 1,
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                              child: Padding(
                                padding: const EdgeInsets.all(12),
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    if (_metadata!.thumbnail != null)
                                      ClipRRect(
                                        borderRadius: BorderRadius.circular(8),
                                        child: Image.network(
                                          _metadata!.thumbnail!,
                                          width: 140,
                                          height: 90,
                                          fit: BoxFit.cover,
                                          errorBuilder: (_, __, ___) => Container(
                                            width: 140,
                                            height: 90,
                                            color: Colors.grey.shade800,
                                            child: const Icon(Icons.broken_image, color: Colors.white38),
                                          ),
                                        ),
                                      )
                                    else
                                      Container(
                                        width: 140,
                                        height: 90,
                                        decoration: BoxDecoration(
                                          color: Colors.indigo.withValues(alpha: 0.2),
                                          borderRadius: BorderRadius.circular(8),
                                        ),
                                        child: const Icon(Icons.music_video, size: 40, color: Colors.indigoAccent),
                                      ),
                                    const SizedBox(width: 14),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            _metadata!.title,
                                            maxLines: 2,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                                          ),
                                          const SizedBox(height: 4),
                                          Text(
                                            '${_metadata!.channel.isNotEmpty ? _metadata!.channel : _metadata!.uploader} • ${_formatDuration(_metadata!.duration)}',
                                            style: TextStyle(fontSize: 12, color: isDark ? Colors.white70 : Colors.black54),
                                          ),
                                          const SizedBox(height: 6),
                                          Wrap(
                                            spacing: 6,
                                            children: [
                                              Chip(
                                                label: Text(_metadata!.extractor.toUpperCase()),
                                                visualDensity: VisualDensity.compact,
                                                labelStyle: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold),
                                              ),
                                              if (_metadata!.isLive)
                                                const Chip(
                                                  avatar: Icon(Icons.circle, color: Colors.red, size: 10),
                                                  label: Text('EN DIRECT'),
                                                  visualDensity: VisualDensity.compact,
                                                  labelStyle: TextStyle(fontSize: 10, color: Colors.red, fontWeight: FontWeight.bold),
                                                ),
                                              if (_metadata!.hasSubtitles)
                                                Chip(
                                                  avatar: const Icon(Icons.subtitles, size: 12),
                                                  label: Text('${_metadata!.subtitles.length + _metadata!.automaticCaptions.length} sous-titres'),
                                                  visualDensity: VisualDensity.compact,
                                                  labelStyle: const TextStyle(fontSize: 10),
                                                ),
                                              if (_metadata!.hasChapters)
                                                Chip(
                                                  avatar: const Icon(Icons.bookmark_border, size: 12),
                                                  label: Text('${_metadata!.chapters.length} chapitres'),
                                                  visualDensity: VisualDensity.compact,
                                                  labelStyle: const TextStyle(fontSize: 10),
                                                ),
                                            ],
                                          ),
                                          if (_metadata!.uploadDate.isNotEmpty || (_selectedSearchResult?.viewCount != null && _selectedSearchResult!.viewCount! > 0)) ...[
                                            const SizedBox(height: 6),
                                            Row(
                                              children: [
                                                if (_metadata!.uploadDate.isNotEmpty) ...[
                                                  Icon(Icons.calendar_today, size: 12, color: isDark ? Colors.white60 : Colors.black54),
                                                  const SizedBox(width: 4),
                                                  Text(
                                                    'Publié le ${_formatUploadDate(_metadata!.uploadDate)}',
                                                    style: TextStyle(fontSize: 11, color: isDark ? Colors.white60 : Colors.black54),
                                                  ),
                                                  const SizedBox(width: 12),
                                                ],
                                                if (_selectedSearchResult?.viewCount != null && _selectedSearchResult!.viewCount! > 0) ...[
                                                  Icon(Icons.visibility, size: 12, color: isDark ? Colors.white60 : Colors.black54),
                                                  const SizedBox(width: 4),
                                                  Text(
                                                    '${_selectedSearchResult!.viewCount} vues',
                                                    style: TextStyle(fontSize: 11, color: isDark ? Colors.white60 : Colors.black54),
                                                  ),
                                                ],
                                              ],
                                            ),
                                          ],
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            const SizedBox(height: 12),

                            // Section Description Complète
                            if (_metadata!.description.trim().isNotEmpty) ...[
                              Card(
                                elevation: 0,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(10),
                                  side: BorderSide(color: isDark ? Colors.grey.shade700 : Colors.grey.shade300),
                                ),
                                child: ExpansionTile(
                                  initiallyExpanded: false,
                                  leading: const Icon(Icons.description, size: 20, color: Colors.indigoAccent),
                                  title: const Text('Description complète', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                                  children: [
                                    Padding(
                                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                                      child: SelectableText(
                                        _metadata!.description.trim(),
                                        style: TextStyle(
                                          fontSize: 12,
                                          height: 1.4,
                                          color: isDark ? Colors.white70 : Colors.black87,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(height: 12),
                            ],

                            // Section Sélection des Sous-titres
                            if (_metadata!.hasSubtitles) ...[
                              Card(
                                elevation: 0,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(10),
                                  side: BorderSide(color: Colors.teal.shade300),
                                ),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          const Icon(Icons.subtitles, size: 18, color: Colors.teal),
                                          const SizedBox(width: 8),
                                          const Text(
                                            'Piste de sous-titres à importer :',
                                            style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                                          ),
                                          const Spacer(),
                                          if (_selectedSubtitleTrack != null)
                                            Container(
                                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                              decoration: BoxDecoration(
                                                color: _selectedSubtitleTrack!.isAuto
                                                    ? Colors.orange.withValues(alpha: 0.15)
                                                    : Colors.green.withValues(alpha: 0.15),
                                                borderRadius: BorderRadius.circular(12),
                                                border: Border.all(
                                                  color: _selectedSubtitleTrack!.isAuto ? Colors.orange : Colors.green,
                                                  width: 0.8,
                                                ),
                                              ),
                                              child: Text(
                                                _selectedSubtitleTrack!.isAuto ? 'AUTO' : 'HUMAIN',
                                                style: TextStyle(
                                                  fontSize: 10,
                                                  fontWeight: FontWeight.bold,
                                                  color: _selectedSubtitleTrack!.isAuto ? Colors.orange : Colors.green,
                                                ),
                                              ),
                                            ),
                                        ],
                                      ),
                                      const SizedBox(height: 8),
                                      DropdownButtonFormField<WebMediaSubtitleTrack>(
                                        initialValue: _selectedSubtitleTrack,
                                        isExpanded: true,
                                        decoration: const InputDecoration(
                                          isDense: true,
                                          contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                                          border: OutlineInputBorder(),
                                        ),
                                        items: _metadata!.allSubtitleTracks.map((track) {
                                          return DropdownMenuItem<WebMediaSubtitleTrack>(
                                            value: track,
                                            child: Text(
                                              '[${track.isAuto ? "Auto" : "Humain"}] ${track.langName} (${track.langCode})',
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(
                                                fontSize: 12,
                                                fontWeight: !track.isAuto ? FontWeight.bold : FontWeight.normal,
                                              ),
                                            ),
                                          );
                                        }).toList(),
                                        onChanged: _isActionRunning ? null : (val) {
                                          setState(() => _selectedSubtitleTrack = val);
                                        },
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                              const SizedBox(height: 12),
                            ] else ...[
                              Container(
                                padding: const EdgeInsets.all(10),
                                decoration: BoxDecoration(
                                  color: Colors.amber.withValues(alpha: 0.1),
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(color: Colors.amber.withValues(alpha: 0.3)),
                                ),
                                child: const Row(
                                  children: [
                                    Icon(Icons.info_outline, size: 16, color: Colors.amber),
                                    SizedBox(width: 8),
                                    Expanded(
                                      child: Text(
                                        'Aucun sous-titre disponible sur cette vidéo. Vous pouvez utiliser "Transcrire l\'audio (ASR)" pour transcrire l\'audio localement.',
                                        style: TextStyle(fontSize: 11),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(height: 12),
                            ],

                            // Section Playlist si applicable
                            if (_metadata!.isPlaylist && _playlistItems.isNotEmpty) ...[
                              Card(
                                elevation: 0,
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10), side: BorderSide(color: Colors.grey.shade400)),
                                child: Padding(
                                  padding: const EdgeInsets.all(10),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.stretch,
                                    children: [
                                      Row(
                                        children: [
                                          const Icon(Icons.playlist_play, color: Colors.teal),
                                          const SizedBox(width: 8),
                                          Text('Éléments de la playlist (${_playlistItems.length})', style: const TextStyle(fontWeight: FontWeight.bold)),
                                          const Spacer(),
                                          TextButton(
                                            child: const Text('Tout cocher'),
                                            onPressed: () {
                                              setState(() {
                                                for (final it in _playlistItems) {
                                                  it.isSelected = true;
                                                }
                                              });
                                            },
                                          ),
                                          TextButton(
                                            child: const Text('Tout décocher'),
                                            onPressed: () {
                                              setState(() {
                                                for (final it in _playlistItems) {
                                                  it.isSelected = false;
                                                }
                                              });
                                            },
                                          ),
                                        ],
                                      ),
                                      const Divider(),
                                      ConstrainedBox(
                                        constraints: const BoxConstraints(maxHeight: 180),
                                        child: ListView.builder(
                                          shrinkWrap: true,
                                          itemCount: _playlistItems.length,
                                          itemBuilder: (context, idx) {
                                            final item = _playlistItems[idx];
                                            return CheckboxListTile(
                                              dense: true,
                                              title: Text(item.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                                              subtitle: item.duration != null ? Text(_formatDuration(item.duration!)) : null,
                                              value: item.isSelected,
                                              onChanged: (val) {
                                                setState(() => item.isSelected = val ?? false);
                                              },
                                            );
                                          },
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                              const SizedBox(height: 12),
                            ],

                            // Section Chapitres si existants
                            if (_metadata!.hasChapters) ...[
                              ExpansionTile(
                                leading: const Icon(Icons.format_list_numbered, size: 20),
                                title: Text('Chapitres (${_metadata!.chapters.length})', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                                children: _metadata!.chapters.map((ch) {
                                  return ListTile(
                                    dense: true,
                                    leading: Text(_formatDuration(ch.startTime), style: const TextStyle(fontSize: 11, fontFamily: 'monospace')),
                                    title: Text(ch.title, style: const TextStyle(fontSize: 12)),
                                  );
                                }).toList(),
                              ),
                              const SizedBox(height: 12),
                            ],

                            // Actions Disponibles
                            const Text('Actions compatibles :', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                            const SizedBox(height: 8),
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                ElevatedButton.icon(
                                  icon: const Icon(Icons.mic, size: 18),
                                  label: const Text('Transcrire l\'audio (ASR)'),
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: Colors.indigoAccent,
                                    foregroundColor: Colors.white,
                                  ),
                                  onPressed: _isActionRunning ? null : _transcribeAudio,
                                ),
                                if (_metadata!.hasSubtitles)
                                  ElevatedButton.icon(
                                    icon: const Icon(Icons.description, size: 18),
                                    label: const Text('Importer sous-titres (Documents)'),
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: Colors.teal,
                                      foregroundColor: Colors.white,
                                    ),
                                    onPressed: _isActionRunning ? null : _importSubtitlesAsDocument,
                                  ),
                                OutlinedButton.icon(
                                  icon: const Icon(Icons.audio_file, size: 18),
                                  label: const Text('Télécharger Audio (MP3)'),
                                  onPressed: _isActionRunning ? null : _downloadAudioFile,
                                ),
                                OutlinedButton.icon(
                                  icon: const Icon(Icons.video_file, size: 18),
                                  label: const Text('Télécharger Vidéo (MP4)'),
                                  onPressed: _isActionRunning ? null : _downloadVideoFile,
                                ),
                                OutlinedButton.icon(
                                  icon: const Icon(Icons.playlist_add, size: 18),
                                  label: Text(_metadata!.isPlaylist ? 'Ajouter sélection au Batch' : 'Ajouter au Batch'),
                                  onPressed: _isActionRunning ? null : _addToBatchQueue,
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
