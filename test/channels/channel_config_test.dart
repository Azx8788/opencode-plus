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
      const OneBot11Config(webSocketUrl: 'ws://127.0.0.1:3001', enabled: true),
      accessToken: 'token-1',
    );
    expect(store.loadOneBot11().webSocketUrl, 'ws://127.0.0.1:3001');
    expect(await store.readOneBot11Token(), 'token-1');
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
}
