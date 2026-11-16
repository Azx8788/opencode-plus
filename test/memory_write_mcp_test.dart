import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencode_mobile/builtin/agents/gen_ui_server.dart';
import 'package:opencode_mobile/domain/long_term_memory.dart';

void main() {
  test('installed MCP advertises memory_write and only acknowledges pending review', () async {
    final directory = await Directory.systemTemp.createTemp('oc-memory-mcp-');
    addTearDown(() => directory.delete(recursive: true));
    final marker = File('${directory.path}/enabled');
    await marker.writeAsString('enabled\n');
    final helper = File('${directory.path}/server.cjs');
    await helper.writeAsString(
      genUiServerScript(enabledMarkerPath: marker.path),
    );
    final requests = [
      {
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'initialize',
        'params': {
          'protocolVersion': '2025-11-25',
          'capabilities': {},
          'clientInfo': {'name': 'memory-test', 'version': '1'},
        },
      },
      {'jsonrpc': '2.0', 'method': 'notifications/initialized'},
      {'jsonrpc': '2.0', 'id': 2, 'method': 'tools/list'},
      for (final (index, args) in [
        {
          'memories': ['请用中文回答'],
          'scope': 'global',
        },
        {
          'memories': ['本项目用 Flutter'],
          'scope': 'project',
        },
        {'memories': [], 'scope': 'global'},
        {
          'memories': ['中' * 342],
          'scope': 'global',
        },
        {
          'memories': ['a'],
          'scope': 'other-project',
        },
        {
          'memories': ['a'],
          'scope': 'global',
          'file': '/tmp/not-allowed',
        },
      ].indexed)
        {
          'jsonrpc': '2.0',
          'id': index + 3,
          'method': 'tools/call',
          'params': {'name': 'memory_write', 'arguments': args},
        },
    ];
    final process = await Process.start('node', [helper.path]);
    addTearDown(() => process.kill());
    final stdout = process.stdout.transform(utf8.decoder).join();
    final stderr = process.stderr.transform(utf8.decoder).join();
    for (final request in requests) {
      process.stdin.writeln(jsonEncode(request));
    }
    await process.stdin.close();
    expect(await process.exitCode.timeout(const Duration(seconds: 15)), 0);
    expect(await stderr, isEmpty);
    final replies = (await stdout)
        .trim()
        .split('\n')
        .map((s) => jsonDecode(s) as Map)
        .toList();
    final catalog =
        (replies.singleWhere((r) => r['id'] == 2)['result']['tools'] as List)
            .cast<Map>();
    expect(catalog.map((t) => t['name']), [
      'show',
      'find_connectors',
      'memory_write',
    ]);
    expect(catalog.last['inputSchema']['required'], ['memories', 'scope']);
    for (var id = 3; id <= 8; id++) {
      final result = replies.singleWhere((r) => r['id'] == id)['result'];
      if (id <= 4) {
        expect(result['isError'], isNull);
        expect(result['content'][0]['text'], startsWith(memoryWriteReceipt));
      } else {
        expect(result['isError'], isTrue);
      }
    }
    // The tool has no vault access and creates no files, even on success.
    expect(await directory.list().length, 2);
  });
}
