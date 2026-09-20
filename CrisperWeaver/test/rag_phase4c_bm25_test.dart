// test/rag_phase4c_bm25_test.dart
//
// RAG Phase 4C — Évaluation BM25 Okapi réel vs Overlap dans harness uniquement.
// Aucune modification de DocumentRagService.
//
// ─── PARAMÈTRES BM25 (fixes, conventionnels, déclarés avant tout résultat) ───
//
//   Algorithme : BM25 Okapi (Robertson & Walker 1994)
//   Tokenisation : identique au keyword overlap de production —
//       split(r'[^\w\u00C0-\u017F]+'), tokens longueur > 2, casse basse
//       (on compare la même tokenisation pour un bilan équitable)
//   TF  : fréquence brute du token dans le chunk (int)
//   IDF : log((N - df + 0.5) / (df + 0.5) + 1)  — Robertson IDF lissée
//         N  = taille du corpus   df = nombre de chunks contenant le token
//   k1  = 1.2  (valeur conventionnelle recommandée par TREC)
//   b   = 0.75 (valeur conventionnelle recommandée)
//   dl  = longueur du chunk en tokens (même tokenisation)
//   avgdl = moyenne des dl sur le corpus
//
// ─── CORPUS ──────────────────────────────────────────────────────────────────
//   A : 35 chunks Phase 3B  — requêtes sémantiques
//   B : 21 chunks codes/refs — requêtes lexicales historiques
//   C : 12 chunks courts (~15 mots)
//   D :  3 chunks longs  (~130 mots)
//
// ─── PIPELINES TESTÉS ────────────────────────────────────────────────────────
//   A-Sem    : Semantic pur MiniLM ou Qwen3
//   B-OvlRRF : Overlap normalisé + RRF (production actuelle)
//   C-BM25   : BM25 pur (classement lexical seul)
//   D-BM25RRF: Semantic + BM25 + RRF k=60 (variante comparée)

import 'dart:io';
import 'dart:math' as math;
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:crispembed/crispembed.dart';

// ─── Chemins ────────────────────────────────────────────────────────────────
const _gguf = r'C:\Jarvisol_Test\CrisperWeaver\build\windows\x64\runner\Release\data\models\whisper_cpp\all-MiniLM-L6-v2-iq4_xs.gguf';
const _dll  = r'C:\Jarvisol_Test\CrisperWeaver\crispembed.dll';
const _lmUrl   = 'http://127.0.0.1:1234/v1/embeddings';
const _lmModel = 'text-embedding-qwen3-embedding-4b';

// ─── Types ──────────────────────────────────────────────────────────────────
class _Q { final String id, text, type; final int exp;
  const _Q(this.id, this.text, this.exp, this.type); }
class _SS { final int idx; final double score; _SS(this.idx, this.score); }

// ════════════════════════════════════════════════════════════════════════════
// CORPUS A — 35 chunks (Phase 3B)
// ════════════════════════════════════════════════════════════════════════════
const List<String> _cA = [
  'Le RGPD est entré en application le 25 mai 2018 dans toute l\'Union Européenne. Il remplace la directive 95/46/CE et unifie la législation sur la protection des données personnelles.',
  'Toute personne physique dispose d\'un droit d\'accès à ses données personnelles. Elle peut demander à l\'organisme responsable de lui communiquer l\'ensemble des informations qu\'il détient sur elle, gratuitement et dans un délai d\'un mois.',
  'Le droit à l\'oubli, formellement appelé droit à l\'effacement, permet à un individu d\'exiger la suppression de ses données personnelles lorsqu\'elles ne sont plus nécessaires ou lorsque le consentement initial est retiré.',
  'Les entreprises qui réalisent un traitement de données à grande échelle doivent désigner un délégué à la protection des données. Ce responsable, souvent désigné par son acronyme anglais DPO (Data Protection Officer), veille au respect du règlement.',
  'En cas de faille de sécurité compromettant des données personnelles, l\'organisation doit notifier l\'autorité de contrôle dans les 72 heures suivant la détection de l\'incident. Cette obligation de signalement est impérative.',
  'Les infractions au règlement européen sur la protection des données peuvent être sanctionnées par des pénalités allant jusqu\'à 4 % du chiffre d\'affaires annuel mondial ou 20 millions d\'euros, selon le montant le plus élevé.',
  'La CNIL, Commission Nationale de l\'Informatique et des Libertés, est l\'autorité française compétente pour contrôler l\'application du RGPD et instruire les plaintes des citoyens en matière de protection des données.',
  'Le transfert de données personnelles vers un pays situé hors de l\'Union Européenne est soumis à des garanties spécifiques : décision d\'adéquation de la Commission européenne ou clauses contractuelles types approuvées.',
  'Un pare-feu (firewall) est un système de sécurité réseau qui filtre les communications entre un réseau interne et Internet selon des règles préétablies, afin de bloquer les accès non autorisés.',
  'L\'authentification à deux facteurs (2FA) renforce la sécurité des comptes en exigeant deux preuves d\'identité distinctes : un mot de passe et un code temporaire envoyé sur un téléphone ou généré par une application.',
  'Une attaque par ransomware chiffre les fichiers d\'une organisation et exige une rançon pour en restaurer l\'accès. Ces cyberattaques ciblent préférentiellement les hôpitaux, collectivités et entreprises mal protégées.',
  'En cybersécurité, une violation de données désigne toute compromission non autorisée de la confidentialité, l\'intégrité ou la disponibilité d\'un système. La notification aux parties prenantes doit suivre les politiques internes de l\'organisation.',
  'Le chiffrement de bout en bout garantit que seuls l\'émetteur et le destinataire peuvent lire les messages échangés. Même le fournisseur du service de messagerie n\'a pas accès au contenu en clair.',
  'Un audit de sécurité informatique évalue les vulnérabilités d\'un système d\'information. Il comprend des tests d\'intrusion (pentests), une analyse de configuration et une revue des politiques de contrôle d\'accès.',
  'Le contrat de travail à durée indéterminée (CDI) est la forme normale et générale de la relation de travail en France. Il ne comporte pas de terme fixé et peut être rompu par le salarié (démission) ou l\'employeur (licenciement).',
  'Le licenciement pour motif économique intervient lorsque l\'entreprise supprime un ou plusieurs postes en raison de difficultés économiques, de mutations technologiques ou d\'une réorganisation nécessaire à la sauvegarde de la compétitivité.',
  'La durée légale du travail est fixée à 35 heures par semaine en France. Les heures effectuées au-delà donnent lieu à des majorations de salaire ou à un repos compensateur, selon les dispositions conventionnelles applicables.',
  'Le droit à la déconnexion permet aux salariés de ne pas être joignables en dehors de leurs horaires de travail habituels, notamment via les outils numériques professionnels (messagerie, téléphone, applications métier).',
  'La période d\'essai permet à l\'employeur et au salarié d\'évaluer leur relation de travail avant de s\'engager définitivement. Sa durée varie selon la catégorie professionnelle et peut être renouvelée une fois si la convention collective le prévoit.',
  'La clause de confidentialité (NDA, Non-Disclosure Agreement) engage les parties à ne pas divulguer les informations sensibles échangées dans le cadre d\'un accord commercial. Elle est souvent réciproque et limitée dans le temps.',
  'La force majeure est un événement imprévisible, irrésistible et extérieur qui libère une partie de ses obligations contractuelles. La pandémie de Covid-19 a été invoquée dans de nombreux litiges contractuels à ce titre.',
  'Un contrat SaaS (Software as a Service) définit les conditions d\'accès à un logiciel hébergé dans le cloud. Il inclut des engagements de niveau de service (SLA), des clauses de portabilité des données et des modalités de résiliation.',
  'La garantie légale de conformité oblige le vendeur professionnel à livrer un bien conforme au contrat. L\'acheteur dispose de deux ans à partir de la délivrance pour agir, sans avoir à prouver l\'existence du défaut.',
  'La clause pénale prévoit forfaitairement le montant des dommages-intérêts dus en cas d\'inexécution d\'une obligation contractuelle. Elle peut être réduite ou augmentée par le juge si son montant est manifestement excessif ou dérisoire.',
  'Le service public est organisé selon trois principes fondamentaux : continuité (fonctionnement ininterrompu), égalité (traitement identique des usagers) et adaptabilité (évolution selon les besoins sociaux).',
  'Le recours pour excès de pouvoir permet à tout citoyen de contester devant le tribunal administratif une décision administrative illégale, sans avoir à justifier d\'un intérêt personnel direct.',
  'La Commission d\'Accès aux Documents Administratifs (CADA) veille au droit d\'accès aux documents produits ou reçus par l\'administration française. Tout citoyen peut demander communication d\'un document administratif.',
  'La commande publique est régie par le Code de la commande publique. Elle impose aux acheteurs publics le respect de principes de liberté d\'accès, d\'égalité de traitement des candidats et de transparence des procédures.',
  'La délégation de service public (DSP) est un contrat par lequel une collectivité confie la gestion d\'un service public à un opérateur privé dont la rémunération est substantiellement assurée par les résultats d\'exploitation.',
  'Dans une base de données relationnelle, les données sont organisées en tables reliées par des clés étrangères. L\'accès aux enregistrements s\'effectue via des requêtes SQL utilisant les clauses SELECT, FROM et WHERE.',
  'La sécurité des bâtiments publics repose sur des systèmes de contrôle d\'accès physique : badges RFID, caméras de surveillance et procédures d\'accréditation du personnel.',
  'Les opérateurs téléphoniques proposent des contrats d\'abonnement avec ou sans engagement. La résiliation sans frais est possible après la période d\'engagement initiale, avec un préavis généralement d\'un mois.',
  'En droit des successions, les héritiers disposent d\'un délai de six mois pour accepter ou renoncer à la succession. Passé ce délai, ils sont réputés acceptants purs et simples et répondent des dettes du défunt.',
  'La violation du secret professionnel est un délit pénal sanctionné par un an d\'emprisonnement et 15 000 euros d\'amende. Elle concerne les professions tenues au secret : médecins, avocats, notaires, experts-comptables.',
  'La conservation des archives numériques d\'entreprise obéit à des règles de durée légale : les documents comptables doivent être conservés 10 ans, les contrats commerciaux 5 ans, les bulletins de paie 5 ans.',
];

// ════════════════════════════════════════════════════════════════════════════
// CORPUS B — Codes / références (Phase 4B)
// ════════════════════════════════════════════════════════════════════════════
const List<String> _cB = [
  'Facture FA-2026-08 émise le 15 août 2026 par Dupont et Associés SARL. Montant HT 4850 euros. TVA 20% 970 euros. Total TTC 5820 euros. Référence bon de commande BC-2026-0342.',
  'Facture FA-2026-09 du 01 septembre 2026. Client Mairie de Villeneuve. Prestation audit informatique trimestriel. Montant 2400 euros HT. Conditions 30 jours net.',
  'Avoir AV-2026-03 correspondant à la facture FA-2026-07. Motif retour de marchandise défectueuse lot REF-PLV-2024. Montant crédité 1200 euros TTC.',
  'Erreur système 0x80070005 accès refusé. Cette erreur Windows survient lorsqu\'un processus tente d\'accéder à une ressource sans les droits suffisants. Vérifier les permissions NTFS et les politiques de groupe.',
  'Code d\'erreur HTTP 403 Forbidden retourné par le serveur API. L\'utilisateur est authentifié mais non autorisé à accéder à la ressource demandée. Vérifier les rôles et scopes OAuth2.',
  'Exception NullReferenceException dans le module OrderProcessor ligne 247. Trace System.NullReferenceException Object reference not set to an instance of an object. Vérifier les initialisations.',
  'Code retour HFSQL WD50027 clé dupliquée sur la table CLIENTS champ EMAIL. Opération INSERT annulée. Vérifier l\'unicité avant insertion ou utiliser HEcritSiExiste.',
  'Rapport établi par Mme Beauchesne-Trottier responsable juridique. Référence interne JURI-BT-2026-114. Signé conjointement avec Me Kowalczyk-Dubois avocat au barreau de Lyon.',
  'Projet Orion-Nexus piloté par M. Vandenberghe. Chef de projet adjoint Mme Aissatou Diallo-Camara. Comité de pilotage constitué le 12 mars 2026.',
  'Article L1237-19 du Code du travail la rupture conventionnelle collective peut être engagée par accord collectif majoritaire fixant le nombre de suppressions d\'emplois envisagées.',
  'Article 226-13 du Code pénal la révélation d\'une information à caractère secret par une personne qui en est dépositaire est punie d\'un an d\'emprisonnement et de 15000 euros d\'amende.',
  'Règlement UE 2016/679 Article 83 paragraphe 4 violations des obligations du responsable du traitement sanctionnées jusqu\'à 10 millions d\'euros ou 2% du CA mondial.',
  'Pièce de rechange REF-PLV-2024 filtre à huile compatible moteur 1.5 dCi. Référence OEM 8200768927. Compatible Clio IV Dacia Logan II Kangoo III. Prix catalogue 12,90 euros.',
  'Référence produit SKU-CW-3847-XL câble HDMI 2.1 48 Gbps longueur 3 mètres connecteurs dorés certifié 8K 60Hz. Stock 147 unités. Fournisseur TechLink référence TL-HD48-3M.',
  'Composant électronique IC-741 amplificateur opérationnel 15V gain 200000 bande passante 1 MHz. Package DIP-8. Référence Mouser 595-LM741CN.',
  'Le SMSI Système de Management de la Sécurité de l\'Information conforme à la norme ISO 27001 exige un inventaire des actifs une analyse de risque et un Plan de Traitement des Risques PTR.',
  'La DSI Direction des Systèmes d\'Information a validé le PRA Plan de Reprise d\'Activité avec un RTO Recovery Time Objective de 4 heures et un RPO Recovery Point Objective de 1 heure.',
  'Les factures doivent être conservées pendant dix ans. Elles doivent mentionner la date le numéro séquentiel le nom du client et le détail des prestations ou marchandises vendues.',
  'Les codes d\'erreur système permettent d\'identifier rapidement la cause d\'un dysfonctionnement. Ils sont définis dans les documentations techniques de chaque système d\'exploitation ou application.',
  'Les articles de loi sont numérotés selon un code spécifique lettre du code suivi d\'un numéro et éventuellement d\'une subdivision. La numérotation peut différer entre versions française et européenne.',
  'Un acronyme est une abréviation formée à partir des initiales d\'un groupe de mots. Dans le domaine informatique les acronymes sont très répandus CPU RAM API SDK IDE.',
];

// ════════════════════════════════════════════════════════════════════════════
// CORPUS C — Chunks courts (~15 mots)
// ════════════════════════════════════════════════════════════════════════════
const List<String> _cC = [
  'Le RGPD protège les données personnelles des citoyens de l\'Union Européenne depuis le 25 mai 2018.',
  'Toute personne peut demander accès à ses données personnelles auprès de l\'organisme qui les détient.',
  'Le droit à l\'effacement permet d\'exiger la suppression de ses données personnelles devenues inutiles.',
  'Les entreprises traitant des données à grande échelle doivent nommer un DPO délégué à la protection.',
  'En cas de faille de sécurité sur des données personnelles notification à la CNIL dans les 72 heures.',
  'Les sanctions RGPD peuvent atteindre 4% du chiffre d\'affaires mondial ou 20 millions d\'euros.',
  'La CNIL contrôle l\'application du RGPD en France et instruit les plaintes des citoyens.',
  'Le transfert de données hors UE nécessite des garanties adéquation ou clauses contractuelles types.',
  'Un pare-feu filtre les communications réseau selon des règles pour bloquer les accès non autorisés.',
  'L\'authentification à deux facteurs 2FA exige un mot de passe et un code temporaire distinct.',
  'Un ransomware chiffre les fichiers et exige une rançon pour restaurer l\'accès. Cible hôpitaux et collectivités.',
  'Une violation de données en cybersécurité désigne tout accès non autorisé à un système ou ses données.',
];

// ════════════════════════════════════════════════════════════════════════════
// CORPUS D — Chunks longs (~130 mots)
// ════════════════════════════════════════════════════════════════════════════
const List<String> _cD = [
  'Le Règlement Général sur la Protection des Données RGPD entré en application le 25 mai 2018 constitue le texte de référence en matière de protection des données à caractère personnel au sein de l\'Union Européenne. Il remplace la directive 95/46/CE adoptée en 1995 et vise à unifier le cadre juridique applicable dans l\'ensemble des États membres. Le RGPD repose sur plusieurs principes fondamentaux la licéité la loyauté et la transparence du traitement la limitation des finalités la minimisation des données l\'exactitude et la limitation de la conservation. Les organisations qui ne respectent pas ces obligations s\'exposent à des sanctions administratives pouvant atteindre 4% du chiffre d\'affaires annuel mondial ou 20 millions d\'euros selon le montant le plus élevé.',
  'En droit du travail français le contrat à durée indéterminée CDI représente la forme normale et générale de la relation de travail conformément à l\'article L1221-2 du Code du travail. Il peut être rompu soit à l\'initiative du salarié par démission soit à l\'initiative de l\'employeur par licenciement personnel ou économique soit d\'un commun accord par rupture conventionnelle individuelle ou collective. Le licenciement pour motif économique est encadré par les articles L1233-1 et suivants du Code du travail. La durée légale du travail est fixée à 35 heures par semaine les heures supplémentaires sont majorées ou compensées en repos.',
  'La sécurité des systèmes d\'information repose sur trois piliers CIA Confidentialité Intégrité Disponibilité. Pour assurer ces garanties les organisations déploient des mesures techniques incluant le déploiement de pare-feux l\'authentification multifacteur MFA le chiffrement TLS et la réalisation d\'audits de sécurité incluant des tests de pénétration. La mise en place d\'un Système de Management de la Sécurité de l\'Information SMSI conforme à la norme ISO 27001 est recommandée. En cas d\'incident notamment d\'attaque par ransomware ou de violation de données un Plan de Reprise d\'Activité PRA préalablement testé permet de minimiser les pertes.',
];

// ─── Requêtes ───────────────────────────────────────────────────────────────
const List<_Q> _qA = [
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

// Refs obligatoires Section 5 (sous-ensemble de _qB)
const List<_Q> _qRefs = [
  _Q('R01','FA-2026-08',                 0, 'ref facture exacte'),
  _Q('R02','0x80070005',                 3, 'code erreur hex exact'),
  _Q('R03','Beauchesne-Trottier',        7, 'nom propre rare exact'),
  _Q('R04','L1237-19',                   9, 'numéro article loi exact'),
  _Q('R05','REF-PLV-2024',              12, 'ref pièce exacte'),
  _Q('R06','SMSI',                      15, 'acronyme domaine exact'),
];

const List<_Q> _qB = [
  _Q('R01','FA-2026-08',                 0,'ref facture exacte'),
  _Q('R02','0x80070005',                 3,'code erreur hex exact'),
  _Q('R03','Beauchesne-Trottier',        7,'nom propre exact'),
  _Q('R04','L1237-19',                   9,'article loi exact'),
  _Q('R05','REF-PLV-2024',              12,'ref pièce exacte'),
  _Q('R06','SMSI',                      15,'acronyme exact'),
  _Q('R07','facture FA-2026-08 Dupont',  0,'ref + contexte'),
  _Q('R08','erreur accès refusé 0x80070005',3,'code + desc'),
  _Q('R09','article L1237-19 rupture conventionnelle collective',9,'article + sujet'),
  _Q('R10','Quels droits lors d\'un départ négocié collectif ?',9,'sem pure → L1237-19'),
  _Q('R11','Comment résoudre un problème d\'autorisation sur Windows ?',3,'sem pure → 0x80070005'),
  _Q('R12','Durée de rétention légale des documents comptables ?',17,'sem pure → factures'),
];

const List<_Q> _qC = [
  _Q('S01','Je veux faire effacer mes informations de leurs fichiers',2,'sem sans mc'),
  _Q('S02','Quelle est l\'amende maximale pour une infraction RGPD ?',5,'sem → sanction'),
  _Q('S03','notification 72 heures violation',4,'lexical → 72h'),
  _Q('S04','DPO délégué protection données',3,'lexical → DPO'),
  _Q('S05','Quels sont les risques d\'un rançongiciel ?',10,'sem → ransomware'),
];

const List<_Q> _qD = [
  _Q('L01','Quelles sont les sanctions prévues par le RGPD ?',0,'sem → sanctions'),
  _Q('L02','Comment fonctionne le licenciement économique en France ?',1,'sem → licenciement'),
  _Q('L03','ransomware SMSI PRA RTO',2,'lexical → sécu'),
  _Q('L04','Quelle est la durée légale de travail hebdomadaire ?',1,'sem → 35h'),
  _Q('L05','ISO 27001 plan reprise activité objectifs recovery',2,'lexical → sécu c2'),
];

const List<_Q> _neg = [
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

// ─── Constantes ─────────────────────────────────────────────────────────────
const int    _kRrf   = 60;
const int    _topK   = 5;
const double _minRel = 0.15;
const double _bm25k1 = 1.2;   // conventionnel TREC
const double _bm25b  = 0.75;  // conventionnel

// ─── Tokenisation commune ────────────────────────────────────────────────────
List<String> _tok(String text) =>
    text.toLowerCase().split(RegExp(r'[^\w\u00C0-\u017F]+')).where((t)=>t.length>2).toList();

Set<String> _qToks(String query) => _tok(query).toSet();

// ─── Cosinus ────────────────────────────────────────────────────────────────
double _cos(List<double> a, List<double> b) {
  double d=0,na=0,nb=0;
  for(var i=0;i<a.length;i++){d+=a[i]*b[i];na+=a[i]*a[i];nb+=b[i]*b[i];}
  if(na==0||nb==0) return 0;
  return (d/(math.sqrt(na)*math.sqrt(nb))).clamp(-1.0,1.0);
}

// ─── Semantic list ───────────────────────────────────────────────────────────
List<_SS> _semList(List<double> q, List<List<double>> vecs, {double minRel=0.0}) {
  final r=<_SS>[];
  for(var i=0;i<vecs.length;i++){
    final s=_cos(q,vecs[i]); if(s>=minRel) r.add(_SS(i,s));
  }
  r.sort((a,b)=>b.score.compareTo(a.score));
  return r;
}

// ─── Overlap (production actuelle) ──────────────────────────────────────────
List<_SS> _overlap(String query, List<String> chunks) {
  final qt=_qToks(query);
  if(qt.isEmpty) return [];
  final r=<_SS>[];
  for(var i=0;i<chunks.length;i++){
    final ct=_tok(chunks[i]);
    if(ct.isEmpty) continue;
    int m=0; for(final t in ct){if(qt.contains(t))m++;}
    if(m>0) r.add(_SS(i,m/math.sqrt(ct.length)));
  }
  r.sort((a,b)=>b.score.compareTo(a.score));
  return r;
}

// ─── BM25 Okapi ─────────────────────────────────────────────────────────────
//
// Préconstruit un index BM25 pour un corpus donné.
// Tokenisation : identique à l'overlap (équité de comparaison).
// IDF  = log((N - df + 0.5) / (df + 0.5) + 1)   Robertson lissée
// TF-score = tf × (k1+1) / (tf + k1×(1 - b + b×dl/avgdl))
//
class _BM25 {
  final List<List<String>> _tokenized;
  final Map<String,int> _df = {};   // document frequency par token
  final double _avgdl;
  final int _N;

  _BM25(List<String> corpus)
      : _tokenized = corpus.map(_tok).toList(),
        _N = corpus.length,
        _avgdl = corpus.map(_tok).map((t)=>t.length.toDouble())
                       .reduce((a,b)=>a+b) / corpus.length {
    for(final toks in _tokenized) {
      for(final t in toks.toSet()) _df[t]=(_df[t]??0)+1;
    }
  }

  double idf(String token) {
    final df = _df[token] ?? 0;
    return math.log((_N - df + 0.5)/(df + 0.5) + 1);
  }

  List<_SS> search(String query) {
    final qt = _qToks(query);
    if(qt.isEmpty) return [];
    final r=<_SS>[];
    for(var i=0;i<_tokenized.length;i++){
      final toks=_tokenized[i];
      final dl=toks.length.toDouble();
      double score=0;
      for(final t in qt){
        final tf=toks.where((x)=>x==t).length.toDouble();
        if(tf==0) continue;
        final idfV=idf(t);
        final tfN=tf*(_bm25k1+1)/(tf+_bm25k1*(1-_bm25b+_bm25b*dl/_avgdl));
        score+=idfV*tfN;
      }
      if(score>0) r.add(_SS(i,score));
    }
    r.sort((a,b)=>b.score.compareTo(a.score));
    return r;
  }
}

// ─── RRF générique ───────────────────────────────────────────────────────────
List<int> _rrf(List<_SS> sem, List<_SS> lex) {
  final sc=<int,double>{};
  for(var r=0;r<sem.length;r++) sc[sem[r].idx]=(sc[sem[r].idx]??0)+1/(_kRrf+r+1);
  for(var r=0;r<lex.length;r++) sc[lex[r].idx]=(sc[lex[r].idx]??0)+1/(_kRrf+r+1);
  return (sc.keys.toList()..sort((a,b)=>sc[b]!.compareTo(sc[a]!))).take(_topK).toList();
}

int _rk(List<int> r, int e) { final i=r.indexOf(e); return i<0?-1:i+1; }
int _rkS(List<_SS> r, int e) { final i=r.indexWhere((s)=>s.idx==e); return i<0?-1:i+1; }
String _f(int r) => r==1?'✅T1':r>=1&&r<=3?'✅T3':r>=1&&r<=5?'⚠️T5':'❌';

// ─── Globals ─────────────────────────────────────────────────────────────────
late CrispEmbed _ml;
bool _lmAvail=false;
late List<List<double>> _mlA, _mlB, _mlC, _mlD;
List<List<double>>? _lmA, _lmB, _lmC, _lmD;
late _BM25 _bm25A, _bm25B, _bm25C, _bm25D;

Future<List<double>?> _enc(String t) async {
  if(!_lmAvail) return null;
  try {
    final r=await http.post(Uri.parse(_lmUrl),
        headers:{'Content-Type':'application/json'},
        body:jsonEncode({'model':_lmModel,'input':t}));
    if(r.statusCode==200)
      return (jsonDecode(r.body)['data'][0]['embedding'] as List).cast<double>();
  } catch(_){}
  return null;
}

Future<List<List<double>>?> _batch(List<String> texts) async {
  final res=<List<double>>[];
  for(final t in texts){ final v=await _enc(t); if(v==null) return null; res.add(v); }
  return res;
}

// ─── MAIN ────────────────────────────────────────────────────────────────────
void main() {

  setUpAll(() async {
    // Paramètres BM25 annoncés
    print('\n╔══════════════════════════════════════════════════════════════╗');
    print('║  PARAMÈTRES BM25 — DÉCLARÉS AVANT TOUT RÉSULTAT            ║');
    print('╠══════════════════════════════════════════════════════════════╣');
    print('║  Algorithme : BM25 Okapi (Robertson & Walker 1994)         ║');
    print('║  Tokenisation : split([^\\w\\u00C0-\\u017F]+) len>2 lowercase ║');
    print('║  TF  : fréquence brute du token dans le chunk              ║');
    print('║  IDF : log((N - df + 0.5) / (df + 0.5) + 1)              ║');
    print('║  k1  = $_bm25k1  (TREC conventionnel, NON tuné)             ║');
    print('║  b   = $_bm25b  (TREC conventionnel, NON tuné)             ║');
    print('║  dl  = longueur chunk en tokens  avgdl = moyenne corpus    ║');
    print('╚══════════════════════════════════════════════════════════════╝');

    _ml = CrispEmbed(_gguf, nThreads:4,
        libPath: File(_dll).existsSync()?_dll:null);

    // MiniLM vecs
    _mlA = _cA.map((c)=>_ml.encode(c).toList()).toList();
    _mlB = _cB.map((c)=>_ml.encode(c).toList()).toList();
    _mlC = _cC.map((c)=>_ml.encode(c).toList()).toList();
    _mlD = _cD.map((c)=>_ml.encode(c).toList()).toList();

    // BM25 index
    _bm25A = _BM25(_cA.toList());
    _bm25B = _BM25(_cB.toList());
    _bm25C = _BM25(_cC.toList());
    _bm25D = _BM25(_cD.toList());

    // Stats BM25 par corpus
    print('\n  BM25 avgdl :'
        '  A=${_bm25A._avgdl.toStringAsFixed(1)}'
        '  B=${_bm25B._avgdl.toStringAsFixed(1)}'
        '  C=${_bm25C._avgdl.toStringAsFixed(1)}'
        '  D=${_bm25D._avgdl.toStringAsFixed(1)}');
    print('  BM25 vocab : A=${_bm25A._df.length}  B=${_bm25B._df.length}'
        '  C=${_bm25C._df.length}  D=${_bm25D._df.length}');

    // LM Studio
    try {
      final r=await http.post(Uri.parse(_lmUrl),
          headers:{'Content-Type':'application/json'},
          body:jsonEncode({'model':_lmModel,'input':'test'}))
          .timeout(const Duration(seconds:5));
      if(r.statusCode==200){
        _lmAvail=true;
        _lmA=await _batch(_cA.toList());
        _lmB=await _batch(_cB.toList());
        _lmC=await _batch(_cC.toList());
        _lmD=await _batch(_cD.toList());
        print('[LM Studio] 4 corpus dim=${_lmA!.first.length}');
      }
    } catch(_){ print('[LM Studio] non disponible'); }

    print('[MiniLM] 4 corpus : ${_cA.length}c / ${_cB.length}c / ${_cC.length}c / ${_cD.length}c');
  });

  tearDownAll(()=>_ml.dispose());

  // ══════════════════════════════════════════════════════════════════════════
  // Tableau comparatif générique sur un corpus + liste de requêtes
  // ══════════════════════════════════════════════════════════════════════════
  Future<void> benchCorpus(
      String label, List<String> corpus, List<_Q> queries,
      List<List<double>> mlV, List<List<double>>? lmV, _BM25 bm25) async {

    final n=queries.length;
    // [T1,T3,T5]
    final mSem=[0,0,0], mOvl=[0,0,0], mBm25=[0,0,0], mOvlRrf=[0,0,0], mBm25Rrf=[0,0,0];
    final lSem=[0,0,0], lOvl=[0,0,0], lBm25=[0,0,0], lOvlRrf=[0,0,0], lBm25Rrf=[0,0,0];

    void tally(int rk, List<int> c){ if(rk==1)c[0]++; if(rk>=1&&rk<=3)c[1]++; if(rk>=1&&rk<=5)c[2]++; }

    for(var i=0;i<queries.length;i++){
      final q=queries[i];
      final mqv=_ml.encode(q.text).toList();
      final mSR=_semList(mqv,mlV,minRel:_minRel);
      final ovl=_overlap(q.text,corpus);
      final b25=bm25.search(q.text);
      final mOvlR=_rrf(mSR,ovl);
      final mBm25R=_rrf(mSR,b25);

      tally(_rkS(mSR,q.exp),mSem);
      tally(_rkS(ovl,q.exp),mOvl);
      tally(_rkS(b25,q.exp),mBm25);
      tally(_rk(mOvlR,q.exp),mOvlRrf);
      tally(_rk(mBm25R,q.exp),mBm25Rrf);

      if(_lmAvail&&lmV!=null){
        final lqv=await _enc(q.text);
        if(lqv!=null){
          final lSR=_semList(lqv,lmV,minRel:_minRel);
          final lOvlR=_rrf(lSR,ovl);
          final lBm25R=_rrf(lSR,b25);
          tally(_rkS(lSR,q.exp),lSem);
          tally(_rkS(ovl,q.exp),lOvl);
          tally(_rkS(b25,q.exp),lBm25);
          tally(_rk(lOvlR,q.exp),lOvlRrf);
          tally(_rk(lBm25R,q.exp),lBm25Rrf);
        }
      }
    }

    print('\n  ── $label ($n requêtes) ──');
    print('  ${"Pipeline".padRight(24)} | T-1  | T-3  | T-5');
    print('  ${"─"*55}');
    void row(String lbl,List<int>c){
      print('  ${lbl.padRight(24)} | ${c[0]}/$n | ${c[1]}/$n | ${c[2]}/$n');
    }
    row('MiniLM SemPur',mSem);
    row('MiniLM OvlPur',mOvl);
    row('MiniLM BM25Pur',mBm25);
    row('MiniLM Ovl+RRF',mOvlRrf);
    row('MiniLM BM25+RRF',mBm25Rrf);
    if(_lmAvail&&lmV!=null){
      row('Qwen3 SemPur',lSem);
      row('Qwen3 OvlPur',lOvl);
      row('Qwen3 BM25Pur',lBm25);
      row('Qwen3 Ovl+RRF',lOvlRrf);
      row('Qwen3 BM25+RRF',lBm25Rrf);
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  // SECTION 1 — Corpus A : 35 chunks sémantiques
  // ══════════════════════════════════════════════════════════════════════════
  group('1 — Corpus A sémantique (35c, 10q)', () {
    test('1: SemPur / OvlRRF / BM25Pur / BM25RRF', () async {
      print('\n'+'═'*100);
      print('SECTION 1 — CORPUS A (35 chunks, 10 requêtes sémantiques)');
      print('═'*100);
      await benchCorpus('Corpus A — 35c sémantique', _cA.toList(), _qA.toList(), _mlA, _lmA, _bm25A);
      expect(true,isTrue);
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  // SECTION 2 — Corpus B : références/codes
  // ══════════════════════════════════════════════════════════════════════════
  group('2 — Corpus B références/codes (21c, 12q)', () {
    test('2: SemPur / OvlRRF / BM25Pur / BM25RRF', () async {
      print('\n'+'═'*100);
      print('SECTION 2 — CORPUS B (références / codes)');
      print('═'*100);
      await benchCorpus('Corpus B — codes/refs', _cB.toList(), _qB.toList(), _mlB, _lmB, _bm25B);
      expect(true,isTrue);
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  // SECTION 3 — Corpus C et D
  // ══════════════════════════════════════════════════════════════════════════
  group('3 — Corpus C courts + D longs', () {
    test('3: C+D comparaison', () async {
      print('\n'+'═'*100);
      print('SECTION 3 — CORPUS C (courts) + D (longs)');
      print('═'*100);
      await benchCorpus('Corpus C — chunks courts', _cC.toList(), _qC.toList(), _mlC, _lmC, _bm25C);
      await benchCorpus('Corpus D — chunks longs',  _cD.toList(), _qD.toList(), _mlD, _lmD, _bm25D);
      expect(true,isTrue);
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  // SECTION 4 — Cas obligatoires : 6 références exactes
  // ══════════════════════════════════════════════════════════════════════════
  group('4 — 6 références exactes obligatoires', () {
    test('4: FA-2026-08 / 0x80070005 / Beauchesne / L1237-19 / REF-PLV / SMSI', () async {
      print('\n'+'═'*100);
      print('SECTION 4 — CAS RÉFÉRENCES OBLIGATOIRES (Section 5 du cahier des charges)');
      print('Exigence : BM25+RRF ne doit pas régresser vs Ovl+RRF sur ces recherches exactes.');
      print('─'*100);
      print('  ${"ID".padRight(4)} | ${"Type".padRight(22)} | Sem  | OvlP | BM25P | OvlRRF | BM25RRF | QwOvl | QwBm25 | Régr?');
      print('  ${"─"*100}');

      int regressCount=0;

      for(final q in _qRefs){
        final mqv=_ml.encode(q.text).toList();
        final mSR=_semList(mqv,_mlB,minRel:_minRel);
        final ovl=_overlap(q.text,_cB.toList());
        final b25=_bm25B.search(q.text);
        final mOvlR=_rrf(mSR,ovl);
        final mBm25R=_rrf(mSR,b25);

        final rSem  =_rkS(mSR,q.exp);
        final rOvl  =_rkS(ovl,q.exp);
        final rBm25 =_rkS(b25,q.exp);
        final rOvlR =_rk(mOvlR,q.exp);
        final rBm25R=_rk(mBm25R,q.exp);

        String qwOvl='N/A', qwBm25='N/A';
        if(_lmAvail&&_lmB!=null){
          final lqv=await _enc(q.text);
          if(lqv!=null){
            final lSR=_semList(lqv,_lmB!,minRel:_minRel);
            qwOvl ='r${_rk(_rrf(lSR,ovl),q.exp)}'.replaceAll('r-1','—');
            qwBm25='r${_rk(_rrf(lSR,b25),q.exp)}'.replaceAll('r-1','—');
          }
        }

        // Régression : BM25+RRF perd par rapport à Ovl+RRF (deux niveaux ou plus pire)
        final regress = (rOvlR>=1&&rOvlR<=5) && (rBm25R<0||rBm25R>5||
            (rBm25R>rOvlR+1));
        if(regress) regressCount++;

        print('  ${q.id.padRight(4)} | ${q.type.padRight(22)} | '
            '${rSem>0?"r$rSem":"—  "} | ${rOvl>0?"r$rOvl":"—  "} | '
            '${rBm25>0?"r$rBm25":"—  "} | ${rOvlR>0?"r$rOvlR ${_f(rOvlR)}":"—  ❌ "} | '
            '${rBm25R>0?"r$rBm25R ${_f(rBm25R)}":"—  ❌ "} | '
            '${qwOvl.padRight(5)} | ${qwBm25.padRight(5)} | '
            '${regress?"⚠️ RÉGRESSION":"OK"}');
      }

      print('\n  Régressions BM25+RRF vs Ovl+RRF (refs exactes) : $regressCount/${_qRefs.length}');
      expect(regressCount, equals(0),
          reason: 'BM25+RRF ne doit pas régresser par rapport à Ovl+RRF sur les références exactes');
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  // SECTION 5 — Anatomie Q01 et Q02 : IDF et bruit lexical
  // ══════════════════════════════════════════════════════════════════════════
  group('5 — Anatomie Q01 Q02 : IDF vs tokens fréquents', () {
    test('5: BM25 empêche-t-il le bruit lexical des mots fréquents ?', () {
      print('\n'+'═'*100);
      print('SECTION 5 — ANATOMIE Q01/Q02  : IDF des tokens pertinents et bruit lexical');
      print('═'*100);

      for(final q in [_qA[0],_qA[1]]){ // Q01, Q02
        final qt=_qToks(q.text).toList()..sort();
        print('\n  ${q.id} : "${q.text}"  (attendu c${q.exp})');
        print('  Tokens requête (len>2) : ${qt.join(", ")}');
        print('  IDF par token dans corpus A (${_cA.length} chunks) :');
        for(final t in qt){
          final df=_bm25A._df[t]??0;
          final idfV=_bm25A.idf(t);
          print('    "${t.padRight(15)}" df=$df  IDF=${idfV.toStringAsFixed(3)}  '
              '${idfV>1.5?"→ terme INFORMATIF":"→ terme fréquent/commun"}');
        }

        // Top-5 overlap
        final ovl=_overlap(q.text,_cA.toList());
        final b25=_bm25A.search(q.text);
        final mqv=_ml.encode(q.text).toList();
        final mSR=_semList(mqv,_mlA,minRel:0.0);
        final mOvlR=_rrf(mSR.where((s)=>s.score>=_minRel).toList(),ovl);
        final mBm25R=_rrf(mSR.where((s)=>s.score>=_minRel).toList(),b25);

        print('  Overlap top-5 :  ${ovl.take(5).map((s)=>"c${s.idx}(${s.score.toStringAsFixed(3)})").join(", ")}');
        print('  BM25   top-5 :  ${b25.take(5).map((s)=>"c${s.idx}(${s.score.toStringAsFixed(3)})").join(", ")}');
        print('  Hybrid-Ovl top-5 : ${mOvlR.map((i)=>"c$i").join(", ")}  '
            'target c${q.exp} → r${_rk(mOvlR,q.exp)}');
        print('  Hybrid-BM25 top-5: ${mBm25R.map((i)=>"c$i").join(", ")}  '
            'target c${q.exp} → r${_rk(mBm25R,q.exp)}');

        // Pour Q02 : tokens dans c5 vs tokens requête
        if(q.exp==5){
          print('  ─── Analyse c5 (attendu Q02) ───');
          final c5toks=_tok(_cA[5]);
          final qt2=_qToks(q.text);
          final matches=c5toks.where((t)=>qt2.contains(t)).toList();
          final b25score=b25.firstWhere((s)=>s.idx==5, orElse:()=>_SS(5,0)).score;
          print('    Tokens communs c5∩requête : ${matches.isEmpty?"aucun":matches.join(", ")}');
          print('    BM25 score c5 : ${b25score.toStringAsFixed(4)}'
              '  Overlap score c5 : ${ovl.firstWhere((s)=>s.idx==5,orElse:()=>_SS(5,0)).score.toStringAsFixed(4)}');
          print('    Rang c5 — Overlap: ${_rkS(ovl,5)>0?"r${_rkS(ovl,5)}":"absent"}'
              '  BM25: ${_rkS(b25,5)>0?"r${_rkS(b25,5)}":"absent"}');
        }
        // Pour Q01 : pourquoi l'overlap a du bruit
        if(q.exp==2){
          print('  ─── Analyse bruit overlap Q01 ───');
          for(var i=0;i<math.min(5,ovl.length);i++){
            final c=ovl[i]; final ct=_tok(_cA[c.idx]);
            final common=ct.where((t)=>_qToks(q.text).contains(t)).toList();
            final b25score=b25.firstWhere((s)=>s.idx==c.idx,orElse:()=>_SS(c.idx,0)).score;
            print('    Overlap r${i+1} c${c.idx}(${c.score.toStringAsFixed(3)}) '
                'common=${common.join(",")} '
                'BM25=${b25score.toStringAsFixed(3)} '
                'BM25_rank=${_rkS(b25,c.idx)>0?"r${_rkS(b25,c.idx)}":"absent"}');
          }
        }
      }
      expect(true,isTrue);
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  // SECTION 6 — 12 requêtes négatives : signal lexical Overlap vs BM25
  // ══════════════════════════════════════════════════════════════════════════
  group('6 — Requêtes négatives : signal lexical Overlap vs BM25', () {
    test('6: 12 négatives sur corpus A', () {
      print('\n'+'═'*100);
      print('SECTION 6 — REQUÊTES NÉGATIVES (${_neg.length} requêtes) corpus A (35 chunks)');
      print('Mesurer : combien ont un signal lexical malgré tout ?');
      print('─'*100);
      print('  ${"ID".padRight(4)} | ${"Type".padRight(28)} | cos1  | OvlTop1(score) | BM25Top1(score) | OvlActif? | BM25Actif?');
      print('  ${"─"*100}');

      int ovlAny=0, bm25Any=0; // nombre de négatives avec signal lexical > 0

      for(final q in _neg){
        final mqv=_ml.encode(q.text).toList();
        final mSR=_semList(mqv,_mlA,minRel:0.0);
        final ovl=_overlap(q.text,_cA.toList());
        final b25=_bm25A.search(q.text);
        final cos1=mSR.isNotEmpty?mSR.first.score:0.0;
        final ovlS=ovl.isNotEmpty?ovl.first.score:0.0;
        final bm25S=b25.isNotEmpty?b25.first.score:0.0;
        if(ovlS>0) ovlAny++;
        if(bm25S>0) bm25Any++;

        print('  ${q.id.padRight(4)} | ${q.type.padRight(28)} | '
            '${cos1.toStringAsFixed(3)} | '
            '${(ovl.isNotEmpty?"c${ovl.first.idx}(${ovlS.toStringAsFixed(3)})":"—      ").padRight(16)} | '
            '${(b25.isNotEmpty?"c${b25.first.idx}(${bm25S.toStringAsFixed(3)})":"—      ").padRight(16)} | '
            '${ovlS>0?"OUI":"—  "} | ${bm25S>0?"OUI":"—  "}');
      }

      print('\n  Signal lexical positif sur requêtes négatives :');
      print('  Overlap : $ovlAny/${_neg.length}  — BM25 : $bm25Any/${_neg.length}');
      print('  ${bm25Any<ovlAny?"✅ BM25 réduit le signal lexical parasite":"⚠️ BM25 ne réduit pas le signal parasite"} '
          '(${ovlAny-bm25Any} requête(s) en moins)');
      expect(true,isTrue);
    });
  });
}
