// DocumentsUI discovers roots from the manifest before it can query them.
// The JVM provider tests attach a ProviderInfo explicitly; check the real
// registration here so those tests cannot pass with a missing picker entry.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xml/xml.dart';

const _android = 'http://schemas.android.com/apk/res/android';

void main() {
  test('private storage is discoverable and supports SAF URI grants', () {
    final manifest = XmlDocument.parse(
      File('android/app/src/main/AndroidManifest.xml').readAsStringSync(),
    );
    final application = manifest.rootElement.getElement('application')!;
    final provider = application.findElements('provider').singleWhere(
      (element) =>
          element.getAttribute('name', namespace: _android) ==
          '.InternalStorageProvider',
    );

    expect(
      provider.getAttribute('authorities', namespace: _android),
      r'${applicationId}.internalstorage',
    );
    expect(provider.getAttribute('exported', namespace: _android), 'true');
    expect(
      provider.getAttribute('grantUriPermissions', namespace: _android),
      'true',
    );
    expect(
      provider.getAttribute('permission', namespace: _android),
      'android.permission.MANAGE_DOCUMENTS',
    );
    expect(
      provider.getAttribute('enabled', namespace: _android),
      anyOf(isNull, 'true'),
    );
    expect(
      provider
          .findElements('intent-filter')
          .expand((filter) => filter.findElements('action'))
          .map((action) => action.getAttribute('name', namespace: _android)),
      contains('android.content.action.DOCUMENTS_PROVIDER'),
    );
  });
}
