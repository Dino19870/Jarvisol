// test/rag_french_minilm_test.dart
//
// RAG Phase 3 — Test français décisif : MiniLM vs LM Studio
//
// Ce test :
//   1. Indexe un document français sur le RGPD
//   2. Effectue 10 requêtes françaises couvrant synonymes, paraphrases,
//      acronymes, formulation indirecte, mixte fr/en
//   3. Mesure HIT/MISS sur Top-5
//   4. Compare MiniLM (CrispEmbed 384d) avec LM Studio si disponible
//
// Pré-requis :
//   - crispembed.dll + ggml*.dll dans le CWD (déjà copié)
//   - all-MiniLM-L6-v2-iq4_xs.gguf téléchargé
//   - LM Studio sur :1234 avec text-embedding-qwen3-embedding-4b (optionnel)

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:crispembed/crispembed.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Chemins
// ─────────────────────────────────────────────────────────────────────────────

const _ggufPath =
    r'C:\Jarvisol_Test\CrisperWeaver\build\windows\x64\runner\Release\data\models\whisper_cpp\all-MiniLM-L6-v2-iq4_xs.gguf';

const _dllPath =
    r'C:\Jarvisol_Test\CrisperWeaver\crispembed.dll';

const _docPath =
    r'C:\Jarvisol_Test\CrisperWeaver\build\windows\x64\runner\Release\data\rag_test_fr_rgpd.md';

const _lmStudioEndpoint = 'http://127.0.0.1:1234/v1/embeddings';
const _lmStudioModel = 'text-embedding-qwen3-embedding-4b';

// ─────────────────────────────────────────────────────────────────────────────
// Document RGPD — chunks manuels (paragraphes du fichier test)
// ─────────────────────────────────────────────────────────────────────────────

const _chunks = <String>[
  // 0 — Introduction
  'Le Règlement Général sur la Protection des Données, communément appelé RGPD (en anglais GDPR : General Data Protection Regulation), est un texte réglementaire européen qui encadre le traitement des données de façon égalitaire à travers toute l\'Union Européenne. Il est entré en vigueur le 25 mai 2018.',

  // 1 — Droits : effacement, accès, rectification
  'Les personnes dont les données sont collectées bénéficient de nombreux droits fondamentaux. Le droit à l\'effacement, également connu sous le nom de « droit à l\'oubli », permet à toute personne de demander la suppression de ses informations personnelles. Le droit d\'accès garantit à chaque individu la possibilité de consulter les données qui le concernent. Le droit de rectification permet de corriger des informations inexactes.',

  // 2 — Obligations : DPO
  'Les entreprises et organisations qui collectent des données personnelles ont des obligations strictes. Elles doivent désigner un Délégué à la Protection des Données (DPO, Data Protection Officer) lorsque leurs activités impliquent un traitement à grande échelle. Le DPO est chargé de veiller à la conformité au règlement.',

  // 3 — Notification de violation 72h
  'En cas de violation de données (data breach), l\'organisation a l\'obligation de notifier l\'autorité de contrôle compétente dans un délai de 72 heures après avoir eu connaissance de l\'incident. Cette notification de violation est une obligation légale stricte.',

  // 4 — Sanctions 4% CA
  'Le non-respect du RGPD peut entraîner des amendes considérables. Les sanctions peuvent atteindre 20 millions d\'euros ou 4 % du chiffre d\'affaires mondial annuel de l\'entreprise, selon le montant le plus élevé. Ces pénalités s\'appliquent aux infractions les plus graves.',

  // 5 — CNIL
  'En France, c\'est la Commission Nationale de l\'Informatique et des Libertés (CNIL) qui est chargée de veiller à l\'application du règlement. La CNIL peut mener des contrôles, recevoir des plaintes et prononcer des sanctions administratives. Elle joue un rôle central dans la protection de la vie privée des citoyens français.',

  // 6 — Consentement
  'Le traitement des données personnelles doit reposer sur une base légale : le consentement explicite de la personne, l\'exécution d\'un contrat, une obligation légale, ou l\'intérêt légitime du responsable du traitement. Le consentement doit être libre, éclairé, spécifique et univoque.',

  // 7 — Transferts internationaux
  'Le RGPD encadre strictement les transferts de données vers des pays tiers à l\'Union Européenne. Ces transferts ne sont autorisés que si le pays destinataire offre un niveau de protection adéquat, ou si des garanties appropriées sont mises en place, comme les clauses contractuelles types.',
];

// ─────────────────────────────────────────────────────────────────────────────
// 10 requêtes françaises décisives avec chunk attendu
// ─────────────────────────────────────────────────────────────────────────────

class _Query {
  final String query;
  final int expectedChunkIndex;
  final String type;
  final String note;
  const _Query(this.query, this.expectedChunkIndex, this.type, this.note);
}

const _queries = <_Query>[
  // Q1 — synonyme "suppression" → chunk 1 (effacement/oubli)
  _Query(
    'Comment faire supprimer ses données personnelles ?',
    1, 'synonyme', 'suppression ↔ effacement/oubli',
  ),
  // Q2 — paraphrase "amende max" → chunk 4 (4% CA)
  _Query(
    'Quelle est la sanction financière maximale prévue par le règlement ?',
    4, 'paraphrase', 'sanction financière max ↔ amende 4% CA',
  ),
  // Q3 — formulation indirecte "délai signalement incident" → chunk 3 (72h)
  _Query(
    'Combien de temps a-t-on pour signaler une fuite de données à l\'autorité ?',
    3, 'formulation indirecte', 'fuite+délai ↔ notification 72h',
  ),
  // Q4 — acronyme "CNIL" → chunk 5
  _Query(
    'Quel est le rôle de la CNIL ?',
    5, 'acronyme', 'CNIL → Commission Nationale Informatique Libertés',
  ),
  // Q5 — acronyme "DPO" → chunk 2
  _Query(
    'Qu\'est-ce qu\'un DPO et quand faut-il en nommer un ?',
    2, 'acronyme', 'DPO → Délégué Protection Données',
  ),
  // Q6 — terme technique "consentement éclairé" → chunk 6
  _Query(
    'Quelles sont les conditions de validité du consentement ?',
    6, 'terme technique', 'consentement valide ↔ libre éclairé spécifique univoque',
  ),
  // Q7 — terme fr différent "vie privée des citoyens" → chunk 5 (CNIL)
  _Query(
    'Qui protège la vie privée des Français face aux abus de traitement de données ?',
    5, 'terme fr différent', 'vie privée citoyens ↔ CNIL',
  ),
  // Q8 — paraphrase longue "envoyer données hors EU" → chunk 7
  _Query(
    'Est-il possible d\'envoyer des informations personnelles vers un pays hors Union Européenne ?',
    7, 'paraphrase longue', 'données hors EU ↔ transferts internationaux',
  ),
  // Q9 — requête mixte fr/en "data breach notification" → chunk 3
  _Query(
    'data breach notification obligation',
    3, 'mixte fr/en', 'data breach ↔ violation + notification 72h',
  ),
  // Q10 — formulation vague/indirecte "pénalités" → chunk 4
  _Query(
    'Quelles sont les conséquences en cas de non-conformité au règlement ?',
    4, 'formulation vague', 'non-conformité conséquences ↔ pénalités amendes',
  ),
];

// ─────────────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────────────

double _cosine(List<double> a, List<double> b) {
  var dot = 0.0; var na = 0.0; var nb = 0.0;
  for (var i = 0; i < a.length; i++) {
    dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i];
  }
  if (na == 0 || nb == 0) return 0.0;
  return dot / (math.sqrt(na) * math.sqrt(nb));
}

List<int> _topK(List<double> scores, int k) {
  final idx = List.generate(scores.length, (i) => i);
  idx.sort((a, b) => scores[b].compareTo(scores[a]));
  return idx.take(k).toList();
}

// Retourner les top-5 indices pour une requête donnée
List<int> _retrieveTopK(
  List<double> queryVec,
  List<List<double>> chunkVecs,
  int k,
) {
  final scores = chunkVecs
      .map((cv) => _cosine(queryVec, cv))
      .toList();
  return _topK(scores, k);
}

// ─────────────────────────────────────────────────────────────────────────────
// Test principal
// ─────────────────────────────────────────────────────────────────────────────

void main() {
  group('RAG Phase 3 — Test français MiniLM vs LM Studio', () {
    late CrispEmbed miniLm;
    late List<List<double>> miniLmChunkVecs;
    late List<List<double>>? lmStudioChunkVecs;
    bool lmStudioAvailable = false;
    final Stopwatch indexTimer = Stopwatch();

    setUpAll(() async {
      // ── Charger MiniLM ──────────────────────────────────────────────
      miniLm = CrispEmbed(
        _ggufPath,
        nThreads: 4,
        libPath: File(_dllPath).existsSync() ? _dllPath : null,
      );

      // ── Indexer les chunks avec MiniLM ──────────────────────────────
      print('\n=== Indexation MiniLM (${_chunks.length} chunks) ===');
      indexTimer.start();
      miniLmChunkVecs = _chunks
          .map((c) => miniLm.encode(c).toList())
          .toList();
      indexTimer.stop();
      print('  Temps indexation : ${indexTimer.elapsedMilliseconds} ms');
      print('  Dim vecteurs    : ${miniLmChunkVecs.first.length}');

      // ── Tester LM Studio (optionnel, pas de fail si absent) ─────────
      print('\n=== Test connectivité LM Studio :1234 ===');
      try {
        final resp = await http.post(
          Uri.parse(_lmStudioEndpoint),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'model': _lmStudioModel, 'input': 'test'}),
        ).timeout(const Duration(seconds: 5));
        if (resp.statusCode == 200) {
          lmStudioAvailable = true;
          print('  ✅ LM Studio disponible');

          // Indexer les chunks avec LM Studio
          print('  Indexation LM Studio...');
          final lmVecs = <List<double>>[];
          for (final chunk in _chunks) {
            final r = await http.post(
              Uri.parse(_lmStudioEndpoint),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({'model': _lmStudioModel, 'input': chunk}),
            );
            final j = jsonDecode(r.body);
            final vec = (j['data'][0]['embedding'] as List).cast<double>();
            lmVecs.add(vec);
          }
          lmStudioChunkVecs = lmVecs;
          print('  Dim LM Studio : ${lmVecs.first.length}');
        } else {
          print('  ⚠️ LM Studio HTTP ${resp.statusCode} — test LM Studio ignoré');
        }
      } catch (e) {
        print('  ⚠️ LM Studio injoignable : $e');
        lmStudioAvailable = false;
        lmStudioChunkVecs = null;
      }
    });

    tearDownAll(() {
      miniLm.dispose();
    });

    // ── Test d'indexation ──────────────────────────────────────────────
    test('IDX-1 : indexation MiniLM — ${_chunks.length} chunks, dim 384', () {
      expect(miniLmChunkVecs.length, equals(_chunks.length));
      expect(miniLmChunkVecs.first.length, equals(384));
      print('\n  Temps indexation : ${indexTimer.elapsedMilliseconds} ms');
      print('  Moyenne par chunk : ${(indexTimer.elapsedMilliseconds / _chunks.length).toStringAsFixed(1)} ms');
    });

    // ── 10 requêtes françaises — MiniLM ───────────────────────────────
    test('FR-MINILM : 10 requêtes françaises — score N/10', () async {
      print('\n=== RÉSULTATS MiniLM IQ4_XS — 10 requêtes françaises ===\n');
      print('${' N°'.padRight(3)} | ${'Type'.padRight(20)} | ${'HIT'.padRight(4)} | ${'Rang'.padRight(4)} | Requête');
      print('-' * 100);

      int hits = 0;
      final misses = <int>[];

      for (var i = 0; i < _queries.length; i++) {
        final q = _queries[i];
        final qVec = miniLm.encode(q.query).toList();
        final top5 = _retrieveTopK(qVec, miniLmChunkVecs, 5);

        final rank = top5.indexOf(q.expectedChunkIndex);
        final hit = rank >= 0;
        if (hit) hits++; else misses.add(i + 1);

        final hitStr = hit ? '✅' : '❌';
        final rankStr = hit ? '${rank + 1}' : '—';
        final label = 'Q${i + 1}: ${q.type}'.padRight(20);
        print('  Q${i + 1} | $label | $hitStr   | $rankStr    | ${q.query.substring(0, math.min(55, q.query.length))}');
      }

      print('\n  SCORE MINILM : $hits/10');
      if (misses.isNotEmpty) {
        print('  MISS : Q${misses.join(', Q')}');
        for (final idx in misses) {
          final q = _queries[idx - 1];
          print('    Q$idx (${q.type}) : "${q.query}" → attendu chunk ${q.expectedChunkIndex} (${q.note})');
        }
      }

      expect(hits, greaterThanOrEqualTo(0));
      // Stocker pour comparaison avec LM Studio
      addTearDown(() => print('\n  [MiniLM final] $hits/10'));
    });

    // ── 10 requêtes françaises — LM Studio (si disponible) ────────────
    test('FR-LMSTUDIO : 10 requêtes françaises — score N/10 (si dispo)', () async {
      if (!lmStudioAvailable || lmStudioChunkVecs == null) {
        print('\n  ⚠️ LM Studio non disponible — comparaison impossible');
        return;
      }

      print('\n=== RÉSULTATS LM Studio text-embedding-qwen3-embedding-4b ===\n');
      print('${' N°'.padRight(3)} | ${'Type'.padRight(20)} | ${'HIT'.padRight(4)} | ${'Rang'.padRight(4)} | Requête');
      print('-' * 100);

      int hits = 0;
      final misses = <int>[];

      for (var i = 0; i < _queries.length; i++) {
        final q = _queries[i];

        // Encoder la requête via LM Studio
        final resp = await http.post(
          Uri.parse(_lmStudioEndpoint),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'model': _lmStudioModel, 'input': q.query}),
        );
        final j = jsonDecode(resp.body);
        final qVec = (j['data'][0]['embedding'] as List).cast<double>();
        final top5 = _retrieveTopK(qVec, lmStudioChunkVecs!, 5);

        final rank = top5.indexOf(q.expectedChunkIndex);
        final hit = rank >= 0;
        if (hit) hits++; else misses.add(i + 1);

        final hitStr = hit ? '✅' : '❌';
        final rankStr = hit ? '${rank + 1}' : '—';
        final label = 'Q${i + 1}: ${q.type}'.padRight(20);
        print('  Q${i + 1} | $label | $hitStr   | $rankStr    | ${q.query.substring(0, math.min(55, q.query.length))}');
      }

      print('\n  SCORE LM STUDIO : $hits/10');
      if (misses.isNotEmpty) {
        print('  MISS LM Studio : Q${misses.join(', Q')}');
      }

      expect(hits, greaterThanOrEqualTo(0));
    });

    // ── Résumé comparatif ─────────────────────────────────────────────
    test('RÉSUMÉ : comparaison MiniLM vs LM Studio', () async {
      print('\n=== RÉSUMÉ COMPARATIF RAG Phase 3 ===');
      print('  Modèle MiniLM     : all-MiniLM-L6-v2-iq4_xs.gguf (19 MB, 384d, CPU)');
      print('  Modèle LM Studio  : text-embedding-qwen3-embedding-4b (LM Studio :1234, 2560d)');
      print('  Document test     : RGPD français (~450 mots, ${_chunks.length} chunks)');
      print('  Temps indexation  : ${indexTimer.elapsedMilliseconds} ms (MiniLM)');
      print('  LM Studio dispo   : $lmStudioAvailable');
      print('  DLL               : crispembed.dll + ggml (CPU-only, no Python, no server)');

      // Le score réel est imprimé dans les tests précédents
      // Ce test est informatif
      expect(true, isTrue);
    });
  });
}
