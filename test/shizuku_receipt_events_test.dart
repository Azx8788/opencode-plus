import 'package:flutter_test/flutter_test.dart';
import 'package:opencode_mobile/api2/events.dart';
import 'package:opencode_mobile/api2/gateway_events.dart';
import 'package:opencode_mobile/domain/models.dart';
import 'package:opencode_mobile/domain/shizuku_receipt.dart';

void main() {
  late Api2EventAdapter adapter;
  setUp(() => adapter = Api2EventAdapter());

  List<EventEnvelope> send(String type, Map<String, dynamic> data) =>
      adapter.adapt(
        Api2EventEnvelope.fromJson({
          'type': type,
          'created': 1000,
          'data': data,
        }),
      );

  void start({String id = 'call1'}) {
    send('session.tool.input.started', {
      'sessionID': 'ses1',
      'assistantMessageID': 'msg1',
      'id': id,
      'name': 'shizuku_exec',
    });
    send('session.tool.called', {
      'sessionID': 'ses1',
      'assistantMessageID': 'msg1',
      'id': id,
      'input': {'command': 'test command'},
      'executed': false,
    });
  }

  ToolState tool(List<EventEnvelope> events) {
    final part =
        events
                .firstWhere((e) => e.type == 'message.part.updated')
                .properties['part']
            as Map;
    return ToolState.fromJson(part['state']);
  }

  test('progress operation reference survives an interrupted step', () {
    start();
    send('session.tool.progress', {
      'sessionID': 'ses1',
      'assistantMessageID': 'msg1',
      'id': 'call1',
      'metadata': {
        'android': {'operationId': 'original', 'state': 'waiting'},
      },
    });
    final events = send('session.execution.interrupted', {
      'sessionID': 'ses1',
      'reason': 'user',
    });
    final state = tool(events);
    expect(state.metadata?['android']['operationId'], 'original');
    expect(state.executed, isFalse);
    final receipt = ShizukuReceipt.forTool(
      'shizuku_exec',
      metadata: state.metadata,
      inFlight: state.inFlight,
    );
    expect(receipt?.kind, ShizukuReceiptKind.unconfirmed);
    expect(receipt?.operationId, 'original');
    expect(events.any((e) => e.type == 'session.transcript.stale'), isTrue);
  });

  test(
    'a correlated Core rejection is distinct from interrupting another call',
    () {
      start();
      start(id: 'call2');
      send('permission.asked', {
        'id': 'request1',
        'sessionID': 'ses1',
        'action': 'shizuku',
        'resources': ['test command'],
        'source': {'type': 'tool', 'messageID': 'msg1', 'id': 'call1'},
      });
      send('permission.replied', {
        'requestID': 'request1',
        'sessionID': 'ses1',
        'reply': 'reject',
      });
      final events = send('session.execution.interrupted', {
        'sessionID': 'ses1',
        'reason': 'user',
      });
      final parts = events
          .where((e) => e.type == 'message.part.updated')
          .map((e) => e.properties['part'] as Map)
          .toList();
      final rejected = ToolState.fromJson(
        parts.singleWhere((p) => p['callID'] == 'call1')['state'],
      );
      final other = ToolState.fromJson(
        parts.singleWhere((p) => p['callID'] == 'call2')['state'],
      );
      expect(rejected.declined, isTrue);
      expect(other.declined, isFalse);
      expect(other.output, 'Tool execution interrupted');
    },
  );

  test('mismatched session reply cannot create a refusal', () {
    start();
    send('permission.asked', {
      'id': 'request1',
      'sessionID': 'ses1',
      'action': 'shizuku',
      'source': {'type': 'tool', 'messageID': 'msg1', 'id': 'call1'},
    });
    send('permission.replied', {
      'requestID': 'request1',
      'sessionID': 'ses2',
      'reply': 'reject',
    });
    final state = tool(
      send('session.execution.interrupted', {
        'sessionID': 'ses1',
        'reason': 'user',
      }),
    );
    expect(state.declined, isFalse);
  });
}
