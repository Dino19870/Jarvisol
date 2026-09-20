// lib/constants/timeout_policy.dart
// Centralised, observable-driven timeout and budget definitions for Jarvisol.
// Designed to accommodate slow CPUs, cold-starts, and external drives without false timeouts.

import 'dart:core';

class TimeoutPolicy {
  TimeoutPolicy._();

  // ───────────────────────────────────────────────────────────────────────────
  // Service Startup & Lifecycles
  // ───────────────────────────────────────────────────────────────────────────

  /// Maximum ceiling for LiteRT-LM cold start while process is alive.
  /// 240 attempts x 500 ms = 120 seconds.
  /// Immediately fast-fails if the process exits before readiness.
  static const Duration litertStartupMaxDuration = Duration(seconds: 120);
  static const Duration litertStartupPollInterval = Duration(milliseconds: 500);
  static const int litertStartupMaxAttempts = 240;

  /// Readiness timeout for memory_server.exe startup.
  /// 40 attempts x 500 ms = 20 seconds.
  /// Immediately fast-fails if the process exits before readiness.
  static const Duration memoryServerStartupTimeout = Duration(seconds: 20);
  static const Duration memoryServerPollInterval = Duration(milliseconds: 500);
  static const int memoryServerStartupMaxAttempts = 40;
  static const Duration memoryServerProbeTimeout = Duration(milliseconds: 1000);

  // ───────────────────────────────────────────────────────────────────────────
  // RAG & Embeddings
  // ───────────────────────────────────────────────────────────────────────────

  /// Single text embedding timeout (e.g. user question).
  /// Generous enough (8s) to allow local embedders (LM Studio) to wake up GPU/model
  /// while still bounded so the chat prompt isn't stalled indefinitely.
  static const Duration ragEmbeddingSingle = Duration(seconds: 8);

  /// Batch text embedding timeout (document indexing chunks).
  static const Duration ragEmbeddingBatch = Duration(seconds: 60);

  // ───────────────────────────────────────────────────────────────────────────
  // Memory Recall
  // ───────────────────────────────────────────────────────────────────────────

  /// Non-blocking memory recall for chat prompt enhancement.
  /// 1500 ms accommodates slower mechanical drives / high I/O without hanging the chat.
  static const Duration memoryRecall = Duration(milliseconds: 1500);

  // ───────────────────────────────────────────────────────────────────────────
  // Transcript Summarization
  // ───────────────────────────────────────────────────────────────────────────

  /// Ceiling for whole transcript summarization via cloud / local LLM.
  /// 5 minutes allows slow or quantized models to summarize long transcripts without premature timeouts.
  static const Duration transcriptSummarization = Duration(minutes: 5);

  // ───────────────────────────────────────────────────────────────────────────
  // Image Generation
  // ───────────────────────────────────────────────────────────────────────────

  /// Global user budget for a single image generation action (including translation & fallback).
  /// Aligned with local server 2-hour runaway guardrail plus 10 minutes total headroom.
  static const Duration imageGenGlobalBudget = Duration(hours: 2, minutes: 10);

  /// Individual attempt ceiling for local SD WebUI / sd_server.
  /// Fully aligned with server maximum active budget (7200s / 2h runaway guardrail) + 5 min margin.
  /// Prevents premature Dart HTTP socket termination while a slow CPU inference is still ACTIVE.
  static const Duration imageGenLocalAttempt = Duration(hours: 2, minutes: 5);

  /// Fallback attempt ceiling for cloud / OpenAI endpoint.
  static const Duration imageGenCloudAttempt = Duration(minutes: 5);

  /// LLM connection probe timeout to quickly detect an unreachable server.
  static const Duration llmConnectTimeout = Duration(seconds: 5);

  /// LLM visual prompt translation timeout (auxiliary response ceiling).
  /// 5 minutes allows slow local models (e.g. Qwen 35B on CPU) to complete translation.
  static const Duration imagePromptTranslation = Duration(minutes: 5);

  // ───────────────────────────────────────────────────────────────────────────
  // External MCP Tools & Processes
  // ───────────────────────────────────────────────────────────────────────────

  /// Ceiling for external script / CLI execution.
  /// Process tree MUST be forcefully terminated on expiration.
  static const Duration mcpProcessTimeout = Duration(seconds: 30);

  /// Cleanup grace period when terminating hung processes.
  static const Duration processKillGracePeriod = Duration(milliseconds: 1500);

  // ───────────────────────────────────────────────────────────────────────────
  // Web Media Downloads & Processing
  // ───────────────────────────────────────────────────────────────────────────

  /// Inactivity watchdog duration for Web Media downloads (yt-dlp + ffmpeg).
  /// Reset whenever active output is received on stdout or stderr.
  /// Detects real network stalls or frozen processes within 90 seconds.
  static const Duration webMediaDownloadInactivityTimeout = Duration(seconds: 90);

  /// Absolute safety ceiling for Web Media downloads (yt-dlp + ffmpeg).
  /// Hard runaway guardrail that is NEVER reset by ongoing activity.
  static const Duration webMediaDownloadAbsoluteMaxDuration = Duration(hours: 2);

  // ───────────────────────────────────────────────────────────────────────────
  // ASR & Hardware Probes (TO-SRV-POOL-01, TO-SRV-HW-01, TO-SRV-HW-02)
  // ───────────────────────────────────────────────────────────────────────────

  /// ASR worker isolate initialization ceiling.
  static const Duration asrWorkerInitTimeout =
      Duration(seconds: 90);

  /// Hardware probe inspection ceiling.
  static const Duration hardwareProbeTimeout =
      Duration(seconds: 10);

  /// Local LM Studio reachability check probe.
  static const Duration lmStudioProbeTimeout =
      Duration(milliseconds: 1500);
}
