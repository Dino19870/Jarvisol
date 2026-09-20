import 'dart:convert';
import 'package:crypto/crypto.dart';

/// Fiabilite d\'une metrique materielle mesuree
enum MetricReliability {
  reliable,
  partial,
  heuristic,
  unknown,
}

/// Base decisionnelle pour une evaluation de capacite
enum DecisionBasis {
  heuristic,
  verifiedRuntime,
  unknown,
}

/// Metrique materielle typee avec source et fiabilite
class HardwareMetric<T> {
  final T? value;
  final String source;
  final MetricReliability reliability;

  const HardwareMetric({
    required this.value,
    required this.source,
    required this.reliability,
  });

  const HardwareMetric.unknown([this.source = 'none'])
      : value = null,
        reliability = MetricReliability.unknown;

  bool get isAvailable => value != null && reliability != MetricReliability.unknown;

  Map<String, dynamic> toJson() => {
        'value': value,
        'source': source,
        'reliability': reliability.name,
      };

  factory HardwareMetric.fromJson(Map<String, dynamic>? json) {
    if (json == null) return const HardwareMetric.unknown();
    final relName = json['reliability'] as String?;
    final rel = MetricReliability.values.firstWhere(
      (e) => e.name == relName,
      orElse: () => MetricReliability.unknown,
    );
    return HardwareMetric(
      value: json['value'] as T?,
      source: (json['source'] as String?) ?? 'unknown',
      reliability: rel,
    );
  }
}

/// Type de GPU identifie
enum GpuAdapterType {
  discrete,
  integrated,
  software,
  unknown,
}

/// Informations sur un adaptateur graphique DXGI
class GpuAdapterInfo {
  final String name;
  final int vendorId;
  final int deviceId;
  final int dedicatedVideoMemoryBytes;
  final int sharedSystemMemoryBytes;
  final bool isBasicRenderDriver;
  final GpuAdapterType adapterType;

  const GpuAdapterInfo({
    required this.name,
    required this.vendorId,
    required this.deviceId,
    required this.dedicatedVideoMemoryBytes,
    required this.sharedSystemMemoryBytes,
    this.isBasicRenderDriver = false,
    this.adapterType = GpuAdapterType.unknown,
  });

  String get vendorName {
    switch (vendorId) {
      case 0x10DE:
        return 'NVIDIA';
      case 0x1002:
        return 'AMD';
      case 0x8086:
        return 'Intel';
      case 0x1414:
        return 'Microsoft';
      default:
        return 'Unknown';
    }
  }

  Map<String, dynamic> toJson() => {
        'name': name,
        'vendor_id': vendorId,
        'device_id': deviceId,
        'vendor_name': vendorName,
        'dedicated_vram_bytes': dedicatedVideoMemoryBytes,
        'shared_ram_bytes': sharedSystemMemoryBytes,
        'is_basic_driver': isBasicRenderDriver,
        'adapter_type': adapterType.name,
      };

  factory GpuAdapterInfo.fromJson(Map<String, dynamic> json) {
    final typeName = json['adapter_type'] as String?;
    final type = GpuAdapterType.values.firstWhere(
      (e) => e.name == typeName,
      orElse: () => GpuAdapterType.unknown,
    );
    return GpuAdapterInfo(
      name: (json['name'] as String?) ?? 'Unknown GPU',
      vendorId: (json['vendor_id'] as int?) ?? 0,
      deviceId: (json['device_id'] as int?) ?? 0,
      dedicatedVideoMemoryBytes: (json['dedicated_vram_bytes'] as int?) ?? 0,
      sharedSystemMemoryBytes: (json['shared_ram_bytes'] as int?) ?? 0,
      isBasicRenderDriver: (json['is_basic_driver'] as bool?) ?? false,
      adapterType: type,
    );
  }
}

/// Structure distincte pour le support Vulkan
class VulkanSupportInfo {
  final bool backendPresent; // sd_vulkan/ggml-vulkan.dll present dans Jarvisol
  final bool loaderPresent;  // C:\Windows\System32\vulkan-1.dll present sur l'hote
  final MetricReliability deviceSupportReliability;
  final bool? deviceSupported; // null/unknown si aucun probe materiel de peripherique

  const VulkanSupportInfo({
    required this.backendPresent,
    required this.loaderPresent,
    this.deviceSupportReliability = MetricReliability.unknown,
    this.deviceSupported,
  });

  Map<String, dynamic> toJson() => {
        'vulkan_backend_present': backendPresent,
        'vulkan_loader_present': loaderPresent,
        'vulkan_device_support': deviceSupported != null ? deviceSupported.toString() : 'UNKNOWN',
        'device_support_reliability': deviceSupportReliability.name,
      };

  factory VulkanSupportInfo.fromJson(Map<String, dynamic> json) {
    final relName = json['device_support_reliability'] as String?;
    final rel = MetricReliability.values.firstWhere(
      (e) => e.name == relName,
      orElse: () => MetricReliability.unknown,
    );
    final devRaw = json['vulkan_device_support'];
    bool? devSupport;
    if (devRaw == true || devRaw == 'true') {
      devSupport = true;
    } else if (devRaw == false || devRaw == 'false') {
      devSupport = false;
    }
    return VulkanSupportInfo(
      backendPresent: (json['vulkan_backend_present'] as bool?) ?? false,
      loaderPresent: (json['vulkan_loader_present'] as bool?) ?? false,
      deviceSupportReliability: rel,
      deviceSupported: devSupport,
    );
  }
}

/// Disponibilité du runtime d'exécution (REQ-GAP-EXT01-STATE-SEPARATION-001)
enum RuntimeAvailability {
  available,
  unavailable,
  unknown,
  notApplicable,
}

/// État d'installation des modèles locaux requis (REQ-GAP-EXT01-STATE-SEPARATION-001)
enum ModelInstallationState {
  installed,
  notInstalled,
  unknown,
  notApplicable,
}

/// Disponibilité du service local externe (ex: LM Studio)
enum ServiceReachability {
  reachable,
  unreachable,
  unknown,
  notApplicable,
}

/// Évaluation de compatibilité d'un modèle spécifique précis
enum ModelSpecificCompatibility {
  compatible,
  limited,
  notRecommended,
  unknown,
  notApplicable,
}

/// Statut de compatibilite materielle d'un moteur
enum CapabilityStatus {
  compatible,
  probablyCompatible,
  limited,
  notRecommended,
  unavailable,
  unknown,
}

/// Niveau de confiance de l'evaluation
enum CapabilityConfidence {
  high,
  medium,
  low,
  unknown,
}

/// Categories de moteurs IA evalues
enum EngineCategory {
  liteRt,
  lmStudio,
  asr,
  tts,
  imageGen,
  imageInpaint,
  portableStorage,
}

/// Evaluation pour une categorie de moteur distinguant clairement :
/// 1. hardware_capability (status)
/// 2. runtime_available
/// 3. model_installed
/// et pour LM Studio :
/// service_state / hardware_capability / model_specific_compatibility
class CapabilityEvaluation {
  final EngineCategory category;
  final CapabilityStatus status; // Capacité matérielle
  final CapabilityConfidence confidence;
  final DecisionBasis decisionBasis;
  final List<String> reasonCodes;
  final String humanMessage;

  // Dimensions séparées typées (REQ-GAP-EXT01-STATE-SEPARATION-001)
  final RuntimeAvailability runtimeAvailable;
  final ModelInstallationState modelInstalled;
  final ServiceReachability serviceState;
  final ModelSpecificCompatibility modelSpecificCompatibility;

  const CapabilityEvaluation({
    required this.category,
    required this.status,
    required this.confidence,
    this.decisionBasis = DecisionBasis.heuristic,
    required this.reasonCodes,
    required this.humanMessage,
    this.runtimeAvailable = RuntimeAvailability.unknown,
    this.modelInstalled = ModelInstallationState.unknown,
    this.serviceState = ServiceReachability.notApplicable,
    this.modelSpecificCompatibility = ModelSpecificCompatibility.notApplicable,
  });

  /// Alias explicite pour la capacité matérielle
  CapabilityStatus get hardwareCapability => status;

  /// Indique si le moteur est entièrement prêt à fonctionner immédiatement :
  /// Matériel compatible ET runtime disponible ET modèle installé.
  /// Ne jamais prétendre prêt si le modèle est non installé ou indéterminé.
  /// Pour LM Studio : service_state = REACHABLE + matériel compatible NE SUFFIT PAS
  /// si model_specific_compatibility == UNKNOWN.
  bool get isFullyReady {
    if (status == CapabilityStatus.unavailable || status == CapabilityStatus.notRecommended) {
      return false;
    }
    if (category == EngineCategory.lmStudio) {
      if (serviceState != ServiceReachability.reachable) {
        return false;
      }
      if (modelSpecificCompatibility != ModelSpecificCompatibility.compatible) {
        return false;
      }
      return true;
    }
    if (category == EngineCategory.portableStorage) {
      return status == CapabilityStatus.compatible || status == CapabilityStatus.probablyCompatible;
    }
    if (runtimeAvailable != RuntimeAvailability.available) {
      return false;
    }
    if (modelInstalled != ModelInstallationState.installed) {
      return false;
    }
    return true;
  }

  Map<String, dynamic> toJson() => {
        'category': category.name,
        'status': status.name,
        'hardware_capability': status.name,
        'confidence': confidence.name,
        'decision_basis': decisionBasis.name,
        'reason_codes': reasonCodes,
        'human_message': humanMessage,
        'runtime_available': runtimeAvailable.name,
        'model_installed': modelInstalled.name,
        'service_state': serviceState.name,
        'model_specific_compatibility': modelSpecificCompatibility.name,
        'is_fully_ready': isFullyReady,
      };

  factory CapabilityEvaluation.fromJson(Map<String, dynamic> json) {
    final catName = json['category'] as String?;
    final cat = EngineCategory.values.firstWhere(
      (e) => e.name == catName,
      orElse: () => EngineCategory.liteRt,
    );
    final statName = (json['hardware_capability'] as String?) ?? (json['status'] as String?);
    final stat = CapabilityStatus.values.firstWhere(
      (e) => e.name == statName,
      orElse: () => CapabilityStatus.unknown,
    );
    final confName = json['confidence'] as String?;
    final conf = CapabilityConfidence.values.firstWhere(
      (e) => e.name == confName,
      orElse: () => CapabilityConfidence.unknown,
    );
    final decName = json['decision_basis'] as String?;
    final dec = DecisionBasis.values.firstWhere(
      (e) => e.name == decName,
      orElse: () => DecisionBasis.unknown,
    );
    final reasons = (json['reason_codes'] as List<dynamic>?)
            ?.map((e) => e.toString())
            .toList() ??
        const [];

    final rtName = json['runtime_available'] as String?;
    final rt = RuntimeAvailability.values.firstWhere(
      (e) => e.name == rtName,
      orElse: () => RuntimeAvailability.unknown,
    );

    final miName = json['model_installed'] as String?;
    final mi = ModelInstallationState.values.firstWhere(
      (e) => e.name == miName,
      orElse: () => ModelInstallationState.unknown,
    );

    final ssName = json['service_state'] as String?;
    final ss = ServiceReachability.values.firstWhere(
      (e) => e.name == ssName,
      orElse: () => ServiceReachability.notApplicable,
    );

    final mscName = json['model_specific_compatibility'] as String?;
    final msc = ModelSpecificCompatibility.values.firstWhere(
      (e) => e.name == mscName,
      orElse: () => ModelSpecificCompatibility.notApplicable,
    );

    return CapabilityEvaluation(
      category: cat,
      status: stat,
      confidence: conf,
      decisionBasis: dec,
      reasonCodes: reasons,
      humanMessage: (json['human_message'] as String?) ?? '',
      runtimeAvailable: rt,
      modelInstalled: mi,
      serviceState: ss,
      modelSpecificCompatibility: msc,
    );
  }
}

/// Profil materiel de la machine hote
class HardwareProfile {
  final HardwareMetric<String> cpuArch;
  final HardwareMetric<String> cpuModel;
  final HardwareMetric<int> logicalProcessors;
  final HardwareMetric<int> physicalCores;
  final HardwareMetric<int> ramTotalBytes;
  final HardwareMetric<int> ramAvailableBytes;
  final List<GpuAdapterInfo> gpuAdapters;
  final VulkanSupportInfo vulkanInfo;
  final HardwareMetric<int> portableDiskTotalBytes;
  final HardwareMetric<int> portableDiskFreeBytes;
  final HardwareMetric<String> portableDiskVolume;
  final HardwareMetric<String> windowsVersion;
  final HardwareMetric<String> osArch;
  final DateTime scanTimestamp;

  const HardwareProfile({
    required this.cpuArch,
    required this.cpuModel,
    required this.logicalProcessors,
    required this.physicalCores,
    required this.ramTotalBytes,
    required this.ramAvailableBytes,
    required this.gpuAdapters,
    required this.vulkanInfo,
    required this.portableDiskTotalBytes,
    required this.portableDiskFreeBytes,
    required this.portableDiskVolume,
    required this.windowsVersion,
    required this.osArch,
    required this.scanTimestamp,
  });

  /// Profil de repli en cas d'erreur d'inspection ou timeout
  factory HardwareProfile.unknown({String details = ''}) {
    return HardwareProfile(
      cpuArch: const HardwareMetric.unknown('timeout_fallback'),
      cpuModel: HardwareMetric(
        value: details.isNotEmpty ? details : 'Inconnu',
        source: 'timeout_fallback',
        reliability: MetricReliability.unknown,
      ),
      logicalProcessors: const HardwareMetric.unknown('timeout_fallback'),
      physicalCores: const HardwareMetric.unknown('timeout_fallback'),
      ramTotalBytes: const HardwareMetric.unknown('timeout_fallback'),
      ramAvailableBytes: const HardwareMetric.unknown('timeout_fallback'),
      gpuAdapters: const [],
      vulkanInfo: const VulkanSupportInfo(
        backendPresent: false,
        loaderPresent: false,
        deviceSupportReliability: MetricReliability.unknown,
        deviceSupported: null,
      ),
      portableDiskTotalBytes: const HardwareMetric.unknown('timeout_fallback'),
      portableDiskFreeBytes: const HardwareMetric.unknown('timeout_fallback'),
      portableDiskVolume: const HardwareMetric.unknown('timeout_fallback'),
      windowsVersion: const HardwareMetric.unknown('timeout_fallback'),
      osArch: const HardwareMetric.unknown('timeout_fallback'),
      scanTimestamp: DateTime.now(),
    );
  }

  GpuAdapterInfo? get primaryGpu {
    final nonBasic = gpuAdapters.where((g) => !g.isBasicRenderDriver).toList();
    if (nonBasic.isEmpty) {
      return gpuAdapters.isNotEmpty ? gpuAdapters.first : null;
    }
    // Privilegier un adaptateur avec VRAM dediee rapportee
    nonBasic.sort((a, b) => b.dedicatedVideoMemoryBytes.compareTo(a.dedicatedVideoMemoryBytes));
    return nonBasic.first;
  }

  /// Calcul d'une empreinte technique anonyme par tranches
  String get technicalFingerprint {
    final arch = cpuArch.value ?? 'unknown_arch';
    final cores = logicalProcessors.value ?? 0;
    final coresBucket = cores >= 16
        ? 'cores_16plus'
        : cores >= 8
            ? 'cores_8_15'
            : cores >= 4
                ? 'cores_4_7'
                : 'cores_1_3';

    final ramBytes = ramTotalBytes.value ?? 0;
    final ramGb = ramBytes / (1024 * 1024 * 1024);
    final ramBucket = ramGb >= 48
        ? 'ram_64'
        : ramGb >= 24
            ? 'ram_32'
            : ramGb >= 12
                ? 'ram_16'
                : ramGb >= 6
                    ? 'ram_8'
                    : 'ram_4_or_less';

    final gpu = primaryGpu;
    final gpuBucket = gpu != null
        ? '${gpu.vendorName.toLowerCase()}_${(gpu.dedicatedVideoMemoryBytes / (1024 * 1024 * 1024)).round()}gb'
        : 'no_gpu';

    final rawString = '$arch|$coresBucket|$ramBucket|$gpuBucket';
    return sha256.convert(utf8.encode(rawString)).toString();
  }

  Map<String, dynamic> toJson() => {
        'scan_timestamp': scanTimestamp.toIso8601String(),
        'fingerprint': technicalFingerprint,
        'cpu_arch': cpuArch.toJson(),
        'cpu_model': cpuModel.toJson(),
        'logical_processors': logicalProcessors.toJson(),
        'physical_cores': physicalCores.toJson(),
        'ram_total_bytes': ramTotalBytes.toJson(),
        'ram_available_bytes': ramAvailableBytes.toJson(),
        'gpu_adapters': gpuAdapters.map((g) => g.toJson()).toList(),
        'vulkan': vulkanInfo.toJson(),
        'disk_total_bytes': portableDiskTotalBytes.toJson(),
        'disk_free_bytes': portableDiskFreeBytes.toJson(),
        'disk_volume': portableDiskVolume.toJson(),
        'windows_version': windowsVersion.toJson(),
        'os_arch': osArch.toJson(),
      };

  factory HardwareProfile.fromJson(Map<String, dynamic> json) {
    final gpus = (json['gpu_adapters'] as List<dynamic>?)
            ?.map((e) => GpuAdapterInfo.fromJson(e as Map<String, dynamic>))
            .toList() ??
        const [];
    final vulkanJson = json['vulkan'] as Map<String, dynamic>?;
    final vulkan = vulkanJson != null
        ? VulkanSupportInfo.fromJson(vulkanJson)
        : const VulkanSupportInfo(backendPresent: false, loaderPresent: false);

    return HardwareProfile(
      cpuArch: HardwareMetric.fromJson(json['cpu_arch'] as Map<String, dynamic>?),
      cpuModel: HardwareMetric.fromJson(json['cpu_model'] as Map<String, dynamic>?),
      logicalProcessors: HardwareMetric.fromJson(json['logical_processors'] as Map<String, dynamic>?),
      physicalCores: HardwareMetric.fromJson(json['physical_cores'] as Map<String, dynamic>?),
      ramTotalBytes: HardwareMetric.fromJson(json['ram_total_bytes'] as Map<String, dynamic>?),
      ramAvailableBytes: HardwareMetric.fromJson(json['ram_available_bytes'] as Map<String, dynamic>?),
      gpuAdapters: gpus,
      vulkanInfo: vulkan,
      portableDiskTotalBytes: HardwareMetric.fromJson(json['disk_total_bytes'] as Map<String, dynamic>?),
      portableDiskFreeBytes: HardwareMetric.fromJson(json['disk_free_bytes'] as Map<String, dynamic>?),
      portableDiskVolume: HardwareMetric.fromJson(json['disk_volume'] as Map<String, dynamic>?),
      windowsVersion: HardwareMetric.fromJson(json['windows_version'] as Map<String, dynamic>?),
      osArch: HardwareMetric.fromJson(json['os_arch'] as Map<String, dynamic>?),
      scanTimestamp: DateTime.tryParse(json['scan_timestamp'] as String? ?? '') ?? DateTime.now(),
    );
  }
}
