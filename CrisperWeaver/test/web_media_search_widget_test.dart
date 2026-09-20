import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvisol/models/web_media_models.dart';
import 'package:jarvisol/services/settings_service.dart';
import 'package:jarvisol/services/web_media_service.dart';
import 'package:jarvisol/utils/portable_preferences.dart';
import 'package:jarvisol/widgets/web_media_import_dialog.dart';

class FakeWebMediaService extends WebMediaService {
  List<WebMediaSearchResult> searchResultsToReturn = [];
  bool delaySearch = false;
  Completer<void>? searchCompleter;

  @override
  Future<WebMediaProbeResult> probe() async {
    return const WebMediaProbeResult(isAvailable: true, version: '2026.08.19');
  }

  @override
  Future<List<WebMediaSearchResult>> searchMedia(
    String query, {
    int limit = 20,
    Duration timeout = const Duration(seconds: 45),
    WebMediaCancellationToken? cancelToken,
  }) async {
    if (delaySearch) {
      searchCompleter = Completer<void>();
      cancelToken?.attachProcess(await Process.start('cmd.exe', ['/c', 'pause']));
      await searchCompleter!.future;
    }
    if (cancelToken?.isCancelled ?? false) {
      throw const CancellationException();
    }
    return searchResultsToReturn;
  }

  @override
  Future<WebMediaMetadata> getMetadata(
    String url, {
    bool includePlaylist = false,
    Duration timeout = const Duration(seconds: 45),
    WebMediaCancellationToken? cancelToken,
  }) async {
    return WebMediaMetadata(
      url: url,
      extractor: 'youtube',
      id: 'mock_123',
      title: 'Mock Video Title',
      description: 'Mock Description',
      uploader: 'Mock Channel',
      channel: 'Mock Channel',
      uploadDate: '20260901',
      duration: 180.0,
      thumbnail: 'https://example.com/thumb.jpg',
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeWebMediaService fakeWebService;
  late SettingsService settingsService;

  setUp(() async {
    fakeWebService = FakeWebMediaService();
    PortablePreferences.resetForTesting();
    final prefs = await PortablePreferences.getInstance();
    settingsService = SettingsService(prefs);
  });

  testWidgets('UI-SEARCH: Parcours complet WebMediaImportDialog (recherche, date, résumé, compteur, Afficher plus, sélection, retour)', (tester) async {
    // Injecter 2 résultats simulés avec dates et résumés
    fakeWebService.searchResultsToReturn = [
      WebMediaSearchResult(
        id: 'vid1',
        url: 'https://www.youtube.com/watch?v=vid1',
        title: 'Spring - Blender Open Movie',
        uploader: 'Blender Studio',
        channel: 'Blender Studio',
        duration: 384.0,
        mediaType: WebMediaResultType.video,
        viewCount: 5000000,
        uploadDate: '20250312',
        description: 'Un magnifique court-métrage d animation réalisé avec Blender.',
      ),
      WebMediaSearchResult(
        id: 'vid2',
        url: 'https://www.youtube.com/watch?v=vid2',
        title: 'Charge - Blender Open Movie',
        uploader: 'Blender Studio',
        channel: 'Blender Studio',
        duration: 210.0,
        mediaType: WebMediaResultType.video,
        viewCount: 3000000,
        description: 'Court-métrage cyberpunk d action.',
      ),
    ];

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          webMediaServiceProvider.overrideWithValue(fakeWebService),
          settingsServiceProvider.overrideWithValue(settingsService),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: WebMediaImportDialog(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 1. Dialogue ouvert, titre visible, mode Recherche sélectionné par défaut
    expect(find.text('Importer un Média Web (yt-dlp)'), findsOneWidget);
    expect(find.text('Recherche de médias'), findsOneWidget);
    expect(find.text('Import direct par URL'), findsOneWidget);

    // 2. Bascule de mode : Recherche <-> Import direct par URL
    await tester.tap(find.text('Import direct par URL'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Collez une URL'), findsOneWidget);
    expect(find.text('Analyser'), findsOneWidget);

    // Revenir au mode recherche
    await tester.tap(find.text('Recherche de médias'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Rechercher un média'), findsOneWidget);
    expect(find.text('Rechercher'), findsOneWidget);

    // 3. Saisie d'une requête de recherche
    await tester.enterText(find.byType(TextField), 'blender open movie');
    await tester.pump();

    // 4. Lancement de la recherche
    await tester.tap(find.text('Rechercher'));
    await tester.pump(); // Début chargement
    await tester.pumpAndSettle(); // Fin chargement

    // 5. Affichage des résultats avec détails : compteur, titre, date, résumé, vues
    expect(find.text('2 résultats affichés'), findsOneWidget);
    expect(find.text('Spring - Blender Open Movie'), findsOneWidget);
    expect(find.text('Charge - Blender Open Movie'), findsOneWidget);
    expect(find.text('Blender Studio'), findsWidgets);
    expect(find.text('VIDÉO'), findsWidgets);
    expect(find.text('6m 24s'), findsOneWidget); // 384s formatée

    // Vérification de la date de publication et du fallback
    expect(find.text('Publié le 12 mars 2025'), findsOneWidget);
    expect(find.text('Date indisponible'), findsOneWidget);

    // Vérification de l'extrait / résumé
    expect(find.text('Un magnifique court-métrage d animation réalisé avec Blender.'), findsOneWidget);
    expect(find.text('Court-métrage cyberpunk d action.'), findsOneWidget);

    // 6. Sélection d'un résultat et acheminement vers _analyzeUrl()
    final selectButtons = find.byIcon(Icons.arrow_forward);
    expect(selectButtons, findsWidgets);
    await tester.tap(selectButtons.first);
    await tester.pump(); // Début analyse
    await tester.pumpAndSettle(); // Fin analyse métadonnées

    // Vérification que les métadonnées de la vidéo sont affichées
    expect(find.text('Retour aux résultats de recherche'), findsOneWidget);
    expect(find.textContaining('Résultat sélectionné : Spring - Blender Open Movie'), findsOneWidget);
    expect(find.text('Mock Video Title'), findsOneWidget);

    // 7. Retour aux résultats de recherche
    await tester.tap(find.text('Retour aux résultats de recherche'));
    await tester.pumpAndSettle();
    expect(find.text('Spring - Blender Open Movie'), findsOneWidget);
    expect(find.text('2 résultats affichés'), findsOneWidget);

    // 8. Test zéro résultat
    fakeWebService.searchResultsToReturn = [];
    await tester.enterText(find.byType(TextField), 'terme_introuvable_xyz123');
    await tester.tap(find.text('Rechercher'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Aucun résultat trouvé pour « terme_introuvable_xyz123 »'), findsOneWidget);

    // 9. Bascule retour vers mode URL direct et intégrité préexistante
    await tester.tap(find.text('Import direct par URL'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Collez une URL'), findsOneWidget);
    expect(find.text('Analyser'), findsOneWidget);
  });
}
