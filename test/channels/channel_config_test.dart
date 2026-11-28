import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opencode_mobile/channels/channel_config.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<ChannelConfigStore> _store() async {
  SharedPreferences.setMockInitialValues({});
  FlutterSecureStorage.setMockInitialValues({});
  return ChannelConfigStore(
    preferences: await SharedPreferences.getInstance(),
    secureStorage: const FlutterSecureStorage(),
  );
}

void main() {
  test('an enabled official bot needs a numeric AppID', () async {
    final store = await _store();
    await expectLater(
      store.saveOfficialQq(
        const OfficialQqConfig(appId: 'abc', enabled: true),
        clientSecret: 'secret-value-123',
      ),
      throwsFormatException,
    );
  });

  test('an enabled official bot needs a secret', () async {
    final store = await _store();
    await expectLater(
      store.saveOfficialQq(
        const OfficialQqConfig(appId: '102000001', enabled: true),
      ),
      throwsFormatException,
    );
  });

  test('the secret is stored apart from the config', () async {
    final store = await _store();
    await store.saveOfficialQq(
      const OfficialQqConfig(appId: '102000001', enabled: true),
      clientSecret: 'secret-value-123',
    );

    expect(store.loadOfficialQq().appId, '102000001');
    expect(store.loadOfficialQq().enabled, isTrue);
    expect(await store.readOfficialQqSecret(), 'secret-value-123');
    final preferences = await SharedPreferences.getInstance();
    expect(
      preferences.getString('oc.channels.qqOfficial.config'),
      isNot(contains('secret-value-123')),
      reason: 'a secret must never be written to plain preferences',
    );
  });

  test('clearing removes both halves', () async {
    final store = await _store();
    await store.saveOfficialQq(
      const OfficialQqConfig(appId: '102000001', enabled: true),
      clientSecret: 'secret-value-123',
    );
    await store.clearOfficialQq();
    expect(store.loadOfficialQq().appId, isEmpty);
    expect(await store.readOfficialQqSecret(), isNull);
  });

  test(
    'official QQ card identity survives disabling but not a new secret',
    () async {
      final store = await _store();
      const account = OfficialQqConfig(appId: '102000001', enabled: true);
      await store.saveOfficialQq(account, clientSecret: 'first-fixture-secret');
      expect(store.verifiedOfficialAccount(account), isNull);
      await store.rememberOfficialAccount(account);

      await store.saveOfficialQq(account.copyWith(enabled: false));
      expect(
        store.verifiedOfficialAccount(store.loadOfficialQq()),
        account.appId,
      );
      await store.saveOfficialQq(
        account,
        clientSecret: 'second-fixture-secret',
      );
      expect(store.verifiedOfficialAccount(store.loadOfficialQq()), isNull);
    },
  );

  test('OneBot card uses verification, not a typed account id', () async {
    final store = await _store();
    const config = OneBot11Config(
      expectedSelfId: '12345',
      webSocketUrl: 'ws://127.0.0.1:3001/',
    );
    await store.saveOneBot11(config, accessToken: 'fixture-token');
    expect(store.verifiedOneBotAccount(config), isNull);
    await store.rememberOneBotAccount(config, '54321');
    expect(store.verifiedOneBotAccount(config), isNull);
    await store.rememberOneBotAccount(config, '12345');
    await store.saveOneBot11(config.copyWith(allowedUsers: {'12345'}));
    expect(store.verifiedOneBotAccount(store.loadOneBot11()), '12345');

    await store.saveOneBot11(
      config.copyWith(webSocketUrl: 'ws://127.0.0.1:3002/'),
    );
    expect(store.verifiedOneBotAccount(store.loadOneBot11()), isNull);
    await store.clearOneBot11();
    expect(store.verifiedOneBotAccount(store.loadOneBot11()), isNull);
  });

  test('a WebSocket address must be ws or wss with a host', () async {
    final store = await _store();
    for (final bad in ['', 'http://host:3001', 'ws://', 'host:3001']) {
      await expectLater(
        store.saveOneBot11(
          OneBot11Config(webSocketUrl: bad, enabled: true),
          accessToken: 'token-1',
        ),
        throwsFormatException,
        reason: '$bad should be rejected',
      );
    }
    await store.saveOneBot11(
      const OneBot11Config(
        webSocketUrl: 'ws://127.0.0.1:3001',
        expectedSelfId: '10001',
        enabled: true,
      ),
      accessToken: 'token-1',
    );
    expect(store.loadOneBot11().webSocketUrl, 'ws://127.0.0.1:3001');
    expect(await store.readOneBot11Token(), 'token-1');
  });

  test(
    'fresh OneBot settings recommend SnowLuma without enabling it',
    () async {
      final store = await _store();
      expect(store.loadOneBot11().backend, OneBotBackend.snowLuma);
      expect(store.loadOneBot11().enabled, isFalse);
      expect(store.loadOneBot11().webSocketUrl, isEmpty);
      expect(await store.readOneBot11Token(), isNull);
    },
  );

  test('SnowLuma activation needs an account and a OneBot token', () async {
    final store = await _store();
    const draft = OneBot11Config(
      webSocketUrl: 'ws://127.0.0.1:3001/',
      enabled: true,
    );

    await expectLater(
      store.saveOneBot11(draft, accessToken: 'test-token'),
      throwsFormatException,
    );
    await expectLater(
      store.saveOneBot11(draft.copyWith(expectedSelfId: '10001')),
      throwsFormatException,
    );
    expect(store.loadOneBot11().enabled, isFalse);
    expect(await store.readOneBot11Token(), isNull);
  });

  test('a SnowLuma address cannot store a credential in the URL', () async {
    final store = await _store();
    for (final url in [
      'wss://test-user:password@qq.invalid/onebot',
      'wss://qq.invalid/onebot?access_token=test-token',
      'wss://qq.invalid/onebot#token',
    ]) {
      await expectLater(
        store.saveOneBot11(OneBot11Config(webSocketUrl: url)),
        throwsFormatException,
      );
    }
    expect(store.loadOneBot11().webSocketUrl, isEmpty);
  });

  test('an expected account must look like a QQ number', () async {
    final store = await _store();
    await expectLater(
      store.saveOneBot11(
        const OneBot11Config(
          webSocketUrl: 'ws://127.0.0.1:3001',
          expectedSelfId: 'abc',
        ),
      ),
      throwsFormatException,
    );
  });

  test('a plain ws address to a remote host is flagged as insecure', () {
    expect(
      const OneBot11Config(
        webSocketUrl: 'ws://10.0.0.5:3001',
      ).isInsecureTransport,
      isTrue,
    );
    expect(
      const OneBot11Config(
        webSocketUrl: 'ws://127.0.0.1:3001',
      ).isInsecureTransport,
      isFalse,
    );
    expect(
      const OneBot11Config(
        webSocketUrl: 'wss://qq.example.com/onebot',
      ).isInsecureTransport,
      isFalse,
    );
  });

  test('allowlists round trip through storage', () async {
    final store = await _store();
    await store.saveOfficialQq(
      const OfficialQqConfig(
        appId: '102000001',
        allowedUsers: {'openid-a', 'openid-b'},
        allowedGroups: {'group-1'},
        allowDirect: false,
      ),
      clientSecret: 'secret-value-123',
    );
    final loaded = store.loadOfficialQq();
    expect(loaded.allowedUsers, {'openid-a', 'openid-b'});
    expect(loaded.allowedGroups, {'group-1'});
    expect(loaded.allowDirect, isFalse);
    expect(loaded.policy.allowedUsers, {'openid-a', 'openid-b'});
  });

  test('a corrupt record reads as unconfigured instead of throwing', () async {
    SharedPreferences.setMockInitialValues({
      'oc.channels.qqOfficial.config': '{not json',
    });
    FlutterSecureStorage.setMockInitialValues({});
    final store = ChannelConfigStore(
      preferences: await SharedPreferences.getInstance(),
      secureStorage: const FlutterSecureStorage(),
    );
    expect(store.loadOfficialQq().appId, isEmpty);
  });

  test('the backend, direction and port survive a round trip', () async {
    final store = await _store();
    await store.saveOneBot11(
      const OneBot11Config(
        backend: OneBotBackend.napcat,
        transport: OneBotTransport.reverse,
        listenPort: 8082,
        expectedSelfId: '10001',
      ),
      accessToken: 'token-value-123',
    );

    final loaded = store.loadOneBot11();

    expect(loaded.backend, OneBotBackend.napcat);
    expect(loaded.transport, OneBotTransport.reverse);
    expect(loaded.listenPort, 8082);
    expect(loaded.configured, isTrue);
  });

  test(
    'a config written before backends existed reads as LLBot forward',
    () async {
      SharedPreferences.setMockInitialValues({
        'oc.channels.onebot11.config':
            '{"webSocketUrl":"ws://127.0.0.1:3001","enabled":true}',
      });
      FlutterSecureStorage.setMockInitialValues({});
      final store = ChannelConfigStore(
        preferences: await SharedPreferences.getInstance(),
        secureStorage: const FlutterSecureStorage(),
      );

      final loaded = store.loadOneBot11();

      expect(loaded.backend, OneBotBackend.llbot);
      expect(loaded.transport, OneBotTransport.forward);
      expect(loaded.listenPort, OneBot11Config.defaultListenPort);
      expect(loaded.webSocketUrl, 'ws://127.0.0.1:3001');
    },
  );

  test('a reverse listener is refused without a token', () async {
    final store = await _store();
    await expectLater(
      store.saveOneBot11(
        const OneBot11Config(
          backend: OneBotBackend.napcat,
          transport: OneBotTransport.reverse,
          enabled: true,
        ),
      ),
      throwsFormatException,
    );
  });

  test('a reverse listener does not need a WebSocket address', () async {
    final store = await _store();
    await store.saveOneBot11(
      const OneBot11Config(
        backend: OneBotBackend.napcat,
        transport: OneBotTransport.reverse,
        enabled: true,
        listenPort: 9000,
      ),
      accessToken: 'token-value-123',
    );

    final loaded = store.loadOneBot11();
    expect(loaded.configured, isTrue);
    expect(loaded.enabled, isTrue);
  });

  test('an impossible port is refused', () async {
    final store = await _store();
    await expectLater(
      store.saveOneBot11(
        const OneBot11Config(
          transport: OneBotTransport.reverse,
          listenPort: 70000,
        ),
        accessToken: 'token-value-123',
      ),
      throwsFormatException,
    );
  });
}
