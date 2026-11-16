// Thoughts always belong to a process card. The Reasoning preference controls
// expansion, not classification; prose never disappears into the card.
import 'package:flutter_test/flutter_test.dart';
import 'package:opencode_mobile/domain/models.dart';
import 'package:opencode_mobile/ui/screens/chat_screen.dart' as chat;

MessageWithParts _prompt(String id) => MessageWithParts(
  info: MessageInfo.fromJson({
    'id': id,
    'sessionID': 'session',
    'role': 'user',
    'time': {'created': 1},
  }),
  parts: [Part(id: 'text-0', type: 'text', text: 'Explain the router.')],
);

MessageWithParts _step(String id, List<Part> parts) => MessageWithParts(
  info: MessageInfo.fromJson({
    'id': id,
    'sessionID': 'session',
    'role': 'assistant',
    'time': {'created': 2},
  }),
  parts: parts,
);

Part _thought(String text) =>
    Part(id: 'reasoning-0', type: 'reasoning', text: text, messageID: 'a1');

Part _tool() =>
    Part(id: 'call-1', type: 'tool', callID: 'call-1', messageID: 'a1');

Part _text(String id, String value) =>
    Part(id: id, type: 'text', text: value, messageID: 'a1');

void main() {
  test('thoughts belong to work with either reasoning preference', () {
    final thought = _thought('Consider both options carefully.\nThen decide.');
    final tool = _tool();
    expect(chat.debugRunsAreWork([thought, tool]), [true, true]);
    expect(chat.debugRunsAreWork([thought, tool], keepReasoning: true), [
      true,
      true,
    ]);
  });

  test('a one-line thought stays its own step inside the work card', () {
    final thought = _thought('**Rebuilding the router**');
    final tool = _tool();
    expect(chat.debugRunsAreWork([thought, tool]), [true, true]);
    expect(chat.debugRunsAreWork([thought, tool], keepReasoning: true), [
      true,
      true,
    ]);
  });

  test('a thought never folds the prose before it, with either preference', () {
    final passing = _text('text-0', 'Let me check the router:');
    final thought = _thought('The routes are built in main.dart.\nCheck it.');
    final explanation = _text(
      'text-1',
      'The router is assembled at startup and every screen registers itself.',
    );
    chat.debugTimelineDisplayParts([
      _prompt('u1'),
      _step('a1', [passing, thought, explanation]),
    ]);
    expect(chat.debugIsFoldedIntoWork(passing), isFalse);

    final passingOn = _text('text-0', 'Let me check the router:');
    final thoughtOn = _thought('The routes are built in main.dart.\nCheck it.');
    final explanationOn = _text(
      'text-1',
      'The router is assembled at startup.',
    );
    chat.debugTimelineDisplayParts([
      _prompt('u2'),
      _step('a1', [passingOn, thoughtOn, explanationOn]),
    ], keepReasoning: true);
    expect(chat.debugIsFoldedIntoWork(passingOn), isFalse);
  });
}
