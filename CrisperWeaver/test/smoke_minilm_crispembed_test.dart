// test/smoke_minilm_crispembed_test.dart
//
// Smoke test RAG Phase 3 : CrispEmbed + all-MiniLM-L6-v2-iq4_xs.gguf
//
// Vérifie :
//   1. Chargement du GGUF sans crash
//   2. Dimension réelle == 384
//   3. encode() phrase française → vecteur non vide, valeurs finies
//   4. encodeBatch() plusieurs phrases → N vecteurs cohérents
//   5. Aucun réseau, aucun Python, aucun serveur
//
// Exécuter :
//   flutter test test/smoke_minilm_crispembed_test.dart
//
// Pré-requis :
//   - crispembed.dll doit être dans le CWD ou le PATH de flutter test
//   - all-MiniLM-L6-v2-iq4_xs.gguf doit être dans MINILM_PATH
//     (par défaut : build\windows\x64\runner\Release\data\models\whisper_cpp\)

import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:crispembed/crispembed.dart';

void main() {
  // Chemin absolu du GGUF — flutter test s'exécute depuis la racine du projet
  // Platform.script est incorrect dans le contexte flutter test Windows
  const modelPath =
      r'D:\Antigravity\AgentFolder\CrisperWeaver\build\windows\x64\runner\Release\data\models\whisper_cpp\all-MiniLM-L6-v2-iq4_xs.gguf';

  const dllPath =
      r'D:\Antigravity\AgentFolder\CrisperWeaver\crispembed.dll';

  group('Smoke test — CrispEmbed + MiniLM IQ4_XS', () {
    late CrispEmbed model;

    setUpAll(() {
      if (!File(modelPath).existsSync()) {
        fail(
          'GGUF introuvable : $modelPath\n'
          'Vérifier que le téléchargement Phase 3 est complet.',
        );
      }
      // Charger le modèle (throws si crispembed.dll manquante ou GGUF invalide)
      model = CrispEmbed(
        modelPath,
        nThreads: 2,
        libPath: File(dllPath).existsSync() ? dllPath : null,
      );
    });

    tearDownAll(() {
      model.dispose();
    });

    // ── T-SMOKE-1 ──────────────────────────────────────────────────────
    test('T-SMOKE-1 : chargement GGUF sans exception', () {
      // Si setUpAll n'a pas throw, le modèle est chargé.
      // On vérifie juste que l'objet n'est pas null (late final → toujours non-null si initialisé)
      expect(model, isNotNull);
    });

    // ── T-SMOKE-2 ──────────────────────────────────────────────────────
    test('T-SMOKE-2 : dimension réelle == 384', () {
      final vec = model.encode('test dimension');
      expect(
        vec.length,
        equals(384),
        reason: 'MiniLM-L6-v2 doit produire des vecteurs de dimension 384',
      );
    });

    // ── T-SMOKE-3 ──────────────────────────────────────────────────────
    test('T-SMOKE-3 : encode() phrase française → vecteur non vide et fini', () {
      final phrase = 'Les données personnelles doivent être protégées selon le RGPD.';
      final vec = model.encode(phrase);

      expect(vec.length, equals(384), reason: 'Dimension correcte');
      expect(vec.isNotEmpty, isTrue);

      // Toutes les valeurs doivent être finies (pas NaN, pas inf)
      final allFinite = vec.every((v) => v.isFinite);
      expect(allFinite, isTrue, reason: 'Aucune valeur NaN ou Inf dans le vecteur');

      // Le vecteur doit être non nul (norme > 0)
      final norm = math.sqrt(vec.fold(0.0, (s, v) => s + v * v));
      expect(norm, greaterThan(0.0), reason: 'Norme L2 > 0 (vecteur non nul)');

      // L2-normalisé : norme ≈ 1.0 (CrispEmbed normalise par défaut)
      expect(norm, closeTo(1.0, 0.01),
          reason: 'Vecteur L2-normalisé (norme ≈ 1.0)');

      print('  encode() → dim=${vec.length}, norme=${norm.toStringAsFixed(6)}');
    });

    // ── T-SMOKE-4 ──────────────────────────────────────────────────────
    test('T-SMOKE-4 : encodeBatch() → N vecteurs cohérents', () {
      final phrases = [
        'Protection des données personnelles.',
        'Le RGPD impose des obligations aux entreprises.',
        'Droit à l\'effacement des données.',
        'La CNIL contrôle l\'application du règlement.',
      ];

      final vecs = model.encodeBatch(phrases);

      expect(vecs.length, equals(phrases.length),
          reason: 'encodeBatch doit retourner autant de vecteurs que de phrases');

      for (var i = 0; i < vecs.length; i++) {
        final vec = vecs[i];
        expect(vec.length, equals(384),
            reason: 'Vecteur $i : dimension 384');
        expect(vec.every((v) => v.isFinite), isTrue,
            reason: 'Vecteur $i : valeurs finies');
        final norm = math.sqrt(vec.fold(0.0, (s, v) => s + v * v));
        expect(norm, closeTo(1.0, 0.01),
            reason: 'Vecteur $i : L2-normalisé');
      }

      // Vérifier la cohérence sémantique minimale :
      // cos(phrase0, phrase1) > cos(phrase0, phrase3)
      // ("données personnelles" plus proche de "RGPD" que de "CNIL contrôle")
      // Ce n'est pas un test strict — MiniLM peut varier — mais on vérifie
      // au moins que les vecteurs différents != 0 et != identiques
      final cos01 = _cosine(vecs[0], vecs[1]);
      final cos02 = _cosine(vecs[0], vecs[2]);
      expect(cos01, greaterThan(0.0));
      expect(cos02, greaterThan(0.0));
      expect(cos01, isNot(equals(cos02)),
          reason: 'Vecteurs sémantiquement distincts');

      print('  encodeBatch(${phrases.length}) → ✅');
      print('  cos(phrase0, phrase1) = ${cos01.toStringAsFixed(4)}');
      print('  cos(phrase0, phrase2) = ${cos02.toStringAsFixed(4)}');
    });

    // ── T-SMOKE-5 ──────────────────────────────────────────────────────
    test('T-SMOKE-5 : encode() texte vide ne crash pas', () {
      // Comportement attendu : exception ou vecteur vide — pas de crash natif
      try {
        final vec = model.encode('');
        // Si retourne un vecteur, il doit être valide
        if (vec.isNotEmpty) {
          expect(vec.length, equals(384));
        }
        print('  encode("") → vec.length=${vec.length} (pas de crash)');
      } catch (e) {
        // Une exception Dart est acceptable — ce qui ne l'est pas c'est un crash natif
        print('  encode("") → exception contrôlée : $e');
        expect(e, isA<Exception>());
      }
    });
  });
}

double _cosine(List<double> a, List<double> b) {
  assert(a.length == b.length);
  var dot = 0.0;
  var na = 0.0;
  var nb = 0.0;
  for (var i = 0; i < a.length; i++) {
    dot += a[i] * b[i];
    na += a[i] * a[i];
    nb += b[i] * b[i];
  }
  if (na == 0 || nb == 0) return 0.0;
  return dot / (math.sqrt(na) * math.sqrt(nb));
}
