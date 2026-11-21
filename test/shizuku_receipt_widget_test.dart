import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opencode_mobile/domain/models.dart';
import 'package:opencode_mobile/l10n/app_localizations.dart';
import 'package:opencode_mobile/ui/app_theme.dart';
import 'package:opencode_mobile/ui/kit/chat/kit_tool_row.dart';
import 'package:opencode_mobile/ui/widgets/tool_card.dart';

void main() {
  Future<void> mount(
    WidgetTester tester,
    ToolState state, {
    String tool = 'shizuku_exec',
    Locale locale = const Locale('en'),
  }) async {
    tester.view.physicalSize = const Size(320, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        locale: locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: const TextScaler.linear(2),
            disableAnimations: true,
          ),
          child: child!,
        ),
        home: Scaffold(
          body: SingleChildScrollView(
            child: ToolCard(
              toolName: tool,
              state: state,
              embedded: true,
              onRetry: () => fail('Android calls must not offer a blind retry'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  ToolState native(Map<String, Object?> receipt, {bool executed = false}) =>
      ToolState(
        status: 'completed',
        executed: executed,
        input: const {'command': 'test command'},
        output: jsonEncode({
          'protocolVersion': 1,
          'environment': 'android',
          ...receipt,
        }),
      );

  for (final locale in const [Locale('en'), Locale('zh')]) {
    testWidgets('native refusal and timeout have distinct copy: $locale', (
      tester,
    ) async {
      final l10n = lookupAppLocalizations(locale);
      await mount(
        tester,
        native({
          'state': 'denied',
          'reason': 'confirmation_user_denied',
          'executionStage': 'not_dispatched',
        }),
        locale: locale,
      );
      var row = tester.widget<KitToolRow>(find.byType(KitToolRow));
      expect(row.status, KitToolStatus.declined);
      expect(row.detail, contains(l10n.shizukuReceiptUserDenied));
      expect(row.onRetry, isNull);

      await mount(
        tester,
        native({
          'state': 'denied',
          'reason': 'confirmation_timeout',
          'executionStage': 'not_dispatched',
        }),
        locale: locale,
      );
      row = tester.widget<KitToolRow>(find.byType(KitToolRow));
      expect(row.status, KitToolStatus.notRun);
      expect(row.detail, contains(l10n.shizukuReceiptTimedOut));
      expect(row.detail, isNot(contains(l10n.shizukuReceiptUserDenied)));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('missing final reply is unconfirmed even with executed false', (
    tester,
  ) async {
    await mount(
      tester,
      ToolState(
        status: 'error',
        output: 'Tool execution interrupted',
        executed: false,
        metadata: const {
          'android': {'operationId': 'original', 'state': 'waiting'},
        },
      ),
    );
    final row = tester.widget<KitToolRow>(find.byType(KitToolRow));
    expect(row.status, KitToolStatus.unconfirmed);
    expect(row.onRetry, isNull);
    expect(
      row.detail,
      contains(
        lookupAppLocalizations(const Locale('en')).shizukuReceiptUnconfirmed,
      ),
    );
    expect(
      find.byKey(const Key('shizuku-receipt-explanation')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await mount(
      tester,
      ToolState.fromJson({
        'status': 'error',
        'executed': false,
        'error': 'Tool execution interrupted',
        'metadata': {
          'android': {'operationId': 'original', 'state': 'waiting'},
        },
      }),
    );
    expect(
      tester.widget<KitToolRow>(find.byType(KitToolRow)).status,
      KitToolStatus.unconfirmed,
    );
  });

  testWidgets('Android receipt overrides enclosing tool execution flag', (
    tester,
  ) async {
    await mount(
      tester,
      native({'state': 'succeeded', 'exitCode': 0, 'stdout': '', 'stderr': ''}),
    );
    expect(
      tester.widget<KitToolRow>(find.byType(KitToolRow)).status,
      KitToolStatus.done,
    );
    await mount(tester, native({'state': 'failed', 'exitCode': 1}));
    final row = tester.widget<KitToolRow>(find.byType(KitToolRow));
    expect(row.status, KitToolStatus.failed);
    expect(row.detail, contains('Exit code 1'));
    expect(row.onRetry, isNull);
  });

  testWidgets(
    'rejecting inspection makes no claim about the original command',
    (tester) async {
      await mount(
        tester,
        ToolState(
          status: 'error',
          executed: false,
          output: 'Tool execution interrupted',
          metadata: const {
            'shizukuApproval': {
              'decision': 'reject',
              'action': 'shizuku_result',
            },
          },
        ),
        tool: 'shizuku_result',
      );
      final row = tester.widget<KitToolRow>(find.byType(KitToolRow));
      expect(row.status, KitToolStatus.declined);
      expect(
        find.byKey(const Key('shizuku-receipt-explanation')),
        findsNothing,
      );
    },
  );
}
