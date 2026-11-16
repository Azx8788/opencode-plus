import 'package:flutter/material.dart';
import 'package:opencode_mobile/ui/kit/kit.dart';

/// Linux screenshot tests lack Android's system fallback. Keep AppSans and
/// every appearance setting; supply only the CI-loaded fallback to token and
/// button styles too, rather than just KitText's body style.
ThemeData qaCjkTheme(ThemeData base) {
  final text = base.textTheme.copyWith(
    bodyLarge: base.textTheme.bodyLarge!.copyWith(
      fontFamilyFallback: const ['QaCjkFallback'],
    ),
  );
  ButtonStyle fallback(ButtonStyle? style) =>
      (style ?? const ButtonStyle()).copyWith(
        textStyle: WidgetStateProperty.resolveWith(
          (states) => (style?.textStyle?.resolve(states) ?? const TextStyle())
              .copyWith(fontFamilyFallback: const ['QaCjkFallback']),
        ),
      );
  var theme = base.copyWith(
    textTheme: text,
    filledButtonTheme: FilledButtonThemeData(
      style: fallback(base.filledButtonTheme.style),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: fallback(base.outlinedButtonTheme.style),
    ),
    textButtonTheme: TextButtonThemeData(
      style: fallback(base.textButtonTheme.style),
    ),
  );
  theme = theme.copyWith(
    extensions: [
      ...theme.extensions.values.where((e) => e is! KitTokens),
      KitTokens.fallback(theme),
    ],
  );
  return theme;
}
