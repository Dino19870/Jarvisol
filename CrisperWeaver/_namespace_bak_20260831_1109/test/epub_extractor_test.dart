import 'dart:convert';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:crisper_weaver/services/document_source_service.dart';

void main() {
  test('DocumentSourceService parses EPUB file correctly', () async {
    final archive = Archive();

    // 1. META-INF/container.xml
    const containerXml = '''<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>''';
    final containerBytes = utf8.encode(containerXml);
    archive.addFile(ArchiveFile('META-INF/container.xml', containerBytes.length, containerBytes));

    // 2. OEBPS/content.opf
    const opfXml = '''<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://www.idpf.org/2007/opf" unique-identifier="BookId" version="2.0">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:title>Le Guide du Voyageur Spatial</dc:title>
    <dc:creator>Arthur Dent</dc:creator>
  </metadata>
  <manifest>
    <item id="chap1" href="chap1.xhtml" media-type="application/xhtml+xml"/>
    <item id="chap2" href="chap2.xhtml" media-type="application/xhtml+xml"/>
  </manifest>
  <spine toc="ncx">
    <itemref idref="chap1"/>
    <itemref idref="chap2"/>
  </spine>
</package>''';
    final opfBytes = utf8.encode(opfXml);
    archive.addFile(ArchiveFile('OEBPS/content.opf', opfBytes.length, opfBytes));

    // 3. OEBPS/chap1.xhtml
    const chap1Html = '''<?xml version="1.0" encoding="utf-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml">
  <head><title>Chapitre 1</title></head>
  <body>
    <h1>Chapitre Premier</h1>
    <p>La r&eacute;ponse &agrave; la grande question sur la vie est <strong>42</strong>.</p>
    <p>Ne paniquez pas &amp; emportez une serviette.</p>
  </body>
</html>''';
    final chap1Bytes = utf8.encode(chap1Html);
    archive.addFile(ArchiveFile('OEBPS/chap1.xhtml', chap1Bytes.length, chap1Bytes));

    // 4. OEBPS/chap2.xhtml
    const chap2Html = '''<?xml version="1.0" encoding="utf-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml">
  <head><title>Chapitre 2</title></head>
  <body>
    <h2>Deuxi&egrave;me &Eacute;tape</h2>
    <p>Le propulseur &agrave; improbabilit&eacute; infinie est activ&eacute;.</p>
  </body>
</html>''';
    final chap2Bytes = utf8.encode(chap2Html);
    archive.addFile(ArchiveFile('OEBPS/chap2.xhtml', chap2Bytes.length, chap2Bytes));

    // Encode to ZIP bytes
    final zipEncoder = ZipEncoder();
    final epubBytes = Uint8List.fromList(zipEncoder.encode(archive));

    final service = DocumentSourceService();
    final item = await service.parseFile('guide_spatial.epub', fileBytes: epubBytes);

    expect(item.type, equals('book'));
    expect(item.name, equals('guide_spatial.epub'));
    expect(item.textContent, contains('=== LIVRE EPUB : Le Guide du Voyageur Spatial ==='));
    expect(item.textContent, contains('Auteur : Arthur Dent'));
    expect(item.textContent, contains('Chapitre Premier'));
    expect(item.textContent, contains('La réponse à la grande question sur la vie est 42.'));
    expect(item.textContent, contains('Ne paniquez pas & emportez une serviette.'));
    expect(item.textContent, contains('Deuxième Étape'));
    expect(item.textContent, contains('Le propulseur à improbabilité infinie est activé.'));
  });
}
