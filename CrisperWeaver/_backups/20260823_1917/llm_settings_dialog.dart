import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart' as url_launcher;
import '../models/prompt_item.dart';
import '../services/ai_knowledge_service.dart';
import '../services/document_rag_service.dart';
import '../services/litert_model_registry.dart';
import '../services/llm_service.dart';
import '../services/mcp_tools_service.dart';
import '../services/settings_service.dart';
import '../models/cloud_llm_provider_profile.dart';
import '../utils/platform_utils.dart' as plat;
import 'prompt_library_dialog.dart';

/// Opens the unified LLM Configuration and Model Management dialog.
Future<void> showLlmSettingsDialog(
  BuildContext context,
  WidgetRef ref, {
  VoidCallback? onModelChanged,
}) async {
  final settings = ref.read(settingsServiceProvider);
  final llm = ref.read(llmServiceProvider);

  var selectedProvider = settings.llmProvider;
  final urlController = TextEditingController(text: settings.llmApiUrl);
  final modelController = TextEditingController(text: settings.llmModel);
  final embeddingController = TextEditingController(text: settings.llmEmbeddingModel);
  final apiKeyController = TextEditingController(text: settings.llmApiKey);
  final tokenController = TextEditingController(text: settings.hfToken);
  final imageGenUrlController = TextEditingController(text: settings.imageGenApiUrl);
  final cloudNameController = TextEditingController();
  bool isObscureApiKey = true;

  String selectedProviderKey;
  if (settings.llmProvider == LlmProvider.custom && settings.activeCloudProviderId.isNotEmpty) {
    selectedProviderKey = 'cloud_${settings.activeCloudProviderId}';
  } else if (settings.llmProvider == LlmProvider.custom) {
    if (settings.customCloudProviders.isNotEmpty) {
      selectedProviderKey = 'cloud_${settings.customCloudProviders.first.id}';
    } else {
      selectedProviderKey = 'local_litert_windows';
    }
  } else {
    selectedProviderKey = 'local_${settings.llmProvider.id}';
  }

  // dialogModels DOIT être déclaré AVANT syncWithSelectedProvider qui le référence
  List<String> dialogModels = [];
  if (settings.llmModel.isNotEmpty) {
    dialogModels.add(settings.llmModel);
  }
  for (final m in LiteRtModelRegistry().models) {
    if (m.isDownloaded && m.localPath != null && m.localPath!.isNotEmpty && !dialogModels.contains(m.localPath)) {
      dialogModels.add(m.localPath!);
    }
  }

  void syncWithSelectedProvider(String key) {
    if (key.startsWith('cloud_')) {
      final pid = key.replaceFirst('cloud_', '');
      final match = settings.customCloudProviders.where((p) => p.id == pid).toList();
      if (match.isNotEmpty) {
        final cp = match.first;
        cloudNameController.text = cp.name;
        urlController.text = cp.endpoint;
        apiKeyController.text = cp.apiKey;
        modelController.text = cp.defaultModel;
        dialogModels.clear();
        dialogModels.addAll(cp.cachedModels);
        if (!dialogModels.contains(cp.defaultModel) && cp.defaultModel.isNotEmpty) {
          dialogModels.add(cp.defaultModel);
        }
      }
    } else if (key == 'local_litert_windows') {
      selectedProvider = LlmProvider.liteRtWindows;
      urlController.text = LlmProvider.liteRtWindows.defaultEndpoint;
      apiKeyController.text = '';
    } else if (key == 'local_lmstudio') {
      selectedProvider = LlmProvider.lmStudio;
      urlController.text = LlmProvider.lmStudio.defaultEndpoint;
      apiKeyController.text = '';
    } else if (key == 'local_ollama') {
      selectedProvider = LlmProvider.ollama;
      urlController.text = LlmProvider.ollama.defaultEndpoint;
      apiKeyController.text = '';
    } else if (key == 'local_litert_android') {
      selectedProvider = LlmProvider.liteRtAndroid;
      urlController.text = LlmProvider.liteRtAndroid.defaultEndpoint;
      apiKeyController.text = '';
    }
  }

  syncWithSelectedProvider(selectedProviderKey);

  if (urlController.text.isEmpty) {
    urlController.text = selectedProvider.defaultEndpoint;
  }

  // Synchroniser les curseurs avec le modèle actif
  settings.llmTemperature = settings.getModelTemperature(settings.llmModel);
  settings.llmMaxTokens = settings.getModelMaxTokens(settings.llmModel);

  List<String> imageModels = [];
  try {
    imageModels = await ref.read(mcpToolsServiceProvider).listAvailableImageModels();
    if (imageModels.isNotEmpty && (settings.activeImageModel.isEmpty || !imageModels.contains(settings.activeImageModel))) {
      settings.activeImageModel = imageModels.first;
    }
  } catch (_) {}

  bool isFetchingModels = false;
  bool isCustomModelEntry = false;
  bool hasInitialFetched = false;

  await showDialog<void>(
    context: context, // ignore: use_build_context_synchronously
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setDialogState) {
        Future<void> fetchAndroidModels() async {
          if (ctx.mounted) setDialogState(() => isFetchingModels = true);
          try {
            await LiteRtModelRegistry().init();
            await LiteRtModelRegistry().refreshLocalStatus();

            final regModels = LiteRtModelRegistry().models
                .where((m) => m.isDownloaded && m.localPath != null && m.localPath!.isNotEmpty)
                .map((m) => m.id)
                .toList();

            final combined = <String>{...regModels};
            if (combined.isEmpty) {
              combined.add('gemma-4-e4b-it');
            }
            if (settings.llmModel.isNotEmpty && combined.contains(settings.llmModel)) {
              combined.add(settings.llmModel);
            }
            if (ctx.mounted) {
              setDialogState(() {
                dialogModels = combined.toList();
                isFetchingModels = false;
                if (combined.isNotEmpty && (modelController.text.isEmpty || !combined.contains(modelController.text))) {
                  modelController.text = combined.first;
                }
              });
            }
          } catch (_) {
            if (ctx.mounted) setDialogState(() => isFetchingModels = false);
          } finally {
            if (ctx.mounted && isFetchingModels) {
              setDialogState(() => isFetchingModels = false);
            }
          }
        }

        Future<void> fetchModels() async {
          if (selectedProviderKey == 'local_litert_android' || selectedProviderKey == 'local_litert_windows') {
            return fetchAndroidModels();
          }
          if (ctx.mounted) setDialogState(() => isFetchingModels = true);
          try {
            final apiKey = selectedProviderKey.startsWith('cloud_') ? apiKeyController.text.trim() : null;
            final models = await llm.fetchModelsForEndpoint(urlController.text, apiKey: apiKey);
            if (ctx.mounted) {
              setDialogState(() {
                dialogModels = models;
                isFetchingModels = false;
                if (models.isNotEmpty) {
                  if (modelController.text.isEmpty ||
                      (!isCustomModelEntry && !models.contains(modelController.text))) {
                    modelController.text = models.first;
                  }
                }
              });
            }
          } catch (_) {
            if (ctx.mounted) setDialogState(() => isFetchingModels = false);
          } finally {
            if (ctx.mounted && isFetchingModels) {
              setDialogState(() => isFetchingModels = false);
            }
          }
        }

        Future<void> fetchImageModels() async {
          try {
            final mcp = ref.read(mcpToolsServiceProvider);
            final list = await mcp.listAvailableImageModels();
            if (ctx.mounted) {
              setDialogState(() {
                imageModels = list;
                if (list.isNotEmpty && (settings.activeImageModel.isEmpty || !list.contains(settings.activeImageModel))) {
                  settings.activeImageModel = list.first;
                }
              });
            }
          } catch (_) {}
        }

        if (!hasInitialFetched) {
          hasInitialFetched = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            fetchModels();
            fetchImageModels();
          });
        }

        return AlertDialog(
          title: const Row(
            children: [
              Icon(Icons.smart_toy_outlined, color: Colors.blueAccent),
              SizedBox(width: 8),
              Text('Configuration Moteurs LLM (Local & Cloud)'),
            ],
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Connectez CrisperWeaver à vos serveurs locaux ou configurez vos fournisseurs Cloud (OpenAI, Groq, Mistral, etc.).',
                  style: TextStyle(fontSize: 12, color: Colors.grey),
                ),
                const SizedBox(height: 16),
                DropdownButtonFormField<String>(
                  initialValue: selectedProviderKey,
                  decoration: const InputDecoration(
                    labelText: 'Fournisseur / Serveur LLM',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  items: [
                    if (!plat.isAndroid) ...[
                      const DropdownMenuItem(
                        value: 'local_litert_windows',
                        child: Text('🖥️ Google LiteRT-LM (Serveur Windows)', style: TextStyle(fontSize: 13)),
                      ),
                      const DropdownMenuItem(
                        value: 'local_lmstudio',
                        child: Text('🖥️ LM Studio (Local)', style: TextStyle(fontSize: 13)),
                      ),
                      const DropdownMenuItem(
                        value: 'local_ollama',
                        child: Text('🖥️ Ollama (Local)', style: TextStyle(fontSize: 13)),
                      ),
                    ] else ...[
                      const DropdownMenuItem(
                        value: 'local_litert_android',
                        child: Text('📱 Google LiteRT-LM (Embarqué Android)', style: TextStyle(fontSize: 13)),
                      ),
                    ],
                    for (final cp in settings.customCloudProviders)
                      DropdownMenuItem(
                        value: 'cloud_${cp.id}',
                        child: Text('☁️ ${cp.name}', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                      ),
                    const DropdownMenuItem(
                      value: 'add_new_cloud',
                      child: Text('➕ [ + Ajouter un Fournisseur Cloud (OpenAI, Groq, Mistral...)... ]',
                          style: TextStyle(fontSize: 13, color: Colors.blueAccent, fontWeight: FontWeight.bold)),
                    ),
                  ],
                  onChanged: (val) {
                    if (val == null) return;
                    if (val == 'add_new_cloud') {
                      final newId = 'cloud_${DateTime.now().millisecondsSinceEpoch}';
                      final defaultPreset = CloudLlmProviderProfile.presets.first;
                      setDialogState(() {
                        selectedProviderKey = newId;
                        cloudNameController.text = defaultPreset.name;
                        urlController.text = defaultPreset.endpoint;
                        apiKeyController.text = '';
                        modelController.text = defaultPreset.defaultModel;
                        dialogModels = List.from(defaultPreset.cachedModels);
                        isCustomModelEntry = false;
                      });
                      return;
                    }
                    setDialogState(() {
                      selectedProviderKey = val;
                      isCustomModelEntry = false;
                      syncWithSelectedProvider(val);
                    });
                    fetchModels();
                  },
                ),
                if (selectedProviderKey == 'local_litert_android' || selectedProviderKey == 'local_litert_windows') ...[
                  const SizedBox(height: 14),
                  DefaultTabController(
                    length: 3,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const TabBar(
                          labelColor: Colors.blueAccent,
                          unselectedLabelColor: Colors.grey,
                          indicatorColor: Colors.blueAccent,
                          labelStyle: TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                          tabs: [
                            Tab(icon: Icon(Icons.check_circle_outline, size: 16), text: 'Installés'),
                            Tab(icon: Icon(Icons.cloud_download_outlined, size: 16), text: 'Catalogue'),
                            Tab(icon: Icon(Icons.tune, size: 16), text: 'Paramètres'),
                          ],
                        ),
                        const SizedBox(height: 12),
                        SizedBox(
                          height: 290,
                          child: TabBarView(
                            children: [
                              // TAB 1: Modèles Détectés / Installés
                              SingleChildScrollView(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    if (dialogModels.isNotEmpty) ...[
                                      DropdownButtonFormField<String>(
                                        isExpanded: true,
                                        initialValue: dialogModels.contains(modelController.text)
                                            ? modelController.text
                                            : dialogModels.first,
                                        decoration: InputDecoration(
                                          labelText: 'Modèle actif',
                                          border: const OutlineInputBorder(),
                                          isDense: true,
                                          prefixIcon: const Icon(Icons.memory, size: 18, color: Colors.blueAccent),
                                          suffixIcon: isFetchingModels
                                              ? const Padding(
                                                  padding: EdgeInsets.all(12),
                                                  child: SizedBox(
                                                    width: 14,
                                                    height: 14,
                                                    child: CircularProgressIndicator(strokeWidth: 2),
                                                  ),
                                                )
                                              : null,
                                        ),
                                        items: dialogModels.map((m) {
                                          final filename = p.basename(m);
                                          return DropdownMenuItem(
                                            value: m,
                                            child: Text(
                                              filename,
                                              overflow: TextOverflow.ellipsis,
                                              style: const TextStyle(fontSize: 12),
                                            ),
                                          );
                                        }).toList(),
                                        onChanged: (val) {
                                          if (val != null) {
                                            setDialogState(() {
                                              modelController.text = val;
                                              settings.llmTemperature = settings.getModelTemperature(val);
                                              settings.llmMaxTokens = settings.getModelMaxTokens(val);
                                            });
                                          }
                                        },
                                      ),
                                      const SizedBox(height: 10),
                                      Wrap(
                                        spacing: 8,
                                        runSpacing: 6,
                                        children: [
                                          OutlinedButton.icon(
                                            icon: isFetchingModels
                                                ? const SizedBox(
                                                    width: 12,
                                                    height: 12,
                                                    child: CircularProgressIndicator(strokeWidth: 2),
                                                  )
                                                : const Icon(Icons.refresh, size: 14),
                                            label: const Text('Actualiser', style: TextStyle(fontSize: 11)),
                                            onPressed: isFetchingModels ? null : fetchAndroidModels,
                                          ),
                                          if (plat.isAndroid)
                                            FilledButton.tonalIcon(
                                              icon: const Icon(Icons.folder_open_rounded, size: 14),
                                              label: const Text('Importer', style: TextStyle(fontSize: 11)),
                                              onPressed: () async {
                                                try {
                                                  final nativePath = await const MethodChannel('crisperweaver/litert_lm')
                                                      .invokeMethod<String>('pickModelNative');
                                                  if (nativePath != null && nativePath.isNotEmpty) {
                                                    setDialogState(() {
                                                      modelController.text = nativePath;
                                                      if (!dialogModels.contains(nativePath)) {
                                                        dialogModels.add(nativePath);
                                                      }
                                                    });
                                                  }
                                                } catch (_) {}
                                              },
                                            ),
                                          if (plat.isAndroid)
                                            OutlinedButton.icon(
                                              icon: const Icon(Icons.delete_outline, size: 14, color: Colors.redAccent),
                                              label: const Text('Supprimer', style: TextStyle(fontSize: 11, color: Colors.redAccent)),
                                              onPressed: modelController.text.isEmpty
                                                  ? null
                                                  : () async {
                                                      final currentPath = modelController.text;
                                                      final confirm = await showDialog<bool>(
                                                        context: context,
                                                        builder: (delCtx) => AlertDialog(
                                                          title: const Text('Supprimer ce modèle ?'),
                                                          content: Text('Voulez-vous supprimer définitivement ${p.basename(currentPath)} de votre stockage ?'),
                                                          actions: [
                                                            TextButton(
                                                              onPressed: () => Navigator.of(delCtx).pop(false),
                                                              child: const Text('Annuler'),
                                                            ),
                                                            ElevatedButton(
                                                              style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
                                                              onPressed: () => Navigator.of(delCtx).pop(true),
                                                              child: const Text('Supprimer'),
                                                            ),
                                                          ],
                                                        ),
                                                      );
                                                      if (confirm == true) {
                                                        try {
                                                          await const MethodChannel('crisperweaver/litert_lm')
                                                              .invokeMethod('deleteLocalModel', {'modelPath': currentPath});
                                                          await fetchAndroidModels();
                                                          await LiteRtModelRegistry().refreshLocalStatus();
                                                        } catch (_) {}
                                                      }
                                                    },
                                            ),
                                        ],
                                      ),
                                    ] else ...[
                                      Container(
                                        padding: const EdgeInsets.all(12),
                                        decoration: BoxDecoration(
                                          color: Colors.blueGrey.withValues(alpha: 0.1),
                                          borderRadius: BorderRadius.circular(8),
                                        ),
                                        child: const Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              'Aucun modèle détecté dans le stockage.',
                                              style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                                            ),
                                            SizedBox(height: 4),
                                            Text(
                                              '👉 Téléchargez un modèle dans l\'onglet "Catalogue" ou importez un fichier .bin / .litertlm.',
                                              style: TextStyle(fontSize: 11, color: Colors.grey),
                                            ),
                                          ],
                                        ),
                                      ),
                                      const SizedBox(height: 10),
                                      Wrap(
                                        spacing: 8,
                                        runSpacing: 6,
                                        children: [
                                          OutlinedButton.icon(
                                            icon: const Icon(Icons.refresh, size: 14),
                                            label: const Text('Actualiser', style: TextStyle(fontSize: 11)),
                                            onPressed: fetchAndroidModels,
                                          ),
                                          if (plat.isAndroid)
                                            FilledButton.tonalIcon(
                                              icon: const Icon(Icons.folder_open_rounded, size: 14),
                                              label: const Text('Importer...', style: TextStyle(fontSize: 11)),
                                              onPressed: () async {
                                                try {
                                                  final nativePath = await const MethodChannel('crisperweaver/litert_lm')
                                                      .invokeMethod<String>('pickModelNative');
                                                  if (nativePath != null && nativePath.isNotEmpty) {
                                                    setDialogState(() {
                                                      modelController.text = nativePath;
                                                      if (!dialogModels.contains(nativePath)) {
                                                        dialogModels.add(nativePath);
                                                      }
                                                    });
                                                  }
                                                } catch (_) {}
                                              },
                                            ),
                                        ],
                                      ),
                                    ],
                                  ],
                                ),
                              ),

                              // TAB 2: Catalogue & Téléchargements (Google Edge Gallery)
                              FutureBuilder<void>(
                                future: LiteRtModelRegistry().init(),
                                builder: (context, snapshot) {
                                  final registry = LiteRtModelRegistry();
                                  final modelsList = registry.models;
                                  return StreamBuilder<List<LiteRtModelEntry>>(
                                    stream: registry.modelsStream,
                                    initialData: modelsList,
                                    builder: (context, snap) {
                                      final currentModels = snap.data ?? modelsList;
                                      return ListView.separated(
                                        itemCount: currentModels.length,
                                        separatorBuilder: (_, __) => const Divider(height: 1),
                                        itemBuilder: (context, idx) {
                                          final m = currentModels[idx];
                                          final isInstalled = m.isDownloaded || (m.localPath != null && File(m.localPath!).existsSync());
                                          return Padding(
                                            padding: const EdgeInsets.symmetric(vertical: 4),
                                            child: Row(
                                              children: [
                                                Expanded(
                                                  child: Column(
                                                    crossAxisAlignment: CrossAxisAlignment.start,
                                                    children: [
                                                      Wrap(
                                                        crossAxisAlignment: WrapCrossAlignment.center,
                                                        spacing: 6,
                                                        children: [
                                                          Text(
                                                            m.name,
                                                            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                                                          ),
                                                          if (isInstalled)
                                                            Container(
                                                              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                                                              decoration: BoxDecoration(
                                                                color: Colors.green.shade900.withValues(alpha: 0.35),
                                                                borderRadius: BorderRadius.circular(4),
                                                                border: Border.all(color: Colors.greenAccent, width: 0.8),
                                                              ),
                                                              child: const Row(
                                                                mainAxisSize: MainAxisSize.min,
                                                                children: [
                                                                  Icon(Icons.check_circle, size: 10, color: Colors.greenAccent),
                                                                  SizedBox(width: 3),
                                                                  Text(
                                                                    'Présent sur le PC',
                                                                    style: TextStyle(fontSize: 9, color: Colors.greenAccent, fontWeight: FontWeight.bold),
                                                                  ),
                                                                ],
                                                              ),
                                                            ),
                                                        ],
                                                      ),
                                                      Text(
                                                        '${m.sizeDisplay} • ${m.description}',
                                                        style: const TextStyle(fontSize: 10, color: Colors.grey),
                                                        maxLines: 2,
                                                        overflow: TextOverflow.ellipsis,
                                                      ),
                                                      if (m.isDownloading)
                                                        Padding(
                                                          padding: const EdgeInsets.only(top: 4),
                                                          child: Column(
                                                            crossAxisAlignment: CrossAxisAlignment.start,
                                                            children: [
                                                              LinearProgressIndicator(value: m.downloadProgress > 0 ? m.downloadProgress : null),
                                                              const SizedBox(height: 2),
                                                              Text(
                                                                '${(m.downloadProgress * 100).toStringAsFixed(1)}% (${m.downloadSpeed})',
                                                                style: const TextStyle(fontSize: 9, color: Colors.blueAccent),
                                                              ),
                                                            ],
                                                          ),
                                                        ),
                                                    ],
                                                  ),
                                                ),
                                                const SizedBox(width: 6),
                                                if (m.isDownloading)
                                                  TextButton(
                                                    onPressed: () => registry.cancelDownload(m.id),
                                                    child: const Text('Annuler', style: TextStyle(fontSize: 10, color: Colors.redAccent)),
                                                  )
                                                else if (isInstalled)
                                                  Row(
                                                    mainAxisSize: MainAxisSize.min,
                                                    children: [
                                                      FilledButton.tonal(
                                                        style: FilledButton.styleFrom(
                                                          visualDensity: VisualDensity.compact,
                                                          padding: const EdgeInsets.symmetric(horizontal: 8),
                                                        ),
                                                        onPressed: () async {
                                                          final modelPath = m.localPath ?? m.id;
                                                          settings.llmModel = modelPath;
                                                          final messenger = ScaffoldMessenger.of(context);
                                                          setDialogState(() {
                                                            modelController.text = modelPath;
                                                            if (!dialogModels.contains(modelPath)) {
                                                              dialogModels.add(modelPath);
                                                            }
                                                          });
                                                          onModelChanged?.call();
                                                          Navigator.pop(ctx);

                                                          if (plat.isAndroid && modelPath.isNotEmpty) {
                                                            try {
                                                              await const MethodChannel('crisperweaver/litert_lm')
                                                                  .invokeMethod('initModel', {'modelPath': modelPath});
                                                            } catch (_) {}
                                                          }

                                                          if (context.mounted) {
                                                            messenger.showSnackBar(
                                                              SnackBar(
                                                                content: Row(
                                                                  children: [
                                                                    const Icon(Icons.check_circle, color: Colors.white, size: 18),
                                                                    const SizedBox(width: 8),
                                                                    Expanded(child: Text('Modèle sélectionné : ${m.name}')),
                                                                  ],
                                                                ),
                                                                duration: const Duration(seconds: 3),
                                                                backgroundColor: Colors.teal.shade700,
                                                                behavior: SnackBarBehavior.floating,
                                                              ),
                                                            );
                                                          }
                                                        },
                                                        child: const Text('Utiliser', style: TextStyle(fontSize: 10)),
                                                      ),
                                                      const SizedBox(width: 2),
                                                      IconButton(
                                                        icon: const Icon(Icons.download, size: 14),
                                                        tooltip: 'Re-télécharger le modèle',
                                                        visualDensity: VisualDensity.compact,
                                                        onPressed: () async {
                                                          try {
                                                            await registry.startDownload(
                                                              m,
                                                              hfToken: settings.hfToken,
                                                            );
                                                          } catch (err) {
                                                            final errStr = err.toString();
                                                            if (errStr.contains('401')) {
                                                              if (context.mounted) {
                                                                _showHfTokenPrompt(context, settings, () {
                                                                  registry.startDownload(m, hfToken: settings.hfToken);
                                                                });
                                                              }
                                                            } else if (errStr.contains('403')) {
                                                              if (context.mounted) {
                                                                _showHfLicensePrompt(context, m.id);
                                                              }
                                                            } else {
                                                              if (context.mounted) {
                                                                ScaffoldMessenger.of(context).showSnackBar(
                                                                  SnackBar(content: Text('Erreur téléchargement: $err')),
                                                                );
                                                              }
                                                            }
                                                          }
                                                        },
                                                      ),
                                                    ],
                                                  )
                                                else if (m.downloadUrl.isNotEmpty)
                                                  FilledButton.icon(
                                                    style: FilledButton.styleFrom(
                                                      visualDensity: VisualDensity.compact,
                                                      padding: const EdgeInsets.symmetric(horizontal: 6),
                                                    ),
                                                    icon: const Icon(Icons.download, size: 12),
                                                    label: const Text('Télécharger', style: TextStyle(fontSize: 10)),
                                                    onPressed: () async {
                                                      try {
                                                        await registry.startDownload(
                                                          m,
                                                          hfToken: settings.hfToken,
                                                        );
                                                      } catch (err) {
                                                        final errStr = err.toString();
                                                        if (errStr.contains('401')) {
                                                          if (context.mounted) {
                                                            _showHfTokenPrompt(context, settings, () {
                                                              registry.startDownload(m, hfToken: settings.hfToken);
                                                            });
                                                          }
                                                        } else if (errStr.contains('403')) {
                                                          if (context.mounted) {
                                                            _showHfLicensePrompt(context, m.id);
                                                          }
                                                        } else {
                                                          if (context.mounted) {
                                                            ScaffoldMessenger.of(context).showSnackBar(
                                                              SnackBar(content: Text('Erreur téléchargement: $err')),
                                                            );
                                                          }
                                                        }
                                                      }
                                                    },
                                                  ),
                                              ],
                                            ),
                                          );
                                        },
                                      );
                                    },
                                  );
                                },
                              ),

                              // TAB 3: Paramètres Avancés & Token Hugging Face
                              SingleChildScrollView(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Builder(
                                      builder: (ctx) {
                                        final curTemp = settings.getModelTemperature(modelController.text);
                                        final curTokens = settings.getModelMaxTokens(modelController.text);
                                        final isLiteRt = settings.llmProvider == LlmProvider.liteRtWindows || settings.llmProvider == LlmProvider.liteRtAndroid;
                                        final maxContextAllowed = isLiteRt ? 32768.0 : 524288.0;
                                        final chipsList = isLiteRt
                                            ? [2048, 4096, 8192, 16384, 32768]
                                            : [4096, 8192, 16384, 32768, 65536, 131072, 262144, 524288];

                                        return Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            Row(
                                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                              children: [
                                                const Text('Température (Créativité)', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                                                Text(
                                                  curTemp.toStringAsFixed(2),
                                                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.blueAccent),
                                                ),
                                              ],
                                            ),
                                            Slider(
                                              value: curTemp.clamp(0.0, 1.0),
                                              min: 0.0,
                                              max: 1.0,
                                              divisions: 20,
                                              label: curTemp.toStringAsFixed(2),
                                              onChanged: (val) {
                                                setDialogState(() {
                                                  final rounded = (val * 100).round() / 100;
                                                  settings.setModelTemperature(modelController.text, rounded);
                                                });
                                              },
                                            ),
                                            const SizedBox(height: 6),
                                            Row(
                                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                              children: [
                                                const Text('Contexte Max (Tokens)', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                                                Text(
                                                  '${curTokens >= 1024 ? "${(curTokens / 1024).round()}K" : "$curTokens"} ($curTokens tok)',
                                                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.blueAccent),
                                                ),
                                              ],
                                            ),
                                            Slider(
                                              value: curTokens.clamp(1024, maxContextAllowed.toInt()).toDouble(),
                                              min: 1024,
                                              max: maxContextAllowed,
                                              divisions: isLiteRt ? 31 : 128,
                                              label: curTokens >= 1024 ? '${(curTokens / 1024).round()}K' : '$curTokens',
                                              onChanged: (val) {
                                                setDialogState(() {
                                                  final tok = val.round();
                                                  settings.setModelMaxTokens(modelController.text, tok);
                                                });
                                              },
                                            ),
                                            Wrap(
                                              spacing: 6,
                                              runSpacing: 4,
                                              children: [
                                                for (final t in chipsList)
                                                  ChoiceChip(
                                                    label: Text(t >= 1024 ? '${(t / 1024).round()}K' : '$t', style: const TextStyle(fontSize: 10)),
                                                    selected: curTokens == t,
                                                    onSelected: (sel) {
                                                      if (sel) {
                                                        setDialogState(() {
                                                          settings.setModelMaxTokens(modelController.text, t);
                                                        });
                                                      }
                                                    },
                                                  ),
                                              ],
                                            ),
                                          ],
                                        );
                                      },
                                    ),
                                     const SizedBox(height: 10),
                                      // Thinking Mode switch
                                      Builder(
                                        builder: (bCtx) {
                                          final isDk = Theme.of(bCtx).brightness == Brightness.dark;
                                          return Container(
                                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                            decoration: BoxDecoration(
                                              color: isDk ? Colors.blueGrey.shade900.withValues(alpha: 0.3) : Colors.blueGrey.shade50,
                                              borderRadius: BorderRadius.circular(8),
                                              border: Border.all(color: Colors.cyanAccent.withValues(alpha: 0.3)),
                                            ),
                                            child: Column(
                                              crossAxisAlignment: CrossAxisAlignment.start,
                                              children: [
                                                Row(
                                                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                                  children: [
                                                    const Row(
                                                      children: [
                                                        Icon(Icons.psychology, size: 16, color: Colors.cyanAccent),
                                                        SizedBox(width: 6),
                                                        Text(
                                                          'Mode Pensée / Raisonnement (Thinking)',
                                                          style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                                                        ),
                                                      ],
                                                    ),
                                                    Switch(
                                                      value: settings.getModelThinkingEnabled(modelController.text),
                                                      activeTrackColor: Colors.cyanAccent.withValues(alpha: 0.5),
                                                      activeThumbColor: Colors.cyanAccent,
                                                      onChanged: (val) {
                                                        setDialogState(() {
                                                          settings.setModelThinkingEnabled(modelController.text, val);
                                                        });
                                                      },
                                                    ),
                                                  ],
                                                ),
                                                Text(
                                                  'Pour les modèles dotés de réflexion (Qwen-Thinking, DeepSeek-R1, etc.). '
                                                  'Désactiver ce mode force des réponses directes sans bloc <think>, accélérant la réponse et réduisant la consommation de tokens.',
                                                  style: TextStyle(fontSize: 10, color: isDk ? Colors.grey.shade400 : Colors.grey.shade600),
                                                ),
                                              ],
                                            ),
                                          );
                                        },
                                      ),
                                     _buildRagSettingsSection(
                                       context: context,
                                       settings: settings,
                                       activeModel: modelController.text,
                                       embeddingController: embeddingController,
                                       availableModels: dialogModels,
                                       setDialogState: setDialogState,
                                     ),
                                     const Divider(height: 20),
                                    const Text(
                                      'Jeton d\'accès Hugging Face (Optionnel)',
                                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                                    ),
                                    const SizedBox(height: 4),
                                    const Text(
                                      'Requis pour télécharger les modèles sous licence comme Gemma 3 ou TinyGarden.',
                                      style: TextStyle(fontSize: 10, color: Colors.grey),
                                    ),
                                    const SizedBox(height: 8),
                                    TextField(
                                      controller: tokenController,
                                      obscureText: true,
                                      decoration: InputDecoration(
                                        labelText: 'Token HF (hf_...)',
                                        border: const OutlineInputBorder(),
                                        isDense: true,
                                        suffixIcon: IconButton(
                                          icon: const Icon(Icons.save, size: 16),
                                          tooltip: 'Enregistrer le token',
                                          onPressed: () {
                                            settings.hfToken = tokenController.text.trim();
                                            ScaffoldMessenger.of(context).showSnackBar(
                                              const SnackBar(content: Text('Token Hugging Face enregistré !')),
                                            );
                                          },
                                        ),
                                      ),
                                      onChanged: (v) => settings.hfToken = v.trim(),
                                    ),
                                    Align(
                                       alignment: Alignment.centerRight,
                                       child: TextButton.icon(
                                         icon: const Icon(Icons.open_in_new, size: 12),
                                         label: const Text('Créer un token gratuit', style: TextStyle(fontSize: 10)),
                                         onPressed: () {
                                           url_launcher.launchUrl(
                                             Uri.parse('https://huggingface.co/settings/tokens'),
                                             mode: url_launcher.LaunchMode.externalApplication,
                                           );
                                         },
                                       ),
                                     ),
                                     const Divider(height: 20),
                                     const Text(
                                       'Serveur Text-to-Image Local (Génération d\'Images)',
                                       style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                                     ),
                                     const SizedBox(height: 4),
                                     const Text(
                                       'Endpoint compatible OpenAI (/v1/images/generations) pour SD-Turbo, Stable Diffusion WebUI ou LocalAI.',
                                       style: TextStyle(fontSize: 10, color: Colors.grey),
                                     ),
                                     const SizedBox(height: 8),
                                     TextField(
                                       controller: imageGenUrlController,
                                       decoration: InputDecoration(
                                         labelText: 'Endpoint Image Gen (ex: http://127.0.0.1:7860/v1)',
                                         border: const OutlineInputBorder(),
                                         isDense: true,
                                         prefixIcon: const Icon(Icons.palette_outlined, size: 18, color: Colors.pinkAccent),
                                         suffixIcon: IconButton(
                                           icon: const Icon(Icons.save, size: 16),
                                           tooltip: 'Enregistrer l\'URL Image Gen',
                                           onPressed: () {
                                             settings.imageGenApiUrl = imageGenUrlController.text.trim();
                                             ScaffoldMessenger.of(context).showSnackBar(
                                               const SnackBar(content: Text('Endpoint Image Gen enregistré !')),
                                             );
                                           },
                                         ),
                                       ),
                                       onChanged: (v) => settings.imageGenApiUrl = v.trim(),
                                     ),
                                     const SizedBox(height: 8),
                                     Row(
                                       children: [
                                         Expanded(
                                           child: imageModels.isNotEmpty
                                               ? DropdownButtonFormField<String>(
                                                   initialValue: imageModels.contains(settings.activeImageModel)
                                                       ? settings.activeImageModel
                                                       : imageModels.first,
                                                   decoration: const InputDecoration(
                                                     labelText: 'Modèle Image (.safetensors actif)',
                                                     border: OutlineInputBorder(),
                                                     isDense: true,
                                                     prefixIcon: Icon(Icons.image_outlined, size: 18, color: Colors.pinkAccent),
                                                   ),
                                                   items: imageModels
                                                       .map((m) => DropdownMenuItem(
                                                             value: m,
                                                             child: Text(m, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)),
                                                           ))
                                                       .toList(),
                                                   onChanged: (val) {
                                                     if (val != null) {
                                                       setDialogState(() {
                                                         settings.activeImageModel = val;
                                                       });
                                                     }
                                                   },
                                                 )
                                               : Container(
                                                   padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                                                   decoration: BoxDecoration(
                                                     border: Border.all(color: Colors.grey.shade700),
                                                     borderRadius: BorderRadius.circular(4),
                                                   ),
                                                   child: Row(
                                                     children: [
                                                       const Icon(Icons.folder_open, size: 16, color: Colors.amberAccent),
                                                       const SizedBox(width: 6),
                                                       Expanded(
                                                         child: Text(
                                                           'Dossier : models/Stable-diffusion (Vide)',
                                                           style: TextStyle(fontSize: 11, color: Colors.grey.shade400),
                                                         ),
                                                       ),
                                                     ],
                                                   ),
                                                 ),
                                         ),
                                         const SizedBox(width: 6),
                                         IconButton(
                                           icon: const Icon(Icons.refresh, size: 18, color: Colors.pinkAccent),
                                           tooltip: 'Re-scanner models/Stable-diffusion',
                                           onPressed: fetchImageModels,
                                         ),
                                       ],
                                     ),
                                   ],
                                 ),
                               ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ] else if (selectedProviderKey.startsWith('cloud_')) ...[
                  const SizedBox(height: 12),
                  // Nom du fournisseur
                  TextField(
                    controller: cloudNameController,
                    decoration: const InputDecoration(
                      labelText: 'Nom du Fournisseur Cloud',
                      hintText: 'Ex: OpenAI GPT-4o, Groq Ultra-Rapide, Mistral AI, DeepSeek...',
                      border: OutlineInputBorder(),
                      isDense: true,
                      prefixIcon: Icon(Icons.cloud_outlined, size: 18, color: Colors.blueAccent),
                    ),
                  ),
                  const SizedBox(height: 10),
                  // Quick Presets 1-clic
                  const Text('Modèles rapides (1-Clic) :', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 4),
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        for (final preset in CloudLlmProviderProfile.presets) ...[
                          ActionChip(
                            avatar: const Icon(Icons.flash_on, size: 14, color: Colors.amber),
                            label: Text(preset.name, style: const TextStyle(fontSize: 11)),
                            visualDensity: VisualDensity.compact,
                            onPressed: () {
                              setDialogState(() {
                                cloudNameController.text = preset.name;
                                urlController.text = preset.endpoint;
                                modelController.text = preset.defaultModel;
                                dialogModels = List.from(preset.cachedModels);
                                isCustomModelEntry = false;
                              });
                            },
                          ),
                          const SizedBox(width: 6),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  // Endpoint URL
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: urlController,
                          decoration: const InputDecoration(
                            labelText: 'URL de l\'API (Base Endpoint)',
                            hintText: 'https://api.openai.com/v1',
                            border: OutlineInputBorder(),
                            isDense: true,
                            prefixIcon: Icon(Icons.link, size: 18),
                          ),
                          onSubmitted: (_) => fetchModels(),
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        tooltip: 'Tester la connexion et récupérer les modèles autorisés',
                        icon: isFetchingModels
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.sync, color: Colors.blueAccent),
                        onPressed: isFetchingModels ? null : fetchModels,
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  // Clé API
                  TextField(
                    controller: apiKeyController,
                    obscureText: isObscureApiKey,
                    decoration: InputDecoration(
                      labelText: 'Clé API (API Key)',
                      hintText: 'sk-...',
                      border: const OutlineInputBorder(),
                      isDense: true,
                      prefixIcon: const Icon(Icons.key, size: 18, color: Colors.amber),
                      suffixIcon: IconButton(
                        icon: Icon(isObscureApiKey ? Icons.visibility_off : Icons.visibility, size: 18),
                        tooltip: isObscureApiKey ? 'Afficher la clé' : 'Masquer la clé',
                        onPressed: () {
                          setDialogState(() {
                            isObscureApiKey = !isObscureApiKey;
                          });
                        },
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  // Modèle actif / ID de modèle (Dropdown ou Saisie manuelle de l'ID)
                  if (dialogModels.isNotEmpty && !isCustomModelEntry) ...[
                    Row(
                      children: [
                        Expanded(
                          child: DropdownButtonFormField<String>(
                            initialValue: dialogModels.contains(modelController.text)
                                ? modelController.text
                                : dialogModels.first,
                            decoration: const InputDecoration(
                              labelText: 'Modèle Cloud sélectionné',
                              border: OutlineInputBorder(),
                              isDense: true,
                              prefixIcon: Icon(Icons.psychology, size: 18, color: Colors.purpleAccent),
                            ),
                            items: dialogModels
                                .map((m) => DropdownMenuItem(
                                      value: m,
                                      child: Text(m, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)),
                                    ))
                                .toList(),
                            onChanged: (val) {
                              if (val != null) {
                                setDialogState(() {
                                  modelController.text = val;
                                  settings.llmTemperature = settings.getModelTemperature(val);
                                  settings.llmMaxTokens = settings.getModelMaxTokens(val);
                                });
                              }
                            },
                          ),
                        ),
                        const SizedBox(width: 4),
                        IconButton(
                          tooltip: 'Saisir manuellement l\'ID du modèle',
                          icon: const Icon(Icons.edit, size: 18),
                          onPressed: () {
                            setDialogState(() {
                              isCustomModelEntry = true;
                            });
                          },
                        ),
                      ],
                    ),
                  ] else ...[
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: modelController,
                            decoration: const InputDecoration(
                              labelText: 'ID du Modèle (Saisie Manuelle)',
                              hintText: 'Ex: gpt-4o, deepseek-chat, llama-3.3-70b-versatile, ...',
                              border: OutlineInputBorder(),
                              isDense: true,
                              prefixIcon: Icon(Icons.edit_note, size: 18, color: Colors.purpleAccent),
                            ),
                            onChanged: (val) {
                              setDialogState(() {
                                settings.llmTemperature = settings.getModelTemperature(val);
                                settings.llmMaxTokens = settings.getModelMaxTokens(val);
                              });
                            },
                          ),
                        ),
                        if (dialogModels.isNotEmpty) ...[
                          const SizedBox(width: 4),
                          IconButton(
                            tooltip: 'Revenir à la liste déroulante',
                            icon: const Icon(Icons.list, size: 18),
                            onPressed: () {
                              setDialogState(() {
                                isCustomModelEntry = false;
                              });
                            },
                          ),
                        ],
                      ],
                    ),
                  ],
                  const SizedBox(height: 6),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Text(
                          dialogModels.isEmpty
                              ? '💡 Saisissez manuellement l\'ID de votre modèle si l\'API ne supporte pas le listage automatique.'
                              : '✨ ${dialogModels.length} modèle(s) détecté(s).',
                          style: TextStyle(fontSize: 10, color: Colors.grey.shade400),
                        ),
                      ),
                      TextButton.icon(
                        icon: const Icon(Icons.delete_outline, size: 14, color: Colors.redAccent),
                        label: const Text('Supprimer ce profil', style: TextStyle(color: Colors.redAccent, fontSize: 11)),
                        onPressed: () async {
                          final pid = selectedProviderKey.replaceFirst('cloud_', '');
                          await settings.deleteCloudProvider(pid);
                          setDialogState(() {
                            selectedProviderKey = 'local_litert_windows';
                            syncWithSelectedProvider(selectedProviderKey);
                          });
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  const Divider(),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('Température (Créativité)', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                      Text(
                        settings.llmTemperature.toStringAsFixed(2),
                        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.blueAccent),
                      ),
                    ],
                  ),
                  Slider(
                    value: settings.llmTemperature.clamp(0.0, 1.0),
                    min: 0.0,
                    max: 1.0,
                    divisions: 20,
                    label: settings.llmTemperature.toStringAsFixed(2),
                    onChanged: (val) {
                      setDialogState(() {
                        final rounded = (val * 100).round() / 100;
                        settings.setModelTemperature(modelController.text, rounded);
                      });
                    },
                  ),
                  const SizedBox(height: 6),
                  Builder(
                    builder: (bCtx) {
                      final activeModel = modelController.text;
                      final currentMaxTokens = settings.getModelMaxTokens(activeModel);

                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Text('Contexte Max (Tokens)', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                              Text(
                                '${currentMaxTokens >= 1024 ? "${(currentMaxTokens / 1024).round()}K" : "$currentMaxTokens"} ($currentMaxTokens tok)',
                                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.blueAccent),
                              ),
                            ],
                          ),
                          Slider(
                            value: currentMaxTokens.clamp(1024, 131072).toDouble(),
                            min: 1024,
                            max: 131072,
                            divisions: 127,
                            label: '$currentMaxTokens',
                            onChanged: (val) {
                              setDialogState(() {
                                final tok = val.round();
                                settings.setModelMaxTokens(activeModel, tok);
                              });
                            },
                          ),
                          Wrap(
                            spacing: 6,
                            runSpacing: 4,
                            children: [
                              for (final t in [4096, 8192, 16384, 32768, 65536, 128000])
                                ChoiceChip(
                                  label: Text(t >= 1000 ? '${(t / 1000).round()}K' : '$t', style: const TextStyle(fontSize: 10)),
                                  selected: currentMaxTokens == t,
                                  onSelected: (sel) {
                                    if (sel) {
                                      setDialogState(() {
                                        settings.setModelMaxTokens(activeModel, t);
                                      });
                                    }
                                  },
                                ),
                            ],
                          ),
                        ],
                      );
                    },
                  ),
                  _buildRagSettingsSection(
                    context: context,
                    settings: settings,
                    activeModel: modelController.text,
                    embeddingController: embeddingController,
                    availableModels: dialogModels,
                    setDialogState: setDialogState,
                  ),
                ] else ...[
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: urlController,
                          decoration: const InputDecoration(
                            labelText: 'URL de l\'API (Endpoint)',
                            hintText: 'http://localhost:9379/v1',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                          onSubmitted: (_) => fetchModels(),
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        tooltip: 'Tester et charger les modèles',
                        icon: isFetchingModels
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.sync, color: Colors.blueAccent),
                        onPressed: isFetchingModels ? null : fetchModels,
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),

                  if (dialogModels.isNotEmpty && !isCustomModelEntry) ...[
                    Row(
                      children: [
                        Expanded(
                          child: DropdownButtonFormField<String>(
                            initialValue: dialogModels.contains(modelController.text)
                                ? modelController.text
                                : dialogModels.first,
                            decoration: const InputDecoration(
                              labelText: 'Modèle disponible sur le serveur',
                              border: OutlineInputBorder(),
                              isDense: true,
                              prefixIcon: Icon(Icons.memory, size: 18, color: Colors.blueAccent),
                            ),
                            items: [
                              ...dialogModels.map((m) => DropdownMenuItem(
                                    value: m,
                                    child: Text(m, overflow: TextOverflow.ellipsis),
                                  )),
                            ],
                            onChanged: (val) {
                              if (val != null) {
                                setDialogState(() {
                                  modelController.text = val;
                                  settings.llmTemperature = settings.getModelTemperature(val);
                                  settings.llmMaxTokens = settings.getModelMaxTokens(val);
                                });
                              }
                            },
                          ),
                        ),
                        const SizedBox(width: 4),
                        IconButton(
                          tooltip: 'Saisie manuelle',
                          icon: const Icon(Icons.edit, size: 18),
                          onPressed: () {
                            setDialogState(() {
                              isCustomModelEntry = true;
                            });
                          },
                        ),
                      ],
                    ),
                  ] else ...[
                    TextField(
                      controller: modelController,
                      decoration: const InputDecoration(
                        labelText: 'Nom du modèle (ex: gemma-4-gpu, qwen2.5-coder)',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                      onChanged: (val) {
                        setDialogState(() {
                          settings.llmTemperature = settings.getModelTemperature(val);
                          settings.llmMaxTokens = settings.getModelMaxTokens(val);
                        });
                      },
                    ),
                  ],
                  const SizedBox(height: 16),
                  const Divider(),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('Température (Créativité)', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                      Text(
                        settings.llmTemperature.toStringAsFixed(2),
                        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.blueAccent),
                      ),
                    ],
                  ),
                  Slider(
                    value: settings.llmTemperature.clamp(0.0, 1.0),
                    min: 0.0,
                    max: 1.0,
                    divisions: 20,
                    label: settings.llmTemperature.toStringAsFixed(2),
                    onChanged: (val) {
                      setDialogState(() {
                        final rounded = (val * 100).round() / 100;
                        settings.setModelTemperature(modelController.text, rounded);
                      });
                    },
                  ),
                  const SizedBox(height: 6),
                  Builder(
                    builder: (bCtx) {
                      final activeModel = modelController.text;
                      final currentMaxTokens = settings.getModelMaxTokens(activeModel);

                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Text('Contexte Max (Tokens)', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                              Text(
                                '${currentMaxTokens >= 1024 ? "${(currentMaxTokens / 1024).round()}K" : "$currentMaxTokens"} ($currentMaxTokens tok)',
                                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.blueAccent),
                              ),
                            ],
                          ),
                          Slider(
                            value: currentMaxTokens.clamp(1024, 131072).toDouble(),
                            min: 1024,
                            max: 131072,
                            divisions: 127,
                            label: '$currentMaxTokens',
                            onChanged: (val) {
                              setDialogState(() {
                                final tok = val.round();
                                settings.setModelMaxTokens(activeModel, tok);
                              });
                            },
                          ),
                          Wrap(
                            spacing: 6,
                            runSpacing: 4,
                            children: [
                              for (final t in [4096, 8192, 16384, 32768, 65536, 128000])
                                ChoiceChip(
                                  label: Text(t >= 1000 ? '${(t / 1000).round()}K' : '$t', style: const TextStyle(fontSize: 10)),
                                  selected: currentMaxTokens == t,
                                  onSelected: (sel) {
                                    if (sel) {
                                      setDialogState(() {
                                        settings.setModelMaxTokens(activeModel, t);
                                      });
                                    }
                                  },
                                ),
                            ],
                          ),
                        ],
                      );
                    },
                  ),
                  const SizedBox(height: 10),
                  // Thinking Mode switch for LM Studio / Server models
                  Builder(
                    builder: (bCtx) {
                      final isDk = Theme.of(bCtx).brightness == Brightness.dark;
                      return Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        decoration: BoxDecoration(
                          color: isDk ? Colors.blueGrey.shade900.withValues(alpha: 0.3) : Colors.blueGrey.shade50,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.cyanAccent.withValues(alpha: 0.3)),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                const Row(
                                  children: [
                                    Icon(Icons.psychology, size: 16, color: Colors.cyanAccent),
                                    SizedBox(width: 6),
                                    Text(
                                      'Mode Pensée / Raisonnement (Thinking)',
                                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                                    ),
                                  ],
                                ),
                                Switch(
                                  value: settings.getModelThinkingEnabled(modelController.text),
                                  activeTrackColor: Colors.cyanAccent.withValues(alpha: 0.5),
                                  activeThumbColor: Colors.cyanAccent,
                                  onChanged: (val) {
                                    setDialogState(() {
                                      settings.setModelThinkingEnabled(modelController.text, val);
                                    });
                                  },
                                ),
                              ],
                            ),
                            Text(
                              'Pour les modèles dotés de réflexion (Qwen-Thinking, DeepSeek-R1, etc.). '
                              'Désactiver ce mode force des réponses directes sans bloc <think>, accélérant la réponse et réduisant la consommation de tokens.',
                              style: TextStyle(fontSize: 10, color: isDk ? Colors.grey.shade400 : Colors.grey.shade600),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                  _buildRagSettingsSection(
                    context: context,
                    settings: settings,
                    activeModel: modelController.text,
                    embeddingController: embeddingController,
                    availableModels: dialogModels,
                    setDialogState: setDialogState,
                  ),
                  const Divider(height: 24),
                  const Text(
                    '🎨 Serveur Text-to-Image Local & Modèle Image',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'Endpoint local compatible OpenAI / SD WebUI et sélection du modèle .safetensors',
                    style: TextStyle(fontSize: 10, color: Colors.grey),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: imageGenUrlController,
                    decoration: InputDecoration(
                      labelText: 'Endpoint Image Gen (ex: http://127.0.0.1:7860/v1)',
                      border: const OutlineInputBorder(),
                      isDense: true,
                      prefixIcon: const Icon(Icons.palette_outlined, size: 18, color: Colors.pinkAccent),
                      suffixIcon: IconButton(
                        icon: const Icon(Icons.save, size: 16),
                        tooltip: 'Enregistrer l\'URL Image Gen',
                        onPressed: () {
                          settings.imageGenApiUrl = imageGenUrlController.text.trim();
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Endpoint Image Gen enregistré !')),
                          );
                        },
                      ),
                    ),
                    onChanged: (v) => settings.imageGenApiUrl = v.trim(),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: imageModels.isNotEmpty
                            ? DropdownButtonFormField<String>(
                                initialValue: imageModels.contains(settings.activeImageModel)
                                    ? settings.activeImageModel
                                    : imageModels.first,
                                decoration: const InputDecoration(
                                  labelText: 'Modèle Image (.safetensors actif)',
                                  border: OutlineInputBorder(),
                                  isDense: true,
                                  prefixIcon: Icon(Icons.image_outlined, size: 18, color: Colors.pinkAccent),
                                ),
                                items: imageModels
                                    .map((m) => DropdownMenuItem(
                                          value: m,
                                          child: Text(m, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)),
                                        ))
                                    .toList(),
                                onChanged: (val) {
                                  if (val != null) {
                                    setDialogState(() {
                                      settings.activeImageModel = val;
                                    });
                                  }
                                },
                              )
                            : Container(
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                                decoration: BoxDecoration(
                                  border: Border.all(color: Colors.grey.shade700),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Row(
                                  children: [
                                    const Icon(Icons.folder_open, size: 16, color: Colors.amberAccent),
                                    const SizedBox(width: 6),
                                    Expanded(
                                      child: Text(
                                        'Dossier : models/Stable-diffusion (Vide)',
                                        style: TextStyle(fontSize: 11, color: Colors.grey.shade400),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                      ),
                      const SizedBox(width: 6),
                      IconButton(
                        icon: const Icon(Icons.refresh, size: 18, color: Colors.pinkAccent),
                        tooltip: 'Re-scanner models/Stable-diffusion',
                        onPressed: fetchImageModels,
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Annuler'),
            ),
            ElevatedButton(
              onPressed: () async {
                if (selectedProviderKey.startsWith('cloud_')) {
                  final profileId = selectedProviderKey.replaceFirst('cloud_', '');
                  final name = cloudNameController.text.trim().isNotEmpty
                      ? cloudNameController.text.trim()
                      : 'Fournisseur Cloud';
                  final endpoint = urlController.text.trim();
                  final apiKey = apiKeyController.text.trim();
                  final defaultModel = modelController.text.trim().isNotEmpty
                      ? modelController.text.trim()
                      : 'gpt-4o';

                  final profile = CloudLlmProviderProfile(
                    id: profileId,
                    name: name,
                    endpoint: endpoint,
                    apiKey: apiKey,
                    defaultModel: defaultModel,
                    cachedModels: dialogModels,
                    temperature: settings.llmTemperature,
                    maxTokens: settings.llmMaxTokens,
                    createdAt: DateTime.now(),
                  );
                  await settings.saveCloudProvider(profile);

                  settings.activeCloudProviderId = profileId;
                  settings.llmProvider = LlmProvider.custom;
                  settings.llmApiUrl = endpoint;
                  settings.llmApiKey = apiKey;
                  settings.llmModel = defaultModel;
                } else {
                  settings.activeCloudProviderId = '';
                  if (selectedProviderKey == 'local_litert_windows') {
                    settings.llmProvider = LlmProvider.liteRtWindows;
                  } else if (selectedProviderKey == 'local_lmstudio') {
                    settings.llmProvider = LlmProvider.lmStudio;
                  } else if (selectedProviderKey == 'local_ollama') {
                    settings.llmProvider = LlmProvider.ollama;
                  } else if (selectedProviderKey == 'local_litert_android') {
                    settings.llmProvider = LlmProvider.liteRtAndroid;
                  }
                  settings.llmApiUrl = urlController.text.trim();
                  settings.llmModel = modelController.text.trim();
                  settings.llmApiKey = apiKeyController.text.trim();
                }

                settings.llmEmbeddingModel = embeddingController.text.trim();
                settings.hfToken = tokenController.text.trim();
                onModelChanged?.call();
                if (ctx.mounted) Navigator.pop(ctx);

                if (settings.llmProvider == LlmProvider.liteRtAndroid && settings.llmModel.isNotEmpty) {
                  try {
                    await const MethodChannel('crisperweaver/litert_lm')
                        .invokeMethod('initModel', {'modelPath': settings.llmModel});
                  } catch (e) {
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Initialisation LiteRT-LM : $e')),
                      );
                    }
                  }
                }
              },
              child: const Text('Enregistrer'),
            ),
          ],
        );
      },
    ),
  );
}

void _showHfTokenPrompt(BuildContext context, SettingsService settings, VoidCallback onRetry) {
  final tokenCtrl = TextEditingController(text: settings.hfToken);
  showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.vpn_key_rounded, color: Colors.amber),
          SizedBox(width: 8),
          Text('Token Hugging Face requis'),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Ce modèle requiert un jeton d\'accès Hugging Face (gratuit).',
            style: TextStyle(fontSize: 13),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: tokenCtrl,
            decoration: const InputDecoration(
              labelText: 'Token d\'accès (hf_...)',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              icon: const Icon(Icons.open_in_new, size: 14),
              label: const Text('Créer un token gratuit', style: TextStyle(fontSize: 11)),
              onPressed: () {
                url_launcher.launchUrl(
                  Uri.parse('https://huggingface.co/settings/tokens'),
                  mode: url_launcher.LaunchMode.externalApplication,
                );
              },
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Annuler'),
        ),
        ElevatedButton(
          onPressed: () {
            settings.hfToken = tokenCtrl.text.trim();
            Navigator.pop(ctx);
            onRetry();
          },
          child: const Text('Valider & Télécharger'),
        ),
      ],
    ),
  );
}

void _showHfLicensePrompt(BuildContext context, String modelId) {
  showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.gavel_rounded, color: Colors.orangeAccent),
          SizedBox(width: 8),
          Text('Licence à accepter'),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'L\'accès au modèle $modelId nécessite d\'accepter les conditions d\'utilisation sur la page Hugging Face avec votre compte connecté.',
            style: const TextStyle(fontSize: 13),
          ),
          const SizedBox(height: 12),
          const Text(
            '1. Cliquez sur le bouton ci-dessous pour ouvrir la page du modèle.\n2. Cliquez sur "Acknowledge license" sur le site Hugging Face.\n3. Revenez ici et relancez le téléchargement.',
            style: TextStyle(fontSize: 12, color: Colors.grey),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Fermer'),
        ),
        ElevatedButton.icon(
          icon: const Icon(Icons.open_in_new, size: 16),
          label: const Text('Ouvrir Hugging Face'),
          onPressed: () {
            url_launcher.launchUrl(
              Uri.parse('https://huggingface.co/litert-community/$modelId'),
              mode: url_launcher.LaunchMode.externalApplication,
            );
          },
        ),
      ],
    ),
  );
}

Widget _buildRagSettingsSection({
  required BuildContext context,
  required SettingsService settings,
  required String activeModel,
  required TextEditingController embeddingController,
  required List<String> availableModels,
  required void Function(void Function()) setDialogState,
}) {
  final isDark = Theme.of(context).brightness == Brightness.dark;
  final topK = settings.getModelRagTopK(activeModel);
  final chunkSize = settings.getModelRagChunkSize(activeModel);
  final minRel = settings.getModelRagMinRelevance(activeModel);
  final currentMode = settings.getModelRagSearchMode(activeModel);

  return Container(
    margin: const EdgeInsets.only(top: 14),
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: isDark ? Colors.purple.shade900.withValues(alpha: 0.15) : Colors.purple.shade50.withValues(alpha: 0.5),
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: Colors.purpleAccent.withValues(alpha: 0.3)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Section Header
        Row(
          children: [
            const Icon(Icons.bolt, size: 18, color: Colors.purpleAccent),
            const SizedBox(width: 6),
            const Text(
              'Paramètres du Moteur RAG',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Colors.purpleAccent),
            ),
            const Spacer(),
            Tooltip(
              message: 'Le RAG découpe vos documents et sélectionne les meilleurs extraits avant d\'interroger le modèle.',
              child: Icon(Icons.info_outline, size: 16, color: isDark ? Colors.grey.shade400 : Colors.grey.shade600),
            ),
          ],
        ),
        const SizedBox(height: 12),

        // 0. Stratégie de Recherche RAG
        const Row(
          children: [
            Text('Stratégie de Recherche', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
          ],
        ),
        const SizedBox(height: 3),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: isDark ? Colors.black38 : Colors.white70,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: Colors.purpleAccent.withValues(alpha: 0.3)),
          ),
          child: Text(
            '💡 ${currentMode.description}',
            style: TextStyle(
              fontSize: 10,
              color: isDark ? Colors.purple.shade200 : Colors.purple.shade800,
            ),
          ),
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 6,
          runSpacing: 4,
          children: [
            for (final mode in RagSearchMode.values)
              ChoiceChip(
                label: Text(mode.label, style: const TextStyle(fontSize: 10)),
                selected: currentMode == mode,
                onSelected: (sel) {
                  if (sel) {
                    setDialogState(() {
                      settings.setModelRagSearchMode(activeModel, mode);
                    });
                  }
                },
              ),
          ],
        ),
        const SizedBox(height: 12),

        // --- Live RAG Context Budget Gauge & Safety Alert ---
        Builder(
          builder: (bCtx) {
            final recCapacity = _getRecommendedModelCapacity(activeModel, settings.llmProvider);
            final userConfiguredContext = settings.getModelMaxTokens(activeModel);
            final effectiveContext = userConfiguredContext > 0 ? userConfiguredContext : recCapacity;
            final estimatedRagTokens = ((topK * chunkSize * 1.33) + 400).round();
            final ragUsageRatio = estimatedRagTokens / effectiveContext;
            final isLiteRt = settings.llmProvider == LlmProvider.liteRtWindows || settings.llmProvider == LlmProvider.liteRtAndroid;
            final isContextTooHigh = isLiteRt && (userConfiguredContext > recCapacity);
            final isRagTooHigh = ragUsageRatio > 0.70;
            final isWarning = isContextTooHigh || isRagTooHigh;

            return Container(
              padding: const EdgeInsets.all(10),
              margin: const EdgeInsets.only(bottom: 12),
              decoration: BoxDecoration(
                color: isWarning
                    ? Colors.amber.shade900.withValues(alpha: 0.25)
                    : Colors.blueGrey.shade900.withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: isWarning ? Colors.amberAccent : Colors.purpleAccent.withValues(alpha: 0.4),
                  width: isWarning ? 1.2 : 0.8,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        children: [
                          Icon(
                            isWarning ? Icons.warning_amber_rounded : Icons.analytics_outlined,
                            size: 16,
                            color: isWarning ? Colors.amberAccent : Colors.purpleAccent,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            'Budget Mémoire RAG : ~$estimatedRagTokens tok / ${effectiveContext >= 1024 ? "${(effectiveContext / 1024).round()}K" : effectiveContext} réglé',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                              color: isWarning ? Colors.amberAccent : Colors.purpleAccent,
                            ),
                          ),
                        ],
                      ),
                      Text(
                        '${(ragUsageRatio * 100).round()}% du contexte',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: isWarning ? Colors.amberAccent : Colors.grey,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: ragUsageRatio.clamp(0.0, 1.0),
                      minHeight: 6,
                      backgroundColor: Colors.grey.shade800,
                      valueColor: AlwaysStoppedAnimation<Color>(
                        ragUsageRatio > 0.85
                            ? Colors.redAccent
                            : ragUsageRatio > 0.70
                                ? Colors.amberAccent
                                : Colors.purpleAccent,
                      ),
                    ),
                  ),
                  if (isWarning) ...[
                    const SizedBox(height: 8),
                    Text(
                      isContextTooHigh
                          ? '⚠️ Attention : Le contexte réglé ($userConfiguredContext tok) dépasse la limite de $recCapacity tokens recommandée pour $activeModel.'
                          : (estimatedRagTokens > userConfiguredContext)
                              ? '⚠️ Conflit de capacité : Vos $topK extraits de $chunkSize mots (~$estimatedRagTokens tok) dépassent le Contexte Max configuré ($userConfiguredContext tok). Augmentez le Contexte Max à ${recCapacity >= 1024 ? "${(recCapacity / 1024).round()}K" : recCapacity} ci-dessus ou réduisez le Top-K pour éviter la troncature.'
                              : '⚠️ Risque d\'instabilité : Vos $topK extraits de $chunkSize mots (~$estimatedRagTokens tokens) occupent ${(ragUsageRatio * 100).round()}% du contexte ($userConfiguredContext tok).',
                      style: const TextStyle(fontSize: 10.5, color: Colors.amberAccent),
                    ),
                    const SizedBox(height: 8),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.amber.shade800,
                          foregroundColor: Colors.white,
                          visualDensity: VisualDensity.compact,
                        ),
                        icon: const Icon(Icons.flash_on, size: 14),
                        label: Text(
                          '⚡ Appliquer les réglages optimaux pour $activeModel (${recCapacity >= 1024 ? "${(recCapacity / 1024).round()}K" : recCapacity})',
                          style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
                        ),
                        onPressed: () {
                          setDialogState(() {
                            settings.setModelMaxTokens(activeModel, recCapacity);
                            if (recCapacity <= 4096) {
                              settings.setModelRagTopK(activeModel, 5);
                              settings.setModelRagChunkSize(activeModel, 350);
                            } else if (recCapacity <= 16384) {
                              settings.setModelRagTopK(activeModel, 8);
                              settings.setModelRagChunkSize(activeModel, 350);
                            } else {
                              settings.setModelRagTopK(activeModel, 12);
                              settings.setModelRagChunkSize(activeModel, 500);
                            }
                          });
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text('⚡ Réglages optimisés appliqués pour $activeModel ($recCapacity tokens) !'),
                                backgroundColor: Colors.teal.shade700,
                              ),
                            );
                          }
                        },
                      ),
                    ),
                  ],
                ],
              ),
            );
          },
        ),

        // 1. Modèle d'Embeddings
        const Row(
          children: [
            Text('Modèle d\'Embeddings (Vecteurs)', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
          ],
        ),
        const SizedBox(height: 2),
        Text(
          'Moteur IA qui convertit le texte en représentations vectorielles de sens pour la recherche sémantique.',
          style: TextStyle(fontSize: 10, color: isDark ? Colors.grey.shade400 : Colors.grey.shade600),
        ),
        const SizedBox(height: 6),
        TextField(
          controller: embeddingController,
          decoration: InputDecoration(
            hintText: 'ex: text-embedding-qwen3-embedding-4b, nomic-embed...',
            border: const OutlineInputBorder(),
            isDense: true,
            suffixIcon: availableModels.any((m) => m.toLowerCase().contains('embed') || m.toLowerCase().contains('qwen3'))
                ? PopupMenuButton<String>(
                    icon: const Icon(Icons.arrow_drop_down, size: 20),
                    tooltip: 'Sélectionner un modèle d\'embedding détecté',
                    onSelected: (m) {
                      setDialogState(() {
                        embeddingController.text = m;
                        settings.llmEmbeddingModel = m;
                      });
                    },
                    itemBuilder: (ctx) => availableModels
                        .where((m) => m.toLowerCase().contains('embed') || m.toLowerCase().contains('qwen3'))
                        .map((m) => PopupMenuItem(value: m, child: Text(m, style: const TextStyle(fontSize: 12))))
                        .toList(),
                  )
                : null,
          ),
          onChanged: (v) => settings.llmEmbeddingModel = v.trim(),
        ),
        const SizedBox(height: 12),

        // 2. Top-K Chunks
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text('Nombre d\'extraits RAG (Top-K)', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
            Text(
              'Top $topK extraits',
              style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.purpleAccent),
            ),
          ],
        ),
        const SizedBox(height: 2),
        Text(
          'Nombre maximal de fragments pertinents transmis à l\'IA. Plus il est grand, plus l\'analyse croise de pages du document.',
          style: TextStyle(fontSize: 10, color: isDark ? Colors.grey.shade400 : Colors.grey.shade600),
        ),
        Slider(
          value: topK.clamp(2, 15).toDouble(),
          min: 2,
          max: 15,
          divisions: 13,
          label: 'Top $topK',
          onChanged: (val) {
            setDialogState(() {
              final top = val.round();
              settings.setModelRagTopK(activeModel, top);
            });
          },
        ),
        Wrap(
          spacing: 6,
          runSpacing: 4,
          children: [
            for (final k in [3, 5, 8, 12])
              ChoiceChip(
                label: Text('Top $k', style: const TextStyle(fontSize: 10)),
                selected: topK == k,
                onSelected: (sel) {
                  if (sel) {
                    setDialogState(() {
                      settings.setModelRagTopK(activeModel, k);
                    });
                  }
                },
              ),
          ],
        ),
        const SizedBox(height: 12),

        // 3. Chunk Size
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text('Taille des fragments (Découpage)', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
            Text(
              '$chunkSize mots',
              style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.purpleAccent),
            ),
          ],
        ),
        const SizedBox(height: 2),
        Text(
          'Longueur de chaque bloc découpé. Les petits blocs isolent des faits précis, les grands blocs préservent le contexte narratif.',
          style: TextStyle(fontSize: 10, color: isDark ? Colors.grey.shade400 : Colors.grey.shade600),
        ),
        Slider(
          value: chunkSize.clamp(150, 600).toDouble(),
          min: 150,
          max: 600,
          divisions: 9,
          label: '$chunkSize mots',
          onChanged: (val) {
            setDialogState(() {
              final size = val.round();
              settings.setModelRagChunkSize(activeModel, size);
            });
          },
        ),
        Wrap(
          spacing: 6,
          runSpacing: 4,
          children: [
            for (final (label, size) in [
              ('200 (Court / Précis)', 200),
              ('350 (Standard)', 350),
              ('500 (Long / Récits)', 500)
            ])
              ChoiceChip(
                label: Text(label, style: const TextStyle(fontSize: 10)),
                selected: chunkSize == size,
                onSelected: (sel) {
                  if (sel) {
                    setDialogState(() {
                      settings.setModelRagChunkSize(activeModel, size);
                    });
                  }
                },
              ),
          ],
        ),
        const SizedBox(height: 12),

        // 4. Minimum Relevance Threshold
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text('Seuil de similarité minimale', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
            Text(
              '${(minRel * 100).toStringAsFixed(0)}%',
              style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.purpleAccent),
            ),
          ],
        ),
        const SizedBox(height: 2),
        Text(
          'Score de ressemblance minimal pour retenir un extrait. Évite à l\'IA de recevoir des passages hors-sujet.',
          style: TextStyle(fontSize: 10, color: isDark ? Colors.grey.shade400 : Colors.grey.shade600),
        ),
        Slider(
          value: minRel.clamp(0.05, 0.50),
          min: 0.05,
          max: 0.50,
          divisions: 9,
          label: '${(minRel * 100).toStringAsFixed(0)}%',
          onChanged: (val) {
            setDialogState(() {
              final rel = (val * 100).round() / 100;
              settings.setModelRagMinRelevance(activeModel, rel);
            });
          },
        ),
        Wrap(
          spacing: 6,
          runSpacing: 4,
          children: [
            for (final (label, rel) in [
              ('10% (Permissif)', 0.10),
              ('20% (Équilibré)', 0.20),
              ('35% (Strict)', 0.35)
            ])
              ChoiceChip(
                label: Text(label, style: const TextStyle(fontSize: 10)),
                selected: (minRel - rel).abs() < 0.03,
                onSelected: (sel) {
                  if (sel) {
                    setDialogState(() {
                      settings.setModelRagMinRelevance(activeModel, rel);
                    });
                  }
                },
              ),
          ],
        ),
        const SizedBox(height: 16),
        const Divider(),
        const SizedBox(height: 8),

        // 5. Prompt Système de l'Assistant (Centralisé dans la Bibliothèque)
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: isDark ? Colors.amber.shade900.withValues(alpha: 0.15) : Colors.amber.shade50,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: isDark ? Colors.amberAccent.withValues(alpha: 0.3) : Colors.amber.shade300,
              width: 0.8,
            ),
          ),
          child: Row(
            children: [
              const Icon(Icons.bookmark_added_rounded, size: 22, color: Colors.amberAccent),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Prompt Système Actif',
                      style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.amberAccent),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      settings.systemPromptPresets.firstWhere(
                        (p) => p.id == settings.activeSystemPromptId,
                        orElse: () => defaultSystemPromptPresets.first,
                      ).name,
                      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: Colors.amber.shade800,
                  foregroundColor: Colors.white,
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                ),
                icon: const Icon(Icons.auto_stories, size: 14),
                label: const Text('Bibliothèque', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                onPressed: () async {
                  final picked = await PromptLibraryDialog.show(
                    context,
                    initialType: PromptType.system,
                  );
                  if (picked != null) {
                    setDialogState(() {
                      settings.activeSystemPromptId = picked.id;
                      settings.activeSystemPromptText = picked.content;
                    });
                  }
                },
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        const Divider(),
        const SizedBox(height: 8),

        // 5. Gestion des Emplacements & Stockage sur Disque
        const Row(
          children: [
            Icon(Icons.folder_special, size: 16, color: Colors.purpleAccent),
            SizedBox(width: 6),
            Text('Emplacements & Gestion du Stockage Disque', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
          ],
        ),
        const SizedBox(height: 8),

        // 5.1 Emplacement du Cache RAG
        const Text('Emplacement du Cache RAG (Vecteurs)', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
        const SizedBox(height: 2),
        Text(
          'Dossier où sont stockés les vecteurs précalculés pour un chargement instantané des documents déjà ouverts.',
          style: TextStyle(fontSize: 10, color: isDark ? Colors.grey.shade400 : Colors.grey.shade600),
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            Expanded(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                decoration: BoxDecoration(
                  color: isDark ? Colors.grey.shade900 : Colors.grey.shade200,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: Colors.grey.shade400, width: 0.5),
                ),
                child: Text(
                  settings.ragCacheDirectory.isNotEmpty ? settings.ragCacheDirectory : 'Par défaut (Documents/CrisperWeaver/rag_cache)',
                  style: TextStyle(fontSize: 10, fontStyle: settings.ragCacheDirectory.isEmpty ? FontStyle.italic : FontStyle.normal),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
            const SizedBox(width: 4),
            IconButton(
              icon: const Icon(Icons.folder_open, size: 18, color: Colors.blueAccent),
              tooltip: 'Choisir un autre dossier de cache RAG',
              onPressed: () async {
                final selected = await FilePicker.getDirectoryPath(dialogTitle: 'Sélectionner le dossier de cache RAG');
                if (selected != null && selected.isNotEmpty) {
                  setDialogState(() {
                    settings.ragCacheDirectory = selected;
                  });
                }
              },
            ),
            if (settings.ragCacheDirectory.isNotEmpty)
              IconButton(
                icon: const Icon(Icons.restore, size: 18, color: Colors.orangeAccent),
                tooltip: 'Restaurer l\'emplacement par défaut',
                onPressed: () {
                  setDialogState(() {
                    settings.ragCacheDirectory = '';
                  });
                },
              ),
          ],
        ),
        const SizedBox(height: 6),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.orangeAccent,
                side: const BorderSide(color: Colors.orangeAccent, width: 0.8),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              ),
              icon: const Icon(Icons.delete_outline, size: 14),
              label: const Text('Vider le Cache RAG', style: TextStyle(fontSize: 10)),
              onPressed: () async {
                final confirm = await showDialog<bool>(
                  context: context,
                  builder: (alertCtx) => AlertDialog(
                    title: const Row(
                      children: [
                        Icon(Icons.warning_amber_rounded, color: Colors.orangeAccent),
                        SizedBox(width: 8),
                        Text('Vider le Cache RAG ?'),
                      ],
                    ),
                    content: const Text(
                      'Êtes-vous sûr de vouloir vider le cache des vecteurs RAG ?\n\nTous les documents devront être recalculés lors de leur prochaine ouverture.',
                      style: TextStyle(fontSize: 12),
                    ),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(alertCtx, false), child: const Text('Annuler')),
                      FilledButton(
                        style: FilledButton.styleFrom(backgroundColor: Colors.orangeAccent),
                        onPressed: () => Navigator.pop(alertCtx, true),
                        child: const Text('Vider le cache'),
                      ),
                    ],
                  ),
                );

                if (confirm == true) {
                  final ragService = DocumentRagService();
                  final deleted = await ragService.clearCache(settings);
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Cache RAG vidé : $deleted fichier(s) supprimé(s)')),
                    );
                  }
                }
              },
            ),
          ],
        ),
        const SizedBox(height: 12),

        // 5.2 Emplacement de la Base de Connaissances IA
        const Text('Emplacement de la Base de Connaissances IA', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
        const SizedBox(height: 2),
        Text(
          'Dossier où sont enregistrées vos synthèses, fiches documentaires et historiques d\'analyses IA.',
          style: TextStyle(fontSize: 10, color: isDark ? Colors.grey.shade400 : Colors.grey.shade600),
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            Expanded(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                decoration: BoxDecoration(
                  color: isDark ? Colors.grey.shade900 : Colors.grey.shade200,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: Colors.grey.shade400, width: 0.5),
                ),
                child: Text(
                  settings.aiKnowledgeDirectory.isNotEmpty ? settings.aiKnowledgeDirectory : 'Par défaut (Documents/CrisperWeaver/ai_knowledge)',
                  style: TextStyle(fontSize: 10, fontStyle: settings.aiKnowledgeDirectory.isEmpty ? FontStyle.italic : FontStyle.normal),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
            const SizedBox(width: 4),
            IconButton(
              icon: const Icon(Icons.folder_open, size: 18, color: Colors.blueAccent),
              tooltip: 'Choisir un autre dossier pour la base de connaissances',
              onPressed: () async {
                final selected = await FilePicker.getDirectoryPath(dialogTitle: 'Sélectionner le dossier de la base de connaissances');
                if (selected != null && selected.isNotEmpty) {
                  setDialogState(() {
                    settings.aiKnowledgeDirectory = selected;
                  });
                  final knowledgeService = AiKnowledgeService();
                  await knowledgeService.reloadFromDisk();
                }
              },
            ),
            if (settings.aiKnowledgeDirectory.isNotEmpty)
              IconButton(
                icon: const Icon(Icons.restore, size: 18, color: Colors.orangeAccent),
                tooltip: 'Restaurer l\'emplacement par défaut',
                onPressed: () async {
                  setDialogState(() {
                    settings.aiKnowledgeDirectory = '';
                  });
                  final knowledgeService = AiKnowledgeService();
                  await knowledgeService.reloadFromDisk();
                },
              ),
          ],
        ),
        const SizedBox(height: 6),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.redAccent,
                side: const BorderSide(color: Colors.redAccent, width: 0.8),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              ),
              icon: const Icon(Icons.delete_forever, size: 14),
              label: const Text('Purger la Base de Connaissances', style: TextStyle(fontSize: 10)),
              onPressed: () async {
                final confirm = await showDialog<bool>(
                  context: context,
                  builder: (alertCtx) => AlertDialog(
                    title: const Row(
                      children: [
                        Icon(Icons.error_outline, color: Colors.redAccent),
                        SizedBox(width: 8),
                        Text('Purger la Base de Connaissances ?'),
                      ],
                    ),
                    content: const Text(
                      '⚠️ ATTENTION : Cette action va supprimer DÉFINITIVEMENT toutes vos synthèses, fiches et discussions enregistrées dans la base de connaissances.\n\nCette action est irréversible. Voulez-vous continuer ?',
                      style: TextStyle(fontSize: 12),
                    ),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(alertCtx, false), child: const Text('Annuler')),
                      FilledButton(
                        style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
                        onPressed: () => Navigator.pop(alertCtx, true),
                        child: const Text('Confirmer la purge définitive'),
                      ),
                    ],
                  ),
                );

                if (confirm == true) {
                  final knowledgeService = AiKnowledgeService();
                  final count = await knowledgeService.clearAllRecords();
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Base de connaissances purgée : $count fiche(s) supprimée(s)')),
                    );
                  }
                }
              },
            ),
          ],
        ),
      ],
    ),
  );
}

int _getRecommendedModelCapacity(String modelName, LlmProvider provider) {
  return getRecommendedModelCapacity(modelName, provider);
}
