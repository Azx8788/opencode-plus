// The transcript's "Reasoning" switch keeps a turn's thoughts in view.
//
// With it off (the default), a finished turn folds its thoughts and tool calls
// into one work line: a thought streams past and then disappears behind the
// line. With it on, a thought keeps a block of its own, so what the model
// thought stays readable after the turn ends — tool calls still fold.
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
  test('with the switch on, a thought is not folded into the work line', () {
    final thought = _thought('Consider both options carefully.\nThen decide.');
    final tool = _tool();
    expect(chat.debugRunsAreWork([thought, tool]), [true, true]);
    expect(
      chat.debugRunsAreWork([thought, tool], keepReasoning: true),
      [false, true],
    );
  });

  test('with the switch on, a one-line thought stays a block of its own', () {
    final thought = _thought('**Rebuilding the router**');
    final tool = _tool();
    // Off: the line titles the tool run, so both are one work stretch.
    expect(chat.debugRunsAreWork([thought, tool]), [true]);
    // On: the thought keeps its own block above the work line.
    expect(
      chat.debugRunsAreWork([thought, tool], keepReasoning: true),
      [false, true],
    );
  });

  test('with the switch on, a thought does not fold the line before it', () {
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
    expect(chat.debugIsFoldedIntoWork(passing), isTrue);

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