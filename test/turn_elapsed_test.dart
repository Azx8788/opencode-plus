import 'package:flutter_test/flutter_test.dart';
import 'package:opencode_mobile/domain/models.dart';
import 'package:opencode_mobile/domain/turn_elapsed.dart';

MessageWithParts step(
  String id, {
  int? created,
  int? firstToken,
  int? streamed,
  int? completed,
  List<Part> parts = const [],
}) => MessageWithParts(
  info: MessageInfo(
    id: id,
    sessionID: 's',
    role: 'assistant',
    modelID: 'model',
    time: MsgTime(
      created: created,
      firstToken: firstToken,
      streamed: streamed,
      completed: completed,
    ),
  ),
  parts: parts,
);

void main() {
  test('recorded phases are separated; the generation window is not double counted', () {
    final reasoning = Part(
      type: 'reasoning',
      text: 'thought',
      startedAt: DateTime.fromMillisecondsSinceEpoch(1500),
      completedAt: DateTime.fromMillisecondsSinceEpoch(2500),
    );
    final tool = Part(
      type: 'tool',
      callID: 'c1',
      toolState: ToolState(
        status: 'completed',
        startedAt: DateTime.fromMillisecondsSinceEpoch(3000),
        completedAt: DateTime.fromMillisecondsSinceEpoch(8000),
      ),
    );
    final elapsed = TurnElapsed.fromSteps([
      step(
        'a1',
        created: 1000,
        firstToken: 1500,
        streamed: 4000,
        completed: 8500,
        parts: [reasoning, tool],
      ),
    ]);
    expect(elapsed.wait, const Duration(milliseconds: 500));
    expect(elapsed.thinking, const Duration(milliseconds: 1000));
    // The remaining 1.5s could contain tool arguments, not necessarily text.
    expect(elapsed.output, Duration.zero);
    expect(elapsed.unclassified, const Duration(milliseconds: 1500));
    expect(elapsed.toolExecution, const Duration(seconds: 5));
    expect(elapsed.wall, const Duration(milliseconds: 7500));
    expect(elapsed.steps, 1);
    expect(elapsed.toolCalls, 1);
  });

  test(
    'V1 text intervals supply output when no streaming window was recorded',
    () {
      final text = Part(
        type: 'text',
        text: 'answer',
        startedAt: DateTime.fromMillisecondsSinceEpoch(2000),
        completedAt: DateTime.fromMillisecondsSinceEpoch(3500),
      );
      final elapsed = TurnElapsed.fromSteps([
        step('a1', created: 1000, completed: 4000, parts: [text]),
      ]);
      expect(elapsed.output, const Duration(milliseconds: 1500));
      expect(elapsed.wait, Duration.zero);
      expect(elapsed.wall, const Duration(milliseconds: 3000));
    },
  );

  test(
    'missing timestamps stay unknown; unexecuted calls are not tool time',
    () {
      final elapsed = TurnElapsed.fromSteps([
        step(
          'a1',
          parts: [
            Part(
              type: 'tool',
              toolState: ToolState(
                status: 'pending',
                executed: false,
                startedAt: DateTime.fromMillisecondsSinceEpoch(1),
                completedAt: DateTime.fromMillisecondsSinceEpoch(9000),
              ),
            ),
          ],
        ),
      ]);
      expect(elapsed.isEmpty, isTrue);
      expect(elapsed.wall, isNull);
      expect(elapsed.toolCalls, 0);
    },
  );

  test(
    'session groups replies by prompts and totals only recorded reply spans',
    () {
      final session = SessionElapsed.fromMessages([
        MessageWithParts(
          info: MessageInfo(id: 'u1', sessionID: 's', role: 'user'),
        ),
        step(
          'a1',
          created: 1000,
          firstToken: 1500,
          streamed: 2500,
          completed: 3000,
        ),
        // A replayed step with the same server id must count once.
        step(
          'a1',
          created: 1000,
          firstToken: 1500,
          streamed: 2500,
          completed: 3000,
        ),
        MessageWithParts(
          info: MessageInfo(id: 'u2', sessionID: 's', role: 'user'),
        ),
        step(
          'a3',
          created: 5000,
          firstToken: 5500,
          streamed: 6500,
          completed: 7000,
        ),
      ]);
      expect(session.turns.length, 2);
      expect(session.steps, 2);
      expect(session.wait, const Duration(seconds: 1));
      expect(session.output, Duration.zero);
      expect(session.unclassified, const Duration(seconds: 2));
      // Two reply spans, not the wall time that includes the person's pause.
      expect(session.wall, const Duration(seconds: 4));
    },
  );

  test('overlapping explicit parts and repeated tool calls count once', () {
    Part text(int a, int b) => Part(
      type: 'text',
      text: 'x',
      startedAt: DateTime.fromMillisecondsSinceEpoch(a),
      completedAt: DateTime.fromMillisecondsSinceEpoch(b),
    );
    final tool = Part(
      type: 'tool',
      callID: 'c',
      toolState: ToolState(
        status: 'completed',
        startedAt: DateTime.fromMillisecondsSinceEpoch(4000),
        completedAt: DateTime.fromMillisecondsSinceEpoch(5000),
      ),
    );
    final elapsed = TurnElapsed.fromSteps([
      step(
        'one',
        created: 1000,
        firstToken: 2000,
        streamed: 4000,
        completed: 5000,
        parts: [text(2000, 3500), text(3000, 4000), tool],
      ),
      MessageWithParts(
        info: MessageInfo(
          id: 'shell-notice',
          sessionID: 's',
          role: 'assistant',
        ),
        parts: [tool],
      ),
    ]);
    expect(elapsed.output, const Duration(seconds: 2));
    expect(elapsed.unclassified, Duration.zero);
    expect(elapsed.toolExecution, const Duration(seconds: 1));
    expect(elapsed.toolCalls, 1);
  });
}
