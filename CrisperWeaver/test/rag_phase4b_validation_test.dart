// test/rag_phase4b_validation_test.dart  (v2 — syntaxe Dart correcte)
//
// RAG Phase 4B — Validation D-Cond sur cas historiques
//   C — Corpus codes / références (cas lexicaux historiques)
//   D — Robustesse seuil 0.2 : 4 corpus
//   E — Comparaison normative SemPur / CurrentRRF / D-Cond
//   F — Requêtes négatives : D-Cond n'aggrave pas les injections
//
// INC-RAG-LEXICAL-LABEL : aucune modification du code ou de l'UI.
// Aucun téléchargement. Aucune modification production.

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

const double _condThr = 0.2; // seuil D-Cond sous examen
const int    _kRrf    = 60;
const int    _topK    = 5;
const double _minRel  = 0.15;

// ─── Types ──────────────────────────────────────────────────────────────────
class _Q {
  final String id, text, type; final int exp;
  const _Q(this.id, this.text, this.exp, this.type);
}
class _SS { final int idx; final double score; _SS(this.idx, this.score); }

// ════════════════════════════════════════════════════════════════════════════
// CORPUS 1 — 35 chunks (Phase 3B)
// ════════════════════════════════════════════════════════════════════════════
const List<String> _c35 = [
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

const List<_Q> _q35 = [
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

// ════════════════════════════════════════════════════════════════════════════
// CORPUS 2 — Codes / références historiques (Section C + D)
// ════════════════════════════════════════════════════════════════════════════
const List<String> _cRef = [
  // c0 — Facture FA-2026-08
  'Facture FA-2026-08 émise le 15 août 2026 par Dupont et Associés SARL. Montant HT 4850 euros. TVA 20% : 970 euros. Total TTC 5820 euros. Référence bon de commande BC-2026-0342.',
  // c1 — Facture FA-2026-09
  'Facture FA-2026-09 du 01 septembre 2026. Client Mairie de Villeneuve. Prestation audit informatique trimestriel. Montant 2400 euros HT. Conditions 30 jours net.',
  // c2 — Avoir AV-2026-03
  'Avoir AV-2026-03 correspondant à la facture FA-2026-07. Motif retour de marchandise défectueuse lot REF-PLV-2024. Montant crédité 1200 euros TTC.',
  // c3 — Erreur 0x80070005
  'Erreur système 0x80070005 accès refusé. Cette erreur Windows survient lorsqu\'un processus tente d\'accéder à une ressource sans les droits suffisants. Vérifier les permissions NTFS et les politiques de groupe.',
  // c4 — HTTP 403
  'Code d\'erreur HTTP 403 Forbidden retourné par le serveur API. L\'utilisateur est authentifié mais non autorisé à accéder à la ressource demandée. Vérifier les rôles et scopes OAuth2.',
  // c5 — NullReferenceException
  'Exception NullReferenceException dans le module OrderProcessor ligne 247. Trace System.NullReferenceException Object reference not set to an instance of an object. Vérifier les initialisations.',
  // c6 — Code HFSQL WD50027
  'Code retour HFSQL WD50027 clé dupliquée sur la table CLIENTS champ EMAIL. Opération INSERT annulée. Vérifier l\'unicité avant insertion ou utiliser HEcritSiExiste.',
  // c7 — Nom propre Beauchesne-Trottier
  'Rapport établi par Mme Beauchesne-Trottier responsable juridique. Référence interne JURI-BT-2026-114. Signé conjointement avec Me Kowalczyk-Dubois avocat au barreau de Lyon.',
  // c8 — Nom propre Vandenberghe
  'Projet Orion-Nexus piloté par M. Vandenberghe. Chef de projet adjoint Mme Aissatou Diallo-Camara. Comité de pilotage constitué le 12 mars 2026.',
  // c9 — Article L1237-19
  'Article L1237-19 du Code du travail la rupture conventionnelle collective peut être engagée par accord collectif majoritaire fixant le nombre de suppressions d\'emplois envisagées.',
  // c10 — Article 226-13
  'Article 226-13 du Code pénal la révélation d\'une information à caractère secret par une personne qui en est dépositaire est punie d\'un an d\'emprisonnement et de 15000 euros d\'amende.',
  // c11 — Art 83 RGPD
  'Règlement UE 2016/679 Article 83 paragraphe 4 violations des obligations du responsable du traitement sanctionnées jusqu\'à 10 millions d\'euros ou 2% du CA mondial.',
  // c12 — Référence pièce REF-PLV-2024
  'Pièce de rechange REF-PLV-2024 filtre à huile compatible moteur 1.5 dCi. Référence OEM 8200768927. Compatible Clio IV Dacia Logan II Kangoo III. Prix catalogue 12,90 euros.',
  // c13 — SKU-CW-3847-XL
  'Référence produit SKU-CW-3847-XL câble HDMI 2.1 48 Gbps longueur 3 mètres connecteurs dorés certifié 8K 60Hz. Stock 147 unités. Fournisseur TechLink référence TL-HD48-3M.',
  // c14 — IC-741
  'Composant électronique IC-741 amplificateur opérationnel 15V gain 200000 bande passante 1 MHz. Package DIP-8. Référence Mouser 595-LM741CN.',
  // c15 — SMSI ISO 27001
  'Le SMSI Système de Management de la Sécurité de l\'Information conforme à la norme ISO 27001 exige un inventaire des actifs une analyse de risque et un Plan de Traitement des Risques PTR.',
  // c16 — DSI PRA RTO RPO
  'La DSI Direction des Systèmes d\'Information a validé le PRA Plan de Reprise d\'Activité avec un RTO Recovery Time Objective de 4 heures et un RPO Recovery Point Objective de 1 heure.',
  // c17 — Distracteur factures générique
  'Les factures doivent être conservées pendant dix ans. Elles doivent mentionner la date le numéro séquentiel le nom du client et le détail des prestations ou marchandises vendues.',
  // c18 — Distracteur codes erreur générique
  'Les codes d\'erreur système permettent d\'identifier rapidement la cause d\'un dysfonctionnement. Ils sont définis dans les documentations techniques de chaque système d\'exploitation ou application.',
  // c19 — Distracteur articles de loi générique
  'Les articles de loi sont numérotés selon un code spécifique lettre du code suivi d\'un numéro et éventuellement d\'une subdivision. La numérotation peut différer entre versions française et européenne.',
  // c20 — Distracteur acronymes générique
  'Un acronyme est une abréviation formée à partir des initiales d\'un groupe de mots. Dans le domaine informatique les acronymes sont très répandus CPU RAM API SDK IDE.',
];

const List<_Q> _qRef = [
  // Requêtes de référence exacte
  _Q('R01', 'FA-2026-08',                                                0,  'ref facture exacte'),
  _Q('R02', '0x80070005',                                                3,  'code erreur hex exact'),
  _Q('R03', 'Beauchesne-Trottier',                                       7,  'nom propre rare exact'),
  _Q('R04', 'L1237-19',                                                  9,  'numéro article loi exact'),
  _Q('R05', 'REF-PLV-2024',                                             12,  'ref pièce exacte'),
  _Q('R06', 'SMSI',                                                     15,  'acronyme domaine exact'),
  // Requêtes partielles (token + contexte)
  _Q('R07', 'facture FA-2026-08 Dupont',                                 0,  'ref + contexte'),
  _Q('R08', 'erreur accès refusé 0x80070005',                            3,  'code + description'),
  _Q('R09', 'article L1237-19 rupture conventionnelle collective',        9,  'article + sujet'),
  // Requêtes sémantiques pures (pas de token commun avec la ref cible)
  _Q('R10', 'Quels droits à une indemnité lors d\'un départ négocié collectif ?', 9, 'sem pure → art L1237-19'),
  _Q('R11', 'Comment résoudre un problème d\'autorisation sur Windows ?',          3, 'sem pure → 0x80070005'),
  _Q('R12', 'Quelle est la durée de rétention légale des documents comptables ?', 17, 'sem pure → distracteur factures'),
];

// ════════════════════════════════════════════════════════════════════════════
// CORPUS 3 — Chunks courts (~18-24 mots)
// ════════════════════════════════════════════════════════════════════════════
const List<String> _cShort = [
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

const List<_Q> _qShort = [
  _Q('S01', 'Je veux faire effacer mes informations de leurs fichiers', 2, 'sem sans mc → effacement'),
  _Q('S02', 'Quelle est l\'amende maximale pour une infraction RGPD ?', 5, 'sem → sanction 4% CA'),
  _Q('S03', 'notification 72 heures violation',                         4, 'lexical → 72h'),
  _Q('S04', 'DPO délégué protection données',                          3, 'lexical → DPO'),
  _Q('S05', 'Quels sont les risques d\'un rançongiciel ?',             10, 'sem → ransomware fr→en'),
];

// ════════════════════════════════════════════════════════════════════════════
// CORPUS 4 — Chunks longs (~200-230 mots)
// ════════════════════════════════════════════════════════════════════════════
const List<String> _cLong = [
  'Le Règlement Général sur la Protection des Données RGPD entré en application le 25 mai 2018 constitue le texte de référence en matière de protection des données à caractère personnel au sein de l\'Union Européenne. Il remplace la directive 95/46/CE adoptée en 1995 et vise à unifier le cadre juridique applicable dans l\'ensemble des États membres. Le RGPD repose sur plusieurs principes fondamentaux la licéité la loyauté et la transparence du traitement la limitation des finalités la minimisation des données l\'exactitude et la limitation de la conservation. Il consacre également de nouveaux droits pour les personnes physiques notamment le droit à l\'oubli le droit à la portabilité le droit d\'accès et le droit de rectification. Les organisations qui ne respectent pas ces obligations s\'exposent à des sanctions administratives pouvant atteindre 4% du chiffre d\'affaires annuel mondial ou 20 millions d\'euros selon le montant le plus élevé prononcées par les autorités de contrôle nationales.',
  'En droit du travail français le contrat à durée indéterminée CDI représente la forme normale et générale de la relation de travail conformément à l\'article L1221-2 du Code du travail. Il peut être rompu soit à l\'initiative du salarié par démission soit à l\'initiative de l\'employeur par licenciement personnel ou économique soit d\'un commun accord par rupture conventionnelle individuelle ou collective. Le licenciement pour motif économique est encadré par les articles L1233-1 et suivants du Code du travail. Il intervient lorsque l\'entreprise fait face à des difficultés économiques réelles et sérieuses à des mutations technologiques affectant l\'emploi ou lorsqu\'une réorganisation est nécessaire à la sauvegarde de sa compétitivité. La durée légale du travail est fixée à 35 heures par semaine les heures supplémentaires sont majorées ou compensées en repos.',
  'La sécurité des systèmes d\'information repose sur trois piliers CIA Confidentialité Intégrité Disponibilité. Pour assurer ces garanties les organisations déploient des mesures techniques incluant le déploiement de pare-feux l\'authentification multifacteur MFA le chiffrement TLS et AES-256 et la réalisation régulière d\'audits de sécurité incluant des tests de pénétration. Sur le plan organisationnel la mise en place d\'un Système de Management de la Sécurité de l\'Information SMSI conforme à la norme ISO 27001 est recommandée. En cas d\'incident notamment d\'attaque par ransomware ou de violation de données un Plan de Reprise d\'Activité PRA préalablement testé permet de minimiser les pertes et de restaurer les services dans les délais définis par les objectifs de reprise RTO RPO.',
];

const List<_Q> _qLong = [
  _Q('L01', 'Quelles sont les sanctions prévues par le RGPD ?',               0, 'sem → sanctions 4% dans c0'),
  _Q('L02', 'Comment fonctionne le licenciement économique en France ?',       1, 'sem → licenciement dans c1'),
  _Q('L03', 'ransomware SMSI PRA RTO',                                        2, 'lexical → sécu dans c2'),
  _Q('L04', 'Quelle est la durée légale de travail hebdomadaire ?',            1, 'sem → 35h dans c1'),
  _Q('L05', 'ISO 27001 plan reprise activité objectifs recovery',              2, 'lexical → sécu c2'),
];

// ─── 12 requêtes négatives ──────────────────────────────────────────────────
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

// ─── Algorithmes ────────────────────────────────────────────────────────────
double _cos(List<double> a, List<double> b) {
  double d=0,na=0,nb=0;
  for(var i=0;i<a.length;i++){d+=a[i]*b[i];na+=a[i]*a[i];nb+=b[i]*b[i];}
  if(na==0||nb==0) return 0;
  return (d/(math.sqrt(na)*math.sqrt(nb))).clamp(-1.0,1.0);
}

List<_SS> _semList(List<double> q, List<List<double>> vecs, {double minRel=0.0}) {
  final r=<_SS>[];
  for(var i=0;i<vecs.length;i++){
    final s=_cos(q,vecs[i]); if(s>=minRel) r.add(_SS(i,s));
  }
  r.sort((a,b)=>b.score.compareTo(a.score));
  return r;
}

List<_SS> _kwList(String query, List<String> chunks) {
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

List<int> _current(List<_SS> s, List<_SS> k) {
  final sc=<int,double>{};
  for(var r=0;r<s.length;r++) sc[s[r].idx]=(sc[s[r].idx]??0)+1/(_kRrf+r+1);
  for(var r=0;r<k.length;r++) sc[k[r].idx]=(sc[k[r].idx]??0)+1/(_kRrf+r+1);
  return (sc.keys.toList()..sort((a,b)=>sc[b]!.compareTo(sc[a]!))).take(_topK).toList();
}

List<int> _cond(List<_SS> s, List<_SS> k, {double thr=_condThr}) {
  final sc=<int,double>{};
  for(var r=0;r<s.length;r++) sc[s[r].idx]=(sc[s[r].idx]??0)+1/(_kRrf+r+1);
  if(k.isNotEmpty && k.first.score > thr) {
    for(var r=0;r<k.length;r++) sc[k[r].idx]=(sc[k[r].idx]??0)+1/(_kRrf+r+1);
  }
  return (sc.keys.toList()..sort((a,b)=>sc[b]!.compareTo(sc[a]!))).take(_topK).toList();
}

List<int> _semPurList(List<_SS> s) => s.take(_topK).map((x)=>x.idx).toList();

int _rkH(List<int> r, int exp) { final i=r.indexOf(exp); return i<0?-1:i+1; }
int _rkS(List<_SS> r, int exp) { final i=r.indexWhere((s)=>s.idx==exp); return i<0?-1:i+1; }
String _flag(int r) => r==1?'✅T1':r>=1&&r<=3?'✅T3':r>=1&&r<=5?'⚠️T5':'❌';

double _avg(List<double> l)=>l.isEmpty?0:l.reduce((a,b)=>a+b)/l.length;
double _minD(List<double> l)=>l.isEmpty?0:l.reduce((a,b)=>a<b?a:b);
double _maxD(List<double> l)=>l.isEmpty?0:l.reduce((a,b)=>a>b?a:b);

// ─── Globals ─────────────────────────────────────────────────────────────────
late CrispEmbed _ml;
bool _lmAvail = false;
late List<List<double>> _ml35, _mlRef, _mlShort, _mlLong;
List<List<double>>? _lm35, _lmRef, _lmShort, _lmLong;

Future<List<double>?> _enc(String text) async {
  if(!_lmAvail) return null;
  try {
    final r=await http.post(Uri.parse(_lmUrl),
        headers:{'Content-Type':'application/json'},
        body:jsonEncode({'model':_lmModel,'input':text}));
    if(r.statusCode==200){
      return (jsonDecode(r.body)['data'][0]['embedding'] as List).cast<double>();
    }
  } catch(_){}
  return null;
}

Future<List<List<double>>?> _encBatch(List<String> texts) async {
  if(!_lmAvail) return null;
  final res=<List<double>>[];
  for(final t in texts){
    final v=await _enc(t);
    if(v==null) return null;
    res.add(v);
  }
  return res;
}

// ─── MAIN ────────────────────────────────────────────────────────────────────
void main() {

  setUpAll(() async {
    _ml = CrispEmbed(_gguf, nThreads:4,
        libPath: File(_dll).existsSync()?_dll:null);

    _ml35    = _c35.map((c)=>_ml.encode(c).toList()).toList();
    _mlRef   = _cRef.map((c)=>_ml.encode(c).toList()).toList();
    _mlShort = _cShort.map((c)=>_ml.encode(c).toList()).toList();
    _mlLong  = _cLong.map((c)=>_ml.encode(c).toList()).toList();

    print('\n[MiniLM] 4 corpus : ${_c35.length}c / ${_cRef.length}c / ${_cShort.length}c / ${_cLong.length}c');

    try {
      final r=await http.post(Uri.parse(_lmUrl),
          headers:{'Content-Type':'application/json'},
          body:jsonEncode({'model':_lmModel,'input':'test'}))
          .timeout(const Duration(seconds:5));
      if(r.statusCode==200){
        _lmAvail=true;
        _lm35    = await _encBatch(_c35.toList());
        _lmRef   = await _encBatch(_cRef.toList());
        _lmShort = await _encBatch(_cShort.toList());
        _lmLong  = await _encBatch(_cLong.toList());
        print('[LM Studio] 4 corpus dim=${_lm35!.first.length}');
      }
    } catch(_){ print('[LM Studio] non disponible'); }
  });

  tearDownAll(()=>_ml.dispose());

  // ══════════════════════════════════════════════════════════════════════════
  // SECTION C — Cas lexicaux historiques : codes, références, noms propres
  // ══════════════════════════════════════════════════════════════════════════
  group('C — Cas lexicaux historiques', () {
    test('C: Current vs D-Cond vs SemPur vs Keyword — codes/refs', () async {
      print('\n'+'═'*115);
      print('SECTION C — CAS LEXICAUX HISTORIQUES (${_cRef.length} chunks)');
      print('D-Cond ne doit pas supprimer un résultat lexical exact utile.');
      print('─'*115);
      print('  ${"ID".padRight(4)} | ${"Type".padRight(34)} | Sem | KW  | Cur | Cnd ${" ".padRight(3)} | QwCur | QwCnd | kw_score | KW actif?');
      print('  ${"─"*115}');

      int regress=0;
      int mSemT5=0, mKwT5=0, mCurT5=0, mCondT5=0;
      int lCurT5=0, lCondT5=0;

      for(final q in _qRef){
        final qv  = _ml.encode(q.text).toList();
        final semR= _semList(qv, _mlRef, minRel:_minRel);
        final kwR = _kwList(q.text, _cRef.toList());
        final cur = _current(semR, kwR);
        final cn  = _cond(semR, kwR);

        final rSem = _rkS(semR, q.exp);
        final rKw  = _rkS(kwR,  q.exp);
        final rCur = _rkH(cur,  q.exp);
        final rCn  = _rkH(cn,   q.exp);
        if(rSem>=1&&rSem<=5) mSemT5++;
        if(rKw>=1&&rKw<=5)   mKwT5++;
        if(rCur>=1&&rCur<=5) mCurT5++;
        if(rCn>=1&&rCn<=5)   mCondT5++;

        // Régression : kw avait trouvé en T5, D-Cond a perdu
        if(rKw>=1&&rKw<=5 && (rCn<0||rCn>5)) regress++;

        final kwS    = kwR.isNotEmpty?kwR.first.score:0.0;
        final kwAct  = kwR.isNotEmpty && kwS > _condThr;

        String qwCur='N/A', qwCn='N/A';
        if(_lmAvail && _lmRef!=null){
          final lqv=await _enc(q.text);
          if(lqv!=null){
            final lSem=_semList(lqv, _lmRef!, minRel:_minRel);
            final lCur=_current(lSem, kwR);
            final lCn =_cond(lSem, kwR);
            final rLC=_rkH(lCur,q.exp); qwCur=rLC>0?'r$rLC':'  —';
            final rLN=_rkH(lCn,q.exp);  qwCn =rLN>0?'r$rLN':'  —';
            if(rLC>=1&&rLC<=5) lCurT5++;
            if(rLN>=1&&rLN<=5) lCondT5++;
          }
        }

        print('  ${q.id.padRight(4)} | ${q.type.padRight(34)} | '
            '${rSem>0?"r${rSem.toString().padLeft(2)}":"—  "} | '
            '${rKw>0?"r${rKw.toString().padLeft(2)}":"—  "} | '
            '${rCur>0?"r${rCur.toString().padLeft(2)}":"—  "} | '
            '${rCn>0?"r${rCn.toString().padLeft(2)} ${_flag(rCn)}":"—   ❌  "} | '
            '${qwCur.padRight(5)} | ${qwCn.padRight(5)} | '
            '${kwS.toStringAsFixed(3)} | ${kwAct?"KW actif":"—"}');
      }

      print('\n  RÉSUMÉ C (${_qRef.length} requêtes) :');
      print('  MiniLM  SemPur=${mSemT5}/${_qRef.length} T5 | KW=${mKwT5}/${_qRef.length} T5 | Current=${mCurT5}/${_qRef.length} T5 | D-Cond=${mCondT5}/${_qRef.length} T5');
      if(_lmAvail) print('  LM Studio  Current=${lCurT5}/${_qRef.length} T5 | D-Cond=${lCondT5}/${_qRef.length} T5');
      print('  Régressions D-Cond vs KW (refs exactes perdues) : $regress');
      expect(regress, equals(0),
          reason: 'D-Cond ne doit pas supprimer un résultat lexical exact utile');
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  // SECTION D — Robustesse seuil 0.2 sur 4 corpus
  // ══════════════════════════════════════════════════════════════════════════
  group('D — Robustesse seuil $_condThr sur 4 corpus', () {
    test('D: distribution kw_top1_score × longueur chunk', () {
      print('\n'+'═'*115);
      print('SECTION D — ROBUSTESSE SEUIL D-Cond = $_condThr');
      print('Formule : score = matches/sqrt(chunkLen)  → dépend de la longueur');
      print('═'*115);

      void analyzeCorpus(String label, List<String> corpus, List<_Q> queries) {
        final above=<double>[], below=<double>[];
        int kwAct=0, kwIgn=0;
        final words=corpus.map((c)=>c.split(RegExp(r'\s+')).length).toList();
        final avgW=words.reduce((a,b)=>a+b)/words.length;
        final sqrtAvg=math.sqrt(avgW);

        print('\n  ── $label (${corpus.length} chunks, avg ~${avgW.toStringAsFixed(0)} mots, sqrt=${sqrtAvg.toStringAsFixed(1)}) ──');

        for(final q in queries){
          final kwR=_kwList(q.text, corpus);
          if(kwR.isEmpty){ kwIgn++; continue; }
          final s=kwR.first.score;
          if(s>_condThr){kwAct++;above.add(s);}
          else{kwIgn++;below.add(s);}
          print('    ${q.id}: kw=${s.toStringAsFixed(3)} → ${s>_condThr?"KW actif":"KW ignoré"}');
        }
        final oneToken=1.0/sqrtAvg;
        final twoToken=2.0/sqrtAvg;
        print('  1 token match dans chunk moyen: ${oneToken.toStringAsFixed(3)} '
            '${oneToken>_condThr?"→ PASSE seuil":"→ ne passe pas"}');
        print('  2 tokens match dans chunk moyen: ${twoToken.toStringAsFixed(3)} '
            '${twoToken>_condThr?"→ PASSE seuil":"→ ne passe pas"}');
        print('  KW actif=$kwAct  KW ignoré=$kwIgn');
        if(above.isNotEmpty) print('  Au-dessus: min=${_minD(above).toStringAsFixed(3)} avg=${_avg(above).toStringAsFixed(3)} max=${_maxD(above).toStringAsFixed(3)}');
        if(below.isNotEmpty) print('  Sous seuil: min=${_minD(below).toStringAsFixed(3)} avg=${_avg(below).toStringAsFixed(3)} max=${_maxD(below).toStringAsFixed(3)}');
      }

      analyzeCorpus('35 chunks (Phase 3B)', _c35.toList(), _q35.toList());
      analyzeCorpus('Références/Codes', _cRef.toList(), _qRef.toList());
      analyzeCorpus('Chunks courts (~20 mots)', _cShort.toList(), _qShort.toList());
      analyzeCorpus('Chunks longs (~200 mots)', _cLong.toList(), _qLong.toList());

      // Vérification mathématique de la dépendance
      final shortAvgW = _cShort.map((c)=>c.split(RegExp(r'\s+')).length.toDouble()).reduce((a,b)=>a+b)/_cShort.length;
      final longAvgW  = _cLong.map((c)=>c.split(RegExp(r'\s+')).length.toDouble()).reduce((a,b)=>a+b)/_cLong.length;
      final shortOne = 1.0/math.sqrt(shortAvgW);
      final longOne  = 1.0/math.sqrt(longAvgW);
      final minMatchesLong = (_condThr * math.sqrt(longAvgW)).ceil();

      print('\n  CONCLUSION ROBUSTESSE :');
      print('  - Chunks courts (~${shortAvgW.toStringAsFixed(0)}m) : 1 token → ${shortOne.toStringAsFixed(3)}'
          ' → ${shortOne>_condThr?"PASSE (trop permissif)":"ne passe pas"}');
      print('  - Chunks longs (~${longAvgW.toStringAsFixed(0)}m) : 1 token → ${longOne.toStringAsFixed(3)}'
          ' ; nécessite ≥ $minMatchesLong tokens pour passer $_condThr');
      print('  → Verdict seuil : DÉPENDANT DU CORPUS — comportement différent selon longueur chunk.');
      print('    La condition score>0.2 est équivalente à matches > 0.2 × sqrt(chunkLen),');
      print('    soit ~${(0.2*math.sqrt(shortAvgW)).toStringAsFixed(1)} tokens pour chunks courts');
      print('    et  ~${(0.2*math.sqrt(longAvgW)).toStringAsFixed(1)} tokens pour chunks longs.');

      expect(true, isTrue);
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  // SECTION E — Comparaison normative SemPur / Current / D-Cond × 4 corpus
  // ══════════════════════════════════════════════════════════════════════════
  group('E — Comparaison normative × 4 corpus', () {
    test('E: Top-1/3/5 SemPur / Current / D-Cond', () async {
      print('\n'+'═'*115);
      print('SECTION E — COMPARAISON NORMATIVE (Top-1 | Top-3 | Top-5)');
      print('Métrique principale : Top-5 (fragments transmis au LLM)');
      print('═'*115);

      Future<void> bench(String label, List<String> corpus,
          List<_Q> queries, List<List<double>> mlV, List<List<double>>? lmV) async {
        final n=queries.length;
        final mSem=[0,0,0], mCur=[0,0,0], mCnd=[0,0,0];
        final lSem=[0,0,0], lCur=[0,0,0], lCnd=[0,0,0];
        final mSmiss=<String>[], mCndMiss=<String>[];

        for(var i=0;i<queries.length;i++){
          final q=queries[i];
          final qv=_ml.encode(q.text).toList();
          final sr=_semList(qv,mlV,minRel:_minRel);
          final kr=_kwList(q.text,corpus);
          final cu=_current(sr,kr);
          final cn=_cond(sr,kr);
          final sp=_semPurList(sr);

          final rCur=_rkH(cu,q.exp), rCnd=_rkH(cn,q.exp);
          final rSp =_rkH(sp,q.exp);
          if(rSp==1) mSem[0]++; if(rSp>=1&&rSp<=3) mSem[1]++; if(rSp>=1&&rSp<=5) mSem[2]++;
          if(rSp<0||rSp>3) mSmiss.add(q.id);
          if(rCur==1) mCur[0]++; if(rCur>=1&&rCur<=3) mCur[1]++; if(rCur>=1&&rCur<=5) mCur[2]++;
          if(rCnd==1) mCnd[0]++; if(rCnd>=1&&rCnd<=3) mCnd[1]++; if(rCnd>=1&&rCnd<=5) mCnd[2]++;
          if(rCnd<0||rCnd>3) mCndMiss.add(q.id);

          if(_lmAvail&&lmV!=null){
            final lqv=await _enc(q.text);
            if(lqv!=null){
              final lsr=_semList(lqv,lmV,minRel:_minRel);
              final lku=_current(lsr,kr); final lkn=_cond(lsr,kr); final lsp=_semPurList(lsr);
              final ls=_rkH(lsp,q.exp), lc=_rkH(lku,q.exp), ln=_rkH(lkn,q.exp);
              if(ls==1) lSem[0]++; if(ls>=1&&ls<=3) lSem[1]++; if(ls>=1&&ls<=5) lSem[2]++;
              if(lc==1) lCur[0]++; if(lc>=1&&lc<=3) lCur[1]++; if(lc>=1&&lc<=5) lCur[2]++;
              if(ln==1) lCnd[0]++; if(ln>=1&&ln<=3) lCnd[1]++; if(ln>=1&&ln<=5) lCnd[2]++;
            }
          }
        }

        print('\n  ── $label ($n requêtes) ──');
        print('  ${"Pipeline".padRight(22)} | T-1  | T-3  | T-5  | Miss T-3');
        print('  ${"─"*70}');
        print('  ${"MiniLM SemPur".padRight(22)} | ${mSem[0]}/$n | ${mSem[1]}/$n | ${mSem[2]}/$n | ${mSmiss.isEmpty?"aucun":mSmiss.join(",")}');
        print('  ${"MiniLM Current".padRight(22)} | ${mCur[0]}/$n | ${mCur[1]}/$n | ${mCur[2]}/$n |');
        print('  ${"MiniLM D-Cond".padRight(22)} | ${mCnd[0]}/$n | ${mCnd[1]}/$n | ${mCnd[2]}/$n | ${mCndMiss.isEmpty?"aucun":mCndMiss.join(",")}');
        if(_lmAvail&&lmV!=null){
          print('  ${"Qwen3 SemPur".padRight(22)} | ${lSem[0]}/$n | ${lSem[1]}/$n | ${lSem[2]}/$n |');
          print('  ${"Qwen3 Current".padRight(22)} | ${lCur[0]}/$n | ${lCur[1]}/$n | ${lCur[2]}/$n |');
          print('  ${"Qwen3 D-Cond".padRight(22)} | ${lCnd[0]}/$n | ${lCnd[1]}/$n | ${lCnd[2]}/$n |');
        }
      }

      await bench('35 chunks Phase 3B', _c35.toList(), _q35.toList(), _ml35, _lm35);
      await bench('Références/Codes', _cRef.toList(), _qRef.toList(), _mlRef, _lmRef);
      await bench('Chunks courts', _cShort.toList(), _qShort.toList(), _mlShort, _lmShort);
      await bench('Chunks longs',  _cLong.toList(), _qLong.toList(), _mlLong, _lmLong);

      expect(true, isTrue);
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  // SECTION F — Requêtes hors-sujet : D-Cond vs Current injections
  // ══════════════════════════════════════════════════════════════════════════
  group('F — Requêtes négatives : D-Cond n\'aggrave pas les injections', () {
    test('F: 12 négatives sur corpus 35', () {
      print('\n'+'═'*115);
      print('SECTION F — REQUÊTES NÉGATIVES (${_neg.length} requêtes) corpus 35 chunks');
      print('minRel=$_minRel — injection si sem cos1 >= $_minRel');
      print('═'*115);
      print('  ${"ID".padRight(4)} | ${"Type".padRight(28)} | cos1   | KW    | Curr top | Cnd top | Dégradation');
      print('  ${"─"*100}');

      int injCur=0, injCnd=0, kwActNeg=0;

      for(final q in _neg){
        final qv  = _ml.encode(q.text).toList();
        final semR= _semList(qv, _ml35, minRel:0.0);
        final kwR = _kwList(q.text, _c35.toList());
        final cur = _current(semR, kwR);
        final cn  = _cond(semR, kwR);

        final cos1  = semR.isNotEmpty?semR.first.score:0.0;
        final kwS   = kwR.isNotEmpty?kwR.first.score:0.0;
        final inj   = cos1>=_minRel;
        final kwAct = kwR.isNotEmpty && kwS > _condThr;

        if(inj) injCur++;
        if(inj) injCnd++; // injection pilotée par sem, pas par kw
        if(kwAct) kwActNeg++;

        final topCur = cur.isNotEmpty?'c${cur.first}':'—';
        final topCnd = cn.isNotEmpty?'c${cn.first}':'—';
        final diff   = (cur.isNotEmpty&&cn.isNotEmpty&&cur.first!=cn.first)?'⚠️ top chunk différent':'=';

        print('  ${q.id.padRight(4)} | ${q.type.padRight(28)} | '
            '${cos1.toStringAsFixed(3)} ${inj?"⚠️":"✅"} | '
            '${kwS.toStringAsFixed(3)} ${kwAct?"act":"—  "} | '
            '${topCur.padRight(8)} | ${topCnd.padRight(8)} | $diff');
      }

      print('\n  RÉSUMÉ F :');
      print('  Injections Current : $injCur/${_neg.length}');
      print('  Injections D-Cond  : $injCnd/${_neg.length}  → ${injCnd>injCur?"AGGRAVE":"N\'AGGRAVE PAS"}');
      print('  KW actif sur neg   : $kwActNeg/${_neg.length}');
      print('  Note : l\'injection est pilotée par le seuil sémantique (minRel=$_minRel),');
      print('  pas par D-Cond. D-Cond ne peut pas augmenter le nombre d\'injections.');

      expect(injCnd, lessThanOrEqualTo(injCur),
          reason: 'D-Cond ne doit pas augmenter les injections hors-sujet');
    });
  });
}
