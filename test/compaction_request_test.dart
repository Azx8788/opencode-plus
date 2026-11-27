import 'package:flutter_test/flutter_test.dart';
import 'package:opencode_mobile/api2/compaction_request.dart';
import 'package:opencode_mobile/api2/events.dart';
import 'package:opencode_mobile/api2/gateway_events.dart';
import 'package:opencode_mobile/domain/models.dart';
import 'package:opencode_mobile/domain/server_gateway.dart';

const _plain = ServerCapabilities();

const _options = ServerCapabilities(
  compactionOptions: true,
  compactionKeepTurns: true,
);

void main() {
  group('compaction request body', () {
    test('an old server keeps the empty body', () {
      expect(
        compactSessionBody(
          const CompactOptions(instructions: 'keep the plan', keepTurns: 2),
          _plain,
        ),
        isEmpty,
      );
    });

    test('options follow the server capabilities', () {
      expect(
        compactSessionBody(
          const CompactOptions(instructions: 'keep the plan', keepTurns: 2),
          _options,
        ),
        {'instructions': 'keep the plan', 'keepTurns': 2},
      );
    });

    test('a blank instruction is not sent', () {
      expect(
        compactSessionBody(
          const CompactOptions(instructions: '   '),
          _options,
        ),
        isEmpty,
      );
    });

    test('a token budget is only sent when turns are not', () {
      expect(
        compactSessionBody(
          const CompactOptions(keepTokens: 15000),
          _options,
        ),
        {
          'keep': {'tokens': 15000},
        },
      );
      expect(
        compactSessionBody(
          const CompactOptions(keepTokens: 15000, keepTurns: 1),
          _options,
        ),
        {'keepTurns': 1},
      );
    });
  });

  group('compaction events', () {
    final adapter = Api2EventAdapter();
    List<EventEnvelope> send(String type, Map<String, dynamic> data) =>
        adapter.adapt(
          Api2EventEnvelope.fromJson({
            'type': type,
            'created': 1000,
            'data': data,
          }),
        );

    test('started, ended and failed reach the app unchanged', () {
      for (final phase in ['started', 'ended', 'failed']) {
        final events = send('session.compaction.$phase', {
          'sessionID': 'ses1',
          'reason': 'manual',
          if (phase == 'failed') 'error': {'message': 'too long'},
        });
        expect(events.single.type, 'session.compaction.$phase');
        expect(events.single.properties['sessionID'], 'ses1');
      }
    });

    test('a reverted boundary is a distinct event', () {
      final events = send('session.compaction.reverted', {
        'sessionID': 'ses1',
        'compactionID': 'msg_c',
        'modelVisibleFrom': 'msg_a',
      });
      expect(events.single.type, 'session.compaction.reverted');
      expect(events.single.properties['compactionID'], 'msg_c');
      expect(events.single.properties['modelVisibleFrom'], 'msg_a');
    });
  });
}