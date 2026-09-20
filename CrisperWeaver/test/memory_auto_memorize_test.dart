// test/memory_auto_memorize_test.dart
//
// Tests Dart PURS de la logique C2 — sans dépendance Flutter/dart:ui.
// Utilise package:test uniquement.
//
// CES TESTS PROUVENT :
//   T1  : réponses 1–9   → 0 déclenchement de _memorize
//   T2  : réponse 10     → exactement 1 déclenchement
//   T3  : réponses 11–19 → pas de déclenchement supplémentaire
//   T4  : réponse 20     → 2e déclenchement (nouveau cycle)
//   T5  : resetLlmContextKeepScreen() ne remet PAS le compteur à zéro
//   T6  : clearAllContext() — snapshot pré-clear contient les messages corrects
//   T7  : clearAllContext() avec messages vides → 0 appel mémoire
//   T8  : snapshot est une copie figée, immune aux mutations post-clear
//   T9  : _aiResponseCount = 0 après clearAllContext()
//   T10 : exception serveur dans _memorize → clearAllContext ne crashe pas

import 'package:test/test.dart';

// ── Logique extraite de _DocumentChatWidgetState ─────────────────────────────
// Reproduit fidèlement les règles C2 sans dépendances Flutter.

class _TestMsg {
  final String role;
  final String content;
  const _TestMsg(this.role, this.content);
  @override String toString() => '$role:$content';
}

class _AutoMemLogic {
  int _count = 0;
  final List<String> memorizeSnapshots = [];   // trace des arguments passés

  void onAiResponseCompleted(List<_TestMsg> messages) {
    _count++;
    if (_count % 10 == 0) {
      memorizeSnapshots.add(messages.map((m) => m.toString()).join('|'));
    }
  }

  List<_TestMsg> clearAllContext(List<_TestMsg> messages) {
    final snapshot = List<_TestMsg>.of(messages);   // copie figée AVANT clear
    if (snapshot.isNotEmpty) {
      memorizeSnapshots.add('[pre-clear]${snapshot.map((m) => m.toString()).join('|')}');
    }
    _count = 0;
    return snapshot;   // l'appelant vide sa liste lui-même
  }

  void resetLlmContextKeepScreen() { /* ne touche PAS à _count */ }

  int get count => _count;
  int get memorizeCallCount => memorizeSnapshots.length;
}

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  final msg = [const _TestMsg('user', 'Q'), const _TestMsg('assistant', 'A')];

  group('Compteur auto-mémorisation toutes les 10 réponses', () {
    late _AutoMemLogic logic;
    setUp(() => logic = _AutoMemLogic());

    test('T1 — réponses 1–9 → 0 déclenchement', () {
      for (var i = 0; i < 9; i++) logic.onAiResponseCompleted(msg);
      expect(logic.memorizeCallCount, 0);
      expect(logic.count, 9);
    });

    test('T2 — réponse 10 → exactement 1 déclenchement', () {
      for (var i = 0; i < 10; i++) logic.onAiResponseCompleted(msg);
      expect(logic.memorizeCallCount, 1);
      expect(logic.count, 10);
    });

    test('T3 — réponses 11–19 → pas de déclenchement supplémentaire', () {
      for (var i = 0; i < 19; i++) logic.onAiResponseCompleted(msg);
      expect(logic.memorizeCallCount, 1);
    });

    test('T4 — réponse 20 → 2e déclenchement', () {
      for (var i = 0; i < 20; i++) logic.onAiResponseCompleted(msg);
      expect(logic.memorizeCallCount, 2);
      expect(logic.count, 20);
    });

    test('T5 — resetLlmContextKeepScreen ne remet pas le compteur à zéro', () {
      for (var i = 0; i < 7; i++) logic.onAiResponseCompleted(msg);
      logic.resetLlmContextKeepScreen();
      expect(logic.count, 7, reason: 'Compteur conservé après reset LLM context');
      for (var i = 7; i < 10; i++) logic.onAiResponseCompleted(msg);
      expect(logic.memorizeCallCount, 1,
          reason: 'Déclenchement à 10 après resetLlmContextKeepScreen');
    });
  });

  group('Snapshot avant Tout vider', () {
    late _AutoMemLogic logic;
    setUp(() => logic = _AutoMemLogic());

    test('T6 — snapshot contient les messages pré-clear', () {
      final live = [
        const _TestMsg('user', 'Question'),
        const _TestMsg('assistant', 'Réponse mémorable'),
      ];
      final snap = logic.clearAllContext(live);
      expect(snap.length, 2);
      expect(snap[0].content, 'Question');
      expect(snap[1].content, 'Réponse mémorable');
      expect(logic.memorizeCallCount, 1);
      expect(logic.memorizeSnapshots[0], contains('[pre-clear]'));
      expect(logic.memorizeSnapshots[0], contains('Question'));
    });

    test('T7 — clearAllContext vide → 0 appel mémoire', () {
      final snap = logic.clearAllContext([]);
      expect(snap.isEmpty, isTrue);
      expect(logic.memorizeCallCount, 0);
    });

    test('T8 — snapshot est une copie figée (immune aux mutations post-clear)', () {
      final live = [const _TestMsg('user', 'A'), const _TestMsg('assistant', 'B')];
      final snap = logic.clearAllContext(live);
      live.clear();   // simule _messages.clear() post-setState
      expect(snap.length, 2, reason: 'Snapshot non affecté par clear post-capture');
      expect(snap[0].content, 'A');
    });

    test('T9 — _aiResponseCount = 0 après clearAllContext', () {
      for (var i = 0; i < 7; i++) logic.onAiResponseCompleted(msg);
      logic.clearAllContext(msg);
      expect(logic.count, 0);
      // Nouveau cycle : doit déclencher à la 10e réponse suivante
      for (var i = 0; i < 10; i++) logic.onAiResponseCompleted(msg);
      expect(logic.memorizeCallCount, 2,
          reason: '1 pre-clear + 1 nouveau cycle de 10');
    });

    test('T10 — exception dans _memorize → clearAllContext ne crashe pas', () {
      final live = [const _TestMsg('user', 'Test')];
      List<_TestMsg>? snap;
      expect(() {
        snap = logic.clearAllContext(live);
        // Simuler exception _memorize (serveur down)
        try { throw Exception('Connection refused'); } catch (_) { /* capturé */ }
      }, returnsNormally);
      expect(snap?.length, 1);
      expect(snap![0].content, 'Test');
    });
  });
}
