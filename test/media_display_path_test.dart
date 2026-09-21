import 'package:flutter_test/flutter_test.dart';
import 'package:best_viewer/src/modules/viewer/media_directory_location.dart';

void main() {
  test('formats primary SAF document ids without double decoding', () {
    expect(
      formatSafDisplayPath(
        'content://com.android.externalstorage.documents/tree/primary%3ADCIM/document/primary%3ADCIM%2Fele%2FTITANS_20220604_130818.jpg',
      ),
      '内部存储 / DCIM / ele / TITANS_20220604_130818.jpg',
    );
  });

  test('preserves unknown providers and malformed ids', () {
    const uri = 'content://example.documents/document/not-a-volume-id';
    expect(formatSafDisplayPath(uri), uri);
  });

  test('keeps external volume identifiers and decodes unicode once', () {
    expect(
      formatSafDisplayPath(
        'content://com.android.externalstorage.documents/document/1234%3A%E7%9B%B8%E5%86%8C%2F%E6%88%91%20%E7%9A%84.jpg',
      ),
      '1234 / 相册 / 我 的.jpg',
    );
  });
}
