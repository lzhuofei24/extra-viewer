import 'package:flutter_test/flutter_test.dart';

import 'package:best_viewer/src/core/sources/source_handle.dart';

void main() {
  test('source handles preserve local files and Android content URIs', () {
    final local = SourceHandle.parse(r'D:\Media\image.webp');
    final content =
        SourceHandle.parse('content://provider/tree/primary%3AMedia');

    expect(local.isLocalFile, isTrue);
    expect(local.isAndroidContentUri, isFalse);
    expect(content.isLocalFile, isFalse);
    expect(content.isAndroidContentUri, isTrue);
    expect(content.raw, 'content://provider/tree/primary%3AMedia');
  });
}
