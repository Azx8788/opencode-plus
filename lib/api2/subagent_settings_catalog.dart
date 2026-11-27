import '../domain/server_gateway.dart';
import '../domain/subagent_settings.dart';
import 'client.dart';
import 'gateway_mappers.dart';
import 'models.dart';

/// Read-only use of existing V2 routes. No config PATCH, model probe or prompt
/// is sent. Incomplete/malformed catalogues are unknown, not an empty pool.
class Api2SubagentSettingsCatalog {
  Api2SubagentSettingsCatalog(this.client);
  final Api2Client client;

  Future<SubagentSettingsCatalog> load() async {
    final directory = client.directory, workspace = client.workspace;
    final results = await Future.wait([
      client.transport.getJson(
        '/model',
        query: {
          'location[directory]': ?directory,
          'location[workspace]': ?workspace,
        },
      ),
      client.transport.getJson('/project'),
    ]);
    if (client.directory != directory || client.workspace != workspace) {
      throw const SubagentSettingsException(
        SubagentSettingsFailure.staleTarget,
      );
    }
    List<Map<String, dynamic>> rows(Object? value) {
      if (value is! Map || value['data'] is! List || value['next'] != null) {
        throw const FormatException('Incomplete subagent catalogue');
      }
      return (value['data'] as List).map((row) {
        if (row is! Map) throw const FormatException('Invalid catalogue entry');
        return Map<String, dynamic>.from(row);
      }).toList();
    }

    final models = <CatalogModel>[];
    final seen = <String>{};
    for (final row in rows(results[0])) {
      final parsed = Api2ModelInfo.fromJson(row);
      if (parsed == null ||
          parsed.providerID == null ||
          (row['enabled'] != null && row['enabled'] is! bool) ||
          (row['variants'] != null && row['variants'] is! List)) {
        throw const FormatException('Invalid model catalogue');
      }
      final model = mapApi2CatalogModel(parsed);
      final candidate = SubagentModelCandidate(
        providerID: model.providerID,
        modelID: model.id,
      );
      if (!seen.add(candidate.key)) {
        throw const FormatException('Duplicate model');
      }
      final variants = <String>{};
      for (final raw in row['variants'] as List? ?? const []) {
        if (raw is! Map ||
            raw['id'] is! String ||
            (raw['disabled'] != null && raw['disabled'] is! bool) ||
            !variants.add(raw['id'] as String)) {
          throw const FormatException('Invalid model variant');
        }
        SubagentModelCandidate.validateID(raw['id'] as String);
      }
      models.add(model);
    }
    return SubagentSettingsCatalog(
      models: List.unmodifiable(models),
      projects: List.unmodifiable(
        rows(results[1]).map((row) {
          if (row['id'] is! String ||
              (row['name'] != null && row['name'] is! String) ||
              (row['directory'] != null && row['directory'] is! String) ||
              (row['canonical'] != null && row['canonical'] is! String)) {
            throw const FormatException('Invalid project catalogue');
          }
          final id = row['id'] as String;
          return WorkspaceProject(
            id: id,
            name: row['name'] as String? ?? id,
            directory: (row['directory'] ?? row['canonical'] ?? '') as String,
            worktrees: const [],
            updatedAt: 0,
          );
        }),
      ),
    );
  }
}
