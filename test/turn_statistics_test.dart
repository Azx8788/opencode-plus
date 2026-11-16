import 'package:flutter_test/flutter_test.dart';
import 'package:opencode_mobile/api2/events.dart';
import 'package:opencode_mobile/api2/gateway_events.dart';
import 'package:opencode_mobile/api2/gateway_mappers.dart';
import 'package:opencode_mobile/api2/models.dart';
import 'package:opencode_mobile/domain/models.dart';
import 'package:opencode_mobile/domain/turn_statistics.dart';

MessageWithParts _step(
  String id, {
  int? created,
  int? firstToken,
  int? streamed,
  int? completed,
  Tokens? tokens,
  List<Part> parts = const [],
  bool model = true,
}) => MessageWithParts(
  info: MessageInfo(
    id: id,
    sessionID: 'session',
    role: 'assistant',
    modelID: model ? 'model' : null,
    providerID: model ? 'provider' : null,
    tokens: tokens,
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
  test('context is the last request, speed excludes the ten-second tool', () {
    final tool = Part(
      id: 'call',
      callID: 'call',
      type: 'tool',
      toolName: 'shell',
      toolState: ToolState(status: 'completed'),
    );
    final first = _step(
      'a1',
      created: 1000,
      firstToken: 1500,
      streamed: 2500,
      completed: 12500,
      tokens: Tokens(
        input: 100,
        output: 60,
        reasoning: 40,
        cacheRead: 900,
        cacheWrite: 100,
      ),
      parts: [tool],
    );
    final last = _step(
      'a2',
      created: 13000,
      firstToken: 14000,
      streamed: 16000,
      completed: 16000,
      tokens: Tokens(input: 2000, output: 100, reasoning: 20, cacheRead: 8000),
    );
    final shellNotice = _step(
      'shell-notice',
      created: 17000,
      completed: 20000,
      model: false,
      parts: [tool],
    );
    final stats = TurnStatistics.fromSteps([first, last, shellNotice, last]);
    expect(stats.steps, 2);
    expect(stats.toolCalls, 1);
    expect(stats.contextTokens, 10120);
    expect(stats.lastUsage!.cacheRead, 8000);
    expect(stats.cacheHitRate, .8);
    expect(stats.total.input, 2100);
    expect(stats.generatedTokens, 220);
    expect(stats.total.total, 11320);
    expect(stats.duration, const Duration(seconds: 15));
    expect(stats.generationDuration, const Duration(seconds: 3));
    expect(stats.tokensPerSecond, closeTo(220 / 3, .001));
  });

  test(
    'missing final usage is unknown, not an earlier request or an estimate',
    () {
      final stats = TurnStatistics.fromSteps([
        _step(
          'a1',
          created: 1000,
          firstToken: 1100,
          streamed: 2100,
          completed: 2100,
          tokens: Tokens(input: 100, output: 50),
        ),
        _step(
          'a2',
          created: 2200,
          firstToken: 2300,
          streamed: 3300,
          completed: 3300,
          parts: [Part(type: 'text', text: 'An answer.')],
        ),
      ]);
      expect(stats.contextTokens, isNull);
      expect(stats.cacheHitRate, isNull);
      expect(stats.tokensPerSecond, isNull);
      expect(
        stats.total.total,
        150,
        reason: 'reported usage is still inspectable',
      );
      expect(stats.steps, 2);
    },
  );

  test('wall-clock timestamps do not become generation speed', () {
    final stats = TurnStatistics.fromSteps([
      _step(
        'a1',
        created: 1000,
        completed: 3000,
        tokens: Tokens(input: 100, output: 50),
      ),
    ]);
    expect(stats.duration, const Duration(seconds: 2));
    expect(stats.tokensPerSecond, isNull);
    expect(TurnStatistics.fromSteps([_step('a2')]).duration, isNull);
    expect(TurnStatistics.fromSteps([_step('a2')]).contextTokens, isNull);
  });

  test(
    'cache rate uses final prompt input including cache writes, not output',
    () {
      final stats = TurnStatistics.fromSteps([
        _step('previous', tokens: Tokens(input: 1, cacheRead: 999)),
        _step(
          'last',
          tokens: Tokens(
            input: 100,
            cacheRead: 300,
            cacheWrite: 100,
            output: 500,
            reasoning: 1000,
          ),
        ),
      ]);
      expect(stats.cacheHitRate, .6);
      expect(
        TurnStatistics.fromSteps([
          _step('last', tokens: Tokens(input: 100, output: 50)),
        ]).cacheHitRate,
        0,
      );
      expect(
        TurnStatistics.fromSteps([_step('last', tokens: Tokens(output: 50))])
            .cacheHitRate,
        isNull,
      );
    },
  );

  test('explicit overlapping V1 intervals are counted once', () {
    Part timed(String type, int start, int end) => Part(
      type: type,
      text: type,
      startedAt: DateTime.fromMillisecondsSinceEpoch(start),
      completedAt: DateTime.fromMillisecondsSinceEpoch(end),
    );
    final stats = TurnStatistics.fromSteps([
      _step(
        'a1',
        tokens: Tokens(output: 90, reasoning: 10),
        parts: [timed('reasoning', 1000, 2500), timed('text', 2000, 3000)],
      ),
    ]);
    expect(stats.generationDuration, const Duration(seconds: 2));
    expect(stats.tokensPerSecond, 50);
  });

  test('bad timing and unexecuted calls do not manufacture statistics', () {
    final stats = TurnStatistics.fromSteps([
      _step(
        'a1',
        created: 5000,
        firstToken: 5000,
        streamed: 4000,
        completed: 4000,
        tokens: Tokens(output: 50),
        parts: [
          Part(
            type: 'tool',
            callID: 'not-run',
            toolState: ToolState(status: 'pending', executed: false),
          ),
        ],
      ),
    ]);
    expect(stats.duration, isNull);
    expect(stats.tokensPerSecond, isNull);
    expect(stats.toolCalls, 0);
  });

  test('V2 refetch retains first-token, stream and reasoning timestamps', () {
    final message = Api2Message.fromJson({
      'id': 'a1',
      'type': 'assistant',
      'agent': 'build',
      'model': {'providerID': 'provider', 'id': 'model'},
      'time': {
        'created': 1000,
        'firstToken': 1100,
        'streamed': 26000,
        'completed': 28000,
      },
      'tokens': {
        'input': 100,
        'output': 100,
        'reasoning': 100,
        'cache': {'read': 0, 'write': 0},
      },
      'content': [
        {
          'type': 'reasoning',
          'text': 'Think carefully.',
          'time': {'created': 1100, 'completed': 25200},
        },
        {'type': 'text', 'text': 'Done.'},
      ],
    })!;
    final mapped = mapApi2Message('session', message);
    expect(mapped.info.time!.firstToken, 1100);
    expect(mapped.info.time!.streamed, 26000);
    expect(mapped.parts.first.duration, const Duration(milliseconds: 24100));
    expect(mapped.parts.first.ended, isTrue);
    expect(
      TurnStatistics.fromSteps([mapped]).generationDuration,
      const Duration(milliseconds: 24900),
    );
  });

  test(
    'live events preserve server clocks and usage through step completion',
    () {
      final adapter = Api2EventAdapter();
      List<EventEnvelope> send(
        String type,
        int? time,
        Map<String, dynamic> data,
      ) => adapter.adapt(
        Api2EventEnvelope.fromJson({
          'type': type,
          'created': ?time,
          'data': {'sessionID': 'session', 'assistantMessageID': 'a1', ...data},
        }),
      );
      send('session.step.started', 1000, {
        'agent': 'build',
        'model': {'providerID': 'provider', 'id': 'model'},
      });
      send('session.step.first-token', 1100, {});
      send('session.step.streamed', 2100, {
        'tokens': {
          'input': 100,
          'output': 50,
          'reasoning': 10,
          'cache': {'read': 20, 'write': 0},
        },
        'cost': .01,
      });
      final ended = send('session.step.ended', 3100, {'finish': 'stop'});
      final info = MessageInfo.fromJson(
        ended
                .singleWhere((event) => event.type == 'message.updated')
                .properties['info']
            as Map<String, dynamic>,
      );
      expect(info.time!.created, 1000);
      expect(info.time!.firstToken, 1100);
      expect(info.time!.streamed, 2100);
      expect(info.time!.completed, 3100);
      expect(info.tokens.total, 180);
      expect(info.cost, .01);
      send('session.reasoning.started', 1200, {'ordinal': 0});
      final thought = send('session.reasoning.ended', 1700, {
        'ordinal': 0,
        'text': 'A thought.',
      });
      final part = Part.fromJson(
        thought.single.properties['part'] as Map<String, dynamic>,
      );
      expect(part.duration, const Duration(milliseconds: 500));
      send('session.reasoning.started', null, {'ordinal': 1});
      final noTime = send('session.reasoning.ended', null, {
        'ordinal': 1,
        'text': 'No timing.',
      });
      final unknown = Part.fromJson(
        noTime.single.properties['part'] as Map<String, dynamic>,
      );
      expect(unknown.duration, isNull);
      expect(unknown.ended, isTrue);
    },
  );
}
