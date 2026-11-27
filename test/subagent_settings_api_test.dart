import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencode_mobile/api2/client.dart';
import 'package:opencode_mobile/api2/gateway.dart';
import 'package:opencode_mobile/api2/subagent_settings_catalog.dart';
import 'package:opencode_mobile/background/live_background.dart';
import 'package:opencode_mobile/domain/server_gateway.dart';
import 'package:opencode_mobile/domain/subagent_settings.dart';
import 'package:opencode_mobile/state/connection.dart';
import 'package:opencode_mobile/state/profiles.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures/subagent_settings_fixture.dart';

void main() {
  late HttpServer server;
  late Api2Client client;
  late StreamSubscription<HttpRequest> listener;
  late List<HttpRequest> requests;
  Object? modelResponse;
  Object? projectResponse;
  Completer<void>? gate;
  Completer<void>? bothRequested;

  setUp(() async {
    gate = null;
    bothRequested = null;
    requests = [];
    modelResponse = {
      'data': [
        {
          'id': 'old-model',
          'providerID': 'gateway',
          'name': 'Old model',
          'variants': [
            {'id': 'high'},
            {'id': 'disabled', 'disabled': true},
          ],
        },
        {
          'id': 'new-model',
          'providerID': 'gateway',
          'name': 'New model',
          'variants': [],
        },
      ],
    };
    projectResponse = {
      'data': [
        {'id': 'project-one', 'name': 'Project', 'canonical': '/work/project'},
      ],
    };
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    listener = server.listen((request) async {
      requests.add(request);
      if (requests.length == 2) bothRequested?.complete();
      await gate?.future;
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode(
          request.uri.path == '/api/model' ? modelResponse : projectResponse,
        ),
      );
      await request.response.close();
    });
    client = Api2Client.connect(
      baseUrl: 'http://127.0.0.1:${server.port}',
      password: '',
      directory: '/work/project',
      workspace: 'workspace-one',
    );
  });

  tearDown(() async {
    client.close();
    await listener.cancel();
    await server.close(force: true);
  });

  test(
    'only existing read-only routes run; all models and exact variants are retained',
    () async {
      final result = await Api2SubagentSettingsCatalog(client).load();
      expect(requests.map((r) => r.method).toSet(), {'GET'});
      expect(requests.map((r) => r.uri.path).toSet(), {
        '/api/model',
        '/api/project',
      });
      final modelRequest = requests.singleWhere(
        (r) => r.uri.path == '/api/model',
      );
      expect(
        modelRequest.uri.queryParameters['location[directory]'],
        '/work/project',
      );
      expect(
        modelRequest.uri.queryParameters['location[workspace]'],
        'workspace-one',
      );
      expect(result.models.map((m) => m.id), ['old-model', 'new-model']);
      expect(result.projects.single.id, 'project-one');
      expect(
        result.candidates.keys
            .where((m) => m.modelID == 'old-model')
            .map((m) => m.variant)
            .toSet(),
        {null, 'high'},
      );
    },
  );

  test(
    'malformed catalogue is unknown, not a successful empty catalogue',
    () async {
      modelResponse = {'data': 'invalid'};
      await expectLater(
        Api2SubagentSettingsCatalog(client).load(),
        throwsFormatException,
      );
    },
  );

  test(
    'unconsumed pagination is not silently treated as a complete pool',
    () async {
      modelResponse = {'data': [], 'next': 'another-page'};
      await expectLater(
        Api2SubagentSettingsCatalog(client).load(),
        throwsFormatException,
      );
    },
  );

  test(
    'invalid variants and duplicate stable project IDs are rejected',
    () async {
      modelResponse = {
        'data': [
          {
            'id': 'a',
            'providerID': 'gateway',
            'variants': [{}],
          },
        ],
      };
      await expectLater(
        Api2SubagentSettingsCatalog(client).load(),
        throwsFormatException,
      );
      modelResponse = {'data': []};
      projectResponse = {
        'data': [
          {'id': 'same'},
          {'id': 'same'},
        ],
      };
      await expectLater(
        Api2SubagentSettingsCatalog(client).load(),
        throwsFormatException,
      );
    },
  );

  test('a location switch invalidates the original in-flight read', () async {
    gate = Completer<void>();
    bothRequested = Completer<void>();
    final loading = Api2SubagentSettingsCatalog(client).load();
    await bothRequested!.future;
    client.setLocation(directory: '/work/other');
    gate!.complete();
    await expectLater(
      loading,
      throwsA(
        isA<SubagentSettingsException>().having(
          (e) => e.reason,
          'reason',
          SubagentSettingsFailure.staleTarget,
        ),
      ),
    );
  });

  test('the settings connection only reads the exact live catalogue', () async {
    final profile = subagentProfile('one');
    SharedPreferences.setMockInitialValues({
      'oc.profiles': jsonEncode([profile, subagentProfile('two')]),
      'oc.activeProfile': 'two',
    });
    final prefs = await SharedPreferences.getInstance();
    final controller =
        ConnectionController(
            ProfileStore(prefs: prefs),
            isIsolated: true,
            backgroundLive: BackgroundLiveController(
              preferences: prefs,
              invoke: (_, [arguments]) async => const {},
            ),
          )
          ..adoptConnectedProfileForTesting(ServerProfile.fromJson(profile))
          ..api = Api2Gateway(client: client)
          ..status = StreamStatus.connected;
    addTearDown(controller.dispose);
    await expectLater(
      controller.readSubagentDraftCatalog(subagentServer('two')),
      throwsA(
        isA<SubagentSettingsException>().having(
          (error) => error.reason,
          'reason',
          SubagentSettingsFailure.unavailable,
        ),
      ),
    );
    expect(requests, isEmpty);

    final catalog = await controller.readSubagentDraftCatalog(
      subagentServer('one'),
    );
    expect(catalog.models, hasLength(2));
    expect(requests.map((r) => r.method).toSet(), {'GET'});
  });
}
