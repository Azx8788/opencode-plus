import 'package:flutter/gestures.dart'
    show PointerDeviceKind, kSecondaryMouseButton;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opencode_mobile/domain/models.dart';
import 'package:opencode_mobile/l10n/app_localizations.dart';
import 'package:opencode_mobile/ui/app_theme.dart';
import 'package:opencode_mobile/ui/kit/kit.dart';
import 'package:opencode_mobile/ui/screens/chat_screen.dart'
    show V2TranscriptRow;

Future<void> _mount(WidgetTester tester, Widget row) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(390, 844);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(),
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: KitEffectsScope(
          effects: KitEffects.defaults.copyWith(
            motion: KitMotionLevel.off,
            haptics: false,
          ),
          child: row,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  const summary = 'Decisions and next steps';
  final header = find.text(
    lookupAppLocalizations(const Locale('en')).chatUiContextCompacted,
  );
  final summaryBody = find.byWidgetPredicate(
    (widget) => widget is KitMarkdown && widget.data == summary,
  );
  final revert = find.byKey(const ValueKey('compaction-revert'));

  testWidgets('compaction tap unfolds and long-press opens the menu', (
    tester,
  ) async {
    var reverted = 0;
    await _mount(
      tester,
      V2TranscriptRow(
        part: Part(type: 'v2:compaction', toolName: 'completed', text: summary),
        messageId: 'msg_compacted',
        onRevertCompaction: () => reverted++,
      ),
    );

    expect(summaryBody, findsNothing);
    await tester.longPress(header);
    await tester.pumpAndSettle();
    expect(revert, findsOneWidget);
    expect(summaryBody, findsNothing);
    expect(reverted, 0);

    await tester.tap(revert);
    await tester.pumpAndSettle();
    expect(reverted, 1);

    await tester.tap(header);
    await tester.pumpAndSettle();
    expect(summaryBody, findsOneWidget);
    expect(revert, findsNothing);

    await tester.tap(
      header,
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();
    expect(revert, findsOneWidget);
    expect(summaryBody, findsOneWidget);
    expect(reverted, 1);
  });

  testWidgets('a notice without details still offers the compaction menu', (
    tester,
  ) async {
    await _mount(
      tester,
      V2TranscriptRow(
        part: Part(type: 'v2:compaction', toolName: 'completed'),
        messageId: 'msg_compacted',
        onRevertCompaction: () {},
      ),
    );
    await tester.longPress(header);
    await tester.pumpAndSettle();
    expect(revert, findsOneWidget);
  });
}
