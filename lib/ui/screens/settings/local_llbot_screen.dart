import 'dart:async';

import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../../app_iconography.dart';
import '../../kit/kit.dart';

/// Shows only the locally running LLBot console. It has no browser fallback
/// and does not install, start or configure the protocol process.
class LocalLlbotScreen extends StatefulWidget {
  const LocalLlbotScreen({super.key});

  @override
  State<LocalLlbotScreen> createState() => _LocalLlbotScreenState();
}

class _LocalLlbotScreenState extends State<LocalLlbotScreen> {
  static final _origin = Uri.parse('http://127.0.0.1:3080/');
  final _web = KitWebPreviewController();
  bool _blockedLink = false;

  @override
  void dispose() {
    _web.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final zh = Localizations.localeOf(context).languageCode == 'zh';
    final supported = KitWebPreview.platformSupported();
    final tokens = KitTokens.of(context);
    return ListenableBuilder(
      listenable: _web,
      builder: (context, _) => KitScreen(
        topBar: KitTopBar(
          title: zh ? '本机 LLBot 管理页' : 'Local LLBot console',
          actions: [
            if (supported)
              KitAction(
                label: l10n.devPreviewReload,
                icon: AppIconography.retry,
                onPressed: () => unawaited(_web.reload()),
              ),
          ],
        ),
        loading: supported && _web.phase == KitWebPreviewPhase.loading,
        loadingLabel: l10n.devPreviewLoading,
        header: [
          const KitDivider(),
          if (_blockedLink)
            Padding(
              padding: EdgeInsets.all(tokens.space2),
              child: KitGroupNote(
                message: zh
                    ? '本机管理页不打开外部链接。'
                    : 'The local console does not open external links.',
              ),
            ),
        ],
        body: KitWebPreview(
          origin: _origin,
          controller: _web,
          strictOrigin: true,
          unsupportedBody: zh
              ? '当前设备无法显示内置的 LLBot 管理页。'
              : 'This device cannot display the built-in LLBot console.',
          failureBody: zh
              ? '请先在这台手机的内置 Ubuntu 中启动 LLBot，再点重试。'
              : 'Start LLBot in this phone’s built-in Ubuntu, then try again.',
          onLeave: (_) {
            if (mounted && !_blockedLink) setState(() => _blockedLink = true);
          },
        ),
      ),
    );
  }
}
