import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'log_service.dart';

final imageOcrServiceProvider = Provider<ImageOcrService>((ref) {
  return ImageOcrService();
});

/// High-performance local OCR service for images.
class ImageOcrService {
  /// Extracts text from an image file using native OS OCR engines.
  Future<String> extractText(String filePath, {Uint8List? bytes}) async {
    final fileName = p.basename(filePath);
    final ext = p.extension(filePath).toLowerCase();

    if (!['.png', '.jpg', '.jpeg', '.webp', '.bmp', '.gif'].contains(ext)) {
      return '';
    }

    try {
      if (Platform.isWindows) {
        return await _extractWindowsOcr(filePath, bytes: bytes);
      }
    } catch (e, st) {
      Log.instance.w('ocr', 'Erreur lors de l\'extraction OCR sur $fileName: $e', error: e, stack: st);
    }

    return '';
  }

  /// Uses Windows 10/11 native WinRT OCR engine (Windows.Media.Ocr).
  /// Fast (50-150ms), 100% offline, zero extra dependencies.
  /// Uses Base64 transport for both input path and output text to eliminate
  /// any path escaping issues (apostrophes, accents, special symbols) and codepage mismatches.
  Future<String> _extractWindowsOcr(String filePath, {Uint8List? bytes}) async {
    String targetPath = filePath;
    File? tempFile;

    if (!File(filePath).existsSync() && bytes != null && bytes.isNotEmpty) {
      final tempDir = Directory.systemTemp.createTempSync('cw_ocr_');
      tempFile = File(p.join(tempDir.path, p.basename(filePath)));
      tempFile.writeAsBytesSync(bytes);
      targetPath = tempFile.path;
    }

    // Base64 encode path to avoid any PowerShell parsing errors on special characters (', ’, spaces, etc.)
    final b64Path = base64Encode(utf8.encode(targetPath));

    final psScript = '''
try {
    Add-Type -AssemblyName System.Runtime.WindowsRuntime
    \$asTaskGeneric = ([System.WindowsRuntimeSystemExtensions].GetMethods() | ? { \$_.Name -eq 'AsTask' -and \$_.GetParameters().Count -eq 1 -and \$_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' })[0]
    function Await(\$WinRtTask, \$ResultType) {
        \$asTask = \$asTaskGeneric.MakeGenericMethod(\$ResultType)
        \$netTask = \$asTask.Invoke(\$null, @(\$WinRtTask))
        \$netTask.Wait(8000) | Out-Null
        return \$netTask.Result
    }

    [Windows.Storage.StorageFile,Windows.Storage,ContentType=WindowsRuntime] | Out-Null
    [Windows.Graphics.Imaging.BitmapDecoder,Windows.Graphics.Imaging,ContentType=WindowsRuntime] | Out-Null
    [Windows.Media.Ocr.OcrEngine,Windows.Media.Ocr,ContentType=WindowsRuntime] | Out-Null

    \$rawBytes = [Convert]::FromBase64String('$b64Path')
    \$realPath = [System.Text.Encoding]::UTF8.GetString(\$rawBytes)

    \$file = Await ([Windows.Storage.StorageFile]::GetFileFromPathAsync(\$realPath)) ([Windows.Storage.StorageFile])
    if (\$file -eq \$null) { exit 1 }

    \$stream = Await (\$file.OpenAsync([Windows.Storage.FileAccessMode]::Read)) ([Windows.Storage.Streams.IRandomAccessStream])
    \$decoder = Await ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync(\$stream)) ([Windows.Graphics.Imaging.BitmapDecoder])
    \$softwareBitmap = Await (\$decoder.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])

    \$engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages()
    if (\$engine -eq \$null) {
        \$engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromLanguage([Windows.Globalization.Language]::new("fr-FR"))
    }
    if (\$engine -eq \$null) {
        \$engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromLanguage([Windows.Globalization.Language]::new("en-US"))
    }
    if (\$engine -eq \$null) {
        \$engine = [Windows.Media.Ocr.OcrEngine]::AllAvailableLanguages | Select-Object -First 1 | ForEach-Object { [Windows.Media.Ocr.OcrEngine]::TryCreateFromLanguage(\$_) }
    }
    if (\$engine -eq \$null) { exit 2 }

    \$ocrResult = Await (\$engine.RecognizeAsync(\$softwareBitmap)) ([Windows.Media.Ocr.OcrResult])
    if (\$ocrResult -ne \$null) {
        \$lines = [System.Collections.Generic.List[string]]::new()
        foreach (\$line in \$ocrResult.Lines) {
            \$lines.Add(\$line.Text)
        }
        \$fullText = \$lines -join "`n"
        \$resBytes = [System.Text.Encoding]::UTF8.GetBytes(\$fullText)
        [Console]::WriteLine([Convert]::ToBase64String(\$resBytes))
    }
} catch {
    exit 3
}
''';

    try {
      final result = await Process.run(
        'powershell',
        ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-Command', psScript],
      ).timeout(const Duration(seconds: 12));

      if (tempFile != null && tempFile.existsSync()) {
        try {
          tempFile.parent.deleteSync(recursive: true);
        } catch (_) {}
      }

      if (result.exitCode == 0 && result.stdout is String) {
        final b64Output = (result.stdout as String).trim();
        if (b64Output.isNotEmpty) {
          final decodedBytes = base64Decode(b64Output.replaceAll(RegExp(r'\s+'), ''));
          final extractedText = utf8.decode(decodedBytes, allowMalformed: true).trim();
          if (extractedText.isNotEmpty) {
            Log.instance.i('ocr', 'OCR Windows réussi sur "${p.basename(filePath)}" (${extractedText.length} caractères extraits)');
            return extractedText;
          }
        }
      }
    } catch (e) {
      Log.instance.w('ocr', 'Timeout ou échec OCR PowerShell sur $filePath: $e');
    }

    return '';
  }
}
