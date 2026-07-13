import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:charset/charset.dart';

Future<String> readTextFile(File file, {int? maxBytes}) async {
  if (maxBytes == null) {
    return decodeTextBytes(await file.readAsBytes());
  }
  final bytes = <int>[];
  await for (final chunk in file.openRead(0, maxBytes)) {
    bytes.addAll(chunk);
  }
  return decodeTextBytes(Uint8List.fromList(bytes));
}

String decodeTextBytes(List<int> bytes) {
  if (bytes.isEmpty) return '';
  if (_hasUtf8Bom(bytes)) {
    return utf8.decode(bytes.sublist(3), allowMalformed: true);
  }
  if (hasUtf16Bom(bytes)) {
    return utf16.decode(bytes);
  }
  try {
    return utf8.decode(bytes, allowMalformed: false);
  } on FormatException {
    return gbk.decode(bytes, allowMalformed: true);
  }
}

bool _hasUtf8Bom(List<int> bytes) {
  return bytes.length >= 3 &&
      bytes[0] == 0xef &&
      bytes[1] == 0xbb &&
      bytes[2] == 0xbf;
}
