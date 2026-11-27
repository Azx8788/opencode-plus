import 'package:opencode_mobile/domain/server_gateway.dart';
import 'package:opencode_mobile/domain/subagent_settings.dart';
import 'package:opencode_mobile/state/subagent_settings_store.dart';

Map<String, dynamic> subagentProfile(String id, {String? url}) => {
  'id': id,
  'name': 'Server $id',
  'backend': 'openCode',
  'flavor': 'v2',
  'baseUrl': url ?? 'https://$id.example.test',
  'username': 'opencode',
};

SubagentSettingsServer subagentServer(String id) => SubagentSettingsServer(
  profileID: id,
  binding: subagentSettingsBinding(subagentProfile(id)),
  name: 'Server $id',
);

SubagentModelCandidate subagentCandidate(
  String id, {
  String? variant,
  String provider = 'gateway',
}) =>
    SubagentModelCandidate(providerID: provider, modelID: id, variant: variant);

CatalogModel subagentCatalogModel(String id, {bool enabled = true}) =>
    CatalogModel(
      id: id,
      providerID: 'gateway',
      name: 'Model $id',
      enabled: enabled,
      status: 'active',
      contextLimit: 200000,
      outputLimit: 32000,
      reasoning: true,
      attachments: false,
      tools: true,
      variants: const [
        CatalogVariant(id: 'high'),
        CatalogVariant(id: 'hidden', disabled: true),
      ],
    );

SubagentSettingsCatalog subagentCatalog({
  List<String> ids = const ['a', 'b'],
}) => SubagentSettingsCatalog(
  models: ids.map(subagentCatalogModel),
  projects: const [
    WorkspaceProject(
      id: 'project-one',
      name: 'Same name',
      directory: '/work/one',
      worktrees: [],
      updatedAt: 0,
    ),
    WorkspaceProject(
      id: 'project-two',
      name: 'Same name',
      directory: '/work/two',
      worktrees: [],
      updatedAt: 0,
    ),
  ],
);
