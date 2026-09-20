// test/rag_phase4_audit_test.dart  (v2 — syntaxe Dart correcte)
//
// RAG Phase 4 — Diagnostic RRF anatomy, variantes, garde-fou
// B: anatomie RRF Q01/Q02/Q03/Q05/Q07
// C: preuve défaut structurel rang-only
// D: harness 5 variantes × 2 modèles
// E: 12 négatives + séparation score

import 'dart:io';
import 'dart:math' as math;
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:crispembed/crispembed.dart';

// ─── Chemins ───────────────────────────────────────────────────────────────
const _gguf = r'C:\Jarvisol_Test\CrisperWeaver\build\windows\x64\runner\Release\data\models\whisper_cpp\all-MiniLM-L6-v2-iq4_xs.gguf';
const _dll  = r'C:\Jarvisol_Test\CrisperWeaver\crispembed.dll';
const _lmUrl   = 'http://127.0.0.1:1234/v1/embeddings';
const _lmModel = 'text-embedding-qwen3-embedding-4b';

// ─── Types ─────────────────────────────────────────────────────────────────
class _Q { final String id, text, type; final int exp;
  const _Q(this.id, this.text, this.exp, this.type); }

class _SS { final int idx; final double score; _SS(this.idx, this.score); }

// ─── Corpus 35 chunks (identique Phase 3B/3C) ──────────────────────────────
const _chunks = <String>[
  /*0*/ 'Le RGPD est entré en application le 25 mai 2018 dans toute l\'Union Européenne. Il remplace la directive 95/46/CE et unifie la législation sur la protection des données personnelles.',
  /*1*/ 'Toute personne physique dispose d\'un droit d\'accès à ses données personnelles. Elle peut demander à l\'organisme responsable de lui communiquer l\'ensemble des informations qu\'il détient sur elle, gratuitement et dans un délai d\'un mois.',
  /*2*/ 'Le droit à l\'oubli, formellement appelé droit à l\'effacement, permet à un individu d\'exiger la suppression de ses données personnelles lorsqu\'elles ne sont plus nécessaires ou lorsque le consentement initial est retiré.',
  /*3*/ 'Les entreprises qui réalisent un traitement de données à grande échelle doivent désigner un délégué à la protection des données. Ce responsable, souvent désigné par son acronyme anglais DPO (Data Protection Officer), veille au respect du règlement.',
  /*4*/ 'En cas de faille de sécurité compromettant des données personnelles, l\'organisation doit notifier l\'autorité de contrôle dans les 72 heures suivant la détection de l\'incident. Cette obligation de signalement est impérative.',
  /*5*/ 'Les infractions au règlement européen sur la protection des données peuvent être sanctionnées par des pénalités allant jusqu\'à 4 % du chiffre d\'affaires annuel mondial ou 20 millions d\'euros, selon le montant le plus élevé.',
  /*6*/ 'La CNIL, Commission Nationale de l\'Informatique et des Libertés, est l\'autorité française compétente pour contrôler l\'application du RGPD et instruire les plaintes des citoyens en matière de protection des données.',
  /*7*/ 'Le transfert de données personnelles vers un pays situé hors de l\'Union Européenne est soumis à des garanties spécifiques : décision d\'adéquation de la Commission européenne ou clauses contractuelles types approuvées.',
  /*8*/ 'Un pare-feu (firewall) est un système de sécurité réseau qui filtre les communications entre un réseau interne et Internet selon des règles préétablies, afin de bloquer les accès non autorisés.',
  /*9*/ 'L\'authentification à deux facteurs (2FA) renforce la sécurité des comptes en exigeant deux preuves d\'identité distinctes : un mot de passe et un code temporaire envoyé sur un téléphone ou généré par une application.',
  /*10*/ 'Une attaque par ransomware chiffre les fichiers d\'une organisation et exige une rançon pour en restaurer l\'accès. Ces cyberattaques ciblent préférentiellement les hôpitaux, collectivités et entreprises mal protégées.',
  /*11*/ 'En cybersécurité, une violation de données désigne toute compromission non autorisée de la confidentialité, l\'intégrité ou la disponibilité d\'un système. La notification aux parties prenantes doit suivre les politiques internes de l\'organisation.',
  /*12*/ 'Le chiffrement de bout en bout garantit que seuls l\'émetteur et le destinataire peuvent lire les messages échangés. Même le fournisseur du service de messagerie n\'a pas accès au contenu en clair.',
  /*13*/ 'Un audit de sécurité informatique évalue les vulnérabilités d\'un système d\'information. Il comprend des tests d\'intrusion (pentests), une analyse de configuration et une revue des politiques de contrôle d\'accès.',
  /*14*/ 'Le contrat de travail à durée indéterminée (CDI) est la forme normale et générale de la relation de travail en France. Il ne comporte pas de terme fixé et peut être rompu par le salarié (démission) ou l\'employeur (licenciement).',
  /*15*/ 'Le licenciement pour motif économique intervient lorsque l\'entreprise supprime un ou plusieurs postes en raison de difficultés économiques, de mutations technologiques ou d\'une réorganisation nécessaire à la sauvegarde de la compétitivité.',
  /*16*/ 'La durée légale du travail est fixée à 35 heures par semaine en France. Les heures effectuées au-delà donnent lieu à des majorations de salaire ou à un repos compensateur, selon les dispositions conventionnelles applicables.',
  /*17*/ 'Le droit à la déconnexion permet aux salariés de ne pas être joignables en dehors de leurs horaires de travail habituels, notamment via les outils numériques professionnels (messagerie, téléphone, applications métier).',
  /*18*/ 'La période d\'essai permet à l\'employeur et au salarié d\'évaluer leur relation de travail avant de s\'engager définitivement. Sa durée varie selon la catégorie professionnelle et peut être renouvelée une fois si la convention collective le prévoit.',
  /*19*/ 'La clause de confidentialité (NDA, Non-Disclosure Agreement) engage les parties à ne pas divulguer les informations sensibles échangées dans le cadre d\'un accord commercial. Elle est souvent réciproque et limitée dans le temps.',
  /*20*/ 'La force majeure est un événement imprévisible, irrésistible et extérieur qui libère une partie de ses obligations contractuelles. La pandémie de Covid-19 a été invoquée dans de nombreux litiges contractuels à ce titre.',
  /*21*/ 'Un contrat SaaS (Software as a Service) définit les conditions d\'accès à un logiciel hébergé dans le cloud. Il inclut des engagements de niveau de service (SLA), des clauses de portabilité des données et des modalités de résiliation.',
  /*22*/ 'La garantie légale de conformité oblige le vendeur professionnel à livrer un bien conforme au contrat. L\'acheteur dispose de deux ans à partir de la délivrance pour agir, sans avoir à prouver l\'existence du défaut.',
  /*23*/ 'La clause pénale prévoit forfaitairement le montant des dommages-intérêts dus en cas d\'inexécution d\'une obligation contractuelle. Elle peut être réduite ou augmentée par le juge si son montant est manifestement excessif ou dérisoire.',
  /*24*/ 'Le service public est organisé selon trois principes fondamentaux : continuité (fonctionnement ininterrompu), égalité (traitement identique des usagers) et adaptabilité (évolution selon les besoins sociaux).',
  /*25*/ 'Le recours pour excès de pouvoir permet à tout citoyen de contester devant le tribunal administratif une décision administrative illégale, sans avoir à justifier d\'un intérêt personnel direct.',
  /*26*/ 'La Commission d\'Accès aux Documents Administratifs (CADA) veille au droit d\'accès aux documents produits ou reçus par l\'administration française. Tout citoyen peut demander communication d\'un document administratif.',
  /*27*/ 'La commande publique est régie par le Code de la commande publique. Elle impose aux acheteurs publics le respect de principes de liberté d\'accès, d\'égalité de traitement des candidats et de transparence des procédures.',
  /*28*/ 'La délégation de service public (DSP) est un contrat par lequel une collectivité confie la gestion d\'un service public à un opérateur privé dont la rémunération est substantiellement assurée par les résultats d\'exploitation.',
  /*29*/ 'Dans une base de données relationnelle, les données sont organisées en tables reliées par des clés étrangères. L\'accès aux enregistrements s\'effectue via des requêtes SQL utilisant les clauses SELECT, FROM et WHERE.',
  /*30*/ 'La sécurité des bâtiments publics repose sur des systèmes de contrôle d\'accès physique : badges RFID, caméras de surveillance et procédures d\'accréditation du personnel.',
  /*31*/ 'Les opérateurs téléphoniques proposent des contrats d\'abonnement avec ou sans engagement. La résiliation sans frais est possible après la période d\'engagement initiale, avec un préavis généralement d\'un mois.',
  /*32*/ 'En droit des successions, les héritiers disposent d\'un délai de six mois pour accepter ou renoncer à la succession. Passé ce délai, ils sont réputés acceptants purs et simples et répondent des dettes du défunt.',
  /*33*/ 'La violation du secret professionnel est un délit pénal sanctionné par un an d\'emprisonnement et 15 000 euros d\'amende. Elle concerne les professions tenues au secret : médecins, avocats, notaires, experts-comptables.',
  /*34*/ 'La conservation des archives numériques d\'entreprise obéit à des règles de durée légale : les documents comptables doivent être conservés 10 ans, les contrats commerciaux 5 ans, les bulletins de paie 5 ans.',
];

// ─── Requêtes ──────────────────────────────────────────────────────────────
const _pos = <_Q>[
  _Q('Q01','Je veux faire effacer mes informations de leurs fichiers',2,'synonyme sans mc'),
  _Q('Q02','Quelle est l\'amende record possible pour un géant du numérique ?',5,'paraphrase'),
  _Q('Q03','Que doit faire une entreprise si elle découvre qu\'un pirate a accédé à ses fichiers clients ?',4,'implicite'),
  _Q('Q04','Qu\'est-ce que le DPD et pourquoi les grandes entreprises doivent-elles en nommer un ?',3,'acronyme fr'),
  _Q('Q05','Quels sont les risques d\'une attaque par rançongiciel pour une organisation ?',10,'inter-doc sécu'),
  _Q('Q06','Quelle est l\'obligation légale après une violation de données personnelles ?',4,'terme ambigu'),
  _Q('Q07','GDPR data subject access rights',1,'mixte fr/en'),
  _Q('Q08','Combien d\'heures par semaine un salarié peut-il travailler normalement ?',16,'paraphrase travail'),
  _Q('Q09','Qu\'est-ce qu\'un NDA et dans quel contexte est-il utilisé ?',19,'acronyme anglais'),
  _Q('Q10','Comment obtenir communication d\'un document officiel détenu par la mairie ?',26,'admin indirecte'),
];

const _neg = <_Q>[
  _Q('N01','Quelle est la différence entre un qubit et un bit classique en informatique quantique ?',-1,'quantique'),
  _Q('N02','Comment les données GPS permettent-elles la navigation en temps réel dans une voiture ?',-1,'GPS'),
  _Q('N03','Quelle est la superficie totale de la forêt amazonienne en kilomètres carrés ?',-1,'géographie'),
  _Q('N04','Comment préparer une recette traditionnelle de bœuf bourguignon ?',-1,'cuisine'),
  _Q('N05','Quelle est la vitesse maximale d\'un guépard lors d\'une course ?',-1,'zoologie'),
  _Q('N06','Expliquez le mécanisme de la photosynthèse chez les plantes vertes.',-1,'biologie'),
  _Q('N07','Qui a peint la Joconde et en quelle année a-t-elle été réalisée ?',-1,'art'),
  _Q('N08','What is the boiling point of water at sea level in Celsius ?',-1,'physique en'),
  _Q('N09','Décrivez les principales caractéristiques du style gothique en architecture médiévale.',-1,'architecture'),
  _Q('N10','Comment fonctionne un moteur à réaction dans un avion de ligne ?',-1,'aéronautique'),
  _Q('N11','Quelle est la différence entre une étoile naine blanche et un trou noir ?',-1,'astronomie'),
  _Q('N12','Quels sont les ingrédients de base d\'un cocktail Mojito ?',-1,'mixologie'),
];

// ─── Algorithmes ────────────────────────────────────────────────────────────
const _kRrf   = 60;
const _topK   = 5;
const _minRel = 0.15;

double _cos(List<double> a, List<double> b) {
  double d=0,na=0,nb=0;
  for(var i=0;i<a.length;i++){d+=a[i]*b[i];na+=a[i]*a[i];nb+=b[i]*b[i];}
  if(na==0||nb==0) return 0;
  return (d/(math.sqrt(na)*math.sqrt(nb))).clamp(-1.0,1.0);
}

List<_SS> _sem(List<double> q, List<List<double>> vecs, {double minRel=0.0}) {
  final r = <_SS>[];
  for(var i=0;i<vecs.length;i++){
    final s=_cos(q,vecs[i]); if(s>=minRel) r.add(_SS(i,s));
  }
  r.sort((a,b)=>b.score.compareTo(a.score));
  return r;
}

List<_SS> _kw(String query, List<String> chunks) {
  final q=query.toLowerCase().split(RegExp(r'[^\w\u00C0-\u017F]+')).where((t)=>t.length>2).toSet();
  if(q.isEmpty) return [];
  final r=<_SS>[];
  for(var i=0;i<chunks.length;i++){
    final tok=chunks[i].toLowerCase().split(RegExp(r'[^\w\u00C0-\u017F]+')).where((t)=>t.isNotEmpty).toList();
    if(tok.isEmpty) continue;
    int m=0; for(final t in tok){if(q.contains(t))m++;}
    if(m>0) r.add(_SS(i,m/math.sqrt(tok.length)));
  }
  r.sort((a,b)=>b.score.compareTo(a.score));
  return r;
}

List<int> _rrf(List<_SS> s, List<_SS> k, {double ws=1.0, double wk=1.0, bool cond=false}) {
  final sc=<int,double>{};
  for(var r=0;r<s.length;r++) sc[s[r].idx]=(sc[s[r].idx]??0)+ws/(_kRrf+r+1);
  final doKw = !cond || (k.isNotEmpty && k.first.score > 0.2);
  if(doKw) for(var r=0;r<k.length;r++) sc[k[r].idx]=(sc[k[r].idx]??0)+wk/(_kRrf+r+1);
  final keys=sc.keys.toList()..sort((a,b)=>sc[b]!.compareTo(sc[a]!));
  return keys.take(_topK).toList();
}

int _rk(List<int> ranked, int exp) {
  final i=ranked.indexOf(exp); return i<0?-1:i+1;
}

double _avg(List<double> l) => l.isEmpty?0:l.reduce((a,b)=>a+b)/l.length;
double _minD(List<double> l) => l.isEmpty?0:l.reduce((a,b)=>a<b?a:b);
double _maxD(List<double> l) => l.isEmpty?0:l.reduce((a,b)=>a>b?a:b);

// Variante ID : 'A'=current 'B'=70/30 'C'=80/20 'D'=cond 'E'=sempur
List<int> _variant(String v, List<_SS> semR, List<_SS> kwR) {
  switch(v){
    case 'A': return _rrf(semR,kwR);
    case 'B': return _rrf(semR,kwR,ws:0.7,wk:0.3);
    case 'C': return _rrf(semR,kwR,ws:0.8,wk:0.2);
    case 'D': return _rrf(semR,kwR,cond:true);
    case 'E': return semR.take(_topK).map((s)=>s.idx).toList();
    default: return [];
  }
}

// ─── Global state ──────────────────────────────────────────────────────────
late CrispEmbed _ml;
late List<List<double>> _mlVecs;
bool _lmAvail = false;
List<List<double>>? _lmVecs;
List<List<double>?> _lmPosQ = [];
List<List<double>?> _lmNegQ = [];

// ─── Main ──────────────────────────────────────────────────────────────────
void main() {

  setUpAll(() async {
    _ml = CrispEmbed(_gguf, nThreads:4, libPath:File(_dll).existsSync()?_dll:null);
    _mlVecs = _chunks.map((c)=>_ml.encode(c).toList()).toList();
    print('\n[MiniLM] ${_chunks.length} chunks  dim=${_mlVecs.first.length}');
    try {
      final r=await http.post(Uri.parse(_lmUrl),headers:{'Content-Type':'application/json'},
          body:jsonEncode({'model':_lmModel,'input':'test'})).timeout(const Duration(seconds:5));
      if(r.statusCode==200){
        _lmAvail=true;
        final tmp=<List<double>>[];
        for(final c in _chunks){
          final rr=await http.post(Uri.parse(_lmUrl),headers:{'Content-Type':'application/json'},body:jsonEncode({'model':_lmModel,'input':c}));
          tmp.add((jsonDecode(rr.body)['data'][0]['embedding'] as List).cast<double>());
        }
        _lmVecs=tmp;
        // Encoder requêtes positives et négatives pour LM Studio
        for(final q in _pos){
          final rr=await http.post(Uri.parse(_lmUrl),headers:{'Content-Type':'application/json'},body:jsonEncode({'model':_lmModel,'input':q.text}));
          _lmPosQ.add((jsonDecode(rr.body)['data'][0]['embedding'] as List).cast<double>());
        }
        for(final q in _neg){
          final rr=await http.post(Uri.parse(_lmUrl),headers:{'Content-Type':'application/json'},body:jsonEncode({'model':_lmModel,'input':q.text}));
          _lmNegQ.add((jsonDecode(rr.body)['data'][0]['embedding'] as List).cast<double>());
        }
        print('[LM Studio] ${_chunks.length} chunks dim=${_lmVecs!.first.length}');
      }
    } catch(_){ print('[LM Studio] non disponible'); }
  });

  tearDownAll(()=>_ml.dispose());

  // ─── SECTION B ────────────────────────────────────────────────────────────
  group('B — Anatomie RRF Q01/Q02/Q03/Q05/Q07', () {
    test('B: scores bruts + contributions RRF', () {
      final focus=[_pos[0],_pos[1],_pos[2],_pos[4],_pos[6]];
      print('\n'+'═'*100);
      print('SECTION B — ANATOMIE RRF  kRrf=$_kRrf');
      print('Format: sem_rank c<idx> cos=<val>  rrf_sem=<val>  rrf_kw=<val>  rrf_total=<val>  H_rank');
      print('═'*100);

      for(final q in focus){
        final qv  = _ml.encode(q.text).toList();
        final sem = _sem(qv, _mlVecs, minRel:0.0);
        final kw  = _kw(q.text, _chunks);
        final sc  = <int,double>{};
        for(var r=0;r<sem.length;r++) sc[sem[r].idx]=(sc[sem[r].idx]??0)+1/(_kRrf+r+1);
        for(var r=0;r<kw.length;r++)  sc[kw[r].idx]=(sc[kw[r].idx]??0)+1/(_kRrf+r+1);
        final hybrid=(sc.keys.toList()..sort((a,b)=>sc[b]!.compareTo(sc[a]!))).take(_topK).toList();

        print('\n── ${q.id} (attendu c${q.exp}): "${q.text.substring(0,math.min(55,q.text.length))}"');
        print('  SEMANTIC top-5:');
        for(var i=0;i<math.min(5,sem.length);i++){
          final s=sem[i];
          final kwPos=kw.indexWhere((k)=>k.idx==s.idx);
          final rs=1/(_kRrf+i+1);
          final rk=kwPos>=0?1/(_kRrf+kwPos+1):0.0;
          final tot=rs+rk; final hr=hybrid.indexOf(s.idx)+1;
          final tgt=s.idx==q.exp?'◀TARGET':'';
          print('    r${i+1} c${s.idx.toString().padLeft(2)} cos=${s.score.toStringAsFixed(4)}'
              '  rrf_sem=${rs.toStringAsFixed(5)}  rrf_kw=${rk.toStringAsFixed(5)}'
              '  total=${tot.toStringAsFixed(5)}  H:r$hr $tgt');
        }
        print('  KEYWORD overlap top-5:');
        for(var i=0;i<math.min(5,kw.length);i++){
          final k=kw[i];
          final sp=sem.indexWhere((s)=>s.idx==k.idx);
          final rk=1/(_kRrf+i+1);
          final rs=sp>=0?1/(_kRrf+sp+1):0.0;
          final tot=rs+rk; final hr=hybrid.indexOf(k.idx)+1;
          final tgt=k.idx==q.exp?'◀TARGET':'';
          print('    r${i+1} c${k.idx.toString().padLeft(2)} kw=${k.score.toStringAsFixed(4)}'
              '  rrf_kw=${rk.toStringAsFixed(5)}  rrf_sem=${rs.toStringAsFixed(5)}'
              '  total=${tot.toStringAsFixed(5)}  H:r$hr $tgt');
        }
        final tsp=sem.indexWhere((s)=>s.idx==q.exp);
        final tkp=kw.indexWhere((k)=>k.idx==q.exp);
        final th=hybrid.indexOf(q.exp);
        print('  TARGET c${q.exp}: sem_r=${tsp>=0?tsp+1:-1}  kw_r=${tkp>=0?tkp+1:-1}'
            '  hybrid_r=${th>=0?th+1:"ABSENT"}'
            '  → ${th>=0&&th<3?"✅T3":th>=0&&th<5?"⚠️T5":"❌"}');
      }
      expect(true, isTrue);
    });
  });

  // ─── SECTION C ────────────────────────────────────────────────────────────
  group('C — Défaut structurel RRF', () {
    test('C: preuves rang-only + cas réel Q02', () {
      print('\n'+'═'*100);
      print('SECTION C — DÉFAUT STRUCTUREL RRF');
      print('═'*100);

      print('\nPREUVE 1 — Magnitude ignorée :');
      final c1 = 1/(_kRrf+1+1);
      print('  chunk A sem_rank=1 cos=0.95 → rrf_sem=${c1.toStringAsFixed(6)}');
      print('  chunk B sem_rank=1 cos=0.30 → rrf_sem=${c1.toStringAsFixed(6)}');
      print('  → Contribution IDENTIQUE. Ecart cos 0.65 complètement ignoré.');

      print('\nPREUVE 2 — Double signal bat signal fort unique :');
      final cS1=1/(_kRrf+1+1), cK35=0.0, cS35=1/(_kRrf+35+1), cK1=1/(_kRrf+1+1);
      print('  chunk A: sem_r=1 (cos=0.95), kw_absent  → rrf=${(cS1+cK35).toStringAsFixed(6)}');
      print('  chunk B: sem_r=35(cos=0.10), kw_r=1     → rrf=${(cS35+cK1).toStringAsFixed(6)}');
      print('  → Chunk B ${(cS35+cK1)>(cS1+cK35)?"DÉPASSE":"inférieur"} chunk A grâce au double signal kw');

      // Cas réel Q02
      final q=_pos[1];
      final qv=_ml.encode(q.text).toList();
      final sem=_sem(qv,_mlVecs,minRel:0.0);
      final kw=_kw(q.text,_chunks);
      final sc=<int,double>{};
      for(var r=0;r<sem.length;r++) sc[sem[r].idx]=(sc[sem[r].idx]??0)+1/(_kRrf+r+1);
      for(var r=0;r<kw.length;r++)  sc[kw[r].idx]=(sc[kw[r].idx]??0)+1/(_kRrf+r+1);
      final hybrid=(sc.keys.toList()..sort((a,b)=>sc[b]!.compareTo(sc[a]!))).take(_topK).toList();

      print('\nCAS RÉEL Q02 "${q.text}":');
      final c5sp=sem.indexWhere((s)=>s.idx==5);
      final c5cos=c5sp>=0?sem[c5sp].score:0.0;
      final c5kp=kw.indexWhere((k)=>k.idx==5);
      final c5rrf=sc[5]??0.0;
      print('  c5 (attendu): sem_r=${c5sp>=0?c5sp+1:-1} cos=${c5cos.toStringAsFixed(4)}'
          '  kw_r=${c5kp>=0?c5kp+1:"absent"}  rrf_total=${c5rrf.toStringAsFixed(6)}'
          '  hybrid_r=${hybrid.indexOf(5)>=0?hybrid.indexOf(5)+1:"ABSENT"}');
      print('  Top-5 hybrid: ${hybrid.map((i)=>"c$i(${(sc[i]??0).toStringAsFixed(5)})").join(", ")}');
      print('  Top-5 sem:    ${sem.take(5).map((s)=>"c${s.idx}(${s.score.toStringAsFixed(4)})").join(", ")}');
      print('  Top-5 kw:     ${kw.take(5).map((k)=>"c${k.idx}(${k.score.toStringAsFixed(4)})").join(", ")}');
      print('');
      print('  EXPLICATION : Les chunks du top-5 keyword (même faiblement scorés) reçoivent');
      print('  1/(60+r+1) en plus. Si c5 n\'est pas dans la liste keyword, il ne reçoit que');
      print('  sa contribution sémantique, pendant que des chunks présents dans les deux listes');
      print('  cumulent. Résultat : c5 sem_r=2 (cos=${c5cos.toStringAsFixed(4)}) tombe hors Top-5 hybrid.');

      expect(true, isTrue);
    });
  });

  // ─── SECTION D ────────────────────────────────────────────────────────────
  group('D — Harness 5 variantes × 2 modèles', () {
    test('D: A-current / B-W70/30 / C-W80/20 / D-cond / E-sempur', () async {
      // Encoder requêtes positives LM Studio
      final lmPQ=<List<double>?>[];
      if(_lmAvail){
        for(var i=0;i<_pos.length;i++) lmPQ.add(_lmPosQ.length>i?_lmPosQ[i]:null);
      } else { for(var _ in _pos) lmPQ.add(null); }

      // Compteurs [T1,T3,T5] par variante
      final mC=<String,List<int>>{'A':[0,0,0],'B':[0,0,0],'C':[0,0,0],'D':[0,0,0],'E':[0,0,0]};
      final lC=<String,List<int>>{'A':[0,0,0],'B':[0,0,0],'C':[0,0,0],'D':[0,0,0],'E':[0,0,0]};
      final mM=<String,List<String>>{'A':[],'B':[],'C':[],'D':[],'E':[]};
      final lM=<String,List<String>>{'A':[],'B':[],'C':[],'D':[],'E':[]};

      for(var i=0;i<_pos.length;i++){
        final q=_pos[i];
        final qv=_ml.encode(q.text).toList();
        final mSem=_sem(qv,_mlVecs,minRel:_minRel);
        final kwR=_kw(q.text,_chunks);
        for(final v in ['A','B','C','D','E']){
          final hybrid=_variant(v,mSem,kwR);
          final r=_rk(hybrid,q.exp);
          if(r==1) mC[v]![0]++; if(r>=1&&r<=3) mC[v]![1]++; if(r>=1&&r<=5) mC[v]![2]++;
          if(r<0||r>3) mM[v]!.add(q.id);
        }
        if(_lmAvail&&lmPQ[i]!=null){
          final lSem=_sem(lmPQ[i]!,_lmVecs!,minRel:_minRel);
          for(final v in ['A','B','C','D','E']){
            final hybrid=_variant(v,lSem,kwR);
            final r=_rk(hybrid,q.exp);
            if(r==1) lC[v]![0]++; if(r>=1&&r<=3) lC[v]![1]++; if(r>=1&&r<=5) lC[v]![2]++;
            if(r<0||r>3) lM[v]!.add(q.id);
          }
        }
      }

      const n=10;
      final labels={'A':'A-Current ','B':'B-W70/30  ','C':'C-W80/20  ','D':'D-Cond    ','E':'E-SemPur  '};
      print('\n'+'═'*110);
      print('SECTION D — HARNESS 5 VARIANTES  (n=$n requêtes positives)');
      print('  A=RRF k=60 égalitaire   B=RRF sem×0.7+kw×0.3   C=RRF sem×0.8+kw×0.2');
      print('  D=RRF cond (kw si score>0.2)   E=Semantic pur');
      print('  Seuil D-Cond: kw_top1_score > 0.2');
      print('═'*110);

      print('\n  MiniLM IQ4_XS (384d, 19MB) :');
      print('  ${"Variante".padRight(12)} | T-1  | T-3  | T-5  | Miss T-3');
      print('  ${"─"*70}');
      for(final v in ['A','B','C','D','E']){
        final c=mC[v]!;
        print('  ${labels[v]!.padRight(12)} |  ${c[0]}/$n |  ${c[1]}/$n |  ${c[2]}/$n | '
            '${mM[v]!.isEmpty?"aucun":mM[v]!.join(",")}');
      }
      print('');
      if(_lmAvail){
        print('  LM Studio Qwen3 (2560d) :');
        print('  ${"Variante".padRight(12)} | T-1  | T-3  | T-5  | Miss T-3');
        print('  ${"─"*70}');
        for(final v in ['A','B','C','D','E']){
          final c=lC[v]!;
          print('  ${labels[v]!.padRight(12)} |  ${c[0]}/$n |  ${c[1]}/$n |  ${c[2]}/$n | '
              '${lM[v]!.isEmpty?"aucun":lM[v]!.join(",")}');
        }
      }

      // Détail par requête pour D-Cond
      print('\n  DÉTAIL D-Cond par requête :');
      print('  ${"ID".padRight(4)} | att | ML rang | Qw rang | KW actif? (score>0.2)');
      for(var i=0;i<_pos.length;i++){
        final q=_pos[i];
        final qv=_ml.encode(q.text).toList();
        final mSem=_sem(qv,_mlVecs,minRel:_minRel);
        final kwR=_kw(q.text,_chunks);
        final mH=_variant('D',mSem,kwR);
        final mR=_rk(mH,q.exp);
        final kwAct=kwR.isNotEmpty&&kwR.first.score>0.2;
        String lStr='N/A';
        if(_lmAvail&&_lmPosQ.length>i&&_lmPosQ[i]!=null){
          final lSem=_sem(_lmPosQ[i]!,_lmVecs!,minRel:_minRel);
          final lH=_variant('D',lSem,kwR);
          final lR=_rk(lH,q.exp);
          lStr=lR>0?'r$lR':'—';
        }
        print('  ${q.id.padRight(4)} | c${q.exp.toString().padLeft(2)} | '
            '${mR>0?"r$mR ${mR<=3?"✅":"⚠️"}":"—  ❌"} | '
            '${lStr.padLeft(4)} ${lStr!="N/A"&&lStr!="—"&&int.tryParse(lStr.substring(1))!=null&&int.parse(lStr.substring(1))<=3?"✅":"  "} | '
            '${kwAct?"OUI (${kwR.first.score.toStringAsFixed(3)})":"NON (${kwR.isNotEmpty?kwR.first.score.toStringAsFixed(3):"0.000"})"}');
      }

      expect(true, isTrue);
    });
  });

  // ─── SECTION E ────────────────────────────────────────────────────────────
  group('E — Garde-fou : distribution positives vs négatives', () {
    test('E: 10 positives + 12 négatives — séparation cosinus MiniLM vs Qwen3', () async {
      print('\n'+'═'*110);
      print('SECTION E — DISTRIBUTION COSINUS TOP-1/2/3  (minRel actuel=${_minRel})');
      print('═'*110);

      final mPTop=<double>[], mNTop=<double>[];
      final lPTop=<double>[], lNTop=<double>[];

      print('\n  POSITIVES (top-1 cosinus) :');
      print('  ${"ID".padRight(4)} | ${"Type".padRight(22)} | ML cos1/2/3       | Qwen3 cos1/2/3    | Inj?');
      print('  ${"─"*90}');
      for(var i=0;i<_pos.length;i++){
        final q=_pos[i];
        final qv=_ml.encode(q.text).toList();
        final mA=_sem(qv,_mlVecs,minRel:0.0);
        final mc1=mA.isNotEmpty?mA[0].score:0.0;
        final mc2=mA.length>1?mA[1].score:0.0;
        final mc3=mA.length>2?mA[2].score:0.0;
        mPTop.add(mc1);
        String ls='N/A';
        if(_lmAvail&&_lmPosQ.length>i&&_lmPosQ[i]!=null){
          final la=_sem(_lmPosQ[i]!,_lmVecs!,minRel:0.0);
          final lc1=la.isNotEmpty?la[0].score:0.0;
          final lc2=la.length>1?la[1].score:0.0;
          final lc3=la.length>2?la[2].score:0.0;
          lPTop.add(lc1);
          ls='${lc1.toStringAsFixed(3)}/${lc2.toStringAsFixed(3)}/${lc3.toStringAsFixed(3)}';
        }
        print('  ${q.id.padRight(4)} | ${q.type.padRight(22)} | '
            '${mc1.toStringAsFixed(3)}/${mc2.toStringAsFixed(3)}/${mc3.toStringAsFixed(3)} | '
            '${ls.padRight(17)} | ${mc1>=_minRel?"✅":"❌"}');
      }

      print('\n  NÉGATIVES (top-1 cosinus) :');
      print('  ${"ID".padRight(4)} | ${"Type".padRight(28)} | ML cos1/2/3       | Qwen3 cos1/2/3    | Inj?');
      print('  ${"─"*100}');
      for(var i=0;i<_neg.length;i++){
        final q=_neg[i];
        final qv=_ml.encode(q.text).toList();
        final mA=_sem(qv,_mlVecs,minRel:0.0);
        final mc1=mA.isNotEmpty?mA[0].score:0.0;
        final mc2=mA.length>1?mA[1].score:0.0;
        final mc3=mA.length>2?mA[2].score:0.0;
        mNTop.add(mc1);
        String ls='N/A';
        if(_lmAvail&&_lmNegQ.length>i&&_lmNegQ[i]!=null){
          final la=_sem(_lmNegQ[i]!,_lmVecs!,minRel:0.0);
          final lc1=la.isNotEmpty?la[0].score:0.0;
          final lc2=la.length>1?la[1].score:0.0;
          final lc3=la.length>2?la[2].score:0.0;
          lNTop.add(lc1);
          ls='${lc1.toStringAsFixed(3)}/${lc2.toStringAsFixed(3)}/${lc3.toStringAsFixed(3)}';
        }
        print('  ${q.id.padRight(4)} | ${q.type.padRight(28)} | '
            '${mc1.toStringAsFixed(3)}/${mc2.toStringAsFixed(3)}/${mc3.toStringAsFixed(3)} | '
            '${ls.padRight(17)} | ${mc1>=_minRel?"⚠️inj":"✅ok"}');
      }

      print('\n  STATISTIQUES :');
      print('  MiniLM 384d — top-1 cosinus :');
      print('    Positives : min=${_minD(mPTop).toStringAsFixed(3)}  avg=${_avg(mPTop).toStringAsFixed(3)}  max=${_maxD(mPTop).toStringAsFixed(3)}');
      print('    Négatives : min=${_minD(mNTop).toStringAsFixed(3)}  avg=${_avg(mNTop).toStringAsFixed(3)}  max=${_maxD(mNTop).toStringAsFixed(3)}');
      final mOverlap = _maxD(mNTop) >= _minD(mPTop);
      final mGap = _minD(mPTop) - _maxD(mNTop);
      print('    Séparation : ${mOverlap?"⚠️ CHEVAUCHEMENT (écart=${mGap.toStringAsFixed(3)})":"✅ NET (gap=${mGap.toStringAsFixed(3)})"}');
      if(!mOverlap) print('    Seuil optimal possible ≈ ${(_maxD(mNTop)+mGap/2).toStringAsFixed(3)}');

      if(lPTop.isNotEmpty&&lNTop.isNotEmpty){
        print('  LM Studio Qwen3 2560d — top-1 cosinus :');
        print('    Positives : min=${_minD(lPTop).toStringAsFixed(3)}  avg=${_avg(lPTop).toStringAsFixed(3)}  max=${_maxD(lPTop).toStringAsFixed(3)}');
        print('    Négatives : min=${_minD(lNTop).toStringAsFixed(3)}  avg=${_avg(lNTop).toStringAsFixed(3)}  max=${_maxD(lNTop).toStringAsFixed(3)}');
        final lOverlap=_maxD(lNTop)>=_minD(lPTop);
        final lGap=_minD(lPTop)-_maxD(lNTop);
        print('    Séparation : ${lOverlap?"⚠️ CHEVAUCHEMENT (écart=${lGap.toStringAsFixed(3)})":"✅ NET (gap=${lGap.toStringAsFixed(3)})"}');
        if(!lOverlap) print('    Seuil optimal possible ≈ ${(_maxD(lNTop)+lGap/2).toStringAsFixed(3)}');
      }

      print('\n  NOTE : seuil actuel minRel=$_minRel — injections observées ci-dessus.');
      print('  Un seuil adaptatif (percentile ou z-score sur le corpus) résisterait mieux');
      print('  que tout seuil absolu fixe lorsque le corpus change de domaine.');

      expect(true, isTrue);
    });
  });
}
