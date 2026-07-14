import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

const fileFingerprintVersion = 'fp3';
const fileFingerprintPrefixBytes = 8 * 1024;

Future<String> fingerprintFile(File file, {required int size}) async {
  final bytes = BytesBuilder(copy: false);
  await for (final chunk in file.openRead(0, fileFingerprintPrefixBytes)) {
    bytes.add(chunk);
  }
  return fingerprintFromPrefix(size: size, prefix: bytes.takeBytes());
}

String fingerprintFromPrefix({
  required int size,
  required Uint8List prefix,
}) =>
    '$fileFingerprintVersion:$size:${sha256.convert(prefix)}';
