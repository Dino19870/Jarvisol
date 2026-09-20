import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:path/path.dart' as p;

enum VoicePackFamily {
  chatterbox,
  qwen3,
}

class VoicePackValidationResult {
  final bool isValid;
  final VoicePackFamily? family;
  final String? architecture;
  final String? compatibleBackend;
  final List<String> voiceNames;
  final int tensorCount;
  final int fileSizeBytes;
  final String? errorMessage;
  final String? warningMessage;
  final List<String> refTexts;

  const VoicePackValidationResult({
    required this.isValid,
    this.family,
    this.architecture,
    this.compatibleBackend,
    this.voiceNames = const [],
    this.tensorCount = 0,
    this.fileSizeBytes = 0,
    this.errorMessage,
    this.warningMessage,
    this.refTexts = const [],
  });

  factory VoicePackValidationResult.valid({
    required VoicePackFamily family,
    required String architecture,
    required String compatibleBackend,
    required List<String> voiceNames,
    required int tensorCount,
    required int fileSizeBytes,
    String? warningMessage,
    List<String> refTexts = const [],
  }) {
    return VoicePackValidationResult(
      isValid: true,
      family: family,
      architecture: architecture,
      compatibleBackend: compatibleBackend,
      voiceNames: voiceNames,
      tensorCount: tensorCount,
      fileSizeBytes: fileSizeBytes,
      warningMessage: warningMessage,
      refTexts: refTexts,
    );
  }

  factory VoicePackValidationResult.invalid(String message, {int fileSizeBytes = 0}) {
    return VoicePackValidationResult(
      isValid: false,
      fileSizeBytes: fileSizeBytes,
      errorMessage: message,
    );
  }

  String get familyDisplayName {
    switch (family) {
      case VoicePackFamily.chatterbox:
        return 'Chatterbox Voice Pack';
      case VoicePackFamily.qwen3:
        return 'Qwen3-TTS Voice Pack';
      default:
        return 'Voice Pack Inconnu';
    }
  }

  String get compatibleEngineLabel {
    switch (family) {
      case VoicePackFamily.chatterbox:
        return 'Chatterbox';
      case VoicePackFamily.qwen3:
        return 'Qwen3-TTS Base';
      default:
        return 'Incompatible';
    }
  }
}

class VoicePackInspector {
  static const List<int> _ggufMagic = [0x47, 0x47, 0x55, 0x46]; // "GGUF"

  static VoicePackValidationResult inspect(String filePath) {
    final file = File(filePath);
    if (!file.existsSync()) {
      return VoicePackValidationResult.invalid('Fichier introuvable: $filePath');
    }

    final fileSize = file.lengthSync();
    if (fileSize < 24) {
      return VoicePackValidationResult.invalid(
        'Fichier trop petit pour être un Voice Pack GGUF valide ($fileSize octets)',
        fileSizeBytes: fileSize,
      );
    }

    RandomAccessFile? raf;
    try {
      raf = file.openSync(mode: FileMode.read);

      // Magic
      final magic = raf.readSync(4);
      for (int i = 0; i < 4; i++) {
        if (magic[i] != _ggufMagic[i]) {
          return VoicePackValidationResult.invalid(
            'En-tête GGUF invalide (magic attendu GGUF, reçu $magic)',
            fileSizeBytes: fileSize,
          );
        }
      }

      // Version
      final versionBytes = raf.readSync(4);
      final version = ByteData.sublistView(versionBytes).getUint32(0, Endian.little);
      if (version < 2 || version > 3) {
        return VoicePackValidationResult.invalid(
          'Version GGUF non supportée: $version (attendue: 2 ou 3)',
          fileSizeBytes: fileSize,
        );
      }

      // Tensor count & KV count
      final tensorCountBytes = raf.readSync(8);
      final tensorCount = ByteData.sublistView(tensorCountBytes).getUint64(0, Endian.little);

      final kvCountBytes = raf.readSync(8);
      final kvCount = ByteData.sublistView(kvCountBytes).getUint64(0, Endian.little);

      String? architecture;
      String? generalName;
      List<String> voicepackNames = [];
      List<String> voicepackRefTexts = [];

      // Read KV pairs
      for (int i = 0; i < kvCount; i++) {
        final key = _readString(raf);
        final valTypeBytes = raf.readSync(4);
        final valType = ByteData.sublistView(valTypeBytes).getUint32(0, Endian.little);

        final val = _readValue(raf, valType);
        if (key == 'general.architecture' && val is String) {
          architecture = val;
        } else if (key == 'general.name' && val is String) {
          generalName = val;
        } else if (key == 'voicepack.names' && val is List) {
          voicepackNames = val.map((e) => e.toString()).toList();
        } else if (key == 'voicepack.ref_texts' && val is List) {
          voicepackRefTexts = val.map((e) => e.toString()).toList();
        } else if (key.startsWith('voicepack.ref_text') && val is String) {
          voicepackRefTexts.add(val);
        }
      }

      // Read Tensor descriptors
      final tensorNames = <String>{};
      for (int i = 0; i < tensorCount; i++) {
        final tName = _readString(raf);
        final nDimsBytes = raf.readSync(4);
        final nDims = ByteData.sublistView(nDimsBytes).getUint32(0, Endian.little);
        // Skip dimensions (nDims * 8) + type (4) + offset (8)
        final skipLen = (nDims * 8) + 4 + 8;
        raf.setPositionSync(raf.positionSync() + skipLen);
        tensorNames.add(tName);
      }

      if (architecture == null || architecture.isEmpty) {
        return VoicePackValidationResult.invalid(
          'Métadonnée general.architecture absente du fichier GGUF',
          fileSizeBytes: fileSize,
        );
      }

      // ── Chatterbox Voice Pack Validation ──
      if (architecture == 'chatterbox-voice') {
        // Condition tensors can be named conds.* (official baker) or chatterbox.conds.*
        final hasT3Emb = tensorNames.contains('conds.t3.speaker_emb') || tensorNames.contains('chatterbox.conds.t3.cfg');
        final hasT3Prompt = tensorNames.contains('conds.t3.speech_prompt_tokens') || tensorNames.contains('chatterbox.conds.t3.prompt');
        final hasPromptToken = tensorNames.contains('conds.gen.prompt_token') || tensorNames.contains('chatterbox.conds.ve');
        final hasPromptFeat = tensorNames.contains('conds.gen.prompt_feat') || tensorNames.contains('chatterbox.conds.s3gen');
        final hasEmbedding = tensorNames.contains('conds.gen.embedding') || tensorNames.contains('chatterbox.conds.emotion');

        if (!hasT3Emb || !hasT3Prompt || !hasPromptToken || !hasPromptFeat || !hasEmbedding || tensorCount < 5) {
          return VoicePackValidationResult.invalid(
            'Voice Pack Chatterbox incomplet: 5 tenseurs de conditionnement requis (trouvés: ${tensorNames.length})',
            fileSizeBytes: fileSize,
          );
        }

        final voiceName = (generalName != null && generalName.trim().isNotEmpty)
            ? generalName.trim()
            : p.basenameWithoutExtension(filePath);

        return VoicePackValidationResult.valid(
          family: VoicePackFamily.chatterbox,
          architecture: architecture,
          compatibleBackend: 'chatterbox',
          voiceNames: [voiceName],
          tensorCount: tensorCount,
          fileSizeBytes: fileSize,
        );
      }

      // ── Qwen3-TTS Voice Pack Validation ──
      if (architecture == 'qwen3tts.voicepack' || architecture == 'qwen3_tts.voicepack') {
        if (voicepackNames.isEmpty) {
          return VoicePackValidationResult.invalid(
            'Voice Pack Qwen3-TTS invalide: aucune voix déclarée dans voicepack.names',
            fileSizeBytes: fileSize,
          );
        }

        final missingTensors = <String>[];
        for (final vn in voicepackNames) {
          final embdTensor = 'voicepack.spk.$vn.embd';
          final codeTensor = 'voicepack.code.$vn.codes';
          if (!tensorNames.contains(embdTensor)) missingTensors.add(embdTensor);
          if (!tensorNames.contains(codeTensor)) missingTensors.add(codeTensor);
        }

        if (missingTensors.isNotEmpty) {
          return VoicePackValidationResult.invalid(
            'Voice Pack Qwen3-TTS incomplet: tenseurs manquants (${missingTensors.join(", ")})',
            fileSizeBytes: fileSize,
          );
        }

        // Détection d'anomalie de transcription dans les métadonnées du Voice Pack
        String? warning;
        for (final refText in voicepackRefTexts) {
          final norm = refText.replaceAll(RegExp(r'\s+'), ' ').trim();
          final maxLen = norm.length ~/ 2;
          for (int len = (maxLen > 100 ? 100 : maxLen); len >= 35; len--) {
            for (int i = 0; i <= norm.length - 2 * len; i++) {
              final cand = norm.substring(i, i + len);
              final second = norm.indexOf(cand, i + len);
              if (second >= 0) {
                final preview = cand.length > 30 ? '${cand.substring(0, 30)}...' : cand;
                warning = 'Répétition massive suspecte détectée dans la transcription du pack (« $preview »). '
                    'Risque de vocalisation parasite du texte dupliqué à la synthèse.';
                break;
              }
            }
            if (warning != null) break;
          }
          if (warning != null) break;
        }

        return VoicePackValidationResult.valid(
          family: VoicePackFamily.qwen3,
          architecture: architecture,
          compatibleBackend: 'qwen3-tts',
          voiceNames: voicepackNames,
          tensorCount: tensorCount,
          fileSizeBytes: fileSize,
          warningMessage: warning,
          refTexts: voicepackRefTexts,
        );
      }

      // Non-voicepack GGUF (e.g. main LLM, whisper, etc.)
      return VoicePackValidationResult.invalid(
        'Architecture GGUF non reconnue comme Voice Pack: "$architecture". '
        'Seuls les Voice Packs Chatterbox (chatterbox-voice) et Qwen3-TTS (qwen3tts.voicepack) sont acceptés.',
        fileSizeBytes: fileSize,
      );
    } catch (e) {
      return VoicePackValidationResult.invalid(
        'Erreur lors de l\'analyse du fichier GGUF: $e',
        fileSizeBytes: fileSize,
      );
    } finally {
      try {
        raf?.closeSync();
      } catch (_) {}
    }
  }

  static String _readString(RandomAccessFile raf) {
    final lenBytes = raf.readSync(8);
    final len = ByteData.sublistView(lenBytes).getUint64(0, Endian.little);
    if (len == 0) return '';
    if (len > 1024 * 1024) throw FormatException('String GGUF déraisonnablement longue: $len');
    final strBytes = raf.readSync(len);
    return utf8.decode(strBytes, allowMalformed: true);
  }

  static dynamic _readValue(RandomAccessFile raf, int type) {
    switch (type) {
      case 0: // UINT8
        return raf.readByteSync();
      case 1: // INT8
        return ByteData.sublistView(raf.readSync(1)).getInt8(0);
      case 2: // UINT16
        return ByteData.sublistView(raf.readSync(2)).getUint16(0, Endian.little);
      case 3: // INT16
        return ByteData.sublistView(raf.readSync(2)).getInt16(0, Endian.little);
      case 4: // UINT32
        return ByteData.sublistView(raf.readSync(4)).getUint32(0, Endian.little);
      case 5: // INT32
        return ByteData.sublistView(raf.readSync(4)).getInt32(0, Endian.little);
      case 6: // FLOAT32
        return ByteData.sublistView(raf.readSync(4)).getFloat32(0, Endian.little);
      case 7: // BOOL
        return raf.readByteSync() != 0;
      case 8: // STRING
        return _readString(raf);
      case 9: // ARRAY
        final elemTypeBytes = raf.readSync(4);
        final elemType = ByteData.sublistView(elemTypeBytes).getUint32(0, Endian.little);
        final countBytes = raf.readSync(8);
        final count = ByteData.sublistView(countBytes).getUint64(0, Endian.little);
        final list = <dynamic>[];
        for (int i = 0; i < count; i++) {
          list.add(_readValue(raf, elemType));
        }
        return list;
      case 10: // UINT64
        return ByteData.sublistView(raf.readSync(8)).getUint64(0, Endian.little);
      case 11: // INT64
        return ByteData.sublistView(raf.readSync(8)).getInt64(0, Endian.little);
      case 12: // FLOAT64
        return ByteData.sublistView(raf.readSync(8)).getFloat64(0, Endian.little);
      default:
        throw FormatException('Type de valeur GGUF inconnu: $type');
    }
  }
}
