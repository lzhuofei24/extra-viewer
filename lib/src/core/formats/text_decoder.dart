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
  return decodePreviewTextBytes(Uint8List.fromList(bytes));
}

/// Decodes a byte-limited text preview without mistaking a UTF-8 character
/// split at the limit for a legacy GBK document. Full document reads use the
/// normal decoder because they never intentionally stop mid-character.
String decodePreviewTextBytes(List<int> bytes) {
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
    final trimmedUtf8 = _trimIncompleteUtf8Suffix(bytes);
    if (trimmedUtf8.length != bytes.length) {
      try {
        return utf8.decode(trimmedUtf8, allowMalformed: false);
      } on FormatException {
        // The invalid bytes are not only the final partial UTF-8 sequence.
      }
    }
    return gbk.decode(bytes, allowMalformed: true);
  }
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

List<int> _trimIncompleteUtf8Suffix(List<int> bytes) {
  var sequenceStart = bytes.length - 1;
  while (sequenceStart > 0 &&
      bytes[sequenceStart] >= 0x80 &&
      bytes[sequenceStart] <= 0xbf) {
    sequenceStart--;
  }
  final lead = bytes[sequenceStart];
  if (lead < 0x80) {
    return bytes;
  }

  final expectedLength = switch (lead) {
    >= 0xc2 && <= 0xdf => 2,
    >= 0xe0 && <= 0xef => 3,
    >= 0xf0 && <= 0xf4 => 4,
    _ => 1,
  };
  final actualLength = bytes.length - sequenceStart;
  if (actualLength < expectedLength) {
    return bytes.sublist(0, sequenceStart);
  }
  return bytes;
}
