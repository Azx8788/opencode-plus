import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:opencode_mobile/builtin/provider_visibility_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ProviderVisibilityStore store;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    store = ProviderVisibilityStore(await SharedPreferences.getInstance());
  });

  test('hiding is per server and restoring clears only that server', () async {
    await store.hide('phone', 'openai');
    await store.hide('phone', 'gemini');
    await store.hide('laptop', 'openai');

    expect(store.load('phone'), {'openai', 'gemini'});
    expect(store.load('laptop'), {'openai'});

    await store.restoreAll('phone');
    expect(store.load('phone'), isEmpty);
    expect(store.load('laptop'), {'openai'});
  });

  test('untrusted stored ids are ignored', () async {
    SharedPreferences.setMockInitialValues({
      'oc.hiddenProviderTemplates.v1.phone': ['openai', '../escape', ''],
    });
    final restored = ProviderVisibilityStore(
      await SharedPreferences.getInstance(),
    ).load('phone');
    expect(restored, {'openai'});
  });

  test('hidden set is written sorted and can be read back', () async {
    await store.save('phone', {'zhipu', 'openai', 'deepseek'});
    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getStringList('oc.hiddenProviderTemplates.v1.phone'),
      ['deepseek', 'openai', 'zhipu'],
    );
    expect(store.load('phone'), {'deepseek', 'openai', 'zhipu'});
  });
}