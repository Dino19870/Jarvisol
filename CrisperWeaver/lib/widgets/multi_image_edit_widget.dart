import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../constants/timeout_policy.dart';

/// Modes operatoires supportes par le moteur d edition multi-images.
enum MultiImageEditMode {
  referencePersonOrObject(
    id: 'reference_person_or_object',
    label: 'Reference personnage / objet',
    badgeText: 'NATIVE IP-ADAPTER',
    description: 'Reference visuelle — personnage / objet via IP-Adapter Plus SD1.5.',
    isFullySupported: true,
    capabilityLabel: 'NATIVE IP-ADAPTER',
    capabilityDetail: 'Reference visuelle — personnage / objet (IP-Adapter Plus SD1.5)',
    defaultPrompt: 'a high quality subject seamlessly integrated into the scene, photorealistic, matching ambient lighting',
    defaultStrength: 0.65,
  ),
  referenceFace(
    id: 'reference_face',
    label: 'Reference visage',
    badgeText: 'NATIVE IP-ADAPTER FACE',
    description: 'Reference visage — ressemblance renforcee (sans pretention d identite biometrique stricte).',
    isFullySupported: true,
    capabilityLabel: 'NATIVE IP-ADAPTER FACE',
    capabilityDetail: 'Reference visage — ressemblance renforcee (IP-Adapter Plus Face SD1.5 — ressemblance stylistique, sans correspondance biometrique stricte)',
    defaultPrompt: 'portrait face of a person, realistic skin texture, detailed eyes, natural lighting',
    defaultStrength: 0.55,
  ),
  autoFaceDetect(
    id: 'auto_face_detect',
    label: 'Visage automatique',
    badgeText: 'AUTO YOLOv8 + IP-ADAPTER',
    description: 'Detection automatique de la zone du visage par YOLOv8 dans l image cible + conditionnement IP-Adapter Face.',
    isFullySupported: true,
    capabilityLabel: 'AUTO YOLOv8 + IP-ADAPTER',
    capabilityDetail: 'Detection automatique de la zone du visage par YOLOv8 + conditionnement IP-Adapter Face',
    defaultPrompt: 'portrait face of a person, sharp focus, natural expressions, 8k',
    defaultStrength: 0.55,
  ),
  manualMaskPriority(
    id: 'manual_mask_priority',
    label: 'Masque manuel prioritaire',
    badgeText: 'MASQUE PRIORITAIRE',
    description: 'Applique strictement le conditionnement IP-Adapter dans la zone peinte ou chargee par l utilisateur.',
    isFullySupported: true,
    capabilityLabel: 'MASQUE UTILISATEUR',
    capabilityDetail: 'Masque utilisateur prioritaire avec conditionnement IP-Adapter',
    defaultPrompt: 'seamless integration into the masked area, matching texture and lighting',
    defaultStrength: 0.65,
  ),
  legacyHeuristic(
    id: 'legacy_heuristic_r1',
    label: 'Heuristique R1 (sans adaptateur)',
    badgeText: 'FALLBACK SPATIAL',
    description: 'Heuristique R1 est un fallback spatial sans detourage automatique. Utilisez une Image A cadree ou detouree. Pour transferer un visage depuis une photo complete, utilisez Reference visage.',
    isFullySupported: false,
    capabilityLabel: 'FALLBACK HEURISTIQUE',
    capabilityDetail: 'Fallback heuristique spatial PIL R1 (sans conditionnement neuronal direct) — Heuristique R1 est un fallback spatial sans detourage automatique. Utilisez une Image A cadree ou detouree. Pour transferer un visage depuis une photo complete, utilisez Reference visage.',
    defaultPrompt: 'high quality photographic composite, smooth blending',
    defaultStrength: 0.60,
  );

  final String id;
  final String label;
  final String badgeText;
  final String description;
  final bool isFullySupported;
  final String capabilityLabel;
  final String capabilityDetail;
  final String defaultPrompt;
  final double defaultStrength;

  const MultiImageEditMode({
    required this.id,
    required this.label,
    required this.badgeText,
    required this.description,
    required this.isFullySupported,
    required this.capabilityLabel,
    required this.capabilityDetail,
    required this.defaultPrompt,
    required this.defaultStrength,
  });
}

/// Fonction utilitaire robuste pour extraire les octets d'un [PlatformFile]
/// sans supposer que ses octets memoire sont deja alimentes (indispensable sous Windows Desktop).
Future<Uint8List> readPlatformFileBytesRobust(PlatformFile file) async {
  // 1. Chemin physique sur le systeme de fichiers (prioritaire sous Windows Desktop, macOS, Linux)
  final filePath = file.path;
  if (filePath != null && filePath.isNotEmpty) {
    final ioFile = File(filePath);
    if (await ioFile.exists()) {
      return await ioFile.readAsBytes();
    } else {
      throw FileSystemException('Fichier selectionne introuvable ou inaccessible sur le disque', filePath);
    }
  }

  // 2. Octets deja disponibles en memoire (ex: Web ou withData: true)
  // ignore: deprecated_member_use
  final inMemoryBytes = file.bytes;
  if (inMemoryBytes != null && inMemoryBytes.isNotEmpty) {
    return inMemoryBytes;
  }

  // 3. Fallback sur le flux de lecture si disponible (ex: URI cloud Android ou readAsByteStream)
  try {
    final stream = file.readAsByteStream();
    final builder = BytesBuilder(copy: false);
    await for (final chunk in stream) {
      builder.add(chunk);
    }
    final streamBytes = builder.takeBytes();
    if (streamBytes.isNotEmpty) {
      return streamBytes;
    }
  } catch (_) {
    // Si readAsByteStream echoue ou n'est pas supporte
  }

  // 4. Echec clair et explicite
  throw StateError("Donnees inaccessibles pour '${file.name}'. Ni chemin physique ni octets disponibles.");
}

/// Onglet dedie a la modification et composition multi-images dans Jarvisol.
class MultiImageEditWidget extends ConsumerStatefulWidget {
  const MultiImageEditWidget({super.key});

  @override
  ConsumerState<MultiImageEditWidget> createState() => _MultiImageEditWidgetState();
}

class _MultiImageEditWidgetState extends ConsumerState<MultiImageEditWidget> {
  Uint8List? _imageABytes;
  String? _imageAName;

  Uint8List? _imageBBytes;
  String? _imageBName;

  Uint8List? _maskBytes;
  String? _maskName;

  MultiImageEditMode _selectedMode = MultiImageEditMode.referencePersonOrObject;
  String _selectedInpaintModel = 'Realistic_Vision_V6.0_NV_B1_inpainting_fp16.safetensors';
  final List<String> _availableInpaintModels = [
    'Realistic_Vision_V6.0_NV_B1_inpainting_fp16.safetensors',
    'juggernautXL_ragnarok.safetensors',
    'realvisxlV50_v50LightningBakedvae.safetensors',
  ];

  late TextEditingController _promptController;
  double _strength = 0.65;
  int _steps = 25;

  bool _isGenerating = false;
  String? _statusMessage;
  bool _isError = false;

  Uint8List? _resultBytes;
  String? _resultInfo;

  @override
  void initState() {
    super.initState();
    _promptController = TextEditingController(text: _selectedMode.defaultPrompt);
    _strength = _selectedMode.defaultStrength;
  }

  @override
  void dispose() {
    _promptController.dispose();
    super.dispose();
  }

  void _onModeChanged(MultiImageEditMode mode) {
    setState(() {
      _selectedMode = mode;
      _promptController.text = mode.defaultPrompt;
      _strength = mode.defaultStrength;
    });
  }

  Future<Uint8List> _readPlatformFileBytes(PlatformFile file) => readPlatformFileBytesRobust(file);

  Future<void> _pickImageA() async {
    try {
      final file = await FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: const ['png', 'jpg', 'jpeg', 'webp', 'bmp'],
        dialogTitle: 'Charger l Image A (Source / Reference)',
        lockParentWindow: true,
      );
      if (file == null) return;
      final bytes = await _readPlatformFileBytes(file);
      setState(() {
        _imageABytes = bytes;
        _imageAName = file.name;
        _statusMessage = null;
      });
    } catch (e) {
      setState(() {
        _statusMessage = 'Erreur lors du chargement de l Image A : $e';
        _isError = true;
      });
    }
  }

  Future<void> _pickImageB() async {
    try {
      final file = await FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: const ['png', 'jpg', 'jpeg', 'webp', 'bmp'],
        dialogTitle: 'Charger l Image B (Cible / Scene)',
        lockParentWindow: true,
      );
      if (file == null) return;
      final bytes = await _readPlatformFileBytes(file);
      setState(() {
        _imageBBytes = bytes;
        _imageBName = file.name;
        _statusMessage = null;
      });
    } catch (e) {
      setState(() {
        _statusMessage = 'Erreur lors du chargement de l Image B : $e';
        _isError = true;
      });
    }
  }

  Future<void> _pickMask() async {
    try {
      final file = await FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: const ['png', 'jpg', 'jpeg', 'webp', 'bmp'],
        dialogTitle: 'Charger un masque optionnel (noir/blanc)',
        lockParentWindow: true,
      );
      if (file == null) return;
      final bytes = await _readPlatformFileBytes(file);
      setState(() {
        _maskBytes = bytes;
        _maskName = file.name;
        _statusMessage = null;
      });
    } catch (e) {
      setState(() {
        _statusMessage = 'Erreur lors du chargement du masque : $e';
        _isError = true;
      });
    }
  }

  void _clearMask() {
    setState(() {
      _maskBytes = null;
      _maskName = null;
    });
  }

  void _resetAll() {
    setState(() {
      _imageABytes = null;
      _imageAName = null;
      _imageBBytes = null;
      _imageBName = null;
      _maskBytes = null;
      _maskName = null;
      _resultBytes = null;
      _resultInfo = null;
      _statusMessage = null;
      _isError = false;
      _promptController.text = _selectedMode.defaultPrompt;
      _strength = _selectedMode.defaultStrength;
    });
  }

  Future<void> _generateComposition() async {
    if (_imageABytes == null || _imageBBytes == null) {
      setState(() {
        _resultBytes = null;
        _statusMessage = 'Veuillez charger l Image A (source) et l Image B (cible).';
        _isError = true;
      });
      return;
    }

    // Refus clair et explicite de tout modele SDXL dans un mode requerant IP-Adapter SD 1.5
    final isAdapterMode = _selectedMode == MultiImageEditMode.referencePersonOrObject ||
        _selectedMode == MultiImageEditMode.referenceFace ||
        _selectedMode == MultiImageEditMode.autoFaceDetect;
    final isSdxl = !_selectedInpaintModel.contains('Realistic_Vision') &&
        !_selectedInpaintModel.contains('v1-5');

    if (isAdapterMode && isSdxl) {
      setState(() {
        _resultBytes = null;
        _statusMessage =
            'Incompatibilite : Le mode "${_selectedMode.label}" requiert un modele SD 1.5 (ex: Realistic_Vision) pour fonctionner avec IP-Adapter. Le modele SDXL "$_selectedInpaintModel" est incompatible avec ce mode.';
        _isError = true;
      });
      return;
    }

    setState(() {
      _resultBytes = null;
      _isGenerating = true;
      _statusMessage = 'Generation en cours avec le moteur neural local...';
      _isError = false;
    });

    try {
      final aB64 = base64Encode(_imageABytes!);
      final bB64 = base64Encode(_imageBBytes!);
      final maskB64 = _maskBytes != null ? base64Encode(_maskBytes!) : '';

      final bodyData = jsonEncode({
        'image_a': aB64,
        'image_b': bB64,
        'mask': maskB64,
        'mode': _selectedMode.id,
        'prompt': _promptController.text.trim(),
        'strength': _strength,
        'steps': _steps,
        'model': _selectedInpaintModel,
      });

      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 15);
      final req = await client.postUrl(Uri.parse('http://127.0.0.1:7860/edit/multi-image'));
      req.headers.set('Content-Type', 'application/json; charset=utf-8');
      final bodyBytes = utf8.encode(bodyData);
      req.contentLength = bodyBytes.length;
      req.add(bodyBytes);

      final res = await req.close().timeout(TimeoutPolicy.imageGenLocalAttempt);
      final respStr = await res.transform(utf8.decoder).join();

      if (res.statusCode == 200) {
        final data = jsonDecode(respStr) as Map<String, dynamic>;
        final images = data['images'] as List<dynamic>?;
        if (images != null && images.isNotEmpty) {
          final outB64 = images.first as String;
          final outBytes = base64Decode(outB64);
          final pipelineType = data['pipeline_type'] as String? ?? 'NATIVE_IP_ADAPTER';
          final modelUsed = data['inpaint_model_used'] as String? ?? _selectedInpaintModel;
          final ipAdapterUsed = data['ip_adapter_used'] as String?;
          final detectorUsed = data['detector_used'] as String?;
          final detail = data['capability_detail'] as String? ?? '';

          setState(() {
            _resultBytes = outBytes;
            _resultInfo = 'Pipeline : $pipelineType\nModele Inpaint : $modelUsed\nAdaptateur : ${ipAdapterUsed ?? "Aucun"}${detectorUsed != null ? "\nDetecteur : $detectorUsed" : ""}\n$detail';
            _statusMessage = 'Composition generee avec succes ! (${_selectedMode.capabilityLabel})';
            _isError = false;
          });
        } else {
          throw Exception('Reponse serveur invalide (aucune image retournee).');
        }
      } else {
        Map<String, dynamic>? errJson;
        try {
          errJson = jsonDecode(respStr) as Map<String, dynamic>?;
        } catch (_) {}
        final errText = errJson?['error']?.toString() ?? 'Erreur serveur HTTP ${res.statusCode}';
        setState(() {
          _resultBytes = null;
          if (errText.contains('NO_FACE_DETECTED')) {
            _statusMessage = "Visage automatique : aucun visage détecté dans l'image cible.";
          } else {
            _statusMessage = 'Echec : $errText';
          }
          _isError = true;
        });
      }
    } catch (e) {
      setState(() {
        _resultBytes = null;
        _statusMessage = 'Erreur de communication : $e';
        _isError = true;
      });
    } finally {
      if (mounted) setState(() => _isGenerating = false);
    }
  }

  Future<void> _exportResult() async {
    if (_resultBytes == null) return;
    try {
      final ts = DateTime.now().millisecondsSinceEpoch;
      final defaultName = 'multi_edit_${_selectedMode.name}_$ts.png';
      final savedPath = await FilePicker.saveFile(
        dialogTitle: 'Exporter la composition',
        fileName: defaultName,
        type: FileType.custom,
        allowedExtensions: const ['png', 'jpg'],
        bytes: _resultBytes!,
        lockParentWindow: true,
      );
      if (savedPath != null) {
        setState(() {
          _statusMessage = 'Image exportee sous : $savedPath';
          _isError = false;
        });
      }
    } catch (e) {
      setState(() {
        _statusMessage = 'Erreur lors de l export : $e';
        _isError = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Titre et Description
          Row(
            children: [
              const Icon(Icons.auto_fix_high, size: 28, color: Colors.indigoAccent),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Composition & Edition Multi-Images',
                      style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
                    ),
                    Text(
                      'Combinez Image A (source/reference) et Image B (cible/scene) avec harmonisation neurale.',
                      style: theme.textTheme.bodySmall?.copyWith(color: isDark ? Colors.white70 : Colors.black54),
                    ),
                  ],
                ),
              ),
              IconButton(
                icon: const Icon(Icons.refresh),
                tooltip: 'Reinitialiser tout',
                onPressed: _resetAll,
              ),
            ],
          ),
          const SizedBox(height: 16),

          // Zone des 3 Panneaux d Images (A, B, Masque)
          LayoutBuilder(
            builder: (context, constraints) {
              final isNarrow = constraints.maxWidth < 750;
              final imagePanels = [
                _buildImageSlot(
                  title: 'Image A (Source / Reference)',
                  subtitle: 'Personnage, objet ou reference',
                  icon: Icons.filter_1,
                  badgeColor: Colors.blueAccent,
                  badgeText: 'SOURCE',
                  imageBytes: _imageABytes,
                  fileName: _imageAName,
                  onPick: _pickImageA,
                  onClear: () => setState(() { _imageABytes = null; _imageAName = null; }),
                ),
                _buildImageSlot(
                  title: 'Image B (Cible / Scene)',
                  subtitle: 'Arriere-plan, decor ou scene finale',
                  icon: Icons.filter_2,
                  badgeColor: Colors.teal,
                  badgeText: 'CIBLE',
                  imageBytes: _imageBBytes,
                  fileName: _imageBName,
                  onPick: _pickImageB,
                  onClear: () => setState(() { _imageBBytes = null; _imageBName = null; }),
                ),
                _buildImageSlot(
                  title: 'Masque Optionnel (Sur B)',
                  subtitle: 'Zone de placement (blanc = inserer)',
                  icon: Icons.brush,
                  badgeColor: Colors.purpleAccent,
                  badgeText: 'OPTIONNEL',
                  imageBytes: _maskBytes,
                  fileName: _maskName,
                  onPick: _pickMask,
                  onClear: _clearMask,
                ),
              ];

              if (isNarrow) {
                return Column(
                  children: imagePanels.map((p) => Padding(padding: const EdgeInsets.only(bottom: 12), child: p)).toList(),
                );
              }
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: imagePanels.map((p) => Expanded(child: Padding(padding: const EdgeInsets.symmetric(horizontal: 6), child: p))).toList(),
              );
            },
          ),
          const SizedBox(height: 16),

          // Carte Modele Inpainting Actif (Visibilite obligatoire & Transparence)
          Card(
            elevation: 1,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.memory, size: 20, color: Colors.teal),
                      const SizedBox(width: 8),
                      Text(
                        'Modele inpainting actif (aucune substitution silencieuse) :',
                        style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
                      ),
                      const Spacer(),
                      if (_selectedInpaintModel.contains('Realistic_Vision') || _selectedInpaintModel.contains('v1-5'))
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: Colors.green.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(color: Colors.green),
                          ),
                          child: const Text('SD 1.5 COMPATIBLE', style: TextStyle(color: Colors.green, fontSize: 10, fontWeight: FontWeight.bold)),
                        )
                      else
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: Colors.red.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(color: Colors.red),
                          ),
                          child: const Text('INCOMPATIBLE IP-ADAPTER', style: TextStyle(color: Colors.red, fontSize: 10, fontWeight: FontWeight.bold)),
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  DropdownButtonFormField<String>(
                    initialValue: _selectedInpaintModel,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    ),
                    items: _availableInpaintModels.map((m) {
                      return DropdownMenuItem<String>(
                        value: m,
                        child: Text(m, style: const TextStyle(fontSize: 13)),
                      );
                    }).toList(),
                    onChanged: (val) {
                      if (val != null) setState(() => _selectedInpaintModel = val);
                    },
                  ),
                  if (!_selectedInpaintModel.contains('Realistic_Vision') && !_selectedInpaintModel.contains('v1-5')) ...[
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Colors.amber.shade900.withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: Colors.amber),
                      ),
                      child: const Text(
                        'Attention : Ce modele SDXL ne prend pas en charge les adaptateurs IP-Adapter SD1.5. '
                        'Veuillez selectionner Realistic_Vision_V6.0_NV_B1_inpainting_fp16 pour beneficier des pipelines IP-Adapter et ADetailer.',
                        style: TextStyle(fontSize: 11, color: Colors.amber),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          // Selecteur de Mode d Operation
          Card(
            elevation: 1,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.tune, size: 20),
                      const SizedBox(width: 8),
                      Text('Mode d operation :', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
                      const Spacer(),
                      _buildCapabilityBadge(_selectedMode),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: MultiImageEditMode.values.map((mode) {
                      final isSelected = _selectedMode == mode;
                      return ChoiceChip(
                        label: Text(mode.label),
                        selected: isSelected,
                        selectedColor: isDark ? Colors.indigo.shade700 : Colors.indigo.shade100,
                        onSelected: (sel) {
                          if (sel) _onModeChanged(mode);
                        },
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 10),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: _selectedMode.isFullySupported
                          ? (isDark ? Colors.green.shade900.withValues(alpha: 0.3) : Colors.green.shade50)
                          : (isDark ? Colors.amber.shade900.withValues(alpha: 0.3) : Colors.amber.shade50),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: _selectedMode.isFullySupported
                            ? (isDark ? Colors.green.shade700 : Colors.green.shade300)
                            : (isDark ? Colors.amber.shade700 : Colors.amber.shade400),
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          _selectedMode.isFullySupported ? Icons.check_circle_outline : Icons.warning_amber_rounded,
                          color: _selectedMode.isFullySupported ? Colors.green : Colors.amber.shade800,
                          size: 20,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            _selectedMode.capabilityDetail,
                            style: TextStyle(
                              fontSize: 12,
                              color: _selectedMode.isFullySupported
                                  ? (isDark ? Colors.green.shade200 : Colors.green.shade900)
                                  : (isDark ? Colors.amber.shade200 : Colors.amber.shade900),
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 10),
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: isDark ? Colors.blueGrey.shade900.withValues(alpha: 0.4) : Colors.blueGrey.shade50,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: isDark ? Colors.blueGrey.shade700 : Colors.blueGrey.shade300),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Icon(Icons.info_outline, size: 16, color: Colors.blueAccent),
                            const SizedBox(width: 6),
                            Text(
                              'Garanties et limites techniques reelles :',
                              style: theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.bold),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        const Text(
                          '• ADetailer : Detection automatique de la zone du visage (boite englobante YOLOv8 — pas de segmentation pixel-par-pixel d objets arbitraires).\n'
                          '• IP-Adapter Face : Ressemblance faciale renforcee — Aucune pretention d identite biometrique stricte.\n'
                          '• Masque utilisateur : Recommande pour les objets arbitraires ou les contours precis.',
                          style: TextStyle(fontSize: 11, height: 1.3),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          // Parametres & Prompt
          Card(
            elevation: 1,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Prompt descriptif pour l harmonisation :', style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _promptController,
                    maxLines: 2,
                    decoration: const InputDecoration(
                      hintText: 'Decrivez l integration, la lumiere, les details ou le style souhaite...',
                      border: OutlineInputBorder(),
                      contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    ),
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Force de retouche (Strength) : ${_strength.toStringAsFixed(2)}', style: const TextStyle(fontSize: 12)),
                            Slider(
                              value: _strength,
                              min: 0.20,
                              max: 0.90,
                              divisions: 14,
                              label: _strength.toStringAsFixed(2),
                              onChanged: (val) => setState(() => _strength = val),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Etapes (Steps) : $_steps', style: const TextStyle(fontSize: 12)),
                            Slider(
                              value: _steps.toDouble(),
                              min: 10,
                              max: 40,
                              divisions: 6,
                              label: '$_steps',
                              onChanged: (val) => setState(() => _steps = val.toInt()),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      backgroundColor: Colors.indigoAccent,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                    icon: _isGenerating
                        ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                        : const Icon(Icons.bolt),
                    label: Text(
                      _isGenerating ? 'Harmonisation neurale en cours...' : 'Lancer la composition',
                      style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                    ),
                    onPressed: _isGenerating ? null : _generateComposition,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          // Statut Banner
          if (_statusMessage != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              margin: const EdgeInsets.only(bottom: 16),
              decoration: BoxDecoration(
                color: _isError
                    ? (isDark ? Colors.red.shade900.withValues(alpha: 0.4) : Colors.red.shade50)
                    : (isDark ? Colors.green.shade900.withValues(alpha: 0.4) : Colors.green.shade50),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: _isError ? Colors.redAccent : Colors.green),
              ),
              child: Text(
                _statusMessage!,
                style: TextStyle(
                  color: _isError
                      ? (isDark ? Colors.red.shade200 : Colors.red.shade900)
                      : (isDark ? Colors.green.shade200 : Colors.green.shade900),
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),

          // Resultat
          if (_resultBytes != null)
            Card(
              elevation: 2,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.check_circle, color: Colors.green),
                        const SizedBox(width: 8),
                        Text('Resultat de la composition :', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
                        const Spacer(),
                        ElevatedButton.icon(
                          icon: const Icon(Icons.save_alt, size: 18),
                          label: const Text('Sauvegarder / Exporter'),
                          onPressed: _exportResult,
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Center(
                      child: Container(
                        constraints: const BoxConstraints(maxHeight: 500),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.grey.shade400),
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: Image.memory(_resultBytes!),
                      ),
                    ),
                    if (_resultInfo != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        _resultInfo!,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodySmall?.copyWith(color: isDark ? Colors.white60 : Colors.black54),
                      ),
                    ],
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildCapabilityBadge(MultiImageEditMode mode) {
    final Color col = mode.isFullySupported ? Colors.green : Colors.amber;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: col.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: col),
      ),
      child: Text(
        mode.badgeText,
        style: TextStyle(color: col, fontSize: 10, fontWeight: FontWeight.bold),
      ),
    );
  }

  Widget _buildImageSlot({
    required String title,
    required String subtitle,
    required IconData icon,
    required Color badgeColor,
    required String badgeText,
    required Uint8List? imageBytes,
    required String? fileName,
    required VoidCallback onPick,
    required VoidCallback onClear,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      height: 240,
      decoration: BoxDecoration(
        color: isDark ? Colors.grey.shade900 : Colors.grey.shade100,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: isDark ? Colors.grey.shade800 : Colors.grey.shade300),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // En-tete
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: isDark ? Colors.grey.shade800 : Colors.grey.shade200,
              borderRadius: const BorderRadius.vertical(top: Radius.circular(9)),
            ),
            child: Row(
              children: [
                Icon(icon, size: 16),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: badgeColor.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    badgeText,
                    style: TextStyle(color: badgeColor, fontSize: 9, fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
          ),
          // Contenu (Apercu ou bouton d ajout)
          Expanded(
            child: imageBytes == null
                ? InkWell(
                    onTap: onPick,
                    child: Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.add_photo_alternate_outlined, size: 36, color: isDark ? Colors.white38 : Colors.black38),
                          const SizedBox(height: 6),
                          Text('Cliquer pour charger', style: TextStyle(fontSize: 11, color: isDark ? Colors.white60 : Colors.black54)),
                          Text(subtitle, style: TextStyle(fontSize: 9, color: isDark ? Colors.white30 : Colors.black38)),
                        ],
                      ),
                    ),
                  )
                : Stack(
                    fit: StackFit.expand,
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(6),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(6),
                          child: Image.memory(imageBytes, fit: BoxFit.contain),
                        ),
                      ),
                      Positioned(
                        top: 6,
                        right: 6,
                        child: CircleAvatar(
                          radius: 14,
                          backgroundColor: Colors.black54,
                          child: IconButton(
                            padding: EdgeInsets.zero,
                            icon: const Icon(Icons.close, size: 16, color: Colors.white),
                            onPressed: onClear,
                          ),
                        ),
                      ),
                      if (fileName != null)
                        Positioned(
                          bottom: 4,
                          left: 4,
                          right: 4,
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: Colors.black87,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              fileName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.center,
                              style: const TextStyle(color: Colors.white, fontSize: 10),
                            ),
                          ),
                        ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}
