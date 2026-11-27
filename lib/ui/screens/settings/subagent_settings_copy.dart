import 'package:flutter/widgets.dart';

import '../../../domain/subagent_settings.dart';

/// Local copy follows the existing small settings pages' English/Chinese
/// convention; stable search aliases include both languages.
class SubagentSettingsCopy {
  SubagentSettingsCopy(BuildContext context)
    : zh = Localizations.localeOf(context).languageCode == 'zh';
  final bool zh;
  String text(String en, String chinese) => zh ? chinese : en;

  String get title => text('Subagents', '子代理');
  String get server => text('Server', '服务器');
  String get scope => text('Draft scope', '草稿范围');
  String get defaults => text('Server defaults', '该服务器的全局默认');
  String get pool => text('Dedicated model pool', '专用模型候选池');
  String get editPool => text('Edit model pool', '编辑模型候选池');
  String get inherit => text('Follow server defaults', '跟随服务器全局默认');
  String get ownPool => text('Project override', '项目独立候选池');
  String get emptyPool => text('No models selected', '尚未选择模型');
  String get emptyNote => text(
    'An empty pool never means all models. New models are not added automatically.',
    '空候选池不代表开放全部模型，新模型不会自动加入。',
  );
  String get draft =>
      text('Local draft — not applied to the engine', '本机草稿，尚未作用于引擎');
  String get draftNote => text(
    'This build saves the model pool only. Launch approval, model restrictions, '
        'parent permission limits and recovery still need engine integration. '
        'Existing execution behaviour has not changed.',
    '此版本只保存候选池。逐次启动批准、模型范围、父会话权限上限及恢复策略仍待引擎接入，现有执行行为没有改变。',
  );
  String get refresh => text('Refresh catalogue', '刷新模型与项目目录');
  String get unavailable => text(
    'Connect this exact OpenCode V2 server to load its model and project catalogue. '
        'Saved choices are kept; this page does not connect or start a server.',
    '请先连接这台 OpenCode V2 服务器以读取模型和项目目录。已保存的选择会保留，此页不会自动连接或启动服务器。',
  );
  String get catalogueReadFailed => text(
    'Could not read the model and project catalogue, or the connection changed '
        'during the read. Saved choices are kept. Refresh to try again; '
        'this does not necessarily mean the server is disconnected.',
    '模型与项目目录读取失败，或读取期间连接已变化。已保存的选择会保留，请刷新重试；这不一定表示服务器未连接。',
  );
  String get noServers =>
      text('No saved OpenCode V2 server', '尚未保存 OpenCode V2 服务器');
  String get planned => text('Planned rules — not active yet', '计划规则，尚未生效');
  String get perTask =>
      text('Ask separately before every launch', '每个子代理启动前单独确认');
  String get automatic =>
      text('Choose foreground or background per task', '按任务自动选择前台等待或后台执行');
  String get concurrency =>
      text('As needed, within available resources', '按任务需要安排，并尊重可用资源');
  String get selection =>
      text('Main agent recommends; you confirm or change', '主 Agent 推荐，你确认或改选');
  String get recovery =>
      text('Bounded recovery; limits still to be agreed', '有限恢复，具体上限尚待确定');
  String get delivery => text(
    'Handle results according to the parent session state',
    '根据主会话状态处理结果',
  );
  String get permissions =>
      text('No more authority than the parent session', '权限不超过主会话');
  String get nesting =>
      text('Nested subagents disabled by default', '默认禁止嵌套子代理');
  String get save => text('Save local draft', '保存本机草稿');
  String get saved =>
      text('Saved locally; not applied to the engine', '已保存到本机，尚未作用于引擎');
  String get saving => text('Saving…', '正在保存…');
  String get search =>
      text('Search models, providers or variants', '搜索模型、供应商或推理档位');
  String get defaultVariant => text('Default variant only', '仅默认档位');
  String get notListed => text('Not in the current catalogue', '当前目录未列出');
  String get unknown =>
      text('Catalogue unavailable; choice preserved', '目录不可用，保留已存选择');
  String get noMatches => text('No matching models', '没有匹配的模型');
  String get editChanged => text(
    'The server, project or catalogue changed. Reopen the editor before saving.',
    '服务器、项目或目录已变更，请重新打开编辑页面再保存。',
  );
  String get inheritNote => text(
    'Following defaults removes this project’s separate pool. Later changes to '
        'server defaults will be inherited.',
    '跟随全局将移除此项目的独立候选池，以后全局默认变更时会同步继承。',
  );
  String count(int value) =>
      text('$value exact model/variant choices', '$value 个模型／档位组合');

  String failure(SubagentSettingsFailure reason) => switch (reason) {
    SubagentSettingsFailure.unavailable => text(
      'This setting is unavailable for this target.',
      '此目标暂不支持该设置。',
    ),
    SubagentSettingsFailure.corrupt => text(
      'The saved draft cannot be read. It has not been overwritten.',
      '已存草稿无法读取，原数据没有被覆盖。',
    ),
    SubagentSettingsFailure.staleTarget => text(
      'The saved server identity changed or was removed. No draft was applied.',
      '服务器身份已变化或已移除，没有应用草稿。',
    ),
    SubagentSettingsFailure.conflict => text(
      'The draft changed elsewhere. Refresh before editing again.',
      '草稿已被其他页面修改，请刷新后重新编辑。',
    ),
    SubagentSettingsFailure.storageFailed => text(
      'The local save could not be verified. Refresh before retrying.',
      '无法确认本机保存成功，请刷新后重试。',
    ),
  };
}
