import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:syncfusion_flutter_pdf/pdf.dart';
import 'image_ocr_service.dart';

class DocumentSourceItem {
  final String name;
  final String path;
  final String type; // 'text', 'doc', 'sheet', 'slide', 'pdf', 'image', 'audio', 'clipboard', 'manual'
  final String textContent;
  final Uint8List? bytes;
  final int sizeBytes;
  final DateTime importedAt;

  DocumentSourceItem({
    required this.name,
    required this.path,
    required this.type,
    required this.textContent,
    this.bytes,
    required this.sizeBytes,
    required this.importedAt,
  });

  bool get isImage => type == 'image';
  bool get isAudio => type == 'audio';
}

final documentSourceServiceProvider = Provider<DocumentSourceService>((ref) {
  return DocumentSourceService();
});

class DocumentSourceService {
  /// Extracts text and metadata from a local file path.
  Future<DocumentSourceItem> parseFile(String filePath, {Uint8List? fileBytes}) async {
    final bytes = fileBytes ?? await File(filePath).readAsBytes();
    final ext = p.extension(filePath).toLowerCase();
    final name = p.basename(filePath);
    final size = bytes.length;
    final now = DateTime.now();

    // 1. Text & Code files
    if (['.txt', '.md', '.markdown', '.json', '.csv', '.log', '.xml', '.html', '.dart', '.py', '.js', '.ts', '.yaml', '.yml', '.ini', '.env'].contains(ext)) {
      String content;
      try {
        content = utf8.decode(bytes);
      } catch (_) {
        content = latin1.decode(bytes);
      }
      return DocumentSourceItem(
        name: name,
        path: filePath,
        type: 'text',
        textContent: content,
        bytes: bytes,
        sizeBytes: size,
        importedAt: now,
      );
    }

    // 2. Word (.docx)
    if (ext == '.docx') {
      final text = _extractDocx(bytes);
      return DocumentSourceItem(
        name: name,
        path: filePath,
        type: 'doc',
        textContent: text,
        bytes: bytes,
        sizeBytes: size,
        importedAt: now,
      );
    }

    // 3. PowerPoint (.pptx)
    if (ext == '.pptx') {
      final text = _extractPptx(bytes);
      return DocumentSourceItem(
        name: name,
        path: filePath,
        type: 'slide',
        textContent: text,
        bytes: bytes,
        sizeBytes: size,
        importedAt: now,
      );
    }

    // 4. Excel (.xlsx)
    if (ext == '.xlsx') {
      final text = _extractXlsx(bytes);
      return DocumentSourceItem(
        name: name,
        path: filePath,
        type: 'sheet',
        textContent: text,
        bytes: bytes,
        sizeBytes: size,
        importedAt: now,
      );
    }

    // 5. PDF (.pdf)
    if (ext == '.pdf') {
      final text = _extractPdfText(bytes);
      return DocumentSourceItem(
        name: name,
        path: filePath,
        type: 'pdf',
        textContent: text,
        bytes: bytes,
        sizeBytes: size,
        importedAt: now,
      );
    }

    // 6. E-Book (.epub)
    if (ext == '.epub') {
      final text = _extractEpub(bytes);
      return DocumentSourceItem(
        name: name,
        path: filePath,
        type: 'book',
        textContent: text,
        bytes: bytes,
        sizeBytes: size,
        importedAt: now,
      );
    }

    // 6. Images (Automated native OCR extraction)
    if (['.png', '.jpg', '.jpeg', '.webp', '.bmp', '.gif'].contains(ext)) {
      final ocrService = ImageOcrService();
      final ocrText = await ocrService.extractText(filePath, bytes: bytes);
      final formattedContent = ocrText.isNotEmpty
          ? '[Contenu textuel extrait par OCR de l\'image "$name"] :\n---\n$ocrText\n---'
          : '[Image jointe : $name (${(size / 1024).toStringAsFixed(1)} Ko) - Aucun texte lisible détecté]';

      return DocumentSourceItem(
        name: name,
        path: filePath,
        type: 'image',
        textContent: formattedContent,
        bytes: bytes,
        sizeBytes: size,
        importedAt: now,
      );
    }

    // 7. Audio
    if (['.mp3', '.wav', '.m4a', '.aac', '.ogg', '.opus', '.flac', '.webm', '.amr', '.wma'].contains(ext)) {
      return DocumentSourceItem(
        name: name,
        path: filePath,
        type: 'audio',
        textContent: '[Fichier audio : $name (${(size / (1024 * 1024)).toStringAsFixed(2)} Mo)]',
        bytes: bytes,
        sizeBytes: size,
        importedAt: now,
      );
    }

    // Fallback: try raw text decode or binary mention
    try {
      final content = utf8.decode(bytes);
      return DocumentSourceItem(
        name: name,
        path: filePath,
        type: 'text',
        textContent: content,
        bytes: bytes,
        sizeBytes: size,
        importedAt: now,
      );
    } catch (_) {
      return DocumentSourceItem(
        name: name,
        path: filePath,
        type: 'binary',
        textContent: '[Fichier binaire : $name (${(size / 1024).toStringAsFixed(1)} Ko)]',
        bytes: bytes,
        sizeBytes: size,
        importedAt: now,
      );
    }
  }

  /// Creates a source item from clipboard or direct user text input.
  DocumentSourceItem createFromText({required String title, required String text, String type = 'manual'}) {
    final bytes = utf8.encode(text);
    return DocumentSourceItem(
      name: title,
      path: '',
      type: type,
      textContent: text,
      bytes: Uint8List.fromList(bytes),
      sizeBytes: bytes.length,
      importedAt: DateTime.now(),
    );
  }

  /// Extracts text from a .docx ZIP archive.
  String _extractDocx(Uint8List bytes) {
    try {
      final archive = ZipDecoder().decodeBytes(bytes);
      final docFile = archive.findFile('word/document.xml');
      if (docFile == null) return '[Document Word sans contenu document.xml]';

      final xmlContent = utf8.decode(docFile.content as List<int>);
      return _extractXmlText(xmlContent);
    } catch (e) {
      return '[Erreur lors de la lecture du document Word .docx : $e]';
    }
  }

  /// Extracts text from a .pptx ZIP archive.
  String _extractPptx(Uint8List bytes) {
    try {
      final archive = ZipDecoder().decodeBytes(bytes);
      final buffer = StringBuffer();
      int slideIndex = 1;

      for (final file in archive.files) {
        if (file.name.startsWith('ppt/slides/slide') && file.name.endsWith('.xml')) {
          final xmlContent = utf8.decode(file.content as List<int>);
          final slideText = _extractXmlText(xmlContent);
          if (slideText.trim().isNotEmpty) {
            buffer.writeln('--- Diapositive $slideIndex ---');
            buffer.writeln(slideText);
            buffer.writeln();
            slideIndex++;
          }
        }
      }
      return buffer.isNotEmpty ? buffer.toString().trim() : '[Présentation PowerPoint sans texte extractible]';
    } catch (e) {
      return '[Erreur lors de la lecture du fichier PowerPoint .pptx : $e]';
    }
  }

  /// Extracts text from an .xlsx ZIP archive.
  String _extractXlsx(Uint8List bytes) {
    try {
      final archive = ZipDecoder().decodeBytes(bytes);
      final sharedStringsFile = archive.findFile('xl/sharedStrings.xml');
      final buffer = StringBuffer();

      if (sharedStringsFile != null) {
        final xmlContent = utf8.decode(sharedStringsFile.content as List<int>);
        final strings = _extractXmlTags(xmlContent, 't');
        if (strings.isNotEmpty) {
          buffer.writeln('--- Données et Chaînes du Tableur Excel ---');
          for (final s in strings) {
            buffer.writeln(s);
          }
        }
      }

      if (buffer.isEmpty) {
        // Fallback: scan sheet xmls
        for (final file in archive.files) {
          if (file.name.startsWith('xl/worksheets/sheet') && file.name.endsWith('.xml')) {
            final xmlContent = utf8.decode(file.content as List<int>);
            final sheetText = _extractXmlText(xmlContent);
            if (sheetText.trim().isNotEmpty) {
              buffer.writeln(sheetText);
            }
          }
        }
      }

      return buffer.isNotEmpty ? buffer.toString().trim() : '[Feuille Excel sans chaînes de texte partagées]';
    } catch (e) {
      return '[Erreur lors de la lecture du fichier Excel .xlsx : $e]';
    }
  }

  /// Accurate text extractor from PDF documents.
  String _extractPdfText(Uint8List bytes) {
    PdfDocument? document;
    try {
      document = PdfDocument(inputBytes: bytes);
      final text = PdfTextExtractor(document).extractText();
      if (text.trim().isNotEmpty) {
        return text.trim();
      }
      return '[Ce document PDF ne contient pas de texte sélectionnable (il s\'agit peut-être d\'un document scanné ou d\'une image)]';
    } catch (e) {
      return '[Erreur lors de l\'extraction du document PDF : $e]';
    } finally {
      document?.dispose();
    }
  }

  /// Extracts text and structure from an .epub ZIP archive.
  String _extractEpub(Uint8List bytes) {
    try {
      final archive = ZipDecoder().decodeBytes(bytes);
      final buffer = StringBuffer();
      String? bookTitle;
      String? bookAuthor;

      // 1. Locate root OPF file from META-INF/container.xml
      String? opfPath;
      final containerFile = archive.findFile('META-INF/container.xml');
      if (containerFile != null) {
        final containerXml = utf8.decode(containerFile.content as List<int>);
        final match = RegExp(r'full-path="([^"]+)"').firstMatch(containerXml);
        if (match != null) {
          opfPath = match.group(1);
        }
      }

      // Ordered list of chapter file paths
      final chapterPaths = <String>[];

      if (opfPath != null) {
        final opfFile = archive.findFile(opfPath);
        if (opfFile != null) {
          final opfXml = utf8.decode(opfFile.content as List<int>);
          final opfDir = p.dirname(opfPath);

          // Extract metadata
          final titleMatch = RegExp(r'<dc:title[^>]*>([^<]+)<\/dc:title>', caseSensitive: false).firstMatch(opfXml);
          if (titleMatch != null) bookTitle = titleMatch.group(1)?.trim();

          final authorMatch = RegExp(r'<dc:creator[^>]*>([^<]+)<\/dc:creator>', caseSensitive: false).firstMatch(opfXml);
          if (authorMatch != null) bookAuthor = authorMatch.group(1)?.trim();

          // Map manifest id -> href
          final manifestMap = <String, String>{};
          final itemMatches = RegExp(r'<item\s+[^>]*id="([^"]+)"[^>]*href="([^"]+)"', caseSensitive: false).allMatches(opfXml);
          for (final m in itemMatches) {
            final id = m.group(1);
            final href = m.group(2);
            if (id != null && href != null) {
              manifestMap[id] = href;
            }
          }
          // Also try inverted attributes (href before id)
          final itemMatchesInv = RegExp(r'<item\s+[^>]*href="([^"]+)"[^>]*id="([^"]+)"', caseSensitive: false).allMatches(opfXml);
          for (final m in itemMatchesInv) {
            final href = m.group(1);
            final id = m.group(2);
            if (id != null && href != null && !manifestMap.containsKey(id)) {
              manifestMap[id] = href;
            }
          }

          // Follow spine reading order
          final itemrefMatches = RegExp(r'<itemref\s+[^>]*idref="([^"]+)"', caseSensitive: false).allMatches(opfXml);
          for (final m in itemrefMatches) {
            final idref = m.group(1);
            if (idref != null && manifestMap.containsKey(idref)) {
              final rawHref = Uri.decodeFull(manifestMap[idref]!);
              final fullHref = opfDir == '.' || opfDir.isEmpty ? rawHref : '$opfDir/$rawHref';
              // Normalize path separators
              final normalized = fullHref.replaceAll('\\', '/');
              if (!chapterPaths.contains(normalized)) {
                chapterPaths.add(normalized);
              }
            }
          }
        }
      }

      // Fallback: if spine parsing yielded no chapters, find all (x)html files in natural order
      if (chapterPaths.isEmpty) {
        for (final file in archive.files) {
          final low = file.name.toLowerCase();
          if ((low.endsWith('.xhtml') || low.endsWith('.html') || low.endsWith('.htm')) && !low.contains('toc.')) {
            chapterPaths.add(file.name);
          }
        }
      }

      // Write Header
      if (bookTitle != null || bookAuthor != null) {
        buffer.writeln('=== LIVRE EPUB : ${bookTitle ?? 'Sans titre'} ===');
        if (bookAuthor != null) buffer.writeln('Auteur : $bookAuthor');
        buffer.writeln();
      }

      int chapterIndex = 1;
      for (final path in chapterPaths) {
        ArchiveFile? file = archive.findFile(path);
        if (file == null) {
          // Try search without base dir
          final baseName = p.basename(path);
          for (final f in archive.files) {
            if (p.basename(f.name) == baseName) {
              file = f;
              break;
            }
          }
        }

        if (file != null) {
          String html;
          try {
            html = utf8.decode(file.content as List<int>);
          } catch (_) {
            html = latin1.decode(file.content as List<int>);
          }

          final cleanText = _cleanHtml(html);
          if (cleanText.trim().isNotEmpty) {
            buffer.writeln('--- Chapitre / Section $chapterIndex ---');
            buffer.writeln(cleanText.trim());
            buffer.writeln();
            chapterIndex++;
          }
        }
      }

      return buffer.isNotEmpty ? buffer.toString().trim() : '[Livre EPUB sans contenu textuel exploitable]';
    } catch (e) {
      return '[Erreur lors de la lecture du livre EPUB : $e]';
    }
  }

  /// Converts HTML / XHTML strings into clean readable Markdown/Text.
  String _cleanHtml(String html) {
    String text = html;

    // Remove script, style and head tags with their contents
    text = text.replaceAll(RegExp(r'<head[\s\S]*?<\/head>', caseSensitive: false), '');
    text = text.replaceAll(RegExp(r'<style[\s\S]*?<\/style>', caseSensitive: false), '');
    text = text.replaceAll(RegExp(r'<script[\s\S]*?<\/script>', caseSensitive: false), '');

    // Format headers
    text = text.replaceAllMapped(RegExp(r'<h[1-2][^>]*>([\s\S]*?)<\/h[1-2]>', caseSensitive: false), (m) => '\n\n## ${_stripTags(m.group(1) ?? '')}\n\n');
    text = text.replaceAllMapped(RegExp(r'<h[3-6][^>]*>([\s\S]*?)<\/h[3-6]>', caseSensitive: false), (m) => '\n\n### ${_stripTags(m.group(1) ?? '')}\n\n');

    // Paragraphs and breaks
    text = text.replaceAll(RegExp(r'<\/?(p|div|section|article|blockquote)[^>]*>', caseSensitive: false), '\n');
    text = text.replaceAll(RegExp(r'<br\s*\/?>', caseSensitive: false), '\n');
    text = text.replaceAll(RegExp(r'<li[^>]*>', caseSensitive: false), '\n• ');
    text = text.replaceAll(RegExp(r'<\/li>', caseSensitive: false), '\n');

    // Strip remaining tags
    text = _stripTags(text);

    // Unescape common HTML & XML entities
    text = _decodeHtmlEntities(text);

    // Normalize whitespaces and blank lines
    text = text.replaceAll(RegExp(r'[ \t]+'), ' ');
    text = text.replaceAll(RegExp(r'\n{3,}'), '\n\n');

    return text.trim();
  }

  String _stripTags(String s) => s.replaceAll(RegExp(r'<[^>]+>'), '');

  String _decodeHtmlEntities(String input) {
    var out = input
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&')
        .replaceAll('&quot;', '"')
        .replaceAll('&apos;', "'")
        .replaceAll('&#39;', "'")
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&laquo;', '«')
        .replaceAll('&raquo;', '»')
        .replaceAll('&hellip;', '...')
        .replaceAll('&mdash;', '—')
        .replaceAll('&ndash;', '–')
        .replaceAll('&eacute;', 'é')
        .replaceAll('&Eacute;', 'É')
        .replaceAll('&egrave;', 'è')
        .replaceAll('&Egrave;', 'È')
        .replaceAll('&agrave;', 'à')
        .replaceAll('&Agrave;', 'À')
        .replaceAll('&ccedil;', 'ç')
        .replaceAll('&Ccedil;', 'Ç')
        .replaceAll('&ecirc;', 'ê')
        .replaceAll('&Ecirc;', 'Ê')
        .replaceAll('&icirc;', 'î')
        .replaceAll('&Icirc;', 'Î')
        .replaceAll('&ocirc;', 'ô')
        .replaceAll('&Ocirc;', 'Ô')
        .replaceAll('&ucirc;', 'û')
        .replaceAll('&Ucirc;', 'Û')
        .replaceAll('&euml;', 'ë')
        .replaceAll('&Euml;', 'Ë')
        .replaceAll('&iuml;', 'ï')
        .replaceAll('&Iuml;', 'Ï')
        .replaceAll('&uuml;', 'ü')
        .replaceAll('&Uuml;', 'Ü')
        .replaceAll('&deg;', '°')
        .replaceAll('&copy;', '©')
        .replaceAll('&reg;', '®');

    // Numeric decimal entities &#123;
    out = out.replaceAllMapped(RegExp(r'&#([0-9]+);'), (m) {
      final code = int.tryParse(m.group(1) ?? '');
      return code != null ? String.fromCharCode(code) : m.group(0)!;
    });

    // Numeric hex entities &#x1F600;
    out = out.replaceAllMapped(RegExp(r'&#x([0-9a-fA-F]+);'), (m) {
      final code = int.tryParse(m.group(1) ?? '', radix: 16);
      return code != null ? String.fromCharCode(code) : m.group(0)!;
    });

    return out;
  }

  /// Strips XML tags and joins textual content with clean linebreaks.
  String _extractXmlText(String xml) {
    final textTags = RegExp(r'<[^>]+>([^<]+)<\/[^>]+>');
    final buffer = StringBuffer();
    final matches = textTags.allMatches(xml);

    for (final match in matches) {
      final text = match.group(1)?.trim();
      if (text != null && text.isNotEmpty) {
        buffer.write('$text ');
      }
    }
    return buffer.toString().trim();
  }

  /// Extracts content of specific XML tag names.
  List<String> _extractXmlTags(String xml, String tagName) {
    final regex = RegExp('<(?:[a-zA-Z0-9_]+:)?$tagName(?:\\s+[^>]*)?>([\\s\\S]*?)<\\/(?:[a-zA-Z0-9_]+:)?$tagName>');
    return regex.allMatches(xml).map((m) => m.group(1)?.trim() ?? '').where((s) => s.isNotEmpty).toList();
  }
}

