// test/hardware_advisor_test.dart
//
// Tests unitaires du Hardware Capability Advisor (EXT-V1-01)
// Couvre l'ensemble des scénarios A à N et les règles de durcissement :
// - Section 3 : TTS runtime production-path UNKNOWN non transformé en AVAILABLE
// - Section 4 : Vulkan loader/backend/device séparés
// - Section 6 : GPU type UNKNOWN si non prouvé, VRAM dédiée vs partagée
// - Section 9 : Pression mémoire LM Studio (< 2 Go dispo)

import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvisol/models/hardware_profile.dart';
import 'package:jarvisol/services/hardware_advisor_service.dart';
import 'package:jarvisol/services/windows_hardware_probe.dart';
import 'package:jarvisol/utils/app_paths.dart';

/// Sonde factice confinée exclusivement dans l'arborescence test/ (Règle 13)
class FakeHardwareProbe implements HardwareProbe {
  final HardwareProfile cannedProfile;
  final Duration delay;
  final bool shouldThrow;

  FakeHardwareProbe({
    required this.cannedProfile,
    this.delay = Duration.zero,
    this.shouldThrow = false,
  });

  @override
  Future<HardwareProfile> probe() async {
    if (delay > Duration.zero) {
      await Future<void>.delayed(delay);
    }
    if (shouldThrow) {
      throw Exception('Sonde simulée en échec');
    }
    return cannedProfile;
  }
}

HardwareProfile _createTestProfile({
  int ramTotalGb = 16,
  int ramAvailGb = 8,
  int logicalProcs = 8,
  String? cpuModel = 'AMD Ryzen 7 5800H',
  List<GpuAdapterInfo> gpus = const [],
  bool vulkanBackend = true,
  bool vulkanLoader = true,
  bool? vulkanDevice,
  MetricReliability vulkanDeviceReliability = MetricReliability.unknown,
  int diskFreeGb = 50,
  String diskVolume = 'D:',
  MetricReliability reliability = MetricReliability.reliable,
}) {
  return HardwareProfile(
    cpuArch: HardwareMetric(
      value: 'x64',
      source: 'test',
      reliability: reliability,
    ),
    cpuModel: cpuModel != null
        ? HardwareMetric(
            value: cpuModel,
            source: 'test',
            reliability: reliability,
          )
        : const HardwareMetric.unknown('none'),
    logicalProcessors: HardwareMetric(
      value: logicalProcs,
      source: 'test',
      reliability: reliability,
    ),
    physicalCores: const HardwareMetric.unknown('none'),
    ramTotalBytes: HardwareMetric(
      value: ramTotalGb * 1024 * 1024 * 1024,
      source: 'test',
      reliability: reliability,
    ),
    ramAvailableBytes: HardwareMetric(
      value: ramAvailGb * 1024 * 1024 * 1024,
      source: 'test',
      reliability: reliability,
    ),
    gpuAdapters: gpus,
    vulkanInfo: VulkanSupportInfo(
      backendPresent: vulkanBackend,
      loaderPresent: vulkanLoader,
      deviceSupportReliability: vulkanDeviceReliability,
      deviceSupported: vulkanDevice,
    ),
    portableDiskTotalBytes: HardwareMetric(
      value: 500 * 1024 * 1024 * 1024,
      source: 'test',
      reliability: reliability,
    ),
    portableDiskFreeBytes: HardwareMetric(
      value: diskFreeGb * 1024 * 1024 * 1024,
      source: 'test',
      reliability: reliability,
    ),
    portableDiskVolume: HardwareMetric(
      value: diskVolume,
      source: 'test',
      reliability: reliability,
    ),
    windowsVersion: HardwareMetric(
      value: 'Windows 11 Build 22631',
      source: 'test',
      reliability: reliability,
    ),
    osArch: HardwareMetric(
      value: 'x64',
      source: 'test',
      reliability: reliability,
    ),
    scanTimestamp: DateTime(2026, 9, 6, 12, 0, 0),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('HardwareProfile Serialization & Invariants', () {
    test('JSON round-trip preserves all fields', () {
      final original = _createTestProfile(
        ramTotalGb: 16,
        ramAvailGb: 10,
        logicalProcs: 8,
        gpus: [
          const GpuAdapterInfo(
            name: 'NVIDIA GeForce RTX 3060 Laptop',
            vendorId: 0x10DE,
            deviceId: 0x2520,
            dedicatedVideoMemoryBytes: 6 * 1024 * 1024 * 1024,
            sharedSystemMemoryBytes: 8 * 1024 * 1024 * 1024,
            adapterType: GpuAdapterType.discrete,
          ),
        ],
      );

      final json = original.toJson();
      final restored = HardwareProfile.fromJson(json);

      expect(restored.ramTotalBytes.value, original.ramTotalBytes.value);
      expect(restored.ramAvailableBytes.value, original.ramAvailableBytes.value);
      expect(restored.logicalProcessors.value, original.logicalProcessors.value);
      expect(restored.physicalCores.value, isNull);
      expect(restored.gpuAdapters.length, 1);
      expect(restored.gpuAdapters.first.name, 'NVIDIA GeForce RTX 3060 Laptop');
      expect(restored.gpuAdapters.first.adapterType, GpuAdapterType.discrete);
      expect(restored.vulkanInfo.backendPresent, isTrue);
      expect(restored.vulkanInfo.loaderPresent, isTrue);
      expect(restored.technicalFingerprint, original.technicalFingerprint);
    });

    test('Fingerprint is anonymized and bucketized SHA-256', () {
      final profile = _createTestProfile(
        ramTotalGb: 16,
        logicalProcs: 8,
        gpus: [
          const GpuAdapterInfo(
            name: 'NVIDIA GeForce RTX 3060',
            vendorId: 0x10DE,
            deviceId: 0x2520,
            dedicatedVideoMemoryBytes: 6 * 1024 * 1024 * 1024,
            sharedSystemMemoryBytes: 8 * 1024 * 1024 * 1024,
            adapterType: GpuAdapterType.discrete,
          ),
        ],
      );

      final fp = profile.technicalFingerprint;
      expect(fp.length, 64);
      expect(RegExp(r'^[a-f0-9]{64}$').hasMatch(fp), isTrue);
    });
  });

  group('Hardware Advisor Evaluation Scenarios (A to N)', () {
    test('Scenario A: Minimalist machine (4 GB RAM, 2 cores, no GPU, 8 GB disk)', () {
      final profile = _createTestProfile(
        ramTotalGb: 4,
        ramAvailGb: 2,
        logicalProcs: 2,
        gpus: [],
        vulkanBackend: false,
        vulkanLoader: false,
        diskFreeGb: 8,
      );

      final caps = HardwareAdvisorService.instance.evaluateCapabilities(
        profile,
        lmStudioOnline: false,
        ttsRuntimeAvailable: true,
      );

      expect(caps[EngineCategory.liteRt]?.status, CapabilityStatus.limited);
      expect(caps[EngineCategory.liteRt]?.decisionBasis, DecisionBasis.heuristic);

      expect(caps[EngineCategory.asr]?.status, CapabilityStatus.limited);
      expect(caps[EngineCategory.imageGen]?.status, CapabilityStatus.notRecommended);
      expect(caps[EngineCategory.portableStorage]?.status, CapabilityStatus.limited);
    });

    test('Scenario B: Standard office machine (8 GB RAM, 4 cores, iGPU 512 MB, 25 GB disk)', () {
      final profile = _createTestProfile(
        ramTotalGb: 8,
        ramAvailGb: 4,
        logicalProcs: 4,
        gpus: [
          const GpuAdapterInfo(
            name: 'Intel UHD Graphics 630',
            vendorId: 0x8086,
            deviceId: 0x3E92,
            dedicatedVideoMemoryBytes: 512 * 1024 * 1024,
            sharedSystemMemoryBytes: 4 * 1024 * 1024 * 1024,
            adapterType: GpuAdapterType.integrated,
          ),
        ],
        vulkanBackend: true,
        vulkanLoader: true,
        diskFreeGb: 25,
      );

      final caps = HardwareAdvisorService.instance.evaluateCapabilities(
        profile,
        lmStudioOnline: false,
        ttsRuntimeAvailable: true,
      );

      expect(caps[EngineCategory.liteRt]?.status, CapabilityStatus.probablyCompatible);
      expect(caps[EngineCategory.asr]?.status, CapabilityStatus.probablyCompatible);
      expect(caps[EngineCategory.imageGen]?.status, CapabilityStatus.limited);
      expect(caps[EngineCategory.portableStorage]?.status, CapabilityStatus.compatible);
    });

    test('Scenario C: Recommended AI light station (16 GB RAM, 8 cores, dGPU 6 GB, Vulkan, 50 GB disk)', () {
      final profile = _createTestProfile(
        ramTotalGb: 16,
        ramAvailGb: 10,
        logicalProcs: 8,
        gpus: [
          const GpuAdapterInfo(
            name: 'NVIDIA GeForce RTX 3060 Laptop',
            vendorId: 0x10DE,
            deviceId: 0x2520,
            dedicatedVideoMemoryBytes: 6 * 1024 * 1024 * 1024,
            sharedSystemMemoryBytes: 8 * 1024 * 1024 * 1024,
            adapterType: GpuAdapterType.discrete,
          ),
        ],
        vulkanBackend: true,
        vulkanLoader: true,
        diskFreeGb: 50,
      );

      final caps = HardwareAdvisorService.instance.evaluateCapabilities(
        profile,
        lmStudioOnline: true,
        ttsRuntimeAvailable: true,
      );

      expect(caps[EngineCategory.liteRt]?.status, CapabilityStatus.compatible);
      expect(caps[EngineCategory.asr]?.status, CapabilityStatus.compatible);
      expect(caps[EngineCategory.imageGen]?.status, CapabilityStatus.probablyCompatible);
      expect(caps[EngineCategory.lmStudio]?.status, CapabilityStatus.compatible);
      expect(caps[EngineCategory.portableStorage]?.status, CapabilityStatus.compatible);
    });

    test('Scenario D: Workstation (32 GB RAM, 16 cores, dGPU 12 GB, Vulkan, 100 GB disk)', () {
      final profile = _createTestProfile(
        ramTotalGb: 32,
        ramAvailGb: 24,
        logicalProcs: 16,
        gpus: [
          const GpuAdapterInfo(
            name: 'NVIDIA GeForce RTX 4070',
            vendorId: 0x10DE,
            deviceId: 0x2786,
            dedicatedVideoMemoryBytes: 12 * 1024 * 1024 * 1024,
            sharedSystemMemoryBytes: 16 * 1024 * 1024 * 1024,
            adapterType: GpuAdapterType.discrete,
          ),
        ],
        vulkanBackend: true,
        vulkanLoader: true,
        diskFreeGb: 100,
      );

      final caps = HardwareAdvisorService.instance.evaluateCapabilities(
        profile,
        lmStudioOnline: true,
        ttsRuntimeAvailable: true,
      );

      expect(caps[EngineCategory.liteRt]?.status, CapabilityStatus.compatible);
      expect(caps[EngineCategory.asr]?.status, CapabilityStatus.compatible);
      expect(caps[EngineCategory.imageGen]?.status, CapabilityStatus.compatible);
      expect(caps[EngineCategory.tts]?.status, CapabilityStatus.compatible);
      expect(caps[EngineCategory.lmStudio]?.status, CapabilityStatus.compatible);
      expect(caps[EngineCategory.portableStorage]?.status, CapabilityStatus.compatible);
    });

    test('Scenario E: Unknown / timeout fallback profile', () {
      final profile = HardwareProfile.unknown(
        details: 'Délai d\'analyse dépassé ou erreur de sonde matérielle',
      );

      final caps = HardwareAdvisorService.instance.evaluateCapabilities(
        profile,
        lmStudioOnline: false,
        ttsRuntimeAvailable: false,
      );

      expect(caps[EngineCategory.liteRt]?.status, CapabilityStatus.unknown);
      expect(caps[EngineCategory.asr]?.status, CapabilityStatus.unknown);
      expect(caps[EngineCategory.imageGen]?.status, anyOf(CapabilityStatus.unknown, CapabilityStatus.notRecommended));
    });

    test('Scenario F: Low disk space (< 5 GB)', () {
      final profile = _createTestProfile(
        diskFreeGb: 3,
      );

      final caps = HardwareAdvisorService.instance.evaluateCapabilities(
        profile,
        lmStudioOnline: false,
        ttsRuntimeAvailable: true,
      );

      expect(caps[EngineCategory.portableStorage]?.status, CapabilityStatus.notRecommended);
      expect(caps[EngineCategory.portableStorage]?.humanMessage, contains('critique'));
    });

    test('Scenario G: Vulkan backend missing in app folder', () {
      final profile = _createTestProfile(
        vulkanBackend: false,
        vulkanLoader: true,
      );

      final caps = HardwareAdvisorService.instance.evaluateCapabilities(
        profile,
        lmStudioOnline: false,
        ttsRuntimeAvailable: true,
      );

      final imgCap = caps[EngineCategory.imageGen]!;
      expect(imgCap.status, CapabilityStatus.notRecommended);
      expect(imgCap.reasonCodes, contains('NO_VULKAN_BACKEND_CPU_FALLBACK'));
    });

    test('Scenario H: Vulkan loader missing in Windows', () {
      final profile = _createTestProfile(
        vulkanBackend: true,
        vulkanLoader: false,
      );

      final caps = HardwareAdvisorService.instance.evaluateCapabilities(
        profile,
        lmStudioOnline: false,
        ttsRuntimeAvailable: true,
      );

      final imgCap = caps[EngineCategory.imageGen]!;
      expect(imgCap.status, CapabilityStatus.notRecommended);
      expect(imgCap.reasonCodes, contains('NO_VULKAN_LOADER_CPU_FALLBACK'));
    });

    test('Scenario I: TTS runtime absent', () {
      final profile = _createTestProfile(
        ramTotalGb: 16,
        ramAvailGb: 10,
      );

      final caps = HardwareAdvisorService.instance.evaluateCapabilities(
        profile,
        lmStudioOnline: false,
        ttsRuntimeAvailable: false,
      );

      final ttsCap = caps[EngineCategory.tts]!;
      expect(ttsCap.reasonCodes, contains('TTS_RUNTIME_UNAVAILABLE'));
      expect(ttsCap.decisionBasis, DecisionBasis.verifiedRuntime);
    });

    test('Scenario J: LM Studio offline but machine capable', () {
      final profile = _createTestProfile(
        ramTotalGb: 16,
        ramAvailGb: 10,
      );

      final caps = HardwareAdvisorService.instance.evaluateCapabilities(
        profile,
        lmStudioOnline: false,
        ttsRuntimeAvailable: true,
      );

      final lmCap = caps[EngineCategory.lmStudio]!;
      expect(lmCap.reasonCodes, contains('LMSTUDIO_OFFLINE'));
      expect(lmCap.status, CapabilityStatus.compatible);
    });

    test('Scenario K: iGPU/UMA with large shared VRAM does not get dGPU high confidence', () {
      final profile = _createTestProfile(
        ramTotalGb: 16,
        ramAvailGb: 8,
        gpus: [
          const GpuAdapterInfo(
            name: 'AMD Radeon(TM) Graphics',
            vendorId: 0x1002,
            deviceId: 0x1638,
            dedicatedVideoMemoryBytes: 8 * 1024 * 1024 * 1024, // UMA reported 8 GB
            sharedSystemMemoryBytes: 8 * 1024 * 1024 * 1024,
            adapterType: GpuAdapterType.integrated,
          ),
        ],
        vulkanBackend: true,
        vulkanLoader: true,
      );

      final caps = HardwareAdvisorService.instance.evaluateCapabilities(
        profile,
        lmStudioOnline: false,
        ttsRuntimeAvailable: true,
      );

      final imgCap = caps[EngineCategory.imageGen]!;
      expect(imgCap.confidence, isNot(CapabilityConfidence.high));
      expect(imgCap.reasonCodes, contains('GPU_TYPE_UNCONFIRMED'));
    });

    test('Scenario L: Vulkan loader present but device support UNKNOWN -> heuristic basis', () {
      final profile = _createTestProfile(
        ramTotalGb: 16,
        ramAvailGb: 8,
        gpus: [
          const GpuAdapterInfo(
            name: 'Basic Display Adapter',
            vendorId: 0x1414,
            deviceId: 0x008D,
            dedicatedVideoMemoryBytes: 4 * 1024 * 1024 * 1024,
            sharedSystemMemoryBytes: 4 * 1024 * 1024 * 1024,
            adapterType: GpuAdapterType.unknown,
          ),
        ],
        vulkanBackend: true,
        vulkanLoader: true,
        vulkanDevice: null,
        vulkanDeviceReliability: MetricReliability.unknown,
      );

      final caps = HardwareAdvisorService.instance.evaluateCapabilities(
        profile,
        lmStudioOnline: false,
        ttsRuntimeAvailable: true,
      );

      final imgCap = caps[EngineCategory.imageGen]!;
      expect(imgCap.decisionBasis, DecisionBasis.heuristic);
      expect(imgCap.confidence, isNot(CapabilityConfidence.high));
    });

    test('Scenario M: 16 GB RAM total but only 1 GB available -> Memory pressure detected', () {
      final profile = _createTestProfile(
        ramTotalGb: 16,
        ramAvailGb: 1, // Only 1 GB free!
      );

      final caps = HardwareAdvisorService.instance.evaluateCapabilities(
        profile,
        lmStudioOnline: true,
        ttsRuntimeAvailable: true,
      );

      final lmCap = caps[EngineCategory.lmStudio]!;
      expect(lmCap.status, CapabilityStatus.limited);
      expect(lmCap.reasonCodes, contains('MEMORY_PRESSURE_HIGH'));
    });

    test('Scenario N: High RAM with TTS runtime absent separates hardware and runtime', () {
      final profile = _createTestProfile(
        ramTotalGb: 64,
        ramAvailGb: 40,
      );

      final caps = HardwareAdvisorService.instance.evaluateCapabilities(
        profile,
        lmStudioOnline: false,
        ttsRuntimeAvailable: false,
      );

      final ttsCap = caps[EngineCategory.tts]!;
      expect(ttsCap.reasonCodes, contains('TTS_RUNTIME_UNAVAILABLE'));
      expect(ttsCap.status, CapabilityStatus.limited);
      expect(ttsCap.decisionBasis, DecisionBasis.verifiedRuntime);
    });

    // ── SECTION 3 TEST : PRODUCTION PATH TTS RUNTIME PRESERVES UNKNOWN ──────
    test('Section 3 Production Path: evaluateHostCapabilities preserves UNKNOWN runtime state and does NOT promote it to true', () async {
      final profile = _createTestProfile(ramTotalGb: 16);
      
      // Appel du wrapper de production réel
      final caps = await HardwareAdvisorService.instance.evaluateHostCapabilities(profile);
      final ttsCap = caps[EngineCategory.tts]!;

      // Le wrapper réel ne doit JAMAIS supposer true : si le runtime n'a pas été instancié et validé,
      // l'état reste indéterminé (UNKNOWN)
      expect(ttsCap.reasonCodes, contains('TTS_RUNTIME_STATE_UNKNOWN'));
      expect(ttsCap.decisionBasis, DecisionBasis.unknown);
      expect(ttsCap.confidence, CapabilityConfidence.low);
      expect(ttsCap.humanMessage, contains('État du runtime : indéterminé'));
      expect(ttsCap.humanMessage, contains('Capacité matérielle : adéquate'));
    });
  });

  group('EXT-V1-01 Micro-Hardening : Hardware Change Detection & Privacy (D, E, H)', () {
    test('H: Confidentiality & Stability of technical fingerprint', () {
      final p1 = _createTestProfile(
        ramTotalGb: 16,
        ramAvailGb: 12, // 12 Go libre
        diskFreeGb: 100, // 100 Go libre
      );

      final p2 = _createTestProfile(
        ramTotalGb: 16,
        ramAvailGb: 2, // Plus que 2 Go libre
        diskFreeGb: 10, // Plus que 10 Go libre
      );

      // 1. Stabilité face aux variations volatiles (RAM dispo, disque libre)
      expect(p1.technicalFingerprint, equals(p2.technicalFingerprint),
          reason: 'L\'empreinte technique ne doit pas varier pour de simples fluctuations de RAM dispo ou disque');

      // 2. Format : SHA-256 hexadécimal pur (64 caractères, minuscules hex)
      expect(p1.technicalFingerprint, matches(r'^[a-f0-9]{64}$'));

      // 3. Absence absolue de données identifiantes ou sensibles
      final rawFingerprint = p1.technicalFingerprint;
      expect(rawFingerprint, isNot(contains('User')));
      expect(rawFingerprint, isNot(contains('DESKTOP-')));
      expect(rawFingerprint, isNot(contains('WIN-')));
    });

    test('D: Empreinte identique -> aucun changement significatif', () {
      final profile = _createTestProfile(ramTotalGb: 16, logicalProcs: 8);
      final fp = profile.technicalFingerprint;

      final changed = HardwareAdvisorService.instance.hasSignificantHardwareChange(
        currentProfile: profile,
        savedFingerprint: fp,
      );

      expect(changed, isFalse,
          reason: 'Une empreinte identique ne doit générer aucune alerte de changement de configuration');
    });

    test('E: Empreinte significativement différente -> changement détecté', () {
      final originalProfile = _createTestProfile(
        ramTotalGb: 16,
        logicalProcs: 8,
        gpus: [
          const GpuAdapterInfo(
            name: 'NVIDIA RTX 3060',
            vendorId: 0x10DE,
            deviceId: 0x2520,
            dedicatedVideoMemoryBytes: 6 * 1024 * 1024 * 1024,
            sharedSystemMemoryBytes: 8 * 1024 * 1024 * 1024,
          ),
        ],
      );
      final savedFp = originalProfile.technicalFingerprint;

      // Machine différente : CPU 4 coeurs, 8 Go RAM, sans GPU dédié
      final newMachineProfile = _createTestProfile(
        ramTotalGb: 8,
        logicalProcs: 4,
        gpus: [],
      );

      final changed = HardwareAdvisorService.instance.hasSignificantHardwareChange(
        currentProfile: newMachineProfile,
        savedFingerprint: savedFp,
      );

      expect(changed, isTrue,
          reason: 'Un changement significatif de configuration matérielle doit être détecté');
    });

    test('D/E Boundary: Sonde en échec/unknown ne déclenche pas faussement de changement', () {
      final validProfile = _createTestProfile(ramTotalGb: 16);
      final savedFp = validProfile.technicalFingerprint;

      final fallbackProfile = HardwareProfile.unknown(details: 'Timeout');

      final changed = HardwareAdvisorService.instance.hasSignificantHardwareChange(
        currentProfile: fallbackProfile,
        savedFingerprint: savedFp,
      );

      expect(changed, isFalse,
          reason: 'Un timeout ou échec de sonde ne doit pas prétendre faussement à un changement de machine');
    });

    test('D/E Boundary: Aucun fingerprint sauvegardé (utilisateur a cliqué Continuer sans analyser) -> false', () {
      final validProfile = _createTestProfile(ramTotalGb: 16);

      expect(
        HardwareAdvisorService.instance.hasSignificantHardwareChange(
          currentProfile: validProfile,
          savedFingerprint: null,
        ),
        isFalse,
        reason: 'Aucune empreinte enregistrée ne doit jamais déclencher de faux HardwareChangedDialog',
      );

      expect(
        HardwareAdvisorService.instance.hasSignificantHardwareChange(
          currentProfile: validProfile,
          savedFingerprint: '',
        ),
        isFalse,
        reason: 'Une empreinte vide ne doit jamais déclencher de faux HardwareChangedDialog',
      );
    });
  });

  group('A4: REQ-GAP-EXT01-STATE-SEPARATION-001 Requirement Tests', () {
    test('A4-1: Hardware compatible + Model absent -> Engine is NOT fully ready', () {
      final profile = _createTestProfile(ramTotalGb: 16);

      final caps = HardwareAdvisorService.instance.evaluateCapabilities(
        profile,
        lmStudioOnline: false,
        ttsRuntimeAvailable: true,
        liteRtRuntimeAvailable: RuntimeAvailability.available,
        liteRtModelInstalled: ModelInstallationState.notInstalled, // Modèle absent !
      );

      final liteRtEval = caps[EngineCategory.liteRt]!;
      expect(liteRtEval.status, CapabilityStatus.compatible,
          reason: 'Le matériel reste compatible');
      expect(liteRtEval.hardwareCapability, CapabilityStatus.compatible);
      expect(liteRtEval.runtimeAvailable, RuntimeAvailability.available);
      expect(liteRtEval.modelInstalled, ModelInstallationState.notInstalled);
      expect(liteRtEval.isFullyReady, isFalse,
          reason: 'Un moteur avec modèle non installé ne doit PAS être considéré comme fully ready');
    });

    test('A4-2: model_installed UNKNOWN is preserved without optimistic fallback', () {
      final profile = _createTestProfile(ramTotalGb: 16);

      final caps = HardwareAdvisorService.instance.evaluateCapabilities(
        profile,
        lmStudioOnline: false,
        ttsRuntimeAvailable: true,
        liteRtModelInstalled: ModelInstallationState.unknown,
      );

      final liteRtEval = caps[EngineCategory.liteRt]!;
      expect(liteRtEval.modelInstalled, ModelInstallationState.unknown,
          reason: 'L\'état UNKNOWN ne doit jamais basculer silencieusement vers INSTALLED');
      expect(liteRtEval.isFullyReady, isFalse);
    });

    test('A4-3: runtime UNKNOWN is preserved without being promoted to AVAILABLE', () {
      final profile = _createTestProfile(ramTotalGb: 16);

      final caps = HardwareAdvisorService.instance.evaluateCapabilities(
        profile,
        lmStudioOnline: false,
        ttsRuntimeAvailable: null, // UNKNOWN
        liteRtRuntimeAvailable: RuntimeAvailability.unknown,
      );

      final liteRtEval = caps[EngineCategory.liteRt]!;
      expect(liteRtEval.runtimeAvailable, RuntimeAvailability.unknown,
          reason: 'Runtime UNKNOWN ne doit pas devenir AVAILABLE');
      expect(liteRtEval.isFullyReady, isFalse);

      final ttsEval = caps[EngineCategory.tts]!;
      expect(ttsEval.runtimeAvailable, RuntimeAvailability.unknown);
      expect(ttsEval.isFullyReady, isFalse);
    });

    test('A4-4: LM Studio offline -> serviceState UNREACHABLE, hardwareCapability evaluated independently', () {
      final profile = _createTestProfile(ramTotalGb: 32, ramAvailGb: 20);

      final caps = HardwareAdvisorService.instance.evaluateCapabilities(
        profile,
        lmStudioOnline: false,
      );

      final lmEval = caps[EngineCategory.lmStudio]!;
      expect(lmEval.serviceState, ServiceReachability.unreachable);
      expect(lmEval.hardwareCapability, CapabilityStatus.compatible,
          reason: 'L\'évaluation matérielle est indépendante de la joignabilité du service');
      expect(lmEval.isFullyReady, isFalse,
          reason: 'LM Studio éteint ne peut pas être fully ready');
    });

    test('A4-5: LM Studio online -> serviceState REACHABLE, modelSpecificCompatibility UNKNOWN by default, isFullyReady is FALSE', () {
      final profile = _createTestProfile(ramTotalGb: 32, ramAvailGb: 20);

      final caps = HardwareAdvisorService.instance.evaluateCapabilities(
        profile,
        lmStudioOnline: true,
      );

      final lmEval = caps[EngineCategory.lmStudio]!;
      expect(lmEval.serviceState, ServiceReachability.reachable);
      expect(lmEval.hardwareCapability, CapabilityStatus.compatible);
      expect(lmEval.modelSpecificCompatibility, ModelSpecificCompatibility.unknown,
          reason: 'Sans probe du modèle actif, la compatibilité modèle spécifique reste UNKNOWN');
      expect(lmEval.isFullyReady, isFalse,
          reason: 'Modèle spécifique inconnu => isFullyReady reste false selon la règle d\'honnêteté');
    });

    test('A4-6: TTS production path -> runtimeState UNKNOWN is preserved in evaluateHostCapabilities', () async {
      final profile = _createTestProfile(ramTotalGb: 16);

      final caps = await HardwareAdvisorService.instance.evaluateHostCapabilities(profile);
      final ttsEval = caps[EngineCategory.tts]!;

      expect(ttsEval.runtimeAvailable, RuntimeAvailability.unknown);
      expect(ttsEval.status, CapabilityStatus.probablyCompatible);
      expect(ttsEval.isFullyReady, isFalse);
    });

    test('A4-7: Windows + ASR runtime absent -> probeAsrRuntime does NOT produce available', () {
      final tempDir = Directory.systemTemp.createTempSync('asr_probe_test_');
      AppPaths.setTestOverride(tempDir);
      try {
        final result = HardwareAdvisorService.instance.probeAsrRuntime();
        expect(result, isNot(RuntimeAvailability.available),
            reason: 'Le simple fait d\'être sur Windows ne doit jamais déduire arbitrairement available');
        expect(result, equals(RuntimeAvailability.unavailable));
      } finally {
        AppPaths.resetTestOverride();
        try {
          tempDir.deleteSync(recursive: true);
        } catch (_) {}
      }
    });

    test('A4-8: espeak-ng-data alone -> probeTtsModelInstalled does NOT produce installed', () {
      final tempDir = Directory.systemTemp.createTempSync('tts_probe_test_');
      AppPaths.setTestOverride(tempDir);
      try {
        final espeakDir = Directory('${tempDir.path}/data/espeak-ng-data');
        espeakDir.createSync(recursive: true);
        File('${espeakDir.path}/phontab').writeAsStringSync('dummy');

        final result = HardwareAdvisorService.instance.probeTtsModelInstalled();
        expect(result, isNot(ModelInstallationState.installed),
            reason: 'Les données espeak seules ne prouvent pas la présence d\'un modèle TTS complet');
        expect(result, equals(ModelInstallationState.unknown));
      } finally {
        AppPaths.resetTestOverride();
        try {
          tempDir.deleteSync(recursive: true);
        } catch (_) {}
      }
    });
  });
}
