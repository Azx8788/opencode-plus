import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencode_mobile/api2/client.dart';
import 'package:opencode_mobile/api2/gateway_operations.dart';
import 'package:opencode_mobile/domain/usage_statistics.dart';

void main() {
  test('bucket reads use the scoped statistics API, not provider requests or a database', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final received = Completer<Uri>();
    final from = DateTime(2026, 11, 16).millisecondsSinceEpoch;
    final to = DateTime(2026, 11, 17).millisecondsSinceEpoch;
    final subscription = server.listen((request) async {
      expect(request.method, 'GET');
      expect(request.uri.path, '/api/session/stats');
      received.complete(request.uri);
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode({
          'data': {
            'range': {'from': from, 'to': to},
            'sessions': 1,
            'subagents': 0,
            'prompts': 1,
            'steps': 2,
            'activeDays': 1,
            'streak': 1,
            'cost': 0,
            'tokens': {
              'input': 100,
              'output': 20,
              'reasoning': 5,
              'cache': {'read': 400, 'write': 0},
            },
            'tools': {'mode': 'none'},
            'models': [],
            'activity': [
              {'date': '2026-11-16', 'steps': 2},
            ],
          },
        }),
      );
      await request.response.close();
    });
    final client = Api2Client.connect(
      baseUrl: 'http://127.0.0.1:${server.port}',
      password: '',
      directory: '/must-not-leak-location',
    );
    addTearDown(() async {
      client.close();
      await subscription.cancel();
      await server.close(force: true);
    });
    final repository = Api2OperationsGateway(client: client);
    final stats = await repository.loadUsageStatistics(
      UsageQuery(
        from: from,
        to: to,
        timezone: 'Asia/Shanghai',
        projectID: 'chosen-project',
      ),
    );
    final uri = await received.future;
    expect(uri.queryParameters['from'], '$from');
    expect(uri.queryParameters['to'], '$to');
    expect(uri.queryParameters['project'], 'chosen-project');
    expect(uri.queryParameters['timezone'], 'Asia/Shanghai');
    expect(
      uri.queryParameters.keys.any((key) => key.startsWith('location')),
      isFalse,
    );
    expect(stats.tokens.prompt, 500);
    expect(stats.tokens.completion, 25);
    expect(stats.tokens.total, 525);
  });
}
