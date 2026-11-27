import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencode_mobile/api2/channel_replies.dart';
import 'package:opencode_mobile/api2/client.dart';

void main() {
  const sessionID = 'ses-chat';
  final started = DateTime.fromMillisecondsSinceEpoch(100);
  const prompt = '检查环境';

  late Api2ChannelReplies replies;
  late List<Map<String, Object?>> transcript;
  late Map<String, Object?> status;
  late List<Uri> queries;

  Map<String, Object?> assistant(
    String id,
    String text, {
    int? completed = 125,
  }) => {
    'type': 'assistant',
    'id': id,
    'time': {'created': 110, 'completed': completed},
    'content': [
      {'type': 'reasoning', 'text': 'never relay this'},
      {'type': 'text', 'text': text},
    ],
  };

  setUp(() async {
    transcript = [
      {
        'type': 'idle',
        'id': 'msg-idle',
        'outcome': 'succeeded',
        'time': {'created': 130},
      },
      assistant('msg-answer', '环境正常。'),
      {
        'type': 'user',
        'id': 'msg-user',
        'text': prompt,
        'time': {'created': 101},
      },
    ];
    status = {};
    queries = [];
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      queries.add(request.uri);
      final data = switch (request.uri.path) {
        '/api/session/$sessionID' => {
          'id': sessionID,
          'outcome': 'succeeded',
          'time': {'idle': 130},
        },
        '/api/session/$sessionID/message' => transcript,
        '/api/session/$sessionID/message/msg-original' => assistant(
          'msg-original',
          '切换之前的答复。',
        ),
        '/api/session/active' => status,
        _ => null,
      };
      request.response
        ..statusCode = data == null ? HttpStatus.notFound : HttpStatus.ok
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({'data': data}));
      await request.response.close();
    });
    final client = Api2Client.connect(
      baseUrl: 'http://127.0.0.1:${server.port}',
      password: '',
    );
    addTearDown(client.close);
    replies = Api2ChannelReplies(client);
  });

  test(
    'reads the original message by ID even when the transcript has moved on',
    () async {
      final reply = await replies.byId(sessionID, 'msg-original');
      expect(reply?.messageId, 'msg-original');
      expect(reply?.text, '切换之前的答复。');
      expect(
        queries.single.path,
        '/api/session/$sessionID/message/msg-original',
      );
    },
  );

  test('an unanswered newer prompt cannot borrow text from history', () async {
    transcript.insert(0, {
      'type': 'user',
      'id': 'msg-new',
      'text': '新问题',
      'time': {'created': 135},
    });
    expect(await replies.latest(sessionID), isNull);
  });

  test(
    'the fallback needs durable success, the submitted prompt and visible text',
    () async {
      final reply = await replies.recover(sessionID, started, prompt);
      expect(reply?.messageId, 'msg-answer');
      expect(reply?.text, '环境正常。');
      expect(queries.map((uri) => uri.path), [
        '/api/session/$sessionID',
        '/api/session/$sessionID/message',
        '/api/session/active',
      ]);
      expect(queries[1].queryParameters['order'], 'desc');
    },
  );

  test(
    'wrong prompt, running session and incomplete transcript are not success',
    () async {
      expect(await replies.recover(sessionID, started, '另一项任务'), isNull);
      status = {
        sessionID: {'type': 'running'},
      };
      expect(await replies.recover(sessionID, started, prompt), isNull);
      status.clear();
      transcript[1] = assistant('msg-answer', '还在生成', completed: null);
      expect(await replies.recover(sessionID, started, prompt), isNull);
      transcript[1] = assistant('msg-answer', '环境正常。');
      transcript.removeAt(0);
      expect(await replies.recover(sessionID, started, prompt), isNull);
    },
  );

  test('a previously observed step must belong to the recovered run', () async {
    transcript.insert(2, assistant('msg-step', '先检查工具。'));
    final reply = await replies.recover(
      sessionID,
      started,
      prompt,
      observedMessageId: 'msg-step',
    );
    expect(reply?.messageId, 'msg-answer');
    expect(
      await replies.recover(
        sessionID,
        started,
        prompt,
        observedMessageId: 'some-other-step',
      ),
      isNull,
    );
  });
}
