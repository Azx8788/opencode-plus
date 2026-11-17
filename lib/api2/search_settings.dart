import '../domain/search_settings.dart';
import 'client.dart';
import 'transport.dart';

/// Uses the managed plugin's public RPC rather than inventing a config PATCH
/// field: the pinned server's config PATCH supports only the default shell.
class Api2SearchSettings {
  Api2SearchSettings(this.client);
  final Api2Client client;

  Future<Object?> _call(String method, Map<String, Object?> input) async {
    final result = await client.transport.postJson(
      '/rpc/mobile-insights/$method',
      query: {'location[directory]': ?client.directory},
      body: {'input': input},
      receiveTimeout: const Duration(seconds: 20),
    );
    if (result is! Map || !result.containsKey('output')) {
      throw Api2RequestError('Invalid search settings response');
    }
    return result['output'];
  }

  Future<SearchProviderSettings> load() async =>
      SearchProviderSettings.fromJson(await _call('searchSettings', const {}));

  Future<SearchProviderSettings> select(String? id) async =>
      SearchProviderSettings.fromJson(
        await _call('selectSearch', {'provider': id}),
      );
}
