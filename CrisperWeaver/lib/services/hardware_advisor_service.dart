// lib/services/hardware_advisor_service.dart
//
// Service de diagnostic matériel et d'évaluation des capacités IA (EXT-V1-01)
// Respecte strictement les règles de durcissement :
// - Indépendance complète vis-à-vis d'EXT-V1-02 (aucun catalogue image)
// - Vulkan : concepts séparés backend/loader/device
// - GPU : adapterType UNKNOWN si non prouvé, VRAM dédiée vs partagée
// - Décisions HEURISTIC systématiques
// - LM Studio : prise en compte de la pression mémoire (RAM dispo < 2 Go)
// - TTS : séparation stricte de hardware_capability et runtime_state
// - Stockage : seuils indicatifs
// - Aucun hook de test en production

import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../constants/timeout_policy.dart';
import '../models/hardware_profile.dart';
import '../utils/app_paths.dart';
import '../widgets/hardware_diagnostic_dialog.dart';
import 'log_service.dart';
import 'windows_hardware_probe.dart';

/// Service singleton orchestrant le Hardware Capability Advisor
class HardwareAdvisorService {
  static final HardwareAdvisorService instance = HardwareAdvisorService._();
  HardwareAdvisorService._();

  HardwareProfile? _lastProfile;
  HardwareProfile? get lastProfile => _lastProfile;

  File get _stateFile =>
      File(p.join(AppPaths.appDir.path, 'data', 'config', 'hardware_advisor_state.json'));

  /// Effectue une inspection matérielle non bloquante de la machine hôte
  Future<HardwareProfile> inspectHost({
    HardwareProbe? probe,
    Duration? timeout,
  }) async {
    final activeProbe = probe ?? const WindowsHardwareProbe();
    final effectiveTimeout = timeout ?? TimeoutPolicy.hardwareProbeTimeout;
    try {
      final profile = await activeProbe.probe().timeout(
        effectiveTimeout,
        onTimeout: () {
          Log.instance.w('hw-advisor', 'Timeout inspection matérielle (> ${effectiveTimeout.inSeconds}s), repli inconnu');
          return HardwareProfile.unknown(
            details: 'Délai d\'analyse dépassé (> ${effectiveTimeout.inSeconds}s)',
          );
        },
      );
      _lastProfile = profile;
      return profile;
    } catch (e) {
      Log.instance.w('hw-advisor', 'Échec sonde matérielle: $e');
      final fallback = HardwareProfile.unknown(
        details: 'Erreur lors de la sonde: $e',
      );
      _lastProfile = fallback;
      return fallback;
    }
  }

  /// Évalue les capacités de l'hôte pour chaque catégorie de moteur (fonction pure)
  Map<EngineCategory, CapabilityEvaluation> evaluateCapabilities(
    HardwareProfile profile, {
    required bool lmStudioOnline,
    bool? ttsRuntimeAvailable,
    RuntimeAvailability? liteRtRuntimeAvailable,
    ModelInstallationState? liteRtModelInstalled,
    RuntimeAvailability? asrRuntimeAvailable,
    ModelInstallationState? asrModelInstalled,
    ModelInstallationState? ttsModelInstalled,
    RuntimeAvailability? imageRuntimeAvailable,
    ModelInstallationState? imageModelInstalled,
    RuntimeAvailability? inpaintRuntimeAvailable,
    ModelInstallationState? inpaintModelInstalled,
    ServiceReachability? lmStudioServiceState,
    ModelSpecificCompatibility? lmStudioModelSpecificCompatibility,
  }) {
    final results = <EngineCategory, CapabilityEvaluation>{};

    final ramTotal = profile.ramTotalBytes.value ?? 0;
    final ramGb = ramTotal / (1024 * 1024 * 1024);
    final ramAvail = profile.ramAvailableBytes.value ?? 0;
    final ramAvailGb = ramAvail / (1024 * 1024 * 1024);

    final gpu = profile.primaryGpu;
    final vramReportedBytes = gpu?.dedicatedVideoMemoryBytes ?? 0;
    final vramReportedGb = vramReportedBytes / (1024 * 1024 * 1024);

    final diskFree = profile.portableDiskFreeBytes.value ?? 0;
    final diskFreeGb = diskFree / (1024 * 1024 * 1024);
    final volume = profile.portableDiskVolume.value ?? '';

    final vulkan = profile.vulkanInfo;

    // ── 1. LiteRT (On-device LLM) ─────────────────────────────────────────────
    // RÈGLE 8 : Ne pas promettre de certitude sur un modèle précis.
    final liteRtRuntime = liteRtRuntimeAvailable ?? RuntimeAvailability.unknown;
    final liteRtModel = liteRtModelInstalled ?? ModelInstallationState.unknown;

    if (ramTotal == 0) {
      results[EngineCategory.liteRt] = CapabilityEvaluation(
        category: EngineCategory.liteRt,
        status: CapabilityStatus.unknown,
        confidence: CapabilityConfidence.unknown,
        decisionBasis: DecisionBasis.unknown,
        reasonCodes: const ['RAM_UNKNOWN'],
        humanMessage: 'Quantité de mémoire vive non déterminée. Test recommandé avec les modèles compacts.',
        runtimeAvailable: liteRtRuntime,
        modelInstalled: liteRtModel,
      );
    } else if (ramGb >= 16.0) {
      results[EngineCategory.liteRt] = CapabilityEvaluation(
        category: EngineCategory.liteRt,
        status: CapabilityStatus.compatible,
        confidence: CapabilityConfidence.medium,
        decisionBasis: DecisionBasis.heuristic,
        reasonCodes: const ['RAM_GENEROUS', 'HEURISTIC_EVAL'],
        humanMessage: 'Cette configuration paraît adaptée aux modèles LiteRT légers et intermédiaires. Les modèles plus volumineux peuvent dépasser les ressources disponibles.',
        runtimeAvailable: liteRtRuntime,
        modelInstalled: liteRtModel,
      );
    } else if (ramGb >= 8.0) {
      results[EngineCategory.liteRt] = CapabilityEvaluation(
        category: EngineCategory.liteRt,
        status: CapabilityStatus.probablyCompatible,
        confidence: CapabilityConfidence.medium,
        decisionBasis: DecisionBasis.heuristic,
        reasonCodes: const ['RAM_ADEQUATE', 'HEURISTIC_EVAL'],
        humanMessage: 'Cette configuration paraît adaptée aux modèles LiteRT légers (ex: 2B-3B). Les modèles plus lourds risquent de saturer la mémoire.',
        runtimeAvailable: liteRtRuntime,
        modelInstalled: liteRtModel,
      );
    } else {
      results[EngineCategory.liteRt] = CapabilityEvaluation(
        category: EngineCategory.liteRt,
        status: CapabilityStatus.limited,
        confidence: CapabilityConfidence.medium,
        decisionBasis: DecisionBasis.heuristic,
        reasonCodes: const ['RAM_TIGHT', 'HEURISTIC_EVAL'],
        humanMessage: 'Mémoire vive modeste (< 8 Go). Utilisez exclusivement les modèles LiteRT ultra-compacts.',
        runtimeAvailable: liteRtRuntime,
        modelInstalled: liteRtModel,
      );
    }

    // ── 2. LM Studio (Modèles avancés via API locale) ─────────────────────────
    // RÈGLES 9 & 16 (Test M) : Évaluer RAM totale ET RAM disponible.
    // Séparation explicite : serviceState vs hardwareCapability vs modelSpecificCompatibility.
    final memoryPressure = ramTotal > 0 && ramAvail > 0 && ramAvailGb < 2.0;
    final resolvedLmServiceState = lmStudioServiceState ??
        (lmStudioOnline ? ServiceReachability.reachable : ServiceReachability.unreachable);
    final resolvedLmModelCompatibility = lmStudioModelSpecificCompatibility ??
        ModelSpecificCompatibility.unknown;

    final lmCodes = <String>[
      resolvedLmServiceState == ServiceReachability.reachable ? 'LMSTUDIO_ONLINE' : 'LMSTUDIO_OFFLINE',
      'UNKNOWN_MODEL_SPECIFIC',
      'HEURISTIC_EVAL',
    ];
    if (memoryPressure) {
      lmCodes.add('MEMORY_PRESSURE_HIGH');
    }

    final isLmOnline = resolvedLmServiceState == ServiceReachability.reachable;

    if (ramGb >= 16.0) {
      if (memoryPressure) {
        results[EngineCategory.lmStudio] = CapabilityEvaluation(
          category: EngineCategory.lmStudio,
          status: CapabilityStatus.limited,
          confidence: CapabilityConfidence.medium,
          decisionBasis: DecisionBasis.heuristic,
          reasonCodes: lmCodes,
          humanMessage: 'Mémoire totale importante, mais mémoire disponible très faible (${ramAvailGb.toStringAsFixed(1)} Go disponibles). Risque élevé de saturation si un modèle est chargé.',
          serviceState: resolvedLmServiceState,
          modelSpecificCompatibility: resolvedLmModelCompatibility,
          runtimeAvailable: RuntimeAvailability.notApplicable,
          modelInstalled: ModelInstallationState.notApplicable,
        );
      } else {
        results[EngineCategory.lmStudio] = CapabilityEvaluation(
          category: EngineCategory.lmStudio,
          status: CapabilityStatus.compatible,
          confidence: CapabilityConfidence.medium,
          decisionBasis: DecisionBasis.heuristic,
          reasonCodes: lmCodes,
          humanMessage: isLmOnline
              ? 'LM Studio est connecté. La compatibilité exacte dépend du modèle chargé dans LM Studio.'
              : 'Machine bien dimensionnée pour LM Studio (16+ Go RAM). Démarrez LM Studio si vous souhaitez l\'utiliser.',
          serviceState: resolvedLmServiceState,
          modelSpecificCompatibility: resolvedLmModelCompatibility,
          runtimeAvailable: RuntimeAvailability.notApplicable,
          modelInstalled: ModelInstallationState.notApplicable,
        );
      }
    } else if (ramGb >= 8.0) {
      results[EngineCategory.lmStudio] = CapabilityEvaluation(
        category: EngineCategory.lmStudio,
        status: CapabilityStatus.probablyCompatible,
        confidence: CapabilityConfidence.medium,
        decisionBasis: DecisionBasis.heuristic,
        reasonCodes: lmCodes,
        humanMessage: isLmOnline
            ? 'LM Studio est connecté. Privilégiez des quantifications légères adaptées à la mémoire disponible.'
            : 'Machine adaptée aux modèles intermédiaires légers. Démarrez LM Studio si vous souhaitez l\'utiliser.',
        serviceState: resolvedLmServiceState,
        modelSpecificCompatibility: resolvedLmModelCompatibility,
        runtimeAvailable: RuntimeAvailability.notApplicable,
        modelInstalled: ModelInstallationState.notApplicable,
      );
    } else {
      results[EngineCategory.lmStudio] = CapabilityEvaluation(
        category: EngineCategory.lmStudio,
        status: CapabilityStatus.limited,
        confidence: CapabilityConfidence.medium,
        decisionBasis: DecisionBasis.heuristic,
        reasonCodes: lmCodes,
        humanMessage: isLmOnline
            ? 'LM Studio est connecté, mais la mémoire système est restreinte. Privilégiez des petits modèles.'
            : 'Ressources système restreintes pour des modèles externes lourds.',
        serviceState: resolvedLmServiceState,
        modelSpecificCompatibility: resolvedLmModelCompatibility,
        runtimeAvailable: RuntimeAvailability.notApplicable,
        modelInstalled: ModelInstallationState.notApplicable,
      );
    }

    // ── 3. ASR (CrispASR) ─────────────────────────────────────────────────────
    final asrRuntime = asrRuntimeAvailable ?? RuntimeAvailability.unknown;
    final asrModel = asrModelInstalled ?? ModelInstallationState.unknown;

    if (ramTotal == 0) {
      results[EngineCategory.asr] = CapabilityEvaluation(
        category: EngineCategory.asr,
        status: CapabilityStatus.unknown,
        confidence: CapabilityConfidence.unknown,
        decisionBasis: DecisionBasis.unknown,
        reasonCodes: const ['RAM_UNKNOWN'],
        humanMessage: 'Mémoire non déterminée. Test recommandé avec le modèle Whisper compact.',
        runtimeAvailable: asrRuntime,
        modelInstalled: asrModel,
      );
    } else if (ramGb >= 16.0 && (profile.logicalProcessors.value ?? 0) >= 8) {
      results[EngineCategory.asr] = CapabilityEvaluation(
        category: EngineCategory.asr,
        status: CapabilityStatus.compatible,
        confidence: CapabilityConfidence.medium,
        decisionBasis: DecisionBasis.heuristic,
        reasonCodes: const ['ASR_HARDWARE_ADEQUATE', 'HEURISTIC_EVAL'],
        humanMessage: 'Le matériel paraît bien adapté à la transcription multithread locale.',
        runtimeAvailable: asrRuntime,
        modelInstalled: asrModel,
      );
    } else if (ramGb >= 8.0) {
      results[EngineCategory.asr] = CapabilityEvaluation(
        category: EngineCategory.asr,
        status: CapabilityStatus.probablyCompatible,
        confidence: CapabilityConfidence.medium,
        decisionBasis: DecisionBasis.heuristic,
        reasonCodes: const ['ASR_HARDWARE_STANDARD', 'HEURISTIC_EVAL'],
        humanMessage: 'Le matériel paraît adapté aux modèles de transcription standard.',
        runtimeAvailable: asrRuntime,
        modelInstalled: asrModel,
      );
    } else {
      results[EngineCategory.asr] = CapabilityEvaluation(
        category: EngineCategory.asr,
        status: CapabilityStatus.limited,
        confidence: CapabilityConfidence.medium,
        decisionBasis: DecisionBasis.heuristic,
        reasonCodes: const ['ASR_HARDWARE_LIMITED', 'HEURISTIC_EVAL'],
        humanMessage: 'Mémoire modeste. Exécution sérielle recommandée avec des modèles légers.',
        runtimeAvailable: asrRuntime,
        modelInstalled: asrModel,
      );
    }

    // ── 4. TTS (CrispTTS) — SECTION 3 HARDENING ──────────────────────────────
    // Séparer rigoureusement hardware_capability et runtime_state.
    // Ne JAMAIS supposer true si le runtime est UNKNOWN (null).
    final ttsRuntime = ttsRuntimeAvailable == true
        ? RuntimeAvailability.available
        : (ttsRuntimeAvailable == false ? RuntimeAvailability.unavailable : RuntimeAvailability.unknown);
    final ttsModel = ttsModelInstalled ?? ModelInstallationState.unknown;

    if (ttsRuntimeAvailable == false) {
      results[EngineCategory.tts] = CapabilityEvaluation(
        category: EngineCategory.tts,
        status: CapabilityStatus.limited,
        confidence: CapabilityConfidence.low,
        decisionBasis: DecisionBasis.verifiedRuntime,
        reasonCodes: const ['TTS_RUNTIME_UNAVAILABLE'],
        humanMessage: 'Capacité matérielle : adéquate. État du runtime : indisponible sur cet hôte (runtime non détecté).',
        runtimeAvailable: ttsRuntime,
        modelInstalled: ttsModel,
      );
    } else if (ttsRuntimeAvailable == null) {
      // ÉTAT DU RUNTIME INDÉTERMINÉ (UNKNOWN)
      final hwAdequate = ramTotal > 0 && ramGb >= 4.0;
      results[EngineCategory.tts] = CapabilityEvaluation(
        category: EngineCategory.tts,
        status: hwAdequate ? CapabilityStatus.probablyCompatible : CapabilityStatus.limited,
        confidence: CapabilityConfidence.low,
        decisionBasis: DecisionBasis.unknown,
        reasonCodes: const ['TTS_RUNTIME_STATE_UNKNOWN', 'HEURISTIC_EVAL'],
        humanMessage: hwAdequate
            ? 'Capacité matérielle : adéquate (${ramGb.toStringAsFixed(1)} Go RAM). État du runtime : indéterminé sur cet hôte (test pratique requis).'
            : 'Capacité matérielle : restreinte. État du runtime : indéterminé.',
        runtimeAvailable: ttsRuntime,
        modelInstalled: ttsModel,
      );
    } else if (ramTotal > 0 && ramGb >= 4.0) {
      results[EngineCategory.tts] = CapabilityEvaluation(
        category: EngineCategory.tts,
        status: CapabilityStatus.compatible,
        confidence: CapabilityConfidence.medium,
        decisionBasis: DecisionBasis.heuristic,
        reasonCodes: const ['TTS_HARDWARE_ADEQUATE', 'TTS_RUNTIME_CONFIRMED', 'HEURISTIC_EVAL'],
        humanMessage: 'Capacité matérielle : adéquate. État du runtime : disponible pour la synthèse vocale locale légère.',
        runtimeAvailable: ttsRuntime,
        modelInstalled: ttsModel,
      );
    } else {
      results[EngineCategory.tts] = CapabilityEvaluation(
        category: EngineCategory.tts,
        status: CapabilityStatus.limited,
        confidence: CapabilityConfidence.low,
        decisionBasis: DecisionBasis.heuristic,
        reasonCodes: const ['TTS_LOW_RAM', 'HEURISTIC_EVAL'],
        humanMessage: 'Ressources système restreintes pour la synthèse vocale.',
        runtimeAvailable: ttsRuntime,
        modelInstalled: ttsModel,
      );
    }

    // ── 5. Génération d'Images (SD Vulkan) ────────────────────────────────────
    final hasLoader = vulkan.loaderPresent;
    final isDiscreteGpu = gpu?.adapterType == GpuAdapterType.discrete;
    final imgRuntime = imageRuntimeAvailable ??
        (hasLoader && vulkan.backendPresent ? RuntimeAvailability.available : RuntimeAvailability.unavailable);
    final imgModel = imageModelInstalled ?? ModelInstallationState.unknown;

    if (!hasLoader) {
      results[EngineCategory.imageGen] = CapabilityEvaluation(
        category: EngineCategory.imageGen,
        status: CapabilityStatus.notRecommended,
        confidence: CapabilityConfidence.medium,
        decisionBasis: DecisionBasis.heuristic,
        reasonCodes: const ['NO_VULKAN_LOADER_CPU_FALLBACK'],
        humanMessage: 'Chargeur Vulkan non détecté dans Windows. Fonctionnement CPU éventuellement possible mais très lent.',
        runtimeAvailable: imgRuntime,
        modelInstalled: imgModel,
      );
    } else if (!vulkan.backendPresent) {
      results[EngineCategory.imageGen] = CapabilityEvaluation(
        category: EngineCategory.imageGen,
        status: CapabilityStatus.notRecommended,
        confidence: CapabilityConfidence.medium,
        decisionBasis: DecisionBasis.heuristic,
        reasonCodes: const ['NO_VULKAN_BACKEND_CPU_FALLBACK'],
        humanMessage: 'Bibliothèque ggml-vulkan.dll absente de l\'installation Jarvisol. Accélération Vulkan impossible.',
        runtimeAvailable: imgRuntime,
        modelInstalled: imgModel,
      );
    } else if (gpu == null || vramReportedBytes == 0) {
      results[EngineCategory.imageGen] = CapabilityEvaluation(
        category: EngineCategory.imageGen,
        status: CapabilityStatus.unknown,
        confidence: CapabilityConfidence.unknown,
        decisionBasis: DecisionBasis.unknown,
        reasonCodes: const ['VRAM_UNKNOWN'],
        humanMessage: 'Mémoire vidéo dédiée non déterminée. Prédiction de génération d\'image impossible sans test pratique.',
        runtimeAvailable: imgRuntime,
        modelInstalled: imgModel,
      );
    } else if (vramReportedGb >= 8.0) {
      if (isDiscreteGpu) {
        results[EngineCategory.imageGen] = CapabilityEvaluation(
          category: EngineCategory.imageGen,
          status: CapabilityStatus.compatible,
          confidence: CapabilityConfidence.medium,
          decisionBasis: DecisionBasis.heuristic,
          reasonCodes: const ['VRAM_GENEROUS_REPORTED', 'DGPU_REPORTED', 'HEURISTIC_EVAL'],
          humanMessage: 'GPU dédié avec ${vramReportedGb.toStringAsFixed(1)} Go de VRAM rapportée. Configuration potentiellement favorable aux modèles Image récents.',
          runtimeAvailable: imgRuntime,
          modelInstalled: imgModel,
        );
      } else {
        results[EngineCategory.imageGen] = CapabilityEvaluation(
          category: EngineCategory.imageGen,
          status: CapabilityStatus.probablyCompatible,
          confidence: CapabilityConfidence.medium,
          decisionBasis: DecisionBasis.heuristic,
          reasonCodes: const ['VRAM_GENEROUS_REPORTED', 'GPU_TYPE_UNCONFIRMED', 'HEURISTIC_EVAL'],
          humanMessage: 'Adaptateur avec ${vramReportedGb.toStringAsFixed(1)} Go de mémoire vidéo rapportée par Windows (architecture partagée ou non confirmée). Essai recommandé avec des résolutions modérées.',
          runtimeAvailable: imgRuntime,
          modelInstalled: imgModel,
        );
      }
    } else if (vramReportedGb >= 4.0) {
      results[EngineCategory.imageGen] = CapabilityEvaluation(
        category: EngineCategory.imageGen,
        status: CapabilityStatus.probablyCompatible,
        confidence: CapabilityConfidence.medium,
        decisionBasis: DecisionBasis.heuristic,
        reasonCodes: const ['VRAM_MODERATE_REPORTED', 'HEURISTIC_EVAL'],
        humanMessage: 'Mémoire vidéo rapportée de ${vramReportedGb.toStringAsFixed(1)} Go. Adapté aux modèles compacts (SD 1.5, SD-Turbo) avec gestion prudente de la résolution.',
        runtimeAvailable: imgRuntime,
        modelInstalled: imgModel,
      );
    } else {
      results[EngineCategory.imageGen] = CapabilityEvaluation(
        category: EngineCategory.imageGen,
        status: CapabilityStatus.limited,
        confidence: CapabilityConfidence.medium,
        decisionBasis: DecisionBasis.heuristic,
        reasonCodes: const ['VRAM_LOW_REPORTED', 'HEURISTIC_EVAL'],
        humanMessage: 'Mémoire vidéo rapportée restreinte (${vramReportedGb.toStringAsFixed(1)} Go). Privilégiez les quantifications très compactes.',
        runtimeAvailable: imgRuntime,
        modelInstalled: imgModel,
      );
    }

    // ── 6. Inpainting ─────────────────────────────────────────────────────────
    final inpaintRuntime = inpaintRuntimeAvailable ??
        (hasLoader && vulkan.backendPresent ? RuntimeAvailability.available : RuntimeAvailability.unavailable);
    final inpaintModel = inpaintModelInstalled ?? ModelInstallationState.unknown;

    if (!hasLoader) {
      results[EngineCategory.imageInpaint] = CapabilityEvaluation(
        category: EngineCategory.imageInpaint,
        status: CapabilityStatus.notRecommended,
        confidence: CapabilityConfidence.medium,
        decisionBasis: DecisionBasis.heuristic,
        reasonCodes: const ['NO_VULKAN_LOADER'],
        humanMessage: 'Retouche locale lente sans accélération matérielle Vulkan.',
        runtimeAvailable: inpaintRuntime,
        modelInstalled: inpaintModel,
      );
    } else if (!vulkan.backendPresent) {
      results[EngineCategory.imageInpaint] = CapabilityEvaluation(
        category: EngineCategory.imageInpaint,
        status: CapabilityStatus.notRecommended,
        confidence: CapabilityConfidence.medium,
        decisionBasis: DecisionBasis.heuristic,
        reasonCodes: const ['NO_VULKAN_BACKEND'],
        humanMessage: 'Bibliothèque ggml-vulkan.dll absente. Inpainting matériel indisponible.',
        runtimeAvailable: inpaintRuntime,
        modelInstalled: inpaintModel,
      );
    } else if (gpu == null || vramReportedBytes == 0) {
      results[EngineCategory.imageInpaint] = CapabilityEvaluation(
        category: EngineCategory.imageInpaint,
        status: CapabilityStatus.unknown,
        confidence: CapabilityConfidence.unknown,
        decisionBasis: DecisionBasis.unknown,
        reasonCodes: const ['VRAM_UNKNOWN'],
        humanMessage: 'Ressources graphiques indéterminées.',
        runtimeAvailable: inpaintRuntime,
        modelInstalled: inpaintModel,
      );
    } else if (vramReportedGb >= 4.0) {
      results[EngineCategory.imageInpaint] = CapabilityEvaluation(
        category: EngineCategory.imageInpaint,
        status: CapabilityStatus.compatible,
        confidence: isDiscreteGpu ? CapabilityConfidence.medium : CapabilityConfidence.low,
        decisionBasis: DecisionBasis.heuristic,
        reasonCodes: const ['INPAINT_VRAM_REPORTED_ADEQUATE', 'HEURISTIC_EVAL'],
        humanMessage: 'Mémoire vidéo rapportée (${vramReportedGb.toStringAsFixed(1)} Go) potentiellement suffisante pour la retouche locale.',
        runtimeAvailable: inpaintRuntime,
        modelInstalled: inpaintModel,
      );
    } else {
      results[EngineCategory.imageInpaint] = CapabilityEvaluation(
        category: EngineCategory.imageInpaint,
        status: CapabilityStatus.limited,
        confidence: CapabilityConfidence.low,
        decisionBasis: DecisionBasis.heuristic,
        reasonCodes: const ['INPAINT_VRAM_REPORTED_LOW', 'HEURISTIC_EVAL'],
        humanMessage: 'Mémoire vidéo rapportée restreinte. Privilégiez des masques de retouche ciblés.',
        runtimeAvailable: inpaintRuntime,
        modelInstalled: inpaintModel,
      );
    }

    // ── 7. Stockage Portable Indicatif ─────────────────────────────────────────
    if (diskFree == 0) {
      results[EngineCategory.portableStorage] = const CapabilityEvaluation(
        category: EngineCategory.portableStorage,
        status: CapabilityStatus.unknown,
        confidence: CapabilityConfidence.unknown,
        decisionBasis: DecisionBasis.unknown,
        reasonCodes: ['STORAGE_SPACE_UNKNOWN'],
        humanMessage: 'Espace disque non déterminé sur le volume d\'exécution.',
        runtimeAvailable: RuntimeAvailability.notApplicable,
        modelInstalled: ModelInstallationState.notApplicable,
      );
    } else if (diskFreeGb >= 20.0) {
      results[EngineCategory.portableStorage] = CapabilityEvaluation(
        category: EngineCategory.portableStorage,
        status: CapabilityStatus.compatible,
        confidence: CapabilityConfidence.high,
        decisionBasis: DecisionBasis.heuristic,
        reasonCodes: const ['STORAGE_INDICATIVE_GENEROUS'],
        humanMessage: 'Espace disponible indicatif confortable (${diskFreeGb.toStringAsFixed(1)} Go libres sur $volume). Certains ensembles de modèles Image peuvent nécessiter plusieurs dizaines de gigaoctets.',
        runtimeAvailable: RuntimeAvailability.notApplicable,
        modelInstalled: ModelInstallationState.notApplicable,
      );
    } else if (diskFreeGb >= 10.0) {
      results[EngineCategory.portableStorage] = CapabilityEvaluation(
        category: EngineCategory.portableStorage,
        status: CapabilityStatus.compatible,
        confidence: CapabilityConfidence.high,
        decisionBasis: DecisionBasis.heuristic,
        reasonCodes: const ['STORAGE_INDICATIVE_ADEQUATE'],
        humanMessage: 'Espace indicatif suffisant (${diskFreeGb.toStringAsFixed(1)} Go libres sur $volume) pour les opérations courantes.',
        runtimeAvailable: RuntimeAvailability.notApplicable,
        modelInstalled: ModelInstallationState.notApplicable,
      );
    } else if (diskFreeGb >= 5.0) {
      results[EngineCategory.portableStorage] = CapabilityEvaluation(
        category: EngineCategory.portableStorage,
        status: CapabilityStatus.limited,
        confidence: CapabilityConfidence.high,
        decisionBasis: DecisionBasis.heuristic,
        reasonCodes: const ['STORAGE_INDICATIVE_TIGHT'],
        humanMessage: 'Espace restreint (${diskFreeGb.toStringAsFixed(1)} Go libres sur $volume). Certains ensembles de modèles Image peuvent nécessiter davantage d\'espace.',
        runtimeAvailable: RuntimeAvailability.notApplicable,
        modelInstalled: ModelInstallationState.notApplicable,
      );
    } else {
      results[EngineCategory.portableStorage] = CapabilityEvaluation(
        category: EngineCategory.portableStorage,
        status: CapabilityStatus.notRecommended,
        confidence: CapabilityConfidence.high,
        decisionBasis: DecisionBasis.heuristic,
        reasonCodes: const ['STORAGE_INDICATIVE_VERY_LOW'],
        humanMessage: 'Espace disque critique (${diskFreeGb.toStringAsFixed(1)} Go libres sur $volume). Risque de saturation.',
        runtimeAvailable: RuntimeAvailability.notApplicable,
        modelInstalled: ModelInstallationState.notApplicable,
      );
    }

    return results;
  }

  /// Sonde de la présence locale du runtime LiteRT
  RuntimeAvailability probeLiteRtRuntime() {
    try {
      final appDir = AppPaths.appDir.path;
      final candidates = [
        Directory(p.join(appDir, 'runtime', 'litert_lm')),
        Directory(p.join(Directory.current.path, 'runtime', 'litert_lm')),
        Directory(p.join(Directory.current.path, 'CrisperWeaver', 'runtime', 'litert_lm')),
      ];
      for (final dir in candidates) {
        if (dir.existsSync()) return RuntimeAvailability.available;
      }
      return RuntimeAvailability.unavailable;
    } catch (_) {
      return RuntimeAvailability.unknown;
    }
  }

  /// Sonde de la présence d'au moins un modèle LiteRT installé
  ModelInstallationState probeLiteRtModelInstalled() {
    try {
      final modelsDir = AppPaths.litertModelsDir;
      if (!modelsDir.existsSync()) return ModelInstallationState.notInstalled;
      final entries = modelsDir.listSync(recursive: true);
      for (final e in entries) {
        if (e is File) {
          final ext = p.extension(e.path).toLowerCase();
          if (['.bin', '.tflite', '.litertmodel', '.gguf'].contains(ext) || e.lengthSync() > 10 * 1024 * 1024) {
            return ModelInstallationState.installed;
          }
        }
      }
      return ModelInstallationState.notInstalled;
    } catch (_) {
      return ModelInstallationState.unknown;
    }
  }

  /// Sonde de la disponibilité du runtime ASR (CrispASR / whisper.cpp)
  /// RÈGLE : Ne JAMAIS déduire la disponibilité du runtime du seul OS Windows.
  /// Vérifie la présence physique des DLLs réelles (whisper.dll ou crispasr.dll).
  RuntimeAvailability probeAsrRuntime() {
    try {
      if (!Platform.isWindows) {
        return RuntimeAvailability.unknown;
      }
      final appDirPath = AppPaths.appDir.path;
      const candidateDlls = ['whisper.dll', 'crispasr.dll'];
      for (final dll in candidateDlls) {
        if (File(p.join(appDirPath, dll)).existsSync()) {
          return RuntimeAvailability.available;
        }
      }
      for (final dll in candidateDlls) {
        if (File(p.join(Directory.current.path, dll)).existsSync()) {
          return RuntimeAvailability.available;
        }
      }
      return RuntimeAvailability.unavailable;
    } catch (_) {
      return RuntimeAvailability.unknown;
    }
  }

  /// Sonde de l'installation de modèles ASR
  ModelInstallationState probeAsrModelInstalled() {
    try {
      final appDir = AppPaths.dataDir.path;
      final candidates = [
        Directory(p.join(appDir, 'models', 'whisper_cpp')),
        Directory(p.join(Directory.current.path, 'models', 'whisper_cpp')),
      ];
      for (final dir in candidates) {
        if (dir.existsSync()) {
          for (final f in dir.listSync()) {
            if (f is File && (f.path.endsWith('.bin') || f.path.endsWith('.gguf'))) {
              return ModelInstallationState.installed;
            }
          }
        }
      }
      return ModelInstallationState.notInstalled;
    } catch (_) {
      return ModelInstallationState.unknown;
    }
  }

  /// Sonde de la disponibilité dynamique du runtime TTS local.
  /// RÈGLE SECTION 3 :
  /// Ne JAMAIS supposer vrai l'état du runtime si la disponibilité dynamique
  /// n'est pas établie. Si le runtime n'a pas été testé dynamiquement,
  /// l'état du runtime reste indéterminé (null / UNKNOWN).
  bool? probeTtsRuntimeAvailable() {
    return null;
  }

  /// Sonde de l'installation d'un modèle TTS complet (ex: Kokoro GGUF).
  /// RÈGLE : UNKNOWN > FAUX INSTALLED.
  /// La seule présence de données eSpeak-NG (voix/dictionnaires phonétiques) ne prouve pas
  /// qu'un modèle neuronal TTS complet est installé et opérationnel.
  ModelInstallationState probeTtsModelInstalled() {
    try {
      final appDataDir = AppPaths.dataDir.path;
      final candidateDirs = [
        Directory(p.join(appDataDir, 'models', 'whisper_cpp')),
        Directory(p.join(appDataDir, 'models', 'tts')),
        Directory(p.join(appDataDir, 'models')),
        Directory(p.join(Directory.current.path, 'models', 'whisper_cpp')),
        Directory(p.join(Directory.current.path, 'models')),
      ];
      for (final dir in candidateDirs) {
        if (dir.existsSync()) {
          for (final f in dir.listSync()) {
            if (f is File) {
              final name = p.basename(f.path).toLowerCase();
              if ((name.contains('kokoro') || name.contains('tts') || name.contains('vibevoice')) &&
                  (name.endsWith('.gguf') || name.endsWith('.bin'))) {
                return ModelInstallationState.installed;
              }
            }
          }
        }
      }
      return ModelInstallationState.unknown;
    } catch (_) {
      return ModelInstallationState.unknown;
    }
  }

  /// Sonde de modèles Image installés
  ModelInstallationState probeImageModelInstalled() {
    try {
      final exeDir = p.dirname(Platform.resolvedExecutable);
      final candidateDirs = [
        p.join(exeDir, 'models', 'Stable-diffusion'),
        p.join(Directory.current.path, 'models', 'Stable-diffusion'),
        p.join(Directory.current.path, 'CrisperWeaver', 'models', 'Stable-diffusion'),
      ];
      for (final c in candidateDirs) {
        final d = Directory(c);
        if (d.existsSync()) {
          for (final e in d.listSync()) {
            if (e is File) {
              final name = p.basename(e.path).toLowerCase();
              final ext = p.extension(e.path).toLowerCase();
              if (name.contains('inpaint') || name.startsWith('ae.') || name.startsWith('clip_') || name.startsWith('t5xxl')) {
                continue;
              }
              if (['.safetensors', '.ckpt', '.gguf', '.bin', '.pt'].contains(ext)) {
                return ModelInstallationState.installed;
              }
            }
          }
        }
      }
      return ModelInstallationState.notInstalled;
    } catch (_) {
      return ModelInstallationState.unknown;
    }
  }

  /// Sonde de modèles Inpainting installés
  ModelInstallationState probeInpaintModelInstalled() {
    try {
      final exeDir = p.dirname(Platform.resolvedExecutable);
      final candidateDirs = [
        p.join(exeDir, 'models', 'Stable-diffusion'),
        p.join(Directory.current.path, 'models', 'Stable-diffusion'),
        p.join(Directory.current.path, 'CrisperWeaver', 'models', 'Stable-diffusion'),
      ];
      for (final c in candidateDirs) {
        final d = Directory(c);
        if (d.existsSync()) {
          for (final e in d.listSync()) {
            if (e is File) {
              final name = p.basename(e.path).toLowerCase();
              final ext = p.extension(e.path).toLowerCase();
              if (name.contains('inpaint') && ['.safetensors', '.ckpt', '.gguf', '.bin', '.pt'].contains(ext)) {
                return ModelInstallationState.installed;
              }
            }
          }
        }
      }
      return ModelInstallationState.notInstalled;
    } catch (_) {
      return ModelInstallationState.unknown;
    }
  }

  /// Teste la joignabilité locale de l'API LM Studio
  Future<bool> checkLmStudioReachable({
    http.Client? client,
    Duration? timeout,
    Uri? uri,
  }) async {
    final httpClient = client ?? http.Client();
    final effectiveTimeout = timeout ?? TimeoutPolicy.lmStudioProbeTimeout;
    final targetUri = uri ?? Uri.parse('http://127.0.0.1:1234/v1/models');
    try {
      final res = await httpClient.get(targetUri).timeout(effectiveTimeout);
      if (client == null) httpClient.close();
      return res.statusCode == 200;
    } catch (_) {
      if (client == null) httpClient.close();
      return false;
    }
  }

  /// Wrapper de production évaluant les capacités réelles de l'hôte
  Future<Map<EngineCategory, CapabilityEvaluation>> evaluateHostCapabilities(
    HardwareProfile profile,
  ) async {
    final lmOnline = await checkLmStudioReachable();
    final ttsRuntime = probeTtsRuntimeAvailable();
    final liteRtRuntime = probeLiteRtRuntime();
    final liteRtModel = probeLiteRtModelInstalled();
    final asrRuntime = probeAsrRuntime();
    final asrModel = probeAsrModelInstalled();
    final ttsModel = probeTtsModelInstalled();
    final imgModel = probeImageModelInstalled();
    final inpaintModel = probeInpaintModelInstalled();

    return evaluateCapabilities(
      profile,
      lmStudioOnline: lmOnline,
      ttsRuntimeAvailable: ttsRuntime,
      liteRtRuntimeAvailable: liteRtRuntime,
      liteRtModelInstalled: liteRtModel,
      asrRuntimeAvailable: asrRuntime,
      asrModelInstalled: asrModel,
      ttsModelInstalled: ttsModel,
      imageModelInstalled: imgModel,
      inpaintModelInstalled: inpaintModel,
    );
  }

  // ── Gestion de l'état dédié EXT-01 ─────────────────────────────────────────

  Future<Map<String, dynamic>> _readState() async {
    try {
      final f = _stateFile;
      if (f.existsSync()) {
        final txt = f.readAsStringSync();
        return json.decode(txt) as Map<String, dynamic>;
      }
    } catch (e) {
      Log.instance.w('hw-advisor', 'Erreur lecture état hardware_advisor_state.json: $e');
    }
    return {};
  }

  Future<void> _writeState(Map<String, dynamic> state) async {
    try {
      final f = _stateFile;
      f.parent.createSync(recursive: true);
      f.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(state));
    } catch (e) {
      Log.instance.w('hw-advisor', 'Erreur écriture état hardware_advisor_state.json: $e');
    }
  }

  Future<bool> hasSeenOnboarding() async {
    final s = await _readState();
    return s['onboarding_seen'] == true;
  }

  Future<void> markOnboardingSeen() async {
    final s = await _readState();
    s['onboarding_seen'] = true;
    await _writeState(s);
  }

  Future<void> saveProfileState(HardwareProfile profile) async {
    final s = await _readState();
    s['onboarding_seen'] = true;
    s['last_scan_timestamp'] = profile.scanTimestamp.toIso8601String();
    s['technical_fingerprint'] = profile.technicalFingerprint;
    s['last_profile'] = profile.toJson();
    await _writeState(s);
  }

  Future<String?> getSavedFingerprint() async {
    final s = await _readState();
    return s['technical_fingerprint'] as String?;
  }

  /// Détermine si un changement de configuration matérielle significatif et stable s'est produit.
  /// RÈGLE DE CONFIDENTIALITÉ ABSOLUE :
  /// Cette comparaison repose exclusivement sur l'empreinte technique anonyme
  /// (architecture CPU, tranches de coeurs logiques, tranches de RAM totale, GPU principal rapporté).
  /// Elle ne contient et ne compare aucune donnée personnelle ou identifiante
  /// (aucun username, aucun nom d'hôte, aucune adresse MAC, aucun numéro de série, aucun MachineGuid).
  /// Les variations normales de mémoire vive disponible ou d'espace disque libre
  /// n'affectent PAS cette empreinte.
  bool hasSignificantHardwareChange({
    required HardwareProfile currentProfile,
    required String? savedFingerprint,
  }) {
    if (savedFingerprint == null || savedFingerprint.isEmpty) return false;
    // Ne pas déclencher si le profil actuel est indéterminé ou issu d'un échec de sonde
    if (currentProfile.cpuArch.value == null || currentProfile.ramTotalBytes.value == null) {
      return false;
    }
    return currentProfile.technicalFingerprint != savedFingerprint;
  }

  /// Bootstrap au démarrage dans le post-frame callback (séquencé)
  Future<void> checkAndPromptOnboarding(
    BuildContext context, {
    HardwareProbe? probe,
  }) async {
    if (!Platform.isWindows) return;
    try {
      if (!context.mounted || Navigator.maybeOf(context) == null) return;
      final seen = await hasSeenOnboarding();
      if (!seen) {
        if (context.mounted && Navigator.maybeOf(context) != null) {
          await showDialog<void>(
            context: context,
            barrierDismissible: false,
            builder: (_) => const FirstRunWelcomeDialog(),
          );
        }
        return;
      }

      // ── Démarrage ultérieur : détection d'un changement significatif de configuration ──
      final savedFp = await getSavedFingerprint();
      if (savedFp != null && savedFp.isNotEmpty) {
        final profile = await inspectHost(probe: probe);
        if (hasSignificantHardwareChange(currentProfile: profile, savedFingerprint: savedFp)) {
          if (context.mounted && Navigator.maybeOf(context) != null) {
            await showDialog<void>(
              context: context,
              barrierDismissible: true,
              builder: (_) => const HardwareChangedDialog(),
            );
          }
        }
      }
    } catch (e) {
      Log.instance.w('hw-advisor', 'Erreur vérification onboarding / configuration: $e');
    }
  }
}
