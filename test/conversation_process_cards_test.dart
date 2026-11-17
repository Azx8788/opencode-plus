import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opencode_mobile/domain/models.dart';
import 'package:opencode_mobile/l10n/app_localizations.dart';
import 'package:opencode_mobile/ui/kit/kit.dart';
import 'package:opencode_mobile/ui/app_theme.dart';
import 'package:opencode_mobile/ui/kit/style/kit_style_theme.dart';
import 'package:opencode_mobile/ui/screens/chat_screen.dart' as chat;
import 'package:opencode_mobile/ui/widgets/tool_card.dart';
import 'package:opencode_mobile/ui/widgets/provider_logo.dart';

MessageWithParts _message(
  String id,
  List<Part> parts, {
  String role = 'assistant',
  bool finished = true,
}) => MessageWithParts(
  info: MessageInfo(
    id: id,
    sessionID: 'session',
    role: role,
    modelID: role == 'assistant' ? 'model' : null,
    providerID: role == 'assistant' ? 'provider' : null,
    tokens: role == 'assistant' ? Tokens(input: 1000, output: 100) : null,
    time: MsgTime(
      created: 1000,
      firstToken: 1100,
      streamed: finished ? 2100 : null,
      completed: finished ? 2200 : null,
    ),
  ),
  parts: parts,
);

Part _text(String messageID, String text) => Part(
  id: 'text-0',
  messageID: messageID,
  type: 'text',
  text: text,
  ended: true,
);

Part _thought(String messageID) => Part(
  id: 'reasoning-0',
  messageID: messageID,
  type: 'reasoning',
  text: 'A private thought.\nCompare the alternatives.',
  ended: true,
  startedAt: DateTime.fromMillisecondsSinceEpoch(1100),
  completedAt: DateTime.fromMillisecondsSinceEpoch(1600),
);

Part _tool(
  String messageID,
  String id, {
  String status = 'completed',
  String output = 'fixture output',
}) => Part(
  id: id,
  callID: id,
  messageID: messageID,
  type: 'tool',
  toolName: 'shell',
  toolState: ToolState(
    status: status,
    input: const {'command': 'python3 check.py'},
    output: output,
    startedAt: DateTime.fromMillisecondsSinceEpoch(1600),
    completedAt: status == 'running'
        ? null
        : DateTime.fromMillisecondsSinceEpoch(2200),
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    ProviderLogo.logoLoaderOverride = (_) => Future<String?>.value(null);
    // The CI captures use the shipped fonts, rather than Flutter's Ahem test
    // font. These are the same asset families AppTheme and KitText request.
    for (final entry in const {
      'AppSans': 'assets/fonts/geist/Geist-Variable.ttf',
      'AppMono': 'assets/fonts/geist/GeistMono-Variable.ttf',
      'AppPhosphorRegular': 'assets/fonts/phosphor/Phosphor.ttf',
    }.entries) {
      await (FontLoader(
        entry.key,
      )..addFont(rootBundle.load(entry.value))).load();
    }
  });

  Future<void> mount(
    WidgetTester tester,
    List<MessageWithParts> messages, {
    Map<String, bool>? expansions,
    bool running = false,
    bool reasoningExpanded = false,
    bool dark = false,
    double scale = 1,
    double width = 390,
    Locale locale = const Locale('en'),
    KitTextSize textSize = KitTextSize.normal,
    KitSurfaceStyle style = KitSurfaceStyle.solid,
  }) async {
    final size = ValueNotifier(textSize);
    addTearDown(size.dispose);
    await tester.pumpWidget(
      MaterialApp(
        // Use the same theme factory as the app; the transcript must follow
        // the selected roles/fonts/surface style rather than stock Material.
        theme: dark ? AppTheme.dark() : AppTheme.light(),
        locale: locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            disableAnimations: true,
            textScaler: TextScaler.linear(scale),
          ),
          child: Theme(
            data: AppTheme.forLocale(Theme.of(context), locale),
            child: KitText.appScale(
              size: size,
              max: AppTheme.maxTextScale,
              child: KitEffectsScope(
                effects: KitEffects.defaults.copyWith(
                  motion: KitMotionLevel.off,
                  haptics: false,
                  surfaceStyle: style,
                ),
                child: kitStyleTheme(child: child!),
              ),
            ),
          ),
        ),
        home: RepaintBoundary(
          key: const ValueKey('conversation-preview'),
          child: Scaffold(
            body: Center(
              child: SizedBox(
                width: width,
                child: SingleChildScrollView(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: chat.debugConversationTranscript(
                      messages: messages,
                      expansionStore: expansions,
                      running: running,
                      reasoningExpanded: reasoningExpanded,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  test('finishing a turn neither moves nor folds its prose', () {
    final messages = [
      _message('u1', [_text('u1', 'Check this.')], role: 'user'),
      _message('a1', [
        _text('a1', 'Let me check:'),
        _thought('a1'),
        _tool('a1', 'call-1'),
      ]),
      _message('a2', [
        _text('a2', 'Here is an explanation.'),
        _tool('a2', 'call-2'),
        _text('a2', 'The final answer.'),
      ]),
    ];
    final live = chat.debugTimelineDisplayParts(messages, liveTail: true);
    final done = chat.debugTimelineDisplayParts(messages);
    expect(
      done
          .map((parts) => parts.map((part) => (part.type, part.text)).toList())
          .toList(),
      live
          .map((parts) => parts.map((part) => (part.type, part.text)).toList())
          .toList(),
    );
    for (final message in messages) {
      for (final part in message.parts.where((part) => part.type == 'text')) {
        expect(chat.debugIsFoldedIntoWork(part), isFalse);
      }
    }
  });

  testWidgets(
    'prose is outside cards, shell preview inside, one footer for the reply',
    (tester) async {
      final messages = [
        _message('u1', [_text('u1', 'Check this.')], role: 'user'),
        _message('a1', [
          _text('a1', 'Let me check:'),
          _thought('a1'),
          _tool('a1', 'call-1'),
        ]),
        _message('a2', [
          _text('a2', 'Here is an explanation.'),
          _tool('a2', 'call-2'),
          _text('a2', 'The final answer.'),
        ]),
      ];
      await mount(tester, messages);
      final cards = find.byKey(const ValueKey('kit-work-card'));
      expect(cards, findsNWidgets(2));
      expect(
        find.descendant(
          of: cards,
          matching: find.byKey(const Key('assistant-text-block')),
        ),
        findsNothing,
      );
      expect(find.byType(KitTurnStatistics), findsOneWidget);
      final stats = tester.widget<KitTurnStatistics>(
        find.byType(KitTurnStatistics),
      );
      expect(stats.items.map((item) => item.text), contains('2 steps'));
      expect(
        stats.items.map((item) => item.text),
        contains('1.1k context 0.0% cache hit'),
      );
      expect(find.byKey(const ValueKey('message-meta-a1')), findsNothing);
      expect(find.byKey(const ValueKey('message-meta-a2')), findsOneWidget);
      final header = find.descendant(
        of: cards.first,
        matching: find.byKey(const Key('work-group-header')),
      );
      await tester.tap(header);
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: cards.first,
          matching: find.byKey(const ValueKey('kit-step-command')),
        ),
        findsOneWidget,
      );
      expect(find.text('fixture output'), findsNWidgets(2));
      await tester.tap(header);
      await tester.pumpAndSettle();
      expect(find.byType(ToolCard), findsNWidgets(2));
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'even a lone running tool has a visible collapsible process card',
    (tester) async {
      final expansions = <String, bool>{};
      await mount(
        tester,
        [
          _message('a1', [
            _tool('a1', 'call-1', status: 'running'),
          ], finished: false),
        ],
        expansions: expansions,
        running: true,
      );
      expect(find.byKey(const ValueKey('kit-work-card')), findsOneWidget);
      expect(find.byType(ToolCard), findsOneWidget);
      expect(find.byType(KitTurnStatistics), findsOneWidget);
      await tester.tap(find.byKey(const Key('work-group-header')));
      await tester.pumpAndSettle();
      expect(find.byType(ToolCard), findsOneWidget);
      await mount(tester, [
        _message('a1', [_tool('a1', 'call-1')]),
      ], expansions: expansions);
      expect(
        find.byType(ToolCard),
        findsOneWidget,
        reason:
            'the latest step stays accessible when earlier steps are collapsed',
      );
      expect(find.byType(KitTurnStatistics), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'thought expansion is namespaced across turns and respects the preference',
    (tester) async {
      final expansions = <String, bool>{};
      final messages = [
        _message('u1', [_text('u1', 'First prompt')], role: 'user'),
        _message('a1', [_thought('a1'), _text('a1', 'First answer')]),
        _message('u2', [_text('u2', 'Second prompt')], role: 'user'),
        _message('a2', [_thought('a2'), _text('a2', 'Second answer')]),
      ];
      await mount(tester, messages, expansions: expansions);
      final cards = find.byKey(const ValueKey('kit-work-card'));
      await tester.tap(
        find.descendant(
          of: cards.first,
          matching: find.byKey(const Key('work-group-header')),
        ),
      );
      await tester.pumpAndSettle();
      expect(expansions['work:a1/reasoning-0'], isTrue);
      expect(expansions['work:a2/reasoning-0'], isNull);
      expect(
        find.byKey(const Key('assistant-reasoning-block')),
        findsNWidgets(2),
      );
      await mount(
        tester,
        messages,
        expansions: expansions,
        reasoningExpanded: true,
      );
      expect(
        find.byKey(const Key('assistant-reasoning-block')),
        findsNWidgets(2),
      );
      expect(
        find.byType(KitTurnStatistics),
        findsNWidgets(2),
        reason: 'older replies retain their statistics too',
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'a failed lone tool opens with its error, without hiding the answer',
    (tester) async {
      await mount(tester, [
        _message('a1', [
          _tool(
            'a1',
            'call-1',
            status: 'error',
            output: 'fixture command failed',
          ),
          _text('a1', 'An explanation of the failure.'),
        ]),
      ]);
      expect(find.byKey(const ValueKey('kit-work-card')), findsOneWidget);
      expect(find.byType(ToolCard), findsOneWidget);
      expect(find.text('fixture command failed'), findsWidgets);
      expect(find.byKey(const Key('assistant-text-block')), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('statistics details are available with timestamps off', (
    tester,
  ) async {
    await mount(tester, [
      _message('a1', [_text('a1', 'Done.')]),
    ]);
    await tester.tap(find.byKey(const ValueKey('message-statistics-a1')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('reply-statistics-details-a1')),
      findsOneWidget,
    );
    expect(find.text('Final request context tokens'), findsOneWidget);
    expect(find.text('1100'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final dark in [false, true]) {
    testWidgets(
      'process cards and statistics fit 320dp at 200% text, dark=$dark',
      (tester) async {
        await mount(
          tester,
          [
            _message('a1', [
              _thought('a1'),
              _tool('a1', 'call-1'),
              _text('a1', 'A readable answer with its own prose.'),
            ]),
          ],
          reasoningExpanded: true,
          dark: dark,
          scale: 2,
          width: 320,
        );
        expect(find.byKey(const ValueKey('kit-work-card')), findsOneWidget);
        expect(find.byType(KitTurnStatistics), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets('long output stays bounded until Show all is selected', (
    tester,
  ) async {
    await mount(tester, [
      _message('a1', [
        _tool(
          'a1',
          'call-1',
          output: List.generate(12, (index) => 'output-line-$index').join('\n'),
        ),
      ]),
    ]);
    await tester.tap(find.byKey(const Key('work-group-header')));
    await tester.pumpAndSettle();
    expect(find.text('output-line-5'), findsOneWidget);
    expect(find.text('output-line-6'), findsNothing);
    await tester.ensureVisible(find.byKey(const ValueKey('kit-step-show-all')));
    await tester.tap(find.byKey(const ValueKey('kit-step-show-all')));
    await tester.pumpAndSettle();
    expect(find.text('output-line-11'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'show steps can be manually collapsed, collapse-all survives recycling',
    (tester) async {
      final expansions = <String, bool>{};
      final messages = [
        _message('a1', [
          _thought('a1'),
          _tool('a1', 'call-1'),
          _text('a1', 'An answer.'),
        ]),
      ];
      chat.debugSetTranscriptWorkExpanded(
        expansions,
        messages,
        true,
        reasoningExpanded: true,
      );
      await mount(
        tester,
        messages,
        expansions: expansions,
        reasoningExpanded: true,
      );
      expect(find.byType(ToolCard), findsOneWidget);
      // The card's own tap must win after the global Show steps action.
      await tester.tap(find.byKey(const Key('work-group-header')));
      await tester.pumpAndSettle();
      expect(find.byType(ToolCard), findsOneWidget);
      chat.debugSetTranscriptWorkExpanded(
        expansions,
        messages,
        false,
        reasoningExpanded: true,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await mount(
        tester,
        messages,
        expansions: expansions,
        reasoningExpanded: true,
      );
      expect(find.byType(ToolCard), findsOneWidget);
      await tester.tap(find.byKey(const Key('work-group-header')));
      await tester.pumpAndSettle();
      final thought = tester.widget<KitMessage>(
        find.byWidgetPredicate(
          (widget) =>
              widget is KitMessage && widget.kind == KitMessageKind.thought,
        ),
      );
      expect(thought.expanded, isFalse);
      expect(find.byKey(const ValueKey('kit-step-command')), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final style in KitSurfaceStyle.values) {
    testWidgets(
      'Chinese conversation follows the app $style style and text-size setting',
      (tester) async {
        await mount(
          tester,
          [
            _message('a1', [
              _thought('a1'),
              _tool('a1', 'call-1'),
              _text('a1', '检查完成，正文独立展示。'),
            ]),
          ],
          locale: const Locale('zh'),
          textSize: KitTextSize.large,
          style: style,
          reasoningExpanded: true,
        );
        final context = tester.element(find.byType(KitTurnStatistics));
        expect(KitEffects.of(context).surfaceStyle, style);
        expect(MediaQuery.textScalerOf(context).scale(1), closeTo(1.15, .001));
        expect(
          KitText.styleOf(context, KitTextRole.body).fontFamily,
          AppTheme.sansFamily,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  for (final dark in [false, true]) {
    testWidgets(
      'capture process-card layout with the shipped app theme, dark=$dark',
      (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await mount(
          tester,
          [
            _message('u1', [
              _text('u1', 'Run the checks and explain the result.'),
            ], role: 'user'),
            _message('a1', [
              _text('a1', 'The reply stays readable above the process card.'),
              _thought('a1'),
              _tool('a1', 'call-1', output: 'All 12 checks passed.\nexit 0'),
              _text('a1', 'Done. The result is ready to review.'),
            ]),
          ],
          dark: dark,
          reasoningExpanded: true,
        );
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(const ValueKey('conversation-preview')),
        );
        await tester.runAsync(() async {
          final image = await boundary.toImage(pixelRatio: 2);
          try {
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            final output = File(
              'build/qa/conversation-${dark ? 'dark' : 'light'}.png',
            );
            await output.parent.create(recursive: true);
            await output.writeAsBytes(bytes!.buffer.asUint8List());
          } finally {
            image.dispose();
          }
        });
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}
