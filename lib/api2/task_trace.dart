import 'client.dart';
import 'transport.dart';

class Api2TaskTracePage {
  const Api2TaskTracePage(
    this.events,
    this.next,
    this.truncated,
    this.serverNow,
  );
  final List<Map<String, dynamic>> events;
  final int? next;
  final bool truncated;
  final int? serverNow;
}

class Api2TaskTrace {
  Api2TaskTrace(this.client);
  final Api2Client client;
  Future<Api2TaskTracePage> history({int after = 0}) async {
    final raw = await client.transport.postJson(
      '/rpc/mobile-insights/history',
      query: {'location[directory]': ?client.directory},
      body: {
        'input': {'after': after, 'limit': 500},
      },
      receiveTimeout: const Duration(seconds: 15),
    );
    final value = raw is Map ? raw['output'] : null;
    if (value is! Map ||
        value['version'] != 1 ||
        value['entries'] is! List ||
        (value['next'] != null && value['next'] is! int)) {
      throw Api2RequestError('Invalid task history response');
    }
    return Api2TaskTracePage(
      (value['entries'] as List)
          .map((e) => Map<String, dynamic>.from(e))
          .toList(),
      value['next'],
      value['truncated'] == true,
      value['now'] is int ? value['now'] as int : null,
    );
  }
}
