// test/rag_benchmark_discriminant_test.dart
//
// RAG Phase 3B — Benchmark français réellement discriminant
//
// Corpus : 35 chunks, 6 domaines (RGPD, sécurité info, droit travail,
//          contrats, administration, distracteurs).
// Requêtes : 12 (dont 2 négatives, plusieurs sans mot commun avec le passage).
// Mesure : Top-1, Top-3, Top-5 pour MiniLM, LM Studio et BM25.
//
// Pré-requis : crispembed.dll + ggml*.dll dans le CWD projet.

import 'dart:io';
import 'dart:math' as math;
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
const _lmStudioUrl = 'http://127.0.0.1:1234/v1/embeddings';
const _lmStudioModel = 'text-embedding-qwen3-embedding-4b';

// ─────────────────────────────────────────────────────────────────────────────
// CORPUS — 35 chunks multi-domaines
// ─────────────────────────────────────────────────────────────────────────────
//
// Nomenclature d'index :
//   0-7   : RGPD / vie privée
//   8-13  : Sécurité informatique
//  14-18  : Droit du travail
//  19-23  : Contrats commerciaux
//  24-28  : Administration publique
//  29-34  : Distracteurs (mots clés similaires, sens différent)
//
const _chunks = <String>[
  // ── RGPD / Vie privée (0-7) ─────────────────────────────────────────
  // 0
  'Le RGPD est entré en application le 25 mai 2018 dans toute l\'Union Européenne. Il remplace la directive 95/46/CE et unifie la législation sur la protection des données personnelles.',
  // 1
  'Toute personne physique dispose d\'un droit d\'accès à ses données personnelles. Elle peut demander à l\'organisme responsable de lui communiquer l\'ensemble des informations qu\'il détient sur elle, gratuitement et dans un délai d\'un mois.',
  // 2
  'Le droit à l\'oubli, formellement appelé droit à l\'effacement, permet à un individu d\'exiger la suppression de ses données personnelles lorsqu\'elles ne sont plus nécessaires ou lorsque le consentement initial est retiré.',
  // 3
  'Les entreprises qui réalisent un traitement de données à grande échelle doivent désigner un délégué à la protection des données. Ce responsable, souvent désigné par son acronyme anglais DPO (Data Protection Officer), veille au respect du règlement.',
  // 4
  'En cas de faille de sécurité compromettant des données personnelles, l\'organisation doit notifier l\'autorité de contrôle dans les 72 heures suivant la détection de l\'incident. Cette obligation de signalement est impérative.',
  // 5
  'Les infractions au règlement européen sur la protection des données peuvent être sanctionnées par des pénalités allant jusqu\'à 4 % du chiffre d\'affaires annuel mondial ou 20 millions d\'euros, selon le montant le plus élevé.',
  // 6
  'La CNIL, Commission Nationale de l\'Informatique et des Libertés, est l\'autorité française compétente pour contrôler l\'application du RGPD et instruire les plaintes des citoyens en matière de protection des données.',
  // 7
  'Le transfert de données personnelles vers un pays situé hors de l\'Union Européenne est soumis à des garanties spécifiques : décision d\'adéquation de la Commission européenne ou clauses contractuelles types approuvées.',

  // ── Sécurité informatique (8-13) ────────────────────────────────────
  // 8
  'Un pare-feu (firewall) est un système de sécurité réseau qui filtre les communications entre un réseau interne et Internet selon des règles préétablies, afin de bloquer les accès non autorisés.',
  // 9
  'L\'authentification à deux facteurs (2FA) renforce la sécurité des comptes en exigeant deux preuves d\'identité distinctes : un mot de passe et un code temporaire envoyé sur un téléphone ou généré par une application.',
  // 10
  'Une attaque par ransomware chiffre les fichiers d\'une organisation et exige une rançon pour en restaurer l\'accès. Ces cyberattaques ciblent préférentiellement les hôpitaux, collectivités et entreprises mal protégées.',
  // 11  ← distracteur sécurité-RGPD : "violation", "notification" partagés
  'En cybersécurité, une violation de données désigne toute compromission non autorisée de la confidentialité, l\'intégrité ou la disponibilité d\'un système. La notification aux parties prenantes doit suivre les politiques internes de l\'organisation.',
  // 12
  'Le chiffrement de bout en bout garantit que seuls l\'émetteur et le destinataire peuvent lire les messages échangés. Même le fournisseur du service de messagerie n\'a pas accès au contenu en clair.',
  // 13
  'Un audit de sécurité informatique évalue les vulnérabilités d\'un système d\'information. Il comprend des tests d\'intrusion (pentests), une analyse de configuration et une revue des politiques de contrôle d\'accès.',

  // ── Droit du travail (14-18) ─────────────────────────────────────────
  // 14
  'Le contrat de travail à durée indéterminée (CDI) est la forme normale et générale de la relation de travail en France. Il ne comporte pas de terme fixé et peut être rompu par le salarié (démission) ou l\'employeur (licenciement).',
  // 15
  'Le licenciement pour motif économique intervient lorsque l\'entreprise supprime un ou plusieurs postes en raison de difficultés économiques, de mutations technologiques ou d\'une réorganisation nécessaire à la sauvegarde de la compétitivité.',
  // 16
  'La durée légale du travail est fixée à 35 heures par semaine en France. Les heures effectuées au-delà donnent lieu à des majorations de salaire ou à un repos compensateur, selon les dispositions conventionnelles applicables.',
  // 17
  'Le droit à la déconnexion permet aux salariés de ne pas être joignables en dehors de leurs horaires de travail habituels, notamment via les outils numériques professionnels (messagerie, téléphone, applications métier).',
  // 18
  'La période d\'essai permet à l\'employeur et au salarié d\'évaluer leur relation de travail avant de s\'engager définitivement. Sa durée varie selon la catégorie professionnelle et peut être renouvelée une fois si la convention collective le prévoit.',

  // ── Contrats commerciaux (19-23) ──────────────────────────────────
  // 19
  'La clause de confidentialité (NDA, Non-Disclosure Agreement) engage les parties à ne pas divulguer les informations sensibles échangées dans le cadre d\'un accord commercial. Elle est souvent réciproque et limitée dans le temps.',
  // 20
  'La force majeure est un événement imprévisible, irrésistible et extérieur qui libère une partie de ses obligations contractuelles. La pandémie de Covid-19 a été invoquée dans de nombreux litiges contractuels à ce titre.',
  // 21
  'Un contrat SaaS (Software as a Service) définit les conditions d\'accès à un logiciel hébergé dans le cloud. Il inclut des engagements de niveau de service (SLA), des clauses de portabilité des données et des modalités de résiliation.',
  // 22
  'La garantie légale de conformité oblige le vendeur professionnel à livrer un bien conforme au contrat. L\'acheteur dispose de deux ans à partir de la délivrance pour agir, sans avoir à prouver l\'existence du défaut.',
  // 23
  'La clause pénale prévoit forfaitairement le montant des dommages-intérêts dus en cas d\'inexécution d\'une obligation contractuelle. Elle peut être réduite ou augmentée par le juge si son montant est manifestement excessif ou dérisoire.',

  // ── Administration publique (24-28) ───────────────────────────────
  // 24
  'Le service public est organisé selon trois principes fondamentaux : continuité (fonctionnement ininterrompu), égalité (traitement identique des usagers) et adaptabilité (évolution selon les besoins sociaux).',
  // 25
  'Le recours pour excès de pouvoir permet à tout citoyen de contester devant le tribunal administratif une décision administrative illégale, sans avoir à justifier d\'un intérêt personnel direct.',
  // 26
  'La Commission d\'Accès aux Documents Administratifs (CADA) veille au droit d\'accès aux documents produits ou reçus par l\'administration française. Tout citoyen peut demander communication d\'un document administratif.',
  // 27
  'La commande publique est régie par le Code de la commande publique. Elle impose aux acheteurs publics le respect de principes de liberté d\'accès, d\'égalité de traitement des candidats et de transparence des procédures.',
  // 28
  'La délégation de service public (DSP) est un contrat par lequel une collectivité confie la gestion d\'un service public à un opérateur privé dont la rémunération est substantiellement assurée par les résultats d\'exploitation.',

  // ── Distracteurs — mots partagés, sens différent (29-34) ──────────
  // 29  ← "données", "accès" — contexte bases de données SQL, pas RGPD
  'Dans une base de données relationnelle, les données sont organisées en tables reliées par des clés étrangères. L\'accès aux enregistrements s\'effectue via des requêtes SQL utilisant les clauses SELECT, FROM et WHERE.',
  // 30  ← "sécurité", "contrôle" — sécurité physique bâtiments
  'La sécurité des bâtiments publics repose sur des systèmes de contrôle d\'accès physique : badges RFID, caméras de surveillance et procédures d\'accréditation du personnel. Ces dispositifs visent à prévenir les intrusions non autorisées.',
  // 31  ← "contrat", "résiliation" — contexte abonnement téléphonique
  'Les opérateurs téléphoniques proposent des contrats d\'abonnement avec ou sans engagement. La résiliation sans frais est possible après la période d\'engagement initiale, avec un préavis généralement d\'un mois.',
  // 32  ← "droits", "délai" — droit civil successions, pas travail
  'En droit des successions, les héritiers disposent d\'un délai de six mois pour accepter ou renoncer à la succession. Passé ce délai, ils sont réputés acceptants purs et simples et répondent des dettes du défunt.',
  // 33  ← "violation", "sanction" — droit pénal, pas RGPD
  'La violation du secret professionnel est un délit pénal sanctionné par un an d\'emprisonnement et 15 000 euros d\'amende. Elle concerne les professions tenues au secret : médecins, avocats, notaires, experts-comptables.',
  // 34  ← "protection", "données" — archivage documentaire, pas RGPD
  'La conservation des archives numériques d\'entreprise obéit à des règles de durée légale : les documents comptables doivent être conservés 10 ans, les contrats commerciaux 5 ans, les bulletins de paie 5 ans.',
];

// ─────────────────────────────────────────────────────────────────────────────
// 12 REQUÊTES — dont 2 négatives (chunks attendus = -1)
// ─────────────────────────────────────────────────────────────────────────────

class _Query {
  final String id;
  final String query;
  final int expected;  // index chunk attendu, -1 = requête négative
  final String type;
  final String note;
  const _Query(this.id, this.query, this.expected, this.type, this.note);
}

const _queries = <_Query>[
  // Q1 — Synonyme SANS mot commun : "faire effacer" → chunk 2 (effacement)
  // "faire effacer mes informations" ≠ aucun de ces mots dans chunk 2
  _Query('Q01', 'Je veux faire effacer mes informations de leurs fichiers',
      2, 'synonyme sans mot commun',
      'effacer/infos → droit à l\'oubli/suppression/données (chunk 2)'),

  // Q2 — Paraphrase : "amende record" → chunk 5 (4% CA)
  _Query('Q02', 'Quelle est l\'amende record possible pour un géant du numérique ?',
      5, 'paraphrase',
      'amende record géant numérique → 4% CA / 20M€ (chunk 5)'),

  // Q3 — Formulation implicite : "prévenir en cas d'incident" → chunk 4 (72h)
  _Query('Q03', 'Que doit faire une entreprise si elle découvre qu\'un pirate a accédé à ses fichiers clients ?',
      4, 'formulation implicite',
      'pirate/fichiers clients → notification 72h (chunk 4) — PAS chunk 11 sécurité'),

  // Q4 — Acronyme fr→en : "DPD" (mauvais acronyme français) → chunk 3
  _Query('Q04', 'Qu\'est-ce que le DPD et pourquoi les grandes entreprises doivent-elles en nommer un ?',
      3, 'acronyme fr alternatif',
      'DPD (délégué protection données, terme FR) → DPO (chunk 3)'),

  // Q5 — Recherche inter-document : sécurité informatique + RGPD
  // "ransomware et données personnelles" doit retourner chunk 10 (ransomware), pas chunk 4
  _Query('Q05', 'Quels sont les risques d\'une attaque par rançongiciel pour une organisation ?',
      10, 'inter-doc sécurité/RGPD',
      'rançongiciel → ransomware (chunk 10), distracteur chunk 4 (faille sécu)'),

  // Q6 — Terme ambigu : "violation" présent dans chunks 4, 11, 33
  // Requête RGPD-spécifique doit aller vers chunk 4, pas 11 ou 33
  _Query('Q06', 'Quelle est l\'obligation légale après une violation de données personnelles ?',
      4, 'terme ambigu (violation)',
      'violation données personnelles → obligation 72h RGPD (chunk 4), distracteurs 11 et 33'),

  // Q7 — Mixte fr/en : "GDPR data subject rights" → chunk 1 (droit d'accès)
  _Query('Q07', 'GDPR data subject access rights',
      1, 'mixte fr/en',
      'GDPR data subject rights → droit d\'accès (chunk 1)'),

  // Q8 — Droit travail sans mot explicite : "heures sup" → chunk 16 (35h)
  _Query('Q08', 'Combien d\'heures par semaine un salarié peut-il travailler normalement ?',
      16, 'paraphrase droit travail',
      'heures semaine normalement → 35h légal (chunk 16)'),

  // Q9 — Contrat : "NDA" (acronyme anglais) → chunk 19 (clause confidentialité)
  _Query('Q09', 'Qu\'est-ce qu\'un NDA et dans quel contexte est-il utilisé ?',
      19, 'acronyme anglais',
      'NDA → clause de confidentialité (chunk 19)'),

  // Q10 — Administration : "demander un document à la mairie" → chunk 26 (CADA/accès docs)
  _Query('Q10', 'Comment obtenir communication d\'un document officiel détenu par la mairie ?',
      26, 'administration formulation indirecte',
      'document officiel mairie → accès documents administratifs CADA (chunk 26)'),

  // Q11 — NÉGATIVE : requête hors corpus (physique quantique) → expected -1
  _Query('Q11', 'Quelle est la différence entre un qubit et un bit classique en informatique quantique ?',
      -1, 'NÉGATIVE — hors corpus',
      'Aucun chunk pertinent — le meilleur score cosinus doit rester bas'),

  // Q12 — NÉGATIVE : mots du corpus mais sens complètement différent
  // "données GPS navigation" → NI RGPD NI base de données SQL
  _Query('Q12', 'Comment les données GPS permettent-elles la navigation en temps réel dans une voiture ?',
      -1, 'NÉGATIVE — distracteur GPS',
      'données/GPS/temps réel → aucun chunk pertinent (ni RGPD ni SQL)'),
];

// ─────────────────────────────────────────────────────────────────────────────
// BM25 minimal (Okapi BM25, k1=1.5, b=0.75)
// ─────────────────────────────────────────────────────────────────────────────

class _Bm25 {
  static const double k1 = 1.5;
  static const double b  = 0.75;

  final List<Map<String, int>> _tf;
  final Map<String, int> _df;
  final int _n;
  final double _avgdl;

  _Bm25(List<String> docs)
      : _tf = docs.map(_tokenize).map(_freq).toList(),
        _df = _buildDf(docs.map(_tokenize).map(_freq).toList()),
        _n  = docs.length,
        _avgdl = docs.map(_tokenize).map((t) => t.length.toDouble())
            .fold(0.0, (a, b) => a + b) / docs.length;

  static List<String> _tokenize(String text) =>
      text.toLowerCase()
          .replaceAll(RegExp(r'[^a-zàâäéèêëîïôùûüç\s]'), ' ')
          .split(RegExp(r'\s+'))
          .where((w) => w.length > 2)
          .toList();

  static Map<String, int> _freq(List<String> tokens) {
    final m = <String, int>{};
    for (final t in tokens) m[t] = (m[t] ?? 0) + 1;
    return m;
  }

  static Map<String, int> _buildDf(List<Map<String, int>> tfs) {
    final df = <String, int>{};
    for (final tf in tfs) {
      for (final t in tf.keys) df[t] = (df[t] ?? 0) + 1;
    }
    return df;
  }

  List<double> scores(String query) {
    final qTokens = _tokenize(query);
    final results = List<double>.filled(_n, 0.0);
    for (final term in qTokens) {
      final df = _df[term] ?? 0;
      if (df == 0) continue;
      final idf = math.log((_n - df + 0.5) / (df + 0.5) + 1);
      for (var i = 0; i < _n; i++) {
        final tf = (_tf[i][term] ?? 0).toDouble();
        final dl = _tf[i].values.fold(0, (a, b) => a + b).toDouble();
        final denom = tf + k1 * (1 - b + b * dl / _avgdl);
        results[i] += idf * (tf * (k1 + 1)) / denom;
      }
    }
    return results;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Helpers cosine + topK
// ─────────────────────────────────────────────────────────────────────────────

double _cos(List<double> a, List<double> b) {
  double dot = 0, na = 0, nb = 0;
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

int _rank(List<double> scores, int expected) {
  if (expected < 0) return -1;
  final sorted = _topK(scores, scores.length);
  final pos = sorted.indexOf(expected);
  return pos < 0 ? -1 : pos + 1; // 1-based
}

// Pour requêtes négatives : retourner le meilleur score cosinus
double _bestScore(List<double> scores) =>
    scores.reduce((a, b) => a > b ? a : b);

// ─────────────────────────────────────────────────────────────────────────────
// TESTS
// ─────────────────────────────────────────────────────────────────────────────

void main() {
  group('RAG Phase 3B — Benchmark discriminant 35 chunks / 12 requêtes', () {

    late CrispEmbed miniLm;
    late List<List<double>> miniLmVecs;
    bool lmStudioAvail = false;
    List<List<double>>? lmVecs;
    late _Bm25 bm25;
    final Stopwatch indexSw = Stopwatch();

    // ─── setUpAll ──────────────────────────────────────────────────────
    setUpAll(() async {
      // MiniLM
      miniLm = CrispEmbed(_ggufPath, nThreads: 4,
          libPath: File(_dllPath).existsSync() ? _dllPath : null);
      indexSw.start();
      miniLmVecs = _chunks.map((c) => miniLm.encode(c).toList()).toList();
      indexSw.stop();
      print('\n  [MiniLM] Indexé ${_chunks.length} chunks en ${indexSw.elapsedMilliseconds} ms'
            ' (${(indexSw.elapsedMilliseconds / _chunks.length).toStringAsFixed(1)} ms/chunk)');

      // BM25 (aucune dépendance externe)
      bm25 = _Bm25(_chunks);

      // LM Studio (optionnel)
      try {
        final r = await http.post(Uri.parse(_lmStudioUrl),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'model': _lmStudioModel, 'input': 'test'}))
            .timeout(const Duration(seconds: 5));
        if (r.statusCode == 200) {
          lmStudioAvail = true;
          final tmp = <List<double>>[];
          for (final c in _chunks) {
            final rr = await http.post(Uri.parse(_lmStudioUrl),
                headers: {'Content-Type': 'application/json'},
                body: jsonEncode({'model': _lmStudioModel, 'input': c}));
            tmp.add((jsonDecode(rr.body)['data'][0]['embedding'] as List)
                .cast<double>());
          }
          lmVecs = tmp;
          print('  [LM Studio] Indexé ${_chunks.length} chunks, dim=${lmVecs!.first.length}');
        }
      } catch (_) {
        print('  [LM Studio] Non disponible — comparaison ignorée');
      }
    });

    tearDownAll(() => miniLm.dispose());

    // ─── IDX — Indexation ──────────────────────────────────────────────
    test('IDX : indexation ${_chunks.length} chunks', () {
      expect(miniLmVecs.length, equals(_chunks.length));
      expect(miniLmVecs.first.length, equals(384));
      print('\n  ${_chunks.length} chunks / dim 384 / ${indexSw.elapsedMilliseconds} ms');
    });

    // ─── BENCH PRINCIPAL ───────────────────────────────────────────────
    test('BENCH : 12 requêtes — Top-1 / Top-3 / Top-5 + BM25', () async {

      // Encoder les requêtes via LM Studio
      final lmQVecs = <List<double>?>[];
      if (lmStudioAvail) {
        for (final q in _queries) {
          final r = await http.post(Uri.parse(_lmStudioUrl),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({'model': _lmStudioModel, 'input': q.query}));
          lmQVecs.add((jsonDecode(r.body)['data'][0]['embedding'] as List)
              .cast<double>());
        }
      } else {
        for (var _ in _queries) lmQVecs.add(null);
      }

      // ── Résultats ──────────────────────────────────────────────────
      // Compteurs
      int miniTop1=0, miniTop3=0, miniTop5=0;
      int lmTop1=0,   lmTop3=0,   lmTop5=0;
      int bm25Top1=0, bm25Top3=0, bm25Top5=0;
      final miniMissTop3 = <String>[];
      final lmMissTop3   = <String>[];
      
      // Scores négatifs (requêtes sans chunk attendu)
      final negMiniScores  = <double>[];
      final negLmScores    = <double>[];
      final negBm25Scores  = <double>[];

      print('\n');
      print('='*110);
      print('BENCHMARK DISCRIMINANT — MiniLM IQ4_XS vs LM Studio Qwen3 vs BM25');
      print('Corpus : ${_chunks.length} chunks | Requêtes : ${_queries.length}');
      print('='*110);
      print('');
      print(
        '${'ID'.padRight(4)} | ${'Type'.padRight(28)} | '
        '${'Mini T1/T3/T5'.padRight(16)} | ${'Qwen3 T1/T3/T5'.padRight(16)} | ${'BM25 T1/T3/T5'.padRight(16)} | '
        'Note'
      );
      print('-'*140);

      for (var i = 0; i < _queries.length; i++) {
        final q = _queries[i];
        final isNeg = q.expected < 0;

        // MiniLM scores
        final miniQVec = miniLm.encode(q.query).toList();
        final miniScores = miniLmVecs
            .map((cv) => _cos(miniQVec, cv)).toList();

        // LM Studio scores
        final lmQVec  = lmQVecs[i];
        final lmScores = lmQVec != null
            ? lmVecs!.map((cv) => _cos(lmQVec, cv)).toList()
            : null;

        // BM25 scores
        final bm25Scores = bm25.scores(q.query);

        if (!isNeg) {
          // ── Requêtes normales ──────────────────────────────────
          final mRank = _rank(miniScores, q.expected);
          final lRank = lmScores != null ? _rank(lmScores, q.expected) : -1;
          final bRank = _rank(bm25Scores.map((s) => s).toList(), q.expected);

          if (mRank == 1) miniTop1++;
          if (mRank >= 1 && mRank <= 3) miniTop3++;
          if (mRank >= 1 && mRank <= 5) miniTop5++;
          if (lRank == 1) lmTop1++;
          if (lRank >= 1 && lRank <= 3) lmTop3++;
          if (lRank >= 1 && lRank <= 5) lmTop5++;
          if (bRank == 1) bm25Top1++;
          if (bRank >= 1 && bRank <= 3) bm25Top3++;
          if (bRank >= 1 && bRank <= 5) bm25Top5++;

          if (mRank < 0 || mRank > 3) miniMissTop3.add(q.id);
          if (lRank < 0 || lRank > 3) lmMissTop3.add(q.id);

          final mT3 = (mRank >= 1 && mRank <= 3) ? '✅' : '❌';
          final mT5 = (mRank >= 1 && mRank <= 5) ? '✅' : '❌';
          final mStr = '${mRank > 0 ? "✅ r$mRank" : "❌ —"}/$mT3/$mT5';
          final lT3 = (lRank >= 1 && lRank <= 3) ? '✅' : '❌';
          final lT5 = (lRank >= 1 && lRank <= 5) ? '✅' : '❌';
          final lStr = lRank >= 0
              ? '${lRank > 0 ? "✅ r$lRank" : "❌ —"}/$lT3/$lT5'
              : '— N/A';
          final bT3 = (bRank >= 1 && bRank <= 3) ? '✅' : '❌';
          final bT5 = (bRank >= 1 && bRank <= 5) ? '✅' : '❌';
          final bStr = '${bRank > 0 ? "✅ r$bRank" : "❌ —"}/$bT3/$bT5';
          print(
            '${q.id.padRight(4)} | ${q.type.padRight(28)} | '
            '${mStr.padRight(16)} | ${lStr.padRight(16)} | ${bStr.padRight(16)} | '
            '${q.note.substring(0, math.min(50, q.note.length))}'
          );

        } else {
          // ── Requêtes négatives ─────────────────────────────────
          final mBest = _bestScore(miniScores);
          final lBest = lmScores != null ? _bestScore(lmScores) : -1.0;
          final bBest = _bestScore(bm25Scores);
          negMiniScores.add(mBest);
          if (lBest >= 0) negLmScores.add(lBest);
          negBm25Scores.add(bBest);

          // Chunk le plus proche (pour analyse)
          final mTop1Chunk = _topK(miniScores, 1).first;
          print(
            '${q.id.padRight(4)} | ${'[NEG] ${q.type}'.padRight(28)} | '
            'best cos=${mBest.toStringAsFixed(3)} (c$mTop1Chunk) | '
            'LM=${lBest >= 0 ? lBest.toStringAsFixed(3) : "N/A"} | '
            'BM25=${bBest.toStringAsFixed(3)} | ${q.query.substring(0, math.min(45, q.query.length))}'
          );
        }
      }

      // ── Comptage requêtes positives ─────────────────────────────
      final nPos = _queries.length - 2; // 10 requêtes positives
      
      print('');
      print('─'*110);
      print('SCORES sur $nPos requêtes positives :');
      print('');
      print('  ${'Modèle'.padRight(30)} | Top-1 | Top-3 | Top-5 | Miss Top-3');
      print('  ${'─'*70}');
      print('  ${'MiniLM IQ4_XS (19 MB, CPU)'.padRight(30)} | ${miniTop1.toString().padLeft(3)}/$nPos | ${miniTop3.toString().padLeft(3)}/$nPos | ${miniTop5.toString().padLeft(3)}/$nPos | ${miniMissTop3.isEmpty ? "aucun" : miniMissTop3.join(", ")}');
      print('  ${'LM Studio Qwen3 (2560d)'.padRight(30)} | ${lmTop1.toString().padLeft(3)}/$nPos | ${lmTop3.toString().padLeft(3)}/$nPos | ${lmTop5.toString().padLeft(3)}/$nPos | ${lmMissTop3.isEmpty ? "aucun" : lmMissTop3.join(", ")}');
      print('  ${'BM25 (lexical pur)'.padRight(30)} | ${bm25Top1.toString().padLeft(3)}/$nPos | ${bm25Top3.toString().padLeft(3)}/$nPos | ${bm25Top5.toString().padLeft(3)}/$nPos | —');
      print('');

      // ── Requêtes négatives ─────────────────────────────────────
      print('REQUÊTES NÉGATIVES (score cosinus max — doit être faible) :');
      for (var i = 0; i < negMiniScores.length; i++) {
        print('  ${_queries[_queries.length - 2 + i].id}: MiniLM=${negMiniScores[i].toStringAsFixed(3)}'
            '${negLmScores.isNotEmpty ? "  LM Studio=${negLmScores[i].toStringAsFixed(3)}" : ""}'
            '  BM25=${negBm25Scores[i].toStringAsFixed(3)}');
      }

      // ── Assertions de seuils ───────────────────────────────────
      // Top-3 ≥ 7/10 pour PASS
      expect(miniTop3, greaterThanOrEqualTo(7),
          reason: 'MiniLM doit trouver au moins 7/10 résultats dans Top-3');
      // Valeur apportée vs BM25
      expect(miniTop3, greaterThanOrEqualTo(bm25Top3),
          reason: 'MiniLM doit faire au moins aussi bien que BM25 en Top-3');
    });

  });
}
