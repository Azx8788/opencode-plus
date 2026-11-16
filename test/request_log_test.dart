import 'package:flutter_test/flutter_test.dart';
import 'package:opencode_mobile/domain/request_log.dart';
import 'package:opencode_mobile/state/request_log.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'records only observed dispatches and keeps the most recent entries',
    () async {
      final prefs = await SharedPreferences.getInstance();
      final store = RequestLogStore(prefs);
      await store.load();
      for (var i = 0; i < RequestLogSnapshot.maxEntries + 3; i++) {
        await store.record(
          profileID: 'phone',
          sessionID: 's$i',
          providerID: 'gateway',
          modelID: 'm$i',
        );
      }
      expect(store.snapshot.entries.length, RequestLogSnapshot.maxEntries);
      expect(store.snapshot.entries.first.sessionID, 's3');
      expect(
        store.snapshot.entries.last.sessionID,
        's${RequestLogSnapshot.maxEntries + 2}',
      );
      expect(store.snapshot.entries.last.modelLabel, 'gateway/m2002');
      final reopened = RequestLogStore(prefs);
      await reopened.load();
      expect(reopened.snapshot.entries.length, RequestLogSnapshot.maxEntries);
      expect(
        prefs.getString(RequestLogStore.key),
        isNot(contains('Prompt text')),
      );
    },
  );

  test('corrupt log fails closed until explicitly cleared', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(RequestLogStore.key, '{broken');
    final store = RequestLogStore(prefs);
    await expectLater(store.load(), throwsA(isA<FormatException>()));
    expect(store.snapshot.entries, isEmpty);
    await store.clear();
    await store.load();
    expect(store.snapshot.entries, isEmpty);
  });

  test(
    'entry parsing rejects missing identity but accepts server-default model',
    () async {
      expect(
        () => RequestLogEntry.fromJson({'at': 1}),
        throwsA(isA<FormatException>()),
      );
      final entry = RequestLogEntry.fromJson({
        'id': 'a',
        'at': 1,
        'profileID': 'phone',
        'sessionID': 's',
      });
      expect(entry.modelLabel, isEmpty);
    },
  );
}
