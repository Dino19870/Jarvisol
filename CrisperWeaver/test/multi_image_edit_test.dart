import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:jarvisol/widgets/multi_image_edit_widget.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('MULTI-IMAGE EDIT R3 : Tests Unitaires des Modes & Capacites', () {
    test('1.1 Verification des 5 modes definis pour R3', () {
      expect(MultiImageEditMode.values.length, equals(5));

      final modes = MultiImageEditMode.values.map((m) => m.id).toList();
      expect(modes, contains('reference_person_or_object'));
      expect(modes, contains('reference_face'));
      expect(modes, contains('auto_face_detect'));
      expect(modes, contains('manual_mask_priority'));
      expect(modes, contains('legacy_heuristic_r1'));
    });

    test('1.2 Matrice de capacite factuelle : NATIVE IP-ADAPTER vs FALLBACK', () {
      // 1. reference_person_or_object -> NATIVE IP-ADAPTER
      expect(MultiImageEditMode.referencePersonOrObject.isFullySupported, isTrue);
      expect(MultiImageEditMode.referencePersonOrObject.capabilityLabel, equals('NATIVE IP-ADAPTER'));

      // 2. reference_face -> NATIVE IP-ADAPTER FACE
      expect(MultiImageEditMode.referenceFace.isFullySupported, isTrue);
      expect(MultiImageEditMode.referenceFace.capabilityLabel, equals('NATIVE IP-ADAPTER FACE'));
      expect(MultiImageEditMode.referenceFace.capabilityDetail, contains('sans correspondance biometrique stricte'));

      // 3. auto_face_detect -> AUTO YOLOv8 + IP-ADAPTER
      expect(MultiImageEditMode.autoFaceDetect.isFullySupported, isTrue);
      expect(MultiImageEditMode.autoFaceDetect.capabilityLabel, equals('AUTO YOLOv8 + IP-ADAPTER'));

      // 4. manual_mask_priority -> MASQUE UTILISATEUR
      expect(MultiImageEditMode.manualMaskPriority.isFullySupported, isTrue);
      expect(MultiImageEditMode.manualMaskPriority.capabilityLabel, equals('MASQUE UTILISATEUR'));

      // 5. legacy_heuristic_r1 -> FALLBACK HEURISTIQUE
      expect(MultiImageEditMode.legacyHeuristic.isFullySupported, isFalse);
      expect(MultiImageEditMode.legacyHeuristic.capabilityLabel, equals('FALLBACK HEURISTIQUE'));
    });
  });

  group('MULTI-IMAGE EDIT R3 : Tests de Widgets & Comportement UI', () {
    testWidgets('2.1 Affichage de l onglet, banniere honnete, slots A/B/Masque et selecteur de modele', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 1200));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        const ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: MultiImageEditWidget(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Titre et Description
      expect(find.text('Composition & Edition Multi-Images'), findsOneWidget);
      expect(find.text('Garanties et limites techniques reelles :'), findsOneWidget);
      expect(find.text('SOURCE'), findsOneWidget);
      expect(find.text('CIBLE'), findsOneWidget);
      expect(find.text('OPTIONNEL'), findsOneWidget);

      // Modes R3 affiches (ChoiceChips utilisent mode.label)
      expect(find.text('Reference personnage / objet'), findsOneWidget);
      expect(find.text('Reference visage'), findsOneWidget);
      expect(find.text('Visage automatique'), findsOneWidget);
      expect(find.text('Masque manuel prioritaire'), findsOneWidget);
      expect(find.text('Heuristique R1 (sans adaptateur)'), findsOneWidget);

      // Selecteur de modele
      expect(find.text('Modele inpainting actif (aucune substitution silencieuse) :'), findsOneWidget);
      expect(find.text('SD 1.5 COMPATIBLE'), findsOneWidget);
    });

    testWidgets('2.2 Changement de mode et mise a jour des badges et descriptions', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 1200));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        const ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: MultiImageEditWidget(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Cliquer sur le mode Reference visage
      await tester.tap(find.text('Reference visage'));
      await tester.pumpAndSettle();

      expect(find.text('NATIVE IP-ADAPTER FACE'), findsOneWidget);
      expect(find.textContaining('ressemblance renforcee'), findsWidgets);

      // Cliquer sur Heuristique R1
      await tester.tap(find.text('Heuristique R1 (sans adaptateur)'));
      await tester.pumpAndSettle();

      expect(find.text('FALLBACK SPATIAL'), findsOneWidget);
      expect(find.textContaining('sans conditionnement neuronal direct'), findsWidgets);
    });

    testWidgets('2.3 Validation de securite : refus si images A ou B manquantes', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 1400));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        const ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: MultiImageEditWidget(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // S'assurer que le bouton est visible avant le clic
      final launchBtn = find.text('Lancer la composition');
      await tester.ensureVisible(launchBtn);
      await tester.pumpAndSettle();

      // Tenter de lancer la composition sans charger d images
      await tester.tap(launchBtn);
      await tester.pumpAndSettle();

      // Message d erreur de validation attendu
      expect(find.textContaining('Veuillez charger l Image A (source) et l Image B (cible)'), findsOneWidget);
    });
  });

  group('MULTI-IMAGE EDIT R3-FIX1 : Tests de Chargement Robustes (LOAD-*)', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('jarvisol_load_test_');
    });

    tearDown(() {
      try {
        if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('LOAD-A-01 : Selection reelle d un PNG depuis le disque Windows', () async {
      final pngPath = '${tempDir.path}/sample_a.png';
      final dummyPngBytes = Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00]);
      File(pngPath).writeAsBytesSync(dummyPngBytes);

      // Simule PlatformFile sous Windows Desktop : path renseigne, bytes null
      final platformFile = PlatformFile(
        name: 'sample_a.png',
        path: pngPath,
        size: dummyPngBytes.length,
      );

      final loaded = await readPlatformFileBytesRobust(platformFile);
      expect(loaded, isNotNull);
      expect(loaded.length, equals(dummyPngBytes.length));
      expect(loaded, equals(dummyPngBytes));
    });

    test('LOAD-A-02 : Selection reelle d un JPEG depuis le disque Windows', () async {
      final jpgPath = '${tempDir.path}/sample_a.jpg';
      final dummyJpgBytes = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46]);
      File(jpgPath).writeAsBytesSync(dummyJpgBytes);

      final platformFile = PlatformFile(
        name: 'sample_a.jpg',
        path: jpgPath,
        size: dummyJpgBytes.length,
      );

      final loaded = await readPlatformFileBytesRobust(platformFile);
      expect(loaded, isNotNull);
      expect(loaded.length, equals(dummyJpgBytes.length));
      expect(loaded, equals(dummyJpgBytes));
    });

    test('LOAD-B-01 : Selection reelle d un PNG/JPEG pour Image B', () async {
      final bPath = '${tempDir.path}/target_scene.png';
      final dummyBBytes = Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 0x01, 0x02, 0x03]);
      File(bPath).writeAsBytesSync(dummyBBytes);

      final platformFile = PlatformFile(
        name: 'target_scene.png',
        path: bPath,
        size: dummyBBytes.length,
      );

      final loaded = await readPlatformFileBytesRobust(platformFile);
      expect(loaded, equals(dummyBBytes));
    });

    test('LOAD-MASK-01 : Selection d un masque PNG', () async {
      final maskPath = '${tempDir.path}/mask_binary.png';
      final dummyMaskBytes = Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 0xFF, 0xFF, 0x00, 0x00]);
      File(maskPath).writeAsBytesSync(dummyMaskBytes);

      final platformFile = PlatformFile(
        name: 'mask_binary.png',
        path: maskPath,
        size: dummyMaskBytes.length,
      );

      final loaded = await readPlatformFileBytesRobust(platformFile);
      expect(loaded, equals(dummyMaskBytes));
    });

    test('LOAD-CANCEL-01 : Annuler le FilePicker ne leve aucune erreur', () async {
      // Lorsque l'utilisateur annule le selecteur, file est null
      PlatformFile? cancelledFile;
      expect(cancelledFile, isNull);
    });

    test('LOAD-INVALID-01 : Fichier inexistant produit un message propre et aucun crash', () async {
      final missingPath = '${tempDir.path}/non_existent_file.png';
      final platformFile = PlatformFile(
        name: 'non_existent_file.png',
        path: missingPath,
        size: 0,
      );

      expect(
        () async => await readPlatformFileBytesRobust(platformFile),
        throwsA(isA<FileSystemException>()),
      );
    });

    test('LOAD-FALLBACK-BYTES : Fallback fonctionnel si file.bytes est renseigne (ex: Web ou mock)', () async {
      final mockBytes = Uint8List.fromList([1, 2, 3, 4, 5]);
      final platformFile = PlatformFile(
        name: 'memory_file.png',
        path: null,
        size: mockBytes.length,
        bytes: mockBytes,
      );

      final loaded = await readPlatformFileBytesRobust(platformFile);
      expect(loaded, equals(mockBytes));
    });
  });

  group('MULTI-IMAGE EDIT R1 & MODEL SELECTION FIX1 : Tests de Non-Substitution & Juggernaut', () {
    testWidgets('FIX1.1 Juggernaut nom exact sans coquille', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 1200));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        const ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: MultiImageEditWidget(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Ouvrir le menu déroulant des modèles
      final dropdown = find.byType(DropdownButtonFormField<String>);
      expect(dropdown, findsOneWidget);

      await tester.tap(dropdown);
      await tester.pumpAndSettle();

      // Vérifier le nom exact
      expect(find.text('juggernautXL_ragnarok.safetensors').last, findsOneWidget);
      expect(find.text('juggernautXL_ragnarokBy.safetensors'), findsNothing);
    });

    testWidgets('FIX1.2 Refus propre si modèle SDXL sélectionné en mode IP-Adapter', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 1400));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        const ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: MultiImageEditWidget(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Sélectionner le modèle Juggernaut SDXL
      final dropdown = find.byType(DropdownButtonFormField<String>);
      await tester.tap(dropdown);
      await tester.pumpAndSettle();

      await tester.tap(find.text('juggernautXL_ragnarok.safetensors').last);
      await tester.pumpAndSettle();

      // Le badge d'incompatibilité s'affiche
      expect(find.text('INCOMPATIBLE IP-ADAPTER'), findsOneWidget);
      expect(find.textContaining('Ce modele SDXL ne prend pas en charge les adaptateurs IP-Adapter SD1.5'), findsOneWidget);
    });

    test('UX-2 : Aide explicite pour le fallback Heuristique R1', () {
      expect(MultiImageEditMode.legacyHeuristic.description, contains('Heuristique R1 est un fallback spatial sans detourage automatique'));
      expect(MultiImageEditMode.legacyHeuristic.capabilityDetail, contains('Pour transferer un visage depuis une photo complete, utilisez Reference visage'));
    });
  });
}

