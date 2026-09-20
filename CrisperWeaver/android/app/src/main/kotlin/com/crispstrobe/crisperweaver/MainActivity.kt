package com.crispstrobe.crisperweaver

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.projection.MediaProjectionManager
import android.os.Build
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.concurrent.thread

class MainActivity : FlutterActivity() {

    // §5.1.1 system-audio capture
    // ------------------------------------------------------------
    private val controlChannelName = "crisperweaver/system_audio_capture"
    private val streamChannelName =
        "crisperweaver/system_audio_capture/stream"
    private val mediaProjectionRequestCode = 7311

    // The result from the most recent start() call. We hold the
    // pending Flutter MethodChannel result so we can complete it
    // asynchronously from onActivityResult — Flutter doesn't let
    // us block in the MethodCallHandler.
    private var pendingStartResult: MethodChannel.Result? = null
    private var pendingModelResult: MethodChannel.Result? = null
    private val modelPickerRequestCode = 8492
    // EventSink for streaming PCM frames back to Dart. Bound by
    // the EventChannel's onListen callback.
    private var sink: EventChannel.EventSink? = null
    private var llmInference: com.google.mediapipe.tasks.genai.llminference.LlmInference? = null
    private var litertEngine: com.google.ai.edge.litertlm.Engine? = null
    private var litertConversation: com.google.ai.edge.litertlm.Conversation? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Universal Uncaught Exception Handler
        val defaultHandler = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, throwable ->
            try {
                val logDir = java.io.File(context.filesDir, "app_flutter/logs")
                if (!logDir.exists()) logDir.mkdirs()
                val logFile = java.io.File(logDir, "crash.log")
                val sessionLog = java.io.File(logDir, "session.log")
                val sw = java.io.StringWriter()
                val pw = java.io.PrintWriter(sw)
                throwable.printStackTrace(pw)
                val crashReport = "\n\n=== CRASH DETECTED ${java.util.Date()} [Thread: ${thread.name}] ===\n" +
                    "Exception: ${throwable.javaClass.name}: ${throwable.message}\n" +
                    sw.toString() + "\n=========================================\n"
                logFile.appendText(crashReport)
                sessionLog.appendText(crashReport)

                // 1. Write to app-specific external storage (Always accessible without permissions)
                try {
                    val extLog = java.io.File(context.getExternalFilesDir(null), "crisper_crash.log")
                    extLog.writeText(crashReport)
                } catch (_: Throwable) {}

                // 2. Write to public Downloads via MediaStore on Android 10-16
                if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.Q) {
                    try {
                        val values = android.content.ContentValues().apply {
                            put(android.provider.MediaStore.MediaColumns.DISPLAY_NAME, "crisper_crash.log")
                            put(android.provider.MediaStore.MediaColumns.MIME_TYPE, "text/plain")
                            put(android.provider.MediaStore.MediaColumns.RELATIVE_PATH, android.os.Environment.DIRECTORY_DOWNLOADS)
                        }
                        contentResolver.insert(android.provider.MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)?.let { uri ->
                            contentResolver.openOutputStream(uri)?.use { os ->
                                os.write(crashReport.toByteArray())
                            }
                        }
                    } catch (_: Throwable) {}
                }
            } catch (_: Throwable) {}
            defaultHandler?.uncaughtException(thread, throwable)
        }

        val messenger = flutterEngine.dartExecutor.binaryMessenger
        val control = MethodChannel(messenger, controlChannelName)
        val stream = EventChannel(messenger, streamChannelName)

        stream.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                sink = events
            }
            override fun onCancel(arguments: Any?) {
                sink = null
            }
        })

        control.setMethodCallHandler { call, result ->
            when (call.method) {
                "isSupported" -> {
                    // AudioPlaybackCaptureConfiguration needs API 29 (Android 10).
                    result.success(Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q)
                }
                "start" -> startSystemAudioCapture(result)
                "stop" -> {
                    stopSystemAudioCapture()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }

        // Audio decode channel — transcode opus/m4a/aac/webm to 16 kHz
        // mono PCM WAV via Android's MediaExtractor + MediaCodec.
        val audioDecode = MethodChannel(messenger, "crisperweaver/audio_decode")
        audioDecode.setMethodCallHandler { call, result ->
            when (call.method) {
                "decodeToWav" -> {
                    val filePath = call.argument<String>("path")
                    if (filePath == null) {
                        result.error("bad_args", "missing 'path'", null)
                        return@setMethodCallHandler
                    }
                    thread {
                        try {
                            val wav = decodeToMonoWav(filePath, 16000)
                            runOnUiThread { result.success(wav) }
                        } catch (e: Exception) {
                            runOnUiThread {
                                result.error("decode_failed", e.message, null)
                            }
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }

        // LiteRT-LM (On-device LLM Inference)
        val litertChannel = MethodChannel(messenger, "crisperweaver/litert_lm")
        litertChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "isSupported" -> {
                    result.success(true)
                }
                "listLocalModels" -> {
                    thread {
                        val models = mutableListOf<Map<String, Any>>()
                        val seenPaths = mutableSetOf<String>()

                        try {
                            // 1. Query MediaStore (Downloads & External files)
                            try {
                                val projection = arrayOf(
                                    android.provider.MediaStore.MediaColumns.DISPLAY_NAME,
                                    android.provider.MediaStore.MediaColumns.DATA,
                                    android.provider.MediaStore.MediaColumns.SIZE
                                )
                                val selection = "${android.provider.MediaStore.MediaColumns.DISPLAY_NAME} LIKE '%.bin' OR " +
                                    "${android.provider.MediaStore.MediaColumns.DISPLAY_NAME} LIKE '%.litertlm' OR " +
                                    "${android.provider.MediaStore.MediaColumns.DISPLAY_NAME} LIKE '%.task'"

                                val urisToQuery = mutableListOf<android.net.Uri>()
                                if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.Q) {
                                    urisToQuery.add(android.provider.MediaStore.Downloads.EXTERNAL_CONTENT_URI)
                                }
                                urisToQuery.add(android.provider.MediaStore.Files.getContentUri("external"))

                                for (contentUri in urisToQuery) {
                                    try {
                                        contentResolver.query(contentUri, projection, selection, null, null)?.use { cursor ->
                                            val nameCol = cursor.getColumnIndex(android.provider.MediaStore.MediaColumns.DISPLAY_NAME)
                                            val dataCol = cursor.getColumnIndex(android.provider.MediaStore.MediaColumns.DATA)
                                            val sizeCol = cursor.getColumnIndex(android.provider.MediaStore.MediaColumns.SIZE)
                                            while (cursor.moveToNext()) {
                                                val name = if (nameCol >= 0) cursor.getString(nameCol) else null
                                                val path = if (dataCol >= 0) cursor.getString(dataCol) else null
                                                val size = if (sizeCol >= 0) cursor.getLong(sizeCol) else 0L
                                                if (name != null && path != null) {
                                                    if (!seenPaths.contains(path)) {
                                                        seenPaths.add(path)
                                                        models.add(mapOf(
                                                            "name" to name,
                                                            "path" to path,
                                                            "sizeBytes" to size
                                                        ))
                                                    }
                                                }
                                            }
                                        }
                                    } catch (_: Throwable) {}
                                }
                            } catch (_: Throwable) {}

                            // 2. Direct File System search in standard locations (fast flat listing)
                            val searchDirs = listOf(
                                java.io.File(context.filesDir, "litert_models"),
                                java.io.File(context.filesDir, "app_flutter/litert_models"),
                                context.getExternalFilesDir(null),
                                java.io.File("/storage/emulated/0/Download/litert_models"),
                                java.io.File("/storage/emulated/0/Download"),
                                android.os.Environment.getExternalStoragePublicDirectory(android.os.Environment.DIRECTORY_DOWNLOADS),
                                java.io.File("/sdcard/Download"),
                                java.io.File("/storage/emulated/0/Documents"),
                                java.io.File("/storage/emulated/0/Android/data/com.google.ai.edge.gallery/files")
                            )
                            val validExts = setOf("bin", "litertlm", "task")
                            for (d in searchDirs) {
                                if (d != null && d.exists() && d.isDirectory) {
                                    try {
                                        d.listFiles()?.forEach { f ->
                                            if (f.isFile && f.length() > 500_000L && validExts.contains(f.extension.lowercase())) {
                                                if (!seenPaths.contains(f.absolutePath)) {
                                                    seenPaths.add(f.absolutePath)
                                                    models.add(mapOf(
                                                        "name" to f.name,
                                                        "path" to f.absolutePath,
                                                        "sizeBytes" to f.length()
                                                    ))
                                                }
                                            }
                                        }
                                    } catch (_: Throwable) {}
                                }
                            }

                            val active = java.io.File(context.filesDir, "active_llm_model.bin")
                            if (active.exists() && active.length() > 500_000L && !seenPaths.contains(active.absolutePath)) {
                                models.add(mapOf(
                                    "name" to "Modèle actif (stockage interne)",
                                    "path" to active.absolutePath,
                                    "sizeBytes" to active.length()
                                ))
                            }
                        } catch (_: Throwable) {
                        } finally {
                            runOnUiThread { result.success(models) }
                        }
                    }
                }
                "deleteLocalModel" -> {
                    val modelPath = call.argument<String>("modelPath")
                    if (modelPath == null) {
                        result.error("bad_args", "missing 'modelPath'", null)
                        return@setMethodCallHandler
                    }
                    thread {
                        try {
                            val f = java.io.File(modelPath)
                            var deleted = false
                            if (f.exists()) {
                                deleted = f.delete()
                            }
                            try {
                                android.media.MediaScannerConnection.scanFile(
                                    context,
                                    arrayOf(modelPath),
                                    null,
                                    null
                                )
                            } catch (_: Throwable) {}
                            runOnUiThread { result.success(deleted) }
                        } catch (e: Throwable) {
                            runOnUiThread { result.error("delete_failed", e.message, null) }
                        }
                    }
                }
                "pickModelNative" -> {
                    pendingModelResult = result
                    val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                        addCategory(Intent.CATEGORY_OPENABLE)
                        type = "*/*"
                    }
                    startActivityForResult(intent, modelPickerRequestCode)
                }
                "initModel" -> {
                    val modelPath = call.argument<String>("modelPath")
                    val maxTokensArg = call.argument<Int>("maxTokens") ?: 4096
                    val temperatureArg = call.argument<Double>("temperature") ?: 0.7
                    val topKArg = call.argument<Int>("topK") ?: 40
                    if (modelPath == null) {
                        result.error("bad_args", "missing 'modelPath'", null)
                        return@setMethodCallHandler
                    }
                    thread {
                        try {
                            var resolvedSource: java.io.File? = null
                            val sourceFile = java.io.File(modelPath)
                            if (sourceFile.exists() && sourceFile.length() > 0L) {
                                resolvedSource = sourceFile
                            } else {
                                // Search known fallback locations if temporary cache was purged by Android
                                val fileName = sourceFile.name
                                val candidates = listOf(
                                    java.io.File(context.filesDir, "active_llm_model.bin"),
                                    java.io.File(context.filesDir, "litert_models/$fileName"),
                                    java.io.File(context.filesDir, "app_flutter/litert_models/$fileName"),
                                    java.io.File(context.getExternalFilesDir(null), "litert_models/$fileName"),
                                    java.io.File("/storage/emulated/0/Download/$fileName"),
                                    java.io.File("/storage/emulated/0/Download/litert_models/$fileName"),
                                    java.io.File("/storage/emulated/0/Documents/$fileName"),
                                    java.io.File("/sdcard/Download/$fileName")
                                )
                                for (cand in candidates) {
                                    if (cand.exists() && cand.length() > 0L) {
                                        resolvedSource = cand
                                        break
                                    }
                                }
                            }

                            val fileToLoad = resolvedSource ?: java.io.File(context.filesDir, "active_llm_model.bin")
                            if (!fileToLoad.exists() || fileToLoad.length() == 0L) {
                                runOnUiThread { result.error("init_failed", "Le fichier du modèle n'a pas été trouvé ($modelPath). Veuillez réimporter le fichier .bin ou .litertlm depuis vos Téléchargements.", null) }
                                return@thread
                            }

                            // 1. Try official LiteRT-LM Engine (Natively supports .litertlm, .task & .bin)
                            var litertLoaded = false
                            var lastInitError: Throwable? = null

                            val originalName = "${sourceFile.name} ${fileToLoad.name} $modelPath"
                            val detectedSeq = when {
                                originalName.contains("1280", ignoreCase = true) -> 1280
                                originalName.contains("2048", ignoreCase = true) -> 2048
                                originalName.contains("4096", ignoreCase = true) -> 4096
                                originalName.contains("seq128", ignoreCase = true) -> 128
                                else -> 0
                            }
                            val seqCandidates = if (detectedSeq > 0) {
                                listOf(detectedSeq, 1280, 2048, 4096, 0).distinct()
                            } else {
                                listOf(0, 1280, 2048, 4096).distinct()
                            }

                            litertConversation = null
                            litertEngine?.close()
                            litertEngine = null

                            // 1. Try LiteRT-LM (com.google.ai.edge.litertlm)
                            val isMultimodal = fileToLoad.name.contains("gemma-4", ignoreCase = true) ||
                                              fileToLoad.name.contains("gemma-3", ignoreCase = true) ||
                                              fileToLoad.name.contains("gemma3", ignoreCase = true)
                            val isCpuPreferred = fileToLoad.name.contains("tiny_garden", ignoreCase = true) ||
                                                 fileToLoad.name.contains("mobile_actions", ignoreCase = true)

                            // Backends to attempt in order
                            val backendList = mutableListOf<Pair<String, com.google.ai.edge.litertlm.Backend>>()
                            try {
                                val gpuBackend = Class.forName("com.google.ai.edge.litertlm.Backend\$GPU").getConstructor().newInstance() as com.google.ai.edge.litertlm.Backend
                                val cpuBackend = Class.forName("com.google.ai.edge.litertlm.Backend\$CPU").getConstructor().newInstance() as com.google.ai.edge.litertlm.Backend
                                if (isCpuPreferred) {
                                    backendList.add("CPU" to cpuBackend)
                                    backendList.add("GPU" to gpuBackend)
                                } else {
                                    backendList.add("GPU" to gpuBackend)
                                    backendList.add("CPU" to cpuBackend)
                                }
                            } catch (_: Throwable) {}
                            try {
                                val npuBackend = Class.forName("com.google.ai.edge.litertlm.Backend\$NPU").getConstructor(String::class.java).newInstance(context.applicationInfo.nativeLibraryDir) as com.google.ai.edge.litertlm.Backend
                                backendList.add("NPU" to npuBackend)
                            } catch (_: Throwable) {}

                            for ((bName, backend) in backendList) {
                                if (litertLoaded) break
                                for (seqLen in seqCandidates) {
                                    if (litertLoaded) break
                                    // Try with and without multimodal vision/audio delegates
                                    val configsToTry = mutableListOf<com.google.ai.edge.litertlm.EngineConfig>()
                                    try {
                                        configsToTry.add(
                                            com.google.ai.edge.litertlm.EngineConfig(
                                                modelPath = fileToLoad.absolutePath,
                                                backend = backend,
                                                maxNumTokens = if (seqLen > 0) seqLen else 4096,
                                                cacheDir = context.cacheDir.absolutePath
                                            )
                                        )
                                    } catch (_: Throwable) {}
                                    if (isMultimodal) {
                                        try {
                                            configsToTry.add(
                                                com.google.ai.edge.litertlm.EngineConfig(
                                                    modelPath = fileToLoad.absolutePath,
                                                    backend = backend,
                                                    visionBackend = backend,
                                                    audioBackend = backend,
                                                    maxNumTokens = if (seqLen > 0) seqLen else 4096,
                                                    cacheDir = context.cacheDir.absolutePath
                                                )
                                            )
                                        } catch (_: Throwable) {}
                                    }

                                    for (engineConfig in configsToTry) {
                                        try {
                                            val eng = com.google.ai.edge.litertlm.Engine(engineConfig)
                                            eng.initialize()
                                            litertEngine = eng
                                            litertConversation = eng.createConversation(com.google.ai.edge.litertlm.ConversationConfig())
                                            litertLoaded = true
                                            runOnUiThread { result.success(true) }
                                            return@thread
                                        } catch (t: Throwable) {
                                            lastInitError = t
                                        }
                                    }
                                }
                            }

                            // 2. Fallback to MediaPipe Tasks GenAI
                            // 2A. Try GPU Backend
                            var mpLoaded = false
                            try {
                                val options = com.google.mediapipe.tasks.genai.llminference.LlmInference.LlmInferenceOptions.builder()
                                    .setModelPath(fileToLoad.absolutePath)
                                    .setMaxTokens(1024)
                                    .build()

                                llmInference?.close()
                                llmInference = com.google.mediapipe.tasks.genai.llminference.LlmInference.createFromOptions(context, options)
                                mpLoaded = true
                                runOnUiThread { result.success(true) }
                                return@thread
                            } catch (eMp: Throwable) {
                                lastInitError = eMp
                            }

                            if (!mpLoaded) {
                                val err = lastInitError ?: Exception("Impossible de charger le modèle")
                                val msg = err.message ?: err.toString()
                                runOnUiThread { result.error("init_failed", "Erreur d'initialisation LiteRT-LM : $msg", null) }
                            }
                        } catch (e: Exception) {
                            val msg = e.message ?: e.toString()
                            runOnUiThread { result.error("init_failed", msg, null) }
                        }
                    }
                }
                "generateResponse" -> {
                    val prompt = call.argument<String>("prompt")
                    if (prompt == null) {
                        result.error("bad_args", "missing 'prompt'", null)
                        return@setMethodCallHandler
                    }
                    thread {
                        try {
                            if (litertEngine != null) {
                                litertConversation = litertEngine!!.createConversation(com.google.ai.edge.litertlm.ConversationConfig())
                                val msg = litertConversation!!.sendMessage(prompt)
                                val text = msg.toString()
                                runOnUiThread { result.success(text) }
                            } else if (litertConversation != null) {
                                val msg = litertConversation!!.sendMessage(prompt)
                                val text = msg.toString()
                                runOnUiThread { result.success(text) }
                            } else if (llmInference != null) {
                                val response = llmInference!!.generateResponse(prompt)
                                runOnUiThread { result.success(response) }
                            } else {
                                runOnUiThread { result.error("not_initialized", "Modèle LiteRT non initialisé", null) }
                            }
                        } catch (t: Throwable) {
                            val sw = java.io.StringWriter()
                            t.printStackTrace(java.io.PrintWriter(sw))
                            val errMsg = "${t.javaClass.simpleName}: ${t.message ?: t.toString()}"
                            try {
                                val logDir = java.io.File(context.filesDir, "app_flutter/logs")
                                val sessionLog = java.io.File(logDir, "session.log")
                                sessionLog.appendText("\n[LiteRT-ERR] $errMsg\n$sw\n")
                            } catch (_: Throwable) {}
                            runOnUiThread { result.error("generate_failed", errMsg, sw.toString()) }
                        }
                    }
                }
                "releaseModel" -> {
                    try {
                        litertConversation = null
                        litertEngine?.close()
                        litertEngine = null
                        llmInference?.close()
                        llmInference = null
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("release_failed", e.message, null)
                    }
                }
                "deleteLocalModel" -> {
                    val modelPath = call.argument<String>("modelPath")
                    if (modelPath != null) {
                        thread {
                            try {
                                val f = java.io.File(modelPath)
                                if (f.exists()) {
                                    f.delete()
                                }
                                val active = java.io.File(context.filesDir, "active_llm_model.bin")
                                if (active.exists() && active.absolutePath == modelPath) {
                                    active.delete()
                                }
                                runOnUiThread { result.success(true) }
                            } catch (e: Exception) {
                                runOnUiThread { result.error("delete_failed", e.message, null) }
                            }
                        }
                    } else {
                        result.error("bad_args", "missing 'modelPath'", null)
                    }
                }
                "benchmarkModels" -> {
                    thread {
                        val searchDirs = listOf(
                            java.io.File("/storage/emulated/0/Download"),
                            java.io.File(context.filesDir, "litert_models"),
                            java.io.File("/sdcard/Download")
                        )
                        val validExts = setOf("bin", "litertlm", "task")
                        val modelFiles = mutableListOf<java.io.File>()
                        val seen = mutableSetOf<String>()
                        for (d in searchDirs) {
                            if (d.exists() && d.isDirectory) {
                                d.listFiles()?.forEach { f ->
                                    if (f.isFile && f.length() > 500_000L && validExts.contains(f.extension.lowercase()) && !seen.contains(f.name)) {
                                        seen.add(f.name)
                                        modelFiles.add(f)
                                    }
                                }
                            }
                        }

                        val report = StringBuilder()
                        report.append("=== RAPPORT BENCHMARK MODÈLES LITERT-LM ===\n")
                        report.append("Appareil: Samsung Galaxy S24 Ultra\n")
                        report.append("Modèles détectés (${modelFiles.size}) :\n\n")

                        for (f in modelFiles) {
                            report.append("--------------------------------------------------\n")
                            report.append("📁 Modèle: ${f.name}\n")
                            report.append("Taille: ${f.length() / (1024 * 1024)} Mo\n")

                            val tStartInit = System.currentTimeMillis()
                            var loaded = false
                            var initErr: String? = null
                            var usedBackend = "None"
                            var usedSeq = 0

                            val detectedSeq = when {
                                f.name.contains("1280", ignoreCase = true) -> 1280
                                f.name.contains("2048", ignoreCase = true) -> 2048
                                f.name.contains("4096", ignoreCase = true) -> 4096
                                f.name.contains("seq128", ignoreCase = true) -> 128
                                else -> 0
                            }
                            val seqCandidates = listOf(detectedSeq, 0, 1280, 2048, 4096).distinct()

                            litertConversation = null
                            litertEngine?.close()
                            litertEngine = null

                            val backendList = mutableListOf<Pair<String, com.google.ai.edge.litertlm.Backend>>()
                            try {
                                backendList.add("GPU" to Class.forName("com.google.ai.edge.litertlm.Backend\$GPU").getConstructor().newInstance() as com.google.ai.edge.litertlm.Backend)
                            } catch (_: Throwable) {}
                            try {
                                backendList.add("NPU" to Class.forName("com.google.ai.edge.litertlm.Backend\$NPU").getConstructor(String::class.java).newInstance(context.applicationInfo.nativeLibraryDir) as com.google.ai.edge.litertlm.Backend)
                            } catch (_: Throwable) {}
                            try {
                                backendList.add("CPU" to Class.forName("com.google.ai.edge.litertlm.Backend\$CPU").getConstructor().newInstance() as com.google.ai.edge.litertlm.Backend)
                            } catch (_: Throwable) {}

                            for ((bName, backend) in backendList) {
                                if (loaded) break
                                for (seq in seqCandidates) {
                                    try {
                                        val config = com.google.ai.edge.litertlm.EngineConfig(
                                            f.absolutePath, backend, null, null, 0, seq, context.cacheDir.absolutePath
                                        )
                                        val eng = com.google.ai.edge.litertlm.Engine(config)
                                        eng.initialize()
                                        litertEngine = eng
                                        litertConversation = eng.createConversation(com.google.ai.edge.litertlm.ConversationConfig())
                                        loaded = true
                                        usedBackend = bName
                                        usedSeq = seq
                                        break
                                    } catch (t: Throwable) {
                                        initErr = t.message ?: t.toString()
                                    }
                                }
                            }

                            if (!loaded) {
                                try {
                                    val options = com.google.mediapipe.tasks.genai.llminference.LlmInference.LlmInferenceOptions.builder()
                                        .setModelPath(f.absolutePath)
                                        .setMaxTokens(256)
                                        .build()
                                    llmInference?.close()
                                    llmInference = com.google.mediapipe.tasks.genai.llminference.LlmInference.createFromOptions(context, options)
                                    loaded = true
                                    usedBackend = "MediaPipe GPU"
                                } catch (t: Throwable) {
                                    initErr = t.message ?: t.toString()
                                }
                            }

                            val initTimeMs = System.currentTimeMillis() - tStartInit
                            if (loaded) {
                                report.append("Chargement: ✅ RÉUSSI en ${initTimeMs} ms (Backend: $usedBackend, Seq: $usedSeq)\n")

                                val tStartGen = System.currentTimeMillis()
                                var responseText = ""
                                try {
                                    val prompt = "Bonjour, dis-moi qui tu es en une phrase courte."
                                    if (litertConversation != null) {
                                        val msg = litertConversation!!.sendMessage(prompt)
                                        responseText = msg.toString()
                                    } else if (llmInference != null) {
                                        responseText = llmInference!!.generateResponse(prompt)
                                    }
                                    val genTimeMs = System.currentTimeMillis() - tStartGen
                                    report.append("Inférence: ✅ RÉUSSIE en ${genTimeMs} ms\n")
                                    report.append("Réponse:\n$responseText\n")
                                } catch (t: Throwable) {
                                    report.append("Inférence: ❌ Échec (${t.message})\n")
                                }
                            } else {
                                report.append("Chargement: ❌ ÉCHEC (${initTimeMs} ms)\n")
                                report.append("Détail de l'erreur: $initErr\n")
                            }
                            report.append("\n")

                            litertConversation = null
                            litertEngine?.close()
                            litertEngine = null
                            llmInference?.close()
                            llmInference = null
                        }

                        try {
                            val outDir = java.io.File("/storage/emulated/0/Documents/CrisperWeaver")
                            if (!outDir.exists()) outDir.mkdirs()
                            val outFile = java.io.File(outDir, "benchmark_results.txt")
                            outFile.writeText(report.toString())
                        } catch (_: Throwable) {}

                        runOnUiThread { result.success(report.toString()) }
                    }
                }
                else -> result.notImplemented()
            }
        }

        try {
            val benchmarkFilter = android.content.IntentFilter("com.crispstrobe.crisperweaver.BENCHMARK")
            val receiver = object : android.content.BroadcastReceiver() {
                override fun onReceive(pContext: android.content.Context?, pIntent: Intent?) {
                    // Trigger litertChannel benchmarkModels
                    thread {
                        val searchDirs = listOf(
                            java.io.File("/storage/emulated/0/Download/GoogleEdgeModels"),
                            java.io.File("/storage/emulated/0/Download"),
                            java.io.File(context.filesDir, "litert_models"),
                            java.io.File("/sdcard/Download")
                        )
                        val validExts = setOf("bin", "litertlm", "task")
                        val modelFiles = mutableListOf<java.io.File>()
                        val seen = mutableSetOf<String>()
                        for (d in searchDirs) {
                            if (d.exists() && d.isDirectory) {
                                try {
                                    d.walkTopDown().maxDepth(3).forEach { f ->
                                        if (f.isFile && f.length() > 500_000L && validExts.contains(f.extension.lowercase()) && !seen.contains(f.name)) {
                                            seen.add(f.name)
                                            modelFiles.add(f)
                                        }
                                    }
                                } catch (_: Throwable) {}
                            }
                        }

                        val report = StringBuilder()
                        report.append("=== RAPPORT BENCHMARK MODÈLES LITERT-LM ===\n")
                        report.append("Appareil: Samsung Galaxy S24 Ultra\n")
                        report.append("Date: ${java.util.Date()}\n")
                        report.append("Modèles détectés (${modelFiles.size}) :\n\n")

                        try {
                            val outDir = java.io.File("/storage/emulated/0/Documents/CrisperWeaver")
                            if (!outDir.exists()) outDir.mkdirs()
                            val outFile = java.io.File(outDir, "benchmark_results.txt")
                            outFile.writeText(report.toString())
                        } catch (_: Throwable) {}

                        for (f in modelFiles) {
                            report.append("--------------------------------------------------\n")
                            report.append("📁 Modèle: ${f.name}\n")
                            report.append("Taille: ${f.length() / (1024 * 1024)} Mo\n")

                            val tStartInit = System.currentTimeMillis()
                            var loaded = false
                            var initErr: String? = null
                            var usedBackend = "None"
                            var usedSeq = 0

                            val detectedSeq = when {
                                f.name.contains("1280", ignoreCase = true) -> 1280
                                f.name.contains("2048", ignoreCase = true) -> 2048
                                f.name.contains("4096", ignoreCase = true) -> 4096
                                f.name.contains("seq128", ignoreCase = true) -> 128
                                else -> 0
                            }
                            val seqCandidates = listOf(detectedSeq, 0, 1280, 2048, 4096).distinct()

                            litertConversation = null
                            litertEngine?.close()
                            litertEngine = null

                            val isMultimodal = f.name.contains("gemma-4", ignoreCase = true) ||
                                              f.name.contains("gemma-3", ignoreCase = true) ||
                                              f.name.contains("gemma3", ignoreCase = true)
                            val isCpuPreferred = f.name.contains("tiny_garden", ignoreCase = true) ||
                                                 f.name.contains("mobile_actions", ignoreCase = true)

                            val backendList = mutableListOf<Pair<String, com.google.ai.edge.litertlm.Backend>>()
                            try {
                                val gpuBackend = Class.forName("com.google.ai.edge.litertlm.Backend\$GPU").getConstructor().newInstance() as com.google.ai.edge.litertlm.Backend
                                val cpuBackend = Class.forName("com.google.ai.edge.litertlm.Backend\$CPU").getConstructor().newInstance() as com.google.ai.edge.litertlm.Backend
                                if (isCpuPreferred) {
                                    backendList.add("CPU" to cpuBackend)
                                    backendList.add("GPU" to gpuBackend)
                                } else {
                                    backendList.add("GPU" to gpuBackend)
                                    backendList.add("CPU" to cpuBackend)
                                }
                            } catch (_: Throwable) {}
                            try {
                                val npuBackend = Class.forName("com.google.ai.edge.litertlm.Backend\$NPU").getConstructor(String::class.java).newInstance(context.applicationInfo.nativeLibraryDir) as com.google.ai.edge.litertlm.Backend
                                backendList.add("NPU" to npuBackend)
                            } catch (_: Throwable) {}

                            for ((bName, backend) in backendList) {
                                if (loaded) break
                                for (seq in seqCandidates) {
                                    if (loaded) break
                                    val configsToTry = mutableListOf<com.google.ai.edge.litertlm.EngineConfig>()
                                    try {
                                        configsToTry.add(
                                            com.google.ai.edge.litertlm.EngineConfig(
                                                modelPath = f.absolutePath,
                                                backend = backend,
                                                maxNumTokens = if (seq > 0) seq else 4096,
                                                cacheDir = context.cacheDir.absolutePath
                                            )
                                        )
                                    } catch (_: Throwable) {}
                                    if (isMultimodal) {
                                        try {
                                            configsToTry.add(
                                                com.google.ai.edge.litertlm.EngineConfig(
                                                    modelPath = f.absolutePath,
                                                    backend = backend,
                                                    visionBackend = backend,
                                                    audioBackend = backend,
                                                    maxNumTokens = if (seq > 0) seq else 4096,
                                                    cacheDir = context.cacheDir.absolutePath
                                                )
                                            )
                                        } catch (_: Throwable) {}
                                    }

                                    for (config in configsToTry) {
                                        try {
                                            val eng = com.google.ai.edge.litertlm.Engine(config)
                                            eng.initialize()
                                            litertEngine = eng
                                            litertConversation = eng.createConversation(com.google.ai.edge.litertlm.ConversationConfig())
                                            loaded = true
                                            usedBackend = bName
                                            usedSeq = seq
                                            break
                                        } catch (t: Throwable) {
                                            initErr = t.message ?: t.toString()
                                        }
                                    }
                                }
                            }

                            if (!loaded) {
                                for (mpSeq in listOf(1024, 512, 256, 128)) {
                                    if (loaded) break
                                    try {
                                        val options = com.google.mediapipe.tasks.genai.llminference.LlmInference.LlmInferenceOptions.builder()
                                            .setModelPath(f.absolutePath)
                                            .setMaxTokens(mpSeq)
                                            .build()
                                        llmInference?.close()
                                        llmInference = com.google.mediapipe.tasks.genai.llminference.LlmInference.createFromOptions(context, options)
                                        loaded = true
                                        usedBackend = "MediaPipe GPU"
                                        usedSeq = mpSeq
                                        break
                                    } catch (t: Throwable) {
                                        initErr = t.message ?: t.toString()
                                    }
                                }
                            }

                            val initTimeMs = System.currentTimeMillis() - tStartInit
                            if (loaded) {
                                report.append("Chargement: ✅ RÉUSSI en ${initTimeMs} ms (Backend: $usedBackend, Seq: $usedSeq)\n")

                                val tStartGen = System.currentTimeMillis()
                                var responseText = ""
                                try {
                                    val prompt = when {
                                        f.name.contains("qwen", ignoreCase = true) || f.name.contains("deepseek", ignoreCase = true) ->
                                            "<|im_start|>user\nBonjour, dis-moi qui tu es en une phrase courte.<|im_end|>\n<|im_start|>assistant\n"
                                        f.name.contains("gemma", ignoreCase = true) ->
                                            "<start_of_turn>user\nBonjour, dis-moi qui tu es en une phrase courte.<end_of_turn>\n<start_of_turn>model\n"
                                        else ->
                                            "Bonjour, dis-moi qui tu es en une phrase courte."
                                    }
                                    if (litertConversation != null) {
                                        val msg = litertConversation!!.sendMessage(prompt)
                                        responseText = msg.toString()
                                    } else if (llmInference != null) {
                                        responseText = llmInference!!.generateResponse(prompt)
                                    }
                                    val genTimeMs = System.currentTimeMillis() - tStartGen
                                    report.append("Inférence: ✅ RÉUSSIE en ${genTimeMs} ms\n")
                                    report.append("Réponse:\n$responseText\n")
                                } catch (t: Throwable) {
                                    report.append("Inférence: ❌ Échec (${t.message})\n")
                                }
                            } else {
                                report.append("Chargement: ❌ ÉCHEC (${initTimeMs} ms)\n")
                                report.append("Détail de l'erreur: $initErr\n")
                            }
                            report.append("\n")

                            try {
                                val outDir = java.io.File("/storage/emulated/0/Documents/CrisperWeaver")
                                if (!outDir.exists()) outDir.mkdirs()
                                val outFile = java.io.File(outDir, "benchmark_results.txt")
                                outFile.writeText(report.toString())
                            } catch (_: Throwable) {}

                            litertConversation = null
                            litertEngine?.close()
                            litertEngine = null
                            llmInference?.close()
                            llmInference = null
                        }

                        try {
                            val outDir = java.io.File("/storage/emulated/0/Documents/CrisperWeaver")
                            if (!outDir.exists()) outDir.mkdirs()
                            val outFile = java.io.File(outDir, "benchmark_results.txt")
                            outFile.writeText(report.toString())
                        } catch (_: Throwable) {}
                    }
                }
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                registerReceiver(receiver, benchmarkFilter, android.content.Context.RECEIVER_EXPORTED)
            } else {
                registerReceiver(receiver, benchmarkFilter)
            }
        } catch (_: Throwable) {}

        // Native System Share Channel (WhatsApp, Mail, Telegram, etc.)
        val shareChannel = MethodChannel(messenger, "crisperweaver/share")
        shareChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "shareText" -> {
                    val text = call.argument<String>("text") ?: ""
                    val title = call.argument<String>("title") ?: "Partager les logs CrisperWeaver"
                    try {
                        val sendIntent = Intent(Intent.ACTION_SEND).apply {
                            putExtra(Intent.EXTRA_TEXT, text)
                            type = "text/plain"
                        }
                        val shareIntent = Intent.createChooser(sendIntent, title)
                        startActivity(shareIntent)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("share_failed", e.message, null)
                    }
                }
                "shareFile" -> {
                    val filePath = call.argument<String>("filePath")
                    val title = call.argument<String>("title") ?: "Partager le fichier de logs"
                    if (filePath != null) {
                        try {
                            val file = java.io.File(filePath)
                            if (file.exists()) {
                                val uri = androidx.core.content.FileProvider.getUriForFile(
                                    context,
                                    "${context.packageName}.fileprovider",
                                    file
                                )
                                val sendIntent = Intent(Intent.ACTION_SEND).apply {
                                    putExtra(Intent.EXTRA_STREAM, uri)
                                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                                    type = "text/plain"
                                }
                                val shareIntent = Intent.createChooser(sendIntent, title)
                                startActivity(shareIntent)
                                result.success(true)
                            } else {
                                result.error("not_found", "File not found: $filePath", null)
                            }
                        } catch (e: Exception) {
                            result.error("share_failed", e.message, null)
                        }
                    } else {
                        result.error("bad_args", "missing filePath", null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    /// Launches the MediaProjection permission intent and stashes
    /// the pending Flutter result. Completion happens in
    /// onActivityResult below.
    private fun startSystemAudioCapture(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            result.error(
                "os_too_old",
                "System audio capture requires Android 10 (API 29) or later",
                null
            )
            return
        }
        if (pendingStartResult != null) {
            result.error(
                "already_starting",
                "Another start() is already in flight",
                null
            )
            return
        }
        // Hook the foreground service's frame-listener so PCM
        // arrives at our event sink. Set BEFORE we ask the user
        // for permission so the service has it the moment the
        // foreground intent lands.
        // Kotlin: lambdas assigned to properties have no implicit
        // label, so `return@frameListener` won't compile. Use a
        // small lambda factory with an explicit name so we can
        // early-out cleanly.
        val listener: (FloatArray) -> Unit = inner@{ samples ->
            val sinkLocal = sink ?: return@inner
            // Float32 → bytes (little-endian) for the wire. The
            // Dart side reinterprets via Float32List.view, which
            // is zero-copy.
            val bb = ByteBuffer
                .allocate(samples.size * 4)
                .order(ByteOrder.LITTLE_ENDIAN)
            for (s in samples) bb.putFloat(s)
            val bytes = bb.array()
            runOnUiThread {
                try {
                    sinkLocal.success(bytes)
                } catch (_: Throwable) {
                    // Sink may be cancelled mid-frame; ignore.
                }
            }
        }
        SystemAudioCaptureForegroundService.frameListener = listener

        pendingStartResult = result
        val mpm = getSystemService(Context.MEDIA_PROJECTION_SERVICE)
                as MediaProjectionManager
        val permIntent = mpm.createScreenCaptureIntent()
        try {
            startActivityForResult(permIntent, mediaProjectionRequestCode)
        } catch (e: Exception) {
            pendingStartResult = null
            SystemAudioCaptureForegroundService.frameListener = null
            result.error("start_failed", e.message ?: "start failed", null)
        }
    }

    private fun stopSystemAudioCapture() {
        val svc = Intent(this, SystemAudioCaptureForegroundService::class.java)
            .apply {
                action = SystemAudioCaptureForegroundService.ACTION_STOP
            }
        try {
            stopService(svc)
        } catch (_: Exception) {}
        SystemAudioCaptureForegroundService.frameListener = null
    }

    @Deprecated("Use registerForActivityResult — kept for plugin parity")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == modelPickerRequestCode) {
            val pending = pendingModelResult
            pendingModelResult = null
            if (resultCode == Activity.RESULT_OK && data?.data != null) {
                val uri = data.data!!
                thread {
                    try {
                        var displayName = "gemma_model_${System.currentTimeMillis()}.bin"
                        contentResolver.query(uri, null, null, null, null)?.use { cursor ->
                            val nameIndex = cursor.getColumnIndex(android.provider.OpenableColumns.DISPLAY_NAME)
                            if (cursor.moveToFirst() && nameIndex >= 0) {
                                displayName = cursor.getString(nameIndex)
                            }
                        }
                        val modelsDir = java.io.File(context.filesDir, "litert_models")
                        if (!modelsDir.exists()) modelsDir.mkdirs()
                        val destFile = java.io.File(modelsDir, displayName)
                        contentResolver.openInputStream(uri)?.use { input ->
                            destFile.outputStream().use { output ->
                                input.copyTo(output)
                            }
                        }
                        runOnUiThread { pending?.success(destFile.absolutePath) }
                    } catch (e: Exception) {
                        runOnUiThread { pending?.error("pick_error", e.message, null) }
                    }
                }
            } else {
                pending?.success(null)
            }
            return
        }

        if (requestCode != mediaProjectionRequestCode) return
        val pending = pendingStartResult
        pendingStartResult = null
        if (pending == null) return
        if (resultCode != Activity.RESULT_OK || data == null) {
            SystemAudioCaptureForegroundService.frameListener = null
            pending.error(
                "permission_denied",
                "User declined screen + audio capture",
                null
            )
            return
        }
        // Hand the token to the foreground service. The service is
        // what holds the MediaProjection + AudioRecord; the activity
        // would lose them on screen rotation otherwise.
        val svc = Intent(this, SystemAudioCaptureForegroundService::class.java)
            .apply {
                action = SystemAudioCaptureForegroundService.ACTION_START
                putExtra(
                    SystemAudioCaptureForegroundService.EXTRA_RESULT_CODE,
                    resultCode
                )
                putExtra(
                    SystemAudioCaptureForegroundService.EXTRA_RESULT_DATA,
                    data
                )
            }
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                ContextCompat.startForegroundService(this, svc)
            } else {
                startService(svc)
            }
            pending.success(true)
        } catch (e: Exception) {
            SystemAudioCaptureForegroundService.frameListener = null
            pending.error(
                "start_failed",
                e.message ?: "startForegroundService failed",
                null
            )
        }
    }

    /// Decode any audio file Android can handle (opus, m4a, aac, webm,
    /// mp4, wma…) to a 16 kHz mono 16-bit PCM WAV byte array using
    /// MediaExtractor + MediaCodec. Runs on a background thread.
    private fun decodeToMonoWav(filePath: String, targetSr: Int): ByteArray {
        val extractor = MediaExtractor()
        extractor.setDataSource(filePath)

        // Find the first audio track.
        var trackIndex = -1
        var format: MediaFormat? = null
        for (i in 0 until extractor.trackCount) {
            val tf = extractor.getTrackFormat(i)
            if (tf.getString(MediaFormat.KEY_MIME)?.startsWith("audio/") == true) {
                trackIndex = i
                format = tf
                break
            }
        }
        if (trackIndex < 0 || format == null) {
            extractor.release()
            throw IllegalArgumentException("No audio track found in $filePath")
        }
        extractor.selectTrack(trackIndex)

        val srcSr = format.getInteger(MediaFormat.KEY_SAMPLE_RATE)
        val srcCh = format.getInteger(MediaFormat.KEY_CHANNEL_COUNT)

        val codec = MediaCodec.createDecoderByType(
            format.getString(MediaFormat.KEY_MIME)!!
        )
        codec.configure(format, null, null, 0)
        codec.start()

        val pcmOut = ByteArrayOutputStream()
        val info = MediaCodec.BufferInfo()
        var eos = false

        while (!eos) {
            // Feed input buffers.
            val inIdx = codec.dequeueInputBuffer(10_000)
            if (inIdx >= 0) {
                val inBuf = codec.getInputBuffer(inIdx)!!
                val read = extractor.readSampleData(inBuf, 0)
                if (read < 0) {
                    codec.queueInputBuffer(
                        inIdx, 0, 0, 0,
                        MediaCodec.BUFFER_FLAG_END_OF_STREAM
                    )
                } else {
                    codec.queueInputBuffer(
                        inIdx, 0, read,
                        extractor.sampleTime, 0
                    )
                    extractor.advance()
                }
            }

            // Drain output buffers.
            var outIdx = codec.dequeueOutputBuffer(info, 10_000)
            while (outIdx >= 0) {
                if (info.size > 0) {
                    val outBuf = codec.getOutputBuffer(outIdx)!!
                    val chunk = ByteArray(info.size)
                    outBuf.get(chunk)
                    pcmOut.write(chunk)
                }
                val endOfStream =
                    (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0
                codec.releaseOutputBuffer(outIdx, false)
                if (endOfStream) {
                    eos = true
                    break
                }
                outIdx = codec.dequeueOutputBuffer(info, 0)
            }
        }

        codec.stop()
        codec.release()
        extractor.release()

        // MediaCodec outputs 16-bit PCM. Down-mix to mono and resample
        // to targetSr if needed.
        val rawPcm = pcmOut.toByteArray()
        val srcSamples = ShortArray(rawPcm.size / 2)
        ByteBuffer.wrap(rawPcm).order(ByteOrder.LITTLE_ENDIAN).asShortBuffer()
            .get(srcSamples)

        // Down-mix to mono.
        val mono: ShortArray = if (srcCh > 1) {
            val frames = srcSamples.size / srcCh
            ShortArray(frames) { i ->
                var sum = 0L
                for (c in 0 until srcCh) sum += srcSamples[i * srcCh + c]
                (sum / srcCh).toInt().toShort()
            }
        } else {
            srcSamples
        }

        // Simple linear resample to targetSr.
        val resampled: ShortArray = if (srcSr != targetSr) {
            val ratio = srcSr.toDouble() / targetSr
            val outLen = (mono.size / ratio).toInt()
            ShortArray(outLen) { i ->
                val srcPos = i * ratio
                val idx = srcPos.toInt().coerceAtMost(mono.size - 1)
                mono[idx]
            }
        } else {
            mono
        }

        // Build a WAV in memory.
        val dataSize = resampled.size * 2
        val wav = ByteBuffer.allocate(44 + dataSize)
            .order(ByteOrder.LITTLE_ENDIAN)
        // RIFF header
        wav.put("RIFF".toByteArray())
        wav.putInt(36 + dataSize)
        wav.put("WAVE".toByteArray())
        // fmt chunk
        wav.put("fmt ".toByteArray())
        wav.putInt(16)               // chunk size
        wav.putShort(1)              // PCM
        wav.putShort(1)              // mono
        wav.putInt(targetSr)
        wav.putInt(targetSr * 2)     // byte rate
        wav.putShort(2)              // block align
        wav.putShort(16)             // bits per sample
        // data chunk
        wav.put("data".toByteArray())
        wav.putInt(dataSize)
        for (s in resampled) wav.putShort(s)

        return wav.array()
    }
}
