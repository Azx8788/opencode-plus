// The native surfaces (notifications, widgets, tiles, shortcuts) are not
// part of the Flutter ARB catalogues: Android reads res/values*/ through
// NativeStrings.kt. Those two halves drifted once already — the app shipped
// English notifications to a Chinese interface — so the pairing is checked
// here rather than by reading the folder contents by hand.
//
// Every copy file counts, not just strings.xml: the widgets keep their own
// widget_v2_strings.xml, the scheduled prompts their own
// scheduled_prompts.xml, and a translation missing from either shipped
// English to a Chinese home screen.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xml/xml.dart';

const _resDir = 'android/app/src/main/res';

/// `%1$s`, `%d`, `%%`: the arguments a translation must keep in the same
/// positions as the English original.
Set<String> _placeholders(String text) {
  final found = <String>{};
  for (final match in RegExp(r'%(?:(\d+)\$)?([sd%])').allMatches(text)) {
    if (match.group(2) == '%') continue;
    found.add('${match.group(1) ?? '?'}${match.group(2)}');
  }
  return found;
}

Map<String, XmlElement> _resources(String path) {
  final document = XmlDocument.parse(File(path).readAsStringSync());
  final byName = <String, XmlElement>{};
  for (final element in document.rootElement.childElements) {
    final kind = element.name.local;
    if (kind != 'string' && kind != 'plurals') continue;
    final name = element.getAttribute('name');
    if (name != null) byName[name] = element;
  }
  return byName;
}

/// Every file under `values/` or `values-<lang>/` that carries copy, keyed by
/// file name. Colours and styles carry no copy and drop out here.
Map<String, Map<String, XmlElement>> _copyFiles(String directory) {
  final files = <String, Map<String, XmlElement>>{};
  final dir = Directory(directory);
  if (!dir.existsSync()) return files;
  for (final file in dir.listSync().whereType<File>()) {
    if (!file.path.endsWith('.xml')) continue;
    final resources = _resources(file.path);
    if (resources.isEmpty) continue;
    files[file.uri.pathSegments.last] = resources;
  }
  return files;
}

Set<String> _appLanguages() {
  final source = File(
    'android/app/src/main/kotlin/com/azx8788/opencode/mini/NativeStrings.kt',
  ).readAsStringSync();
  final match = RegExp(
    r'private\s+val\s+supported\s*=\s*setOf\(([^)]*)\)',
  ).firstMatch(source);
  if (match == null) {
    fail('NativeStrings.supported must be a literal setOf(...)');
  }
  final languages = <String>{};
  for (final part in match.group(1)!.split(',')) {
    final code = RegExp(r'"([a-z]{2})"').firstMatch(part)?.group(1);
    if (code != null) languages.add(code);
  }
  return languages;
}

void main() {
  final english = _copyFiles('$_resDir/values');
  final chinese = _copyFiles('$_resDir/values-zh');

  test('every English copy file has a Chinese one', () {
    expect(
      chinese.keys.toSet(),
      equals(english.keys.toSet()),
      reason: 'values-zh/ must hold a translation for every copy file in values/',
    );
  });

  test('every English native string has a Chinese one', () {
    for (final file in english.keys) {
      expect(
        chinese[file]!.keys.toSet(),
        equals(english[file]!.keys.toSet()),
        reason: '$file must list exactly the names in values/$file',
      );
    }
  });

  test('translations keep every format argument', () {
    for (final file in english.keys) {
      for (final entry in english[file]!.entries) {
        final translated = chinese[file]![entry.key];
        expect(translated, isNotNull, reason: '$file: ${entry.key}');
        expect(
          _placeholders(translated!.innerText),
          equals(_placeholders(entry.value.innerText)),
          reason:
              '$file: ${entry.key}: a notification built with these arguments '
              'would throw or print a literal %s in Chinese',
        );
      }
    }
  });

  test('Chinese plurals use the only quantity Chinese reads', () {
    for (final file in chinese.keys) {
      for (final entry in chinese[file]!.entries) {
        if (entry.value.name.local != 'plurals') continue;
        final quantities = entry.value.childElements
            .map((item) => item.getAttribute('quantity'))
            .toSet();
        expect(
          quantities,
          {'other'},
          reason: '$file: ${entry.key} needs only <item quantity="other">',
        );
      }
    }
  });

  test('NativeStrings selects exactly the languages that ship copy', () {
    final languages = _appLanguages();
    expect(languages, {'en', 'zh'});
    for (final language in languages) {
      // English is the default folder; every other language needs its own.
      final folder = language == 'en' ? 'values' : 'values-$language';
      expect(
        Directory('$_resDir/$folder').existsSync(),
        isTrue,
        reason: '$language is selected but $_resDir/$folder does not exist',
      );
    }
  });

  test('the app locale list and the native list agree', () {
    final store = File('lib/state/app_locale.dart').readAsStringSync();
    final match = RegExp(
      r'supportedLanguages\s*=\s*\{([^}]*)\}',
    ).firstMatch(store);
    expect(match, isNotNull);
    final dartLanguages = <String>{};
    for (final part in match!.group(1)!.split(',')) {
      final code = RegExp(r"'([a-z]{2})'").firstMatch(part)?.group(1);
      if (code != null) dartLanguages.add(code);
    }
    expect(dartLanguages, _appLanguages());
  });
}
