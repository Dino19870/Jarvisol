import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvisol/theme/app_theme.dart';
import 'package:jarvisol/l10n/generated/app_localizations.dart';

Future<void> loadFonts() async {
  final iconFile = File(r'D:\Antigravity\AgentFolder\CrisperWeaver\build\windows\x64\runner\Release\data\flutter_assets\fonts\MaterialIcons-Regular.otf');
  if (iconFile.existsSync()) {
    final iconLoader = FontLoader('MaterialIcons');
    iconLoader.addFont(Future.value(ByteData.view(iconFile.readAsBytesSync().buffer)));
    await iconLoader.load();
  }

  final segoeFile = File(r'C:\Windows\Fonts\segoeui.ttf');
  if (segoeFile.existsSync()) {
    final bytes = segoeFile.readAsBytesSync();
    for (final fam in ['Segoe UI', 'Roboto', 'Arial', '.SF UI Text', 'sans-serif']) {
      final l = FontLoader(fam);
      l.addFont(Future.value(ByteData.view(bytes.buffer)));
      await l.load();
    }
  }

  final emojiFile = File(r'C:\Windows\Fonts\seguiemj.ttf');
  if (emojiFile.existsSync()) {
    final bytes = emojiFile.readAsBytesSync();
    final l = FontLoader('Segoe UI Emoji');
    l.addFont(Future.value(ByteData.view(bytes.buffer)));
    await l.load();
  }
}

Future<void> saveScreenshot(GlobalKey key, String path) async {
  final boundary = key.currentContext!.findRenderObject() as RenderRepaintBoundary;
  final image = await boundary.toImage(pixelRatio: 1.0);
  final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
  final pngBytes = byteData!.buffer.asUint8List();
  File(path).writeAsBytesSync(pngBytes);
  print('Screenshot saved to $path (${pngBytes.length} bytes, ${image.width}x${image.height})');
}

class GraniteModelManagementMockWidget extends StatelessWidget {
  const GraniteModelManagementMockWidget({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Gestion des Modèles CrispASR'),
        actions: [
          IconButton(
            icon: const Icon(Icons.image_outlined),
            tooltip: 'Modèles Image',
            onPressed: () {},
          ),
          IconButton(
            icon: const Icon(Icons.rocket_launch_outlined),
            tooltip: 'Pack Démarrage Rapide',
            onPressed: () {},
          ),
          IconButton(
            icon: const Icon(Icons.cloud_download),
            tooltip: 'Rafraîchir depuis HuggingFace',
            onPressed: () {},
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Recharger les modèles locaux',
            onPressed: () {},
          ),
        ],
      ),
      body: Column(
        children: [
          // Filter Chips
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Row(
              children: [
                FilterChip(label: const Text('Tous (64)'), selected: false, onSelected: (_) {}),
                const SizedBox(width: 8),
                FilterChip(label: const Text('ASR (32)'), selected: true, onSelected: (_) {}),
                const SizedBox(width: 8),
                FilterChip(label: const Text('TTS (18)'), selected: false, onSelected: (_) {}),
                const SizedBox(width: 8),
                FilterChip(label: const Text('Voix (10)'), selected: false, onSelected: (_) {}),
                const SizedBox(width: 8),
                FilterChip(label: const Text('Codecs (4)'), selected: false, onSelected: (_) {}),
              ],
            ),
          ),
          // Search & Backend row
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: TextEditingController(text: 'granite'),
                    decoration: const InputDecoration(
                      prefixIcon: Icon(Icons.search, size: 20),
                      hintText: 'Filtrer par nom ou backend...',
                      border: OutlineInputBorder(),
                      contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.grey.shade700),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: const Row(
                    children: [
                      Text('Backend: Tous'),
                      SizedBox(width: 4),
                      Icon(Icons.arrow_drop_down),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          // Models list
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              children: [
                // 1. Granite Speech 4.1 2B NAR (Official - Downloaded)
                Card(
                  elevation: 3,
                  shape: RoundedRectangleBorder(
                    side: const BorderSide(color: Colors.greenAccent, width: 1.5),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  color: const Color(0xFF1E2620),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        const Icon(Icons.check_circle, color: Colors.greenAccent, size: 28),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  const Text(
                                    'Granite Speech 4.1 2B NAR (q4_k)',
                                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                                  ),
                                  const SizedBox(width: 8),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: Colors.indigo.shade800,
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: const Text('granite-4.1-nar', style: TextStyle(fontSize: 11, color: Colors.white, fontWeight: FontWeight.bold)),
                                  ),
                                  const SizedBox(width: 6),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: Colors.deepPurple.shade700,
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: const Text('q4_k', style: TextStyle(fontSize: 11, color: Colors.white)),
                                  ),
                                  const SizedBox(width: 6),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: Colors.green.shade800,
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: const Text('ACTIF / DÉCODAGE PARALLÈLE', style: TextStyle(fontSize: 10, color: Colors.white, fontWeight: FontWeight.bold)),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 6),
                              const Text(
                                'Granite Speech 4.1 2B NAR (non-autoregressive, parallel decode) — ~3.18 Go (3 413 252 640 octets)\nFichier local : data/models/whisper_cpp/granite-speech-4.1-2b-nar-q4_k.gguf',
                                style: TextStyle(fontSize: 12, color: Colors.grey),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 12),
                        const Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Text(
                              'Installé',
                              style: TextStyle(color: Colors.greenAccent, fontWeight: FontWeight.bold, fontSize: 13),
                            ),
                            SizedBox(height: 4),
                            Icon(Icons.delete_outline, color: Colors.redAccent, size: 22),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),

                const SizedBox(height: 8),

                // 2. Granite Speech 4.1 2B+ (q4_k)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        const Icon(Icons.graphic_eq, color: Colors.blueAccent, size: 28),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  const Text(
                                    'Granite Speech 4.1 2B+ (q4_k)',
                                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                                  ),
                                  const SizedBox(width: 8),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: Colors.indigo.shade800,
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: const Text('granite-4.1-plus', style: TextStyle(fontSize: 11, color: Colors.white)),
                                  ),
                                  const SizedBox(width: 6),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: Colors.deepPurple.shade700,
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: const Text('q4_k', style: TextStyle(fontSize: 11, color: Colors.white)),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 4),
                              const Text(
                                'IBM Granite Speech 4.1 2B+ (instruction-tuned) — ~2.9 GB\nLangues : en, fr, de, es, pt',
                                style: TextStyle(fontSize: 12, color: Colors.grey),
                              ),
                            ],
                          ),
                        ),
                        ElevatedButton.icon(
                          icon: const Icon(Icons.download, size: 16),
                          label: const Text('Télécharger'),
                          onPressed: () {},
                        ),
                      ],
                    ),
                  ),
                ),

                const SizedBox(height: 8),

                // 3. Granite Speech 4.1 2B (q4_k)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        const Icon(Icons.graphic_eq, color: Colors.blueAccent, size: 28),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  const Text(
                                    'Granite Speech 4.1 2B (q4_k)',
                                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                                  ),
                                  const SizedBox(width: 8),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: Colors.indigo.shade800,
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: const Text('granite-4.1', style: TextStyle(fontSize: 11, color: Colors.white)),
                                  ),
                                  const SizedBox(width: 6),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: Colors.deepPurple.shade700,
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: const Text('q4_k', style: TextStyle(fontSize: 11, color: Colors.white)),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 4),
                              const Text(
                                'IBM Granite Speech 4.1 (2B) — ~1.4 GB\nLangues : en, fr, de, es, pt, it',
                                style: TextStyle(fontSize: 12, color: Colors.grey),
                              ),
                            ],
                          ),
                        ),
                        ElevatedButton.icon(
                          icon: const Icon(Icons.download, size: 16),
                          label: const Text('Télécharger'),
                          onPressed: () {},
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await loadFonts();
  });

  testWidgets('Capture Screenshot 03: Model Management Granite NAR', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final repaintKey = GlobalKey();
    const fallback = ['Segoe UI Emoji', 'Segoe UI', 'Roboto', 'Arial'];
    final theme = AppTheme.darkTheme.copyWith(
      textTheme: AppTheme.darkTheme.textTheme.apply(fontFamily: 'Segoe UI', fontFamilyFallback: fallback),
      primaryTextTheme: AppTheme.darkTheme.primaryTextTheme.apply(fontFamily: 'Segoe UI', fontFamilyFallback: fallback),
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('fr'),
        home: RepaintBoundary(
          key: repaintKey,
          child: const GraniteModelManagementMockWidget(),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    await saveScreenshot(repaintKey, 'screenshot_03_granite_nar.png');

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}
