// lib/screens/image_models_screen.dart
//
// Écran de gestion et d'installation des modèles d'image Jarvisol (EXT-V1-02 Phase 2).
// Raccordé directement au moteur d'installation P1 validé.
//
// Deux sections strictement indépendantes :
// A. GÉNÉRATION (MOD_01 à MOD_05)
// B. INPAINT / MODIFICATION (MOD_06 à MOD_08)
//
// Respecte l'invariance absolue des préférences et les règles d'intégrité.

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/hardware_profile.dart';
import '../models/image_model_catalog.dart';
import '../services/hardware_advisor_service.dart';
import '../services/image_model_catalog_service.dart';
import '../services/image_model_install_planner.dart';
import '../services/image_model_installer_service.dart';
import '../services/settings_service.dart';

class ImageModelsScreen extends ConsumerStatefulWidget {
  final ImageModelCatalogService? catalogServiceOverride;
  final ImageModelInstallPlanner? plannerOverride;
  final ImageModelInstallerService? installerOverride;
  final SettingsService? settingsServiceOverride;
  final HardwareAdvisorService? hardwareAdvisorOverride;
  final int Function(String path)? diskSpaceProbeOverride;
  final Map<String, LogicalModelStatus>? initialStatusesOverride;
  final Future<bool> Function(Uri uri)? urlLauncherOverride;

  const ImageModelsScreen({
    super.key,
    this.catalogServiceOverride,
    this.plannerOverride,
    this.installerOverride,
    this.settingsServiceOverride,
    this.hardwareAdvisorOverride,
    this.diskSpaceProbeOverride,
    this.initialStatusesOverride,
    this.urlLauncherOverride,
  });

  @override
  ConsumerState<ImageModelsScreen> createState() => _ImageModelsScreenState();
}

class _ImageModelsScreenState extends ConsumerState<ImageModelsScreen> {
  late ImageModelCatalogService _catalogService;
  late ImageModelInstallPlanner _planner;
  late ImageModelInstallerService _installer;
  HardwareAdvisorService? _hardwareAdvisor;

  bool _isLoading = true;
  String? _initErrorMessage;

  final Map<String, LogicalModelStatus> _modelStatuses = {};
  final Set<String> _selectedModelIds = {};
  final Set<String> _acceptedLicensesForSession = {};

  bool _isInstalling = false;
  DownloadProgressEvent? _lastProgressEvent;
  StreamSubscription<DownloadProgressEvent>? _progressSub;
  String? _statusBannerMessage;
  bool _isBannerError = false;

  CapabilityEvaluation? _genHardwareEval;
  CapabilityEvaluation? _inpaintHardwareEval;

  @override
  void initState() {
    super.initState();
    _initServices();
  }

  @override
  void didUpdateWidget(covariant ImageModelsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialStatusesOverride != null) {
      _modelStatuses.clear();
      _modelStatuses.addAll(widget.initialStatusesOverride!);
    }
  }

  @override
  void dispose() {
    _progressSub?.cancel();
    super.dispose();
  }

  void _initServices() {
    _catalogService = widget.catalogServiceOverride ?? ImageModelCatalogService();
    _planner = widget.plannerOverride ??
        ImageModelInstallPlanner(
          catalogService: _catalogService,
          diskSpaceProbe: widget.diskSpaceProbeOverride,
        );
    _installer = widget.installerOverride ??
        ImageModelInstallerService(
          catalogService: _catalogService,
          diskSpaceProbe: widget.diskSpaceProbeOverride,
        );
    _hardwareAdvisor = widget.hardwareAdvisorOverride;

    if (_catalogService.isLoaded) {
      _isLoading = false;
      _populateInitialStatuses();
      if (widget.initialStatusesOverride == null) {
        _refreshStatuses();
      }
    } else {
      _loadCatalogAndRefresh();
    }
  }

  void _populateInitialStatuses() {
    if (widget.initialStatusesOverride != null) {
      _modelStatuses.addAll(widget.initialStatusesOverride!);
    }
    final catalog = _catalogService.catalog;
    for (final model in catalog.logicalModels.values) {
      if (!_modelStatuses.containsKey(model.logicalModelId)) {
        _modelStatuses[model.logicalModelId] = LogicalModelStatus(
          model: model,
          state: LogicalModelInstallState.notInstalled,
          componentStatuses: const {},
          missingComponentIds: model.requiredComponentIds,
          totalRequiredSizeBytes: model.requiredComponentIds
              .map((c) => catalog.components[c]?.expectedSizeBytes ?? 0)
              .fold(0, (a, b) => a + b),
          installedSizeBytes: 0,
        );
      }
    }
  }

  SettingsService get _settings {
    if (widget.settingsServiceOverride != null) {
      return widget.settingsServiceOverride!;
    }
    return ref.read(settingsServiceProvider);
  }

  Future<void> _loadCatalogAndRefresh() async {
    if (mounted) {
      setState(() {
        _isLoading = true;
        _initErrorMessage = null;
      });
    }

    try {
      if (!_catalogService.isLoaded) {
        await _catalogService.loadCatalog();
      }
      _populateInitialStatuses();

      await _refreshStatuses();

      try {
        final advisor = _hardwareAdvisor ?? HardwareAdvisorService.instance;
        final profile = advisor.lastProfile;
        if (profile != null) {
          final probeResult = advisor.probeImageModelInstalled();
          final evalSystem = advisor.evaluateCapabilities(
            profile,
            lmStudioOnline: false,
            imageModelInstalled: probeResult,
          );
          _genHardwareEval = evalSystem[EngineCategory.imageGen];
          _inpaintHardwareEval = evalSystem[EngineCategory.imageInpaint];
        }
      } catch (_) {
        // Fallback discret sans bloquer l'UI
      }
    } catch (e) {
      _initErrorMessage = e.toString();
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _refreshStatuses({bool verifySha = false}) async {
    final catalog = _catalogService.catalog;
    for (final modelId in catalog.logicalModels.keys) {
      try {
        final status = await _catalogService.getLogicalModelStatus(modelId, verifySha: verifySha);
        _modelStatuses[modelId] = status;
      } catch (_) {
        // Laisser unknown si échec
      }
    }
    if (mounted) {
      setState(() {});
    }
  }

  String _formatBytes(int bytes) {
    if (bytes <= 0) return '0 Mo';
    const gb = 1024 * 1024 * 1024;
    const mb = 1024 * 1024;
    if (bytes >= gb) {
      return '${(bytes / gb).toStringAsFixed(2)} Go';
    }
    return '${(bytes / mb).toStringAsFixed(1)} Mo';
  }

  String _formatCapability(CapabilityStatus? status) {
    switch (status) {
      case CapabilityStatus.compatible:
        return 'Matériel : Compatible';
      case CapabilityStatus.probablyCompatible:
        return 'Matériel : Probablement compatible';
      case CapabilityStatus.limited:
        return 'Matériel : Limité';
      case CapabilityStatus.notRecommended:
        return 'Matériel : Non recommandé';
      case CapabilityStatus.unavailable:
        return 'Matériel : Non disponible';
      case CapabilityStatus.unknown:
      default:
        return 'Matériel : Compatibilité inconnue';
    }
  }

  bool _isModelActive(LogicalImageModel model) {
    final activeImg = _settings.activeImageModel.trim();
    final activeInp = _settings.activeInpaintModel.trim();
    final primaryComp = _catalogService.catalog.components[model.primaryComponentId];
    final fileName = primaryComp?.fileName;

    if (model.category == ImageModelCategory.generation) {
      return (fileName != null && activeImg == fileName) ||
          activeImg == model.logicalModelId ||
          activeImg == model.displayName ||
          activeImg == model.primaryComponentId;
    } else {
      return (fileName != null && activeInp == fileName) ||
          activeInp == model.logicalModelId ||
          activeInp == model.displayName ||
          activeInp == model.primaryComponentId;
    }
  }

  void _setActiveModel(LogicalImageModel model) {
    final status = _modelStatuses[model.logicalModelId];
    if (status == null || status.state != LogicalModelInstallState.installed) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Impossible d'activer un modèle non installé ou corrompu."),
          backgroundColor: Colors.redAccent,
        ),
      );
      return;
    }

    final primaryComp = _catalogService.catalog.components[model.primaryComponentId];
    final fileNameToPersist = primaryComp?.fileName ?? model.logicalModelId;

    setState(() {
      if (model.category == ImageModelCategory.generation) {
        _settings.activeImageModel = fileNameToPersist;
      } else {
        _settings.activeInpaintModel = fileNameToPersist;
      }
    });

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Modèle actif défini : ${model.displayName} ($fileNameToPersist)'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  bool _hasMissingActiveModelAlert(ImageModelCategory category) {
    final active = category == ImageModelCategory.generation
        ? _settings.activeImageModel.trim()
        : _settings.activeInpaintModel.trim();

    if (active.isEmpty) return false;

    final catalog = _catalogService.catalog;
    for (final model in catalog.logicalModels.values) {
      if (model.category == category && _isModelActive(model)) {
        final status = _modelStatuses[model.logicalModelId];
        if (status != null && status.state == LogicalModelInstallState.installed) {
          return false;
        }
      }
    }
    return true;
  }

  void _toggleSelection(String modelId) {
    final status = _modelStatuses[modelId];
    if (status?.state == LogicalModelInstallState.installed) {
      return;
    }

    setState(() {
      if (_selectedModelIds.contains(modelId)) {
        _selectedModelIds.remove(modelId);
      } else {
        _selectedModelIds.add(modelId);
      }
    });
  }

  Future<void> _startInstallationFlow() async {
    if (_selectedModelIds.isEmpty || _isInstalling) return;

    try {
      final plan = await _planner.buildPlan(
        targetLogicalModelIds: _selectedModelIds.toList(),
        checkDiskSpace: true,
      );

    if (!mounted) return;

    for (final modelId in plan.unacceptedLicenseModelIds) {
      if (!_acceptedLicensesForSession.contains(modelId)) {
        final model = _catalogService.catalog.logicalModels[modelId]!;
        final accepted = await _showLicenseDialog(model);
        if (!mounted) return;
        if (accepted != true) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Installation annulée : licence requise pour ${model.displayName}.'),
            ),
          );
          return;
        }
        _acceptedLicensesForSession.add(modelId);
      }
    }

    if (!mounted) return;

    final confirmed = await _showRecapDialog(plan);
    if (confirmed != true) return;

    await _executeInstallation(plan);
    } catch (e, st) {
      debugPrint('ERROR in _startInstallationFlow: $e\n$st');
    }
  }

  Future<bool> _launchExternalUrl(String urlStr) async {
    final uri = Uri.tryParse(urlStr);
    if (uri == null) return false;
    if (widget.urlLauncherOverride != null) {
      return widget.urlLauncherOverride!(uri);
    }
    return launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  Future<bool?> _showLicenseDialog(LogicalImageModel model) {
    return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            const Icon(Icons.gavel, color: Colors.orange),
            const SizedBox(width: 8),
            Expanded(child: Text('Acceptation de licence — ${model.displayName}')),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Modèle : ${model.displayName}', style: const TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              Text('Licence officielle : ${model.licenseId}'),
              const SizedBox(height: 12),
              const Text(
                "Des conditions d'utilisation et de distribution s'appliquent. "
                "Consultez le texte officiel de la licence avant de continuer.",
              ),
              const SizedBox(height: 10),
              if (model.licenseUrl != null && model.licenseUrl!.isNotEmpty) ...[
                TextButton.icon(
                  style: TextButton.styleFrom(
                    padding: EdgeInsets.zero,
                    alignment: Alignment.centerLeft,
                  ),
                  icon: const Icon(Icons.open_in_new, size: 14, color: Colors.blueAccent),
                  label: Text(
                    'Voir la licence officielle :\n${model.licenseUrl}',
                    style: const TextStyle(
                      fontSize: 12,
                      color: Colors.blueAccent,
                      decoration: TextDecoration.underline,
                    ),
                  ),
                  onPressed: () => _launchExternalUrl(model.licenseUrl!),
                ),
                const SizedBox(height: 8),
              ],
              if (model.sourcePageUrl != null && model.sourcePageUrl!.isNotEmpty) ...[
                TextButton.icon(
                  style: TextButton.styleFrom(
                    padding: EdgeInsets.zero,
                    alignment: Alignment.centerLeft,
                  ),
                  icon: const Icon(Icons.open_in_new, size: 14, color: Colors.blueAccent),
                  label: Text(
                    'Voir la source officielle :\n${model.sourcePageUrl}',
                    style: const TextStyle(
                      fontSize: 12,
                      color: Colors.blueAccent,
                      decoration: TextDecoration.underline,
                    ),
                  ),
                  onPressed: () => _launchExternalUrl(model.sourcePageUrl!),
                ),
                const SizedBox(height: 8),
              ],
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.amber.withAlpha(30),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  'Statut du catalogue : ${model.licenseStatus}\n'
                  "Obligations connues : attribution et respect des conditions de distribution de l'auteur.",
                  style: const TextStyle(fontSize: 12),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Annuler'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Accepter et continuer'),
          ),
        ],
      ),
    );
  }

  Future<bool?> _showRecapDialog(InstallationPlan plan) {
    final catalog = _catalogService.catalog;
    final selectedNames = plan.targetLogicalModelIds.map((id) => catalog.logicalModels[id]?.displayName ?? id).join(', ');

    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.inventory_2_outlined, color: Colors.teal),
            SizedBox(width: 8),
            Text("Récapitulatif d'installation"),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Modèles sélectionnés : $selectedNames', style: const TextStyle(fontWeight: FontWeight.bold)),
              const Divider(height: 20),
              Text('Composants à télécharger : ${plan.componentsToDownload.length}'),
              ...plan.componentsToDownload.map((c) => Padding(
                    padding: const EdgeInsets.only(left: 12, top: 2),
                    child: Text('• ${c.fileName} (${_formatBytes(c.expectedSizeBytes)})'),
                  )),
              const SizedBox(height: 8),
              if (plan.alreadyInstalledComponents.isNotEmpty) ...[
                Text('Dépendances partagées déjà installées (dédupliquées) : ${plan.alreadyInstalledComponents.length}'),
                ...plan.alreadyInstalledComponents.map((c) => Padding(
                      padding: const EdgeInsets.only(left: 12, top: 2),
                      child: Text('• ${c.fileName} (déjà présent, ignoré)', style: const TextStyle(color: Colors.grey)),
                    )),
                const SizedBox(height: 8),
              ],
              Text('Téléchargement total : ${_formatBytes(plan.downloadRequiredBytes)}',
                  style: const TextStyle(fontWeight: FontWeight.w600)),
              Text('Espace temporaire nécessaire : ${_formatBytes(plan.temporaryOverheadBytes)}'),
              Text('Espace disque requis : ${_formatBytes(plan.minimumFreeDiskBytes)}'),
              Text(
                'Espace libre sur le volume : ${_formatBytes(plan.availableFreeDiskBytes)}',
                style: TextStyle(
                  color: plan.isDiskSpaceSufficient ? Colors.green : Colors.red,
                  fontWeight: FontWeight.bold,
                ),
              ),
              if (!plan.isDiskSpaceSufficient) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.red.withAlpha(30),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: Colors.redAccent),
                  ),
                  child: Text(
                    'Espace disque insuffisant sur le volume portable (${_formatBytes(plan.availableFreeDiskBytes)} '
                    'disponibles vs ${_formatBytes(plan.minimumFreeDiskBytes)} requis).',
                    style: const TextStyle(color: Colors.redAccent, fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Annuler'),
          ),
          ElevatedButton(
            onPressed: plan.isDiskSpaceSufficient ? () => Navigator.of(ctx).pop(true) : null,
            child: const Text('Télécharger et installer'),
          ),
        ],
      ),
    );
  }

  Future<void> _executeInstallation(InstallationPlan plan) async {
    setState(() {
      _isInstalling = true;
      _lastProgressEvent = null;
      _statusBannerMessage = null;
      _isBannerError = false;
    });

    _progressSub?.cancel();
    _progressSub = _installer.progressStream.listen((event) {
      if (mounted) {
        setState(() {
          _lastProgressEvent = event;
        });
      }
    });

    try {
      await _installer.executePlan(plan, acceptedLicenses: true);

      if (mounted) {
        setState(() {
          _isInstalling = false;
          _selectedModelIds.clear();
          _statusBannerMessage = 'Installation terminée avec succès.';
          _isBannerError = false;
        });
      }
      await _refreshStatuses(verifySha: true);
    } on ImageInstallerException catch (e) {
      String msg;
      if (e.code == 'DISK_SPACE_INSUFFICIENT') {
        msg = "Espace disque insuffisant sur le volume portable pour terminer l'installation.";
      } else if (e.code == 'DOWNLOAD_DISK_FULL') {
        msg = 'Le disque est devenu insuffisant pendant le téléchargement.';
      } else if (e.code == 'HASH_MISMATCH') {
        msg = "Le fichier téléchargé ne correspond pas au fichier attendu. Il n'a pas été installé.";
      } else if (e.code == 'REMOTE_ARTIFACT_CHANGED') {
        msg = 'La source distante a changé. Le téléchargement doit être recommencé en toute sécurité.';
      } else if (e.code == 'DOWNLOAD_CANCELLED') {
        msg = 'Téléchargement annulé.';
      } else {
        msg = 'Erreur d\'installation (${e.code}) : ${e.message}';
      }

      if (mounted) {
        setState(() {
          _isInstalling = false;
          _statusBannerMessage = msg;
          _isBannerError = e.code != 'DOWNLOAD_CANCELLED';
        });
      }
      await _refreshStatuses();
    } catch (e) {
      if (mounted) {
        setState(() {
          _isInstalling = false;
          _statusBannerMessage = 'Erreur réseau ou imprévue : ${e.toString()}';
          _isBannerError = true;
        });
      }
      await _refreshStatuses();
    }
  }

  void _cancelDownload() {
    _installer.cancel();
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return Scaffold(
        appBar: AppBar(title: const Text('Modèles Image')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    if (_initErrorMessage != null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Modèles Image')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.error_outline, size: 48, color: Colors.red),
                const SizedBox(height: 12),
                Text('Erreur de chargement du catalogue : $_initErrorMessage'),
                const SizedBox(height: 16),
                ElevatedButton(
                  onPressed: _loadCatalogAndRefresh,
                  child: const Text('Réessayer'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final catalog = _catalogService.catalog;
    final generationModels = catalog.logicalModels.values.where((m) => m.category == ImageModelCategory.generation).toList();
    final inpaintModels = catalog.logicalModels.values.where((m) => m.category == ImageModelCategory.inpaint).toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Modèles Image'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: "Actualiser l'état des fichiers",
            onPressed: _isInstalling ? null : () => _loadCatalogAndRefresh(),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_statusBannerMessage != null) ...[
              Container(
                padding: const EdgeInsets.all(12),
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: _isBannerError ? Colors.red.withAlpha(30) : Colors.green.withAlpha(30),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: _isBannerError ? Colors.redAccent : Colors.green),
                ),
                child: Row(
                  children: [
                    Icon(_isBannerError ? Icons.warning_amber_rounded : Icons.check_circle_outline,
                        color: _isBannerError ? Colors.redAccent : Colors.green),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _statusBannerMessage!,
                        style: TextStyle(color: _isBannerError ? Colors.red[900] : Colors.green[900]),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, size: 16),
                      onPressed: () => setState(() => _statusBannerMessage = null),
                    ),
                  ],
                ),
              ),
            ],
            if (_isInstalling || _lastProgressEvent != null) ...[
              _buildProgressCard(),
              const SizedBox(height: 16),
            ],
            _buildSectionHeader(
              title: 'GÉNÉRATION',
              activeModelText: _settings.activeImageModel,
              hasMissingActiveAlert: _hasMissingActiveModelAlert(ImageModelCategory.generation),
              hwStatus: _genHardwareEval?.status,
            ),
            const SizedBox(height: 8),
            ...generationModels.map((model) => _buildModelCard(model)),
            const SizedBox(height: 24),
            _buildSectionHeader(
              title: 'INPAINT / MODIFICATION',
              activeModelText: _settings.activeInpaintModel,
              hasMissingActiveAlert: _hasMissingActiveModelAlert(ImageModelCategory.inpaint),
              hwStatus: _inpaintHardwareEval?.status,
            ),
            const SizedBox(height: 8),
            ...inpaintModels.map((model) => _buildModelCard(model)),
            const SizedBox(height: 40),
          ],
        ),
      ),
      bottomNavigationBar: _buildBottomActionBar(),
    );
  }

  Widget _buildSectionHeader({
    required String title,
    required String activeModelText,
    required bool hasMissingActiveAlert,
    CapabilityStatus? hwStatus,
  }) {
    final activeDisplay = activeModelText.isEmpty ? '(aucun)' : activeModelText;
    final hwLabel = _formatCapability(hwStatus);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              title,
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0.8,
                  ),
            ),
            const SizedBox(width: 12),
            Flexible(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.blueGrey.withAlpha(30),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  hwLabel,
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          'Actif actuellement : $activeDisplay',
          style: TextStyle(
            fontSize: 13,
            color: Theme.of(context).colorScheme.primary,
            fontWeight: FontWeight.w600,
          ),
        ),
        if (hasMissingActiveAlert) ...[
          const SizedBox(height: 6),
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.amber.withAlpha(40),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: Colors.amber),
            ),
            child: Row(
              children: [
                const Icon(Icons.warning, color: Colors.amber, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    "Le modèle configuré comme actif (« $activeModelText ») n'est pas disponible. "
                    "Veuillez choisir un autre modèle installé.",
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  String _formatLicenseDisplay(LogicalImageModel model) {
    switch (model.licenseStatus) {
      case 'LICENSE_CLEAR_FOR_DOWNLOAD_INSTALLER':
        return 'Licence : téléchargement autorisé (${model.licenseId})';
      case 'LICENSE_REQUIRES_ATTRIBUTION':
        return 'Licence : attribution / notice requise (${model.licenseId})';
      case 'LICENSE_REQUIRES_USER_ACCEPTANCE':
        return 'Licence : acceptation requise (${model.licenseId})';
      default:
        return 'Licence : ${model.licenseStatus} (${model.licenseId})';
    }
  }

  Color _getLicenseDisplayColor(LogicalImageModel model) {
    switch (model.licenseStatus) {
      case 'LICENSE_CLEAR_FOR_DOWNLOAD_INSTALLER':
        return Colors.green[800]!;
      case 'LICENSE_REQUIRES_ATTRIBUTION':
        return Colors.blue[800]!;
      case 'LICENSE_REQUIRES_USER_ACCEPTANCE':
        return Colors.orange[800]!;
      default:
        return Colors.grey[800]!;
    }
  }

  Widget _buildModelCard(LogicalImageModel model) {
    final status = _modelStatuses[model.logicalModelId];
    final installState = status?.state ?? LogicalModelInstallState.unknown;
    final isInstalled = installState == LogicalModelInstallState.installed;
    final isActive = _isModelActive(model);
    final isSelected = _selectedModelIds.contains(model.logicalModelId);

    final totalSizeBytes = status?.totalRequiredSizeBytes ?? 0;
    final installedSizeBytes = status?.installedSizeBytes ?? 0;
    final downloadNeededBytes = totalSizeBytes - installedSizeBytes;

    String stateLabel;
    Color stateColor;
    switch (installState) {
      case LogicalModelInstallState.installed:
        stateLabel = 'INSTALLÉ';
        stateColor = Colors.green;
        break;
      case LogicalModelInstallState.notInstalled:
        stateLabel = 'NON INSTALLÉ';
        stateColor = Colors.grey;
        break;
      case LogicalModelInstallState.partiallyInstalled:
        stateLabel = 'Installation partielle';
        stateColor = Colors.orange;
        break;
      case LogicalModelInstallState.corrupt:
        stateLabel = 'Fichier invalide / vérification nécessaire';
        stateColor = Colors.red;
        break;
      case LogicalModelInstallState.unknown:
        stateLabel = 'État inconnu / À vérifier';
        stateColor = Colors.amber;
        break;
    }

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(
          color: isActive ? Theme.of(context).colorScheme.primary : Colors.grey.withAlpha(40),
          width: isActive ? 2 : 1,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Checkbox(
                  value: isSelected,
                  onChanged: (isInstalled || _isInstalling) ? null : (_) => _toggleSelection(model.logicalModelId),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              model.displayName,
                              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                            ),
                          ),
                          if (isActive) ...[
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: Theme.of(context).colorScheme.primary,
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: const Text(
                                'ACTIF',
                                style: TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold),
                              ),
                            ),
                          ],
                        ],
                      ),
                      Text(
                        'Catégorie : ${model.category.toJsonString()} | Backend : ${model.backend}',
                        style: const TextStyle(fontSize: 12, color: Colors.grey),
                      ),
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: stateColor.withAlpha(30),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: stateColor),
                  ),
                  child: Text(
                    stateLabel,
                    style: TextStyle(color: stateColor, fontSize: 11, fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
            const Divider(height: 16),
            Wrap(
              spacing: 16,
              runSpacing: 6,
              children: [
                Text(
                  installState == LogicalModelInstallState.unknown
                      ? 'Téléchargement nécessaire : à déterminer après vérification'
                      : 'Téléchargement nécessaire : ${_formatBytes(downloadNeededBytes > 0 ? downloadNeededBytes : 0)}',
                  style: const TextStyle(fontSize: 12),
                ),
                Text(
                  'Taille totale installée : ${_formatBytes(totalSizeBytes)}',
                  style: const TextStyle(fontSize: 12),
                ),
                const Text(
                  'Compatibilité modèle : Inconnue',
                  style: TextStyle(fontSize: 12, color: Colors.blueGrey),
                ),
                Text(
                  _formatLicenseDisplay(model),
                  style: TextStyle(
                    fontSize: 12,
                    color: _getLicenseDisplayColor(model),
                  ),
                ),
              ],
            ),
            if (model.sharedDependencyIds.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                'Dépendances partagées : ${model.sharedDependencyIds.map((id) => _catalogService.catalog.components[id]?.fileName ?? id).join(', ')}',
                style: const TextStyle(fontSize: 11, fontStyle: FontStyle.italic, color: Colors.grey),
              ),
            ],
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (!isActive)
                  OutlinedButton.icon(
                    icon: const Icon(Icons.check, size: 16),
                    label: const Text('Définir comme actif'),
                    onPressed: isInstalled ? () => _setActiveModel(model) : null,
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildProgressCard() {
    final event = _lastProgressEvent;
    final status = event?.status ?? ImageDownloadStatus.queued;
    final statusLabel = status.name.toUpperCase();
    final fileName = event?.currentFileName ?? '';
    final percent = event?.progressPercentage ?? 0.0;
    final downloaded = event?.bytesDownloaded ?? 0;
    final total = event?.totalBytes ?? 0;
    final isResumed = event?.isResumed ?? false;

    return Card(
      color: Colors.blueGrey.withAlpha(20),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  'Statut : $statusLabel',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                const Spacer(),
                if (_isInstalling)
                  TextButton(
                    onPressed: _cancelDownload,
                    child: const Text('Annuler', style: TextStyle(color: Colors.redAccent)),
                  ),
              ],
            ),
            if (fileName.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text('Fichier en cours : $fileName', style: const TextStyle(fontSize: 12)),
            ],
            if (isResumed) ...[
              const SizedBox(height: 4),
              const Text(
                'Téléchargement partiel détecté — reprise disponible',
                style: TextStyle(fontSize: 12, color: Colors.teal, fontWeight: FontWeight.bold),
              ),
            ],
            const SizedBox(height: 8),
            LinearProgressIndicator(
              value: percent.clamp(0.0, 1.0),
              backgroundColor: Colors.grey.withAlpha(40),
            ),
            const SizedBox(height: 6),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  '${_formatBytes(downloaded)} / ${_formatBytes(total)}',
                  style: const TextStyle(fontSize: 11),
                ),
                Text(
                  '${(percent * 100).toStringAsFixed(1)}%',
                  style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBottomActionBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        border: Border(top: BorderSide(color: Colors.grey.withAlpha(40))),
      ),
      child: SafeArea(
        child: Row(
          children: [
            Text(
              '${_selectedModelIds.length} modèle(s) sélectionné(s)',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const Spacer(),
            ElevatedButton.icon(
              icon: const Icon(Icons.download),
              label: const Text('Installer la sélection'),
              onPressed: (_selectedModelIds.isEmpty || _isInstalling) ? null : _startInstallationFlow,
            ),
          ],
        ),
      ),
    );
  }
}
