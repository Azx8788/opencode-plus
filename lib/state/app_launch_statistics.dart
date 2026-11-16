import 'package:shared_preferences/shared_preferences.dart';

/// Counts main-app cold starts from this feature's first successful write.
/// Not resume events, widgets, view rebuilds, or reconstructed historical data.
class AppLaunchStatistics {
  const AppLaunchStatistics({required this.count, required this.since});
  final int count;
  final DateTime since;
  static const _key = 'oc.appLaunchStatistics.v1';
  static bool _recordedThisProcess = false;

  static AppLaunchStatistics? read(SharedPreferences prefs) {
    final data = prefs.getStringList(_key);
    if (data == null || data.length != 2) return null;
    final count = int.tryParse(data[0]);
    final since = int.tryParse(data[1]);
    if (count == null || count < 1 || since == null || since <= 0) return null;
    return AppLaunchStatistics(
      count: count,
      since: DateTime.fromMillisecondsSinceEpoch(since),
    );
  }

  static Future<bool> recordMainLaunch(
    SharedPreferences prefs, {
    DateTime? now,
  }) async {
    if (_recordedThisProcess) return true;
    _recordedThisProcess = true;
    try {
      final previous = read(prefs);
      final start = previous?.since ?? now ?? DateTime.now();
      return await prefs.setStringList(_key, [
        '${(previous?.count ?? 0) + 1}',
        '${start.millisecondsSinceEpoch}',
      ]);
    } catch (_) {
      // Launch diagnostics are optional and never block opening the app.
      return false;
    }
  }
}
