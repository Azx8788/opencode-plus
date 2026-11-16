import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:opencode_mobile/builtin/provider_key_ring_store.dart';
import 'package:opencode_mobile/domain/custom_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SharedPreferences prefs;
  late ProviderKeyRingStore store;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    store = ProviderKeyRingStore(prefs);
  });

  test('names and paths survive a reload without the key bytes', () async {
    await store.save(
      profileID: 'phone',
      providerID: 'my-gateway',
      keys: const [
        ProviderKeyRecord(
          id: 'work',
          name: 'Work',
          filePath: '/root/.secrets/opencode-plus/my-gateway/work.key',
        ),
        ProviderKeyRecord(
          id: 'backup',
          name: 'Backup',
          filePath: '/root/.secrets/opencode-plus/my-gateway/backup.key',
        ),
      ],
      activeID: 'backup',
    );
    final loaded = await store.load(
      profileID: 'phone',
      providerID: 'my-gateway',
      currentPath: '/root/.secrets/opencode-plus/my-gateway/backup.key',
    );
    expect(loaded.keys.map((key) => key.name), ['Work', 'Backup']);
    expect(loaded.activeID, 'backup');
    final raw = prefs
        .getKeys()
        .map((key) => prefs.get(key))
        .whereType<String>()
        .join();
    expect(raw.contains('sk-'), isFalse, reason: 'only names and paths');
  });

  test('an older single key file is adopted as the default named key', () async {
    final loaded = await store.load(
      profileID: 'phone',
      providerID: 'my-gateway',
      currentPath: '/root/.secrets/my-gateway.key',
    );
    expect(loaded.keys, hasLength(1));
    expect(loaded.keys.single.id, 'legacy');
    expect(loaded.keys.single.filePath, '/root/.secrets/my-gateway.key');
    expect(loaded.activeID, 'legacy');
  });

  test('the active key always follows the config path, not stale metadata', () async {
    await store.save(
      profileID: 'phone',
      providerID: 'my-gateway',
      keys: const [
        ProviderKeyRecord(
          id: 'work',
          name: 'Work',
          filePath: '/root/.secrets/opencode-plus/my-gateway/work.key',
        ),
      ],
      activeID: 'work',
    );
    final loaded = await store.load(
      profileID: 'phone',
      providerID: 'my-gateway',
      currentPath: '/root/.secrets/my-gateway.key',
    );
    expect(loaded.keys.map((key) => key.id), containsAll(['work', 'legacy']));
    expect(loaded.activeID, 'legacy');
  });

  test('invalid or duplicate entries are refused rather than half-saved', () async {
    for (final keys in [
      const [
        ProviderKeyRecord(
          id: 'x',
          name: '',
          filePath: '/root/.secrets/opencode-plus/my-gateway/x.key',
        ),
      ],
      const [
        ProviderKeyRecord(
          id: 'x',
          name: 'One',
          filePath: '/root/.secrets/opencode-plus/my-gateway/x.key',
        ),
        ProviderKeyRecord(
          id: 'x',
          name: 'Two',
          filePath: '/root/.secrets/opencode-plus/my-gateway/y.key',
        ),
      ],
      const [
        ProviderKeyRecord(
          id: 'x',
          name: 'Outside',
          filePath: '/root/../.ssh/id_ed25519',
        ),
      ],
    ]) {
      await expectLater(
        store.save(
          profileID: 'phone',
          providerID: 'my-gateway',
          keys: keys,
          activeID: 'x',
        ),
        throwsFormatException,
      );
    }
    expect(prefs.getKeys().where((key) => key.startsWith('oc.providerKeys')), isEmpty);
  });

  test('a renamed external key remains named when it is no longer active', () async {
    await store.save(
      profileID: 'phone',
      providerID: 'my-gateway',
      keys: const [
        ProviderKeyRecord(id: 'legacy', name: 'Old personal key', filePath: '/root/custom/key.txt'),
        ProviderKeyRecord(id: 'work', name: 'Work', filePath: '/root/.secrets/opencode-plus/my-gateway/work.key'),
      ],
      activeID: 'work',
    );
    final loaded = await store.load(
      profileID: 'phone',
      providerID: 'my-gateway',
      currentPath: '/root/.secrets/opencode-plus/my-gateway/work.key',
    );
    expect(loaded.keys.first.name, 'Old personal key');
    expect(loaded.activeID, 'work');
  });

  test('adopting a new external path cannot create duplicate legacy IDs', () async {
    await store.save(
      profileID: 'phone', providerID: 'my-gateway', activeID: 'legacy',
      keys: const [ProviderKeyRecord(id: 'legacy', name: 'Old', filePath: '/root/old.key')],
    );
    final loaded = await store.load(
      profileID: 'phone', providerID: 'my-gateway', currentPath: '/root/new.key',
    );
    expect(loaded.keys.map((key) => key.id).toSet().length, 2);
    expect(loaded.activeID, 'legacy-2');
  });
}
