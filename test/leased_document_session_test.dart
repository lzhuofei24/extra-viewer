import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:best_viewer/src/modules/sources/source_file_cache.dart';
import 'package:best_viewer/src/modules/viewer/leased_document_session.dart';

void main() {
  test('source survives until native disposal completes exactly once',
      () async {
    final events = <String>[];
    final gate = Completer<void>();
    final session = LeasedDocumentSession<int>(
      source: Future.value(SourceFileLease(File('unused'), () async {
        events.add('release');
      })),
      open: (_) async => 1,
      disposeDocument: (_) async {
        events.add('dispose');
        await gate.future;
        events.add('disposed');
      },
    );
    await session.document;
    final closing = session.close();
    expect(identical(closing, session.close()), isTrue);
    await Future<void>.delayed(Duration.zero);
    expect(events, ['dispose']);
    gate.complete();
    await closing;
    expect(events, ['dispose', 'disposed', 'release']);
  });

  test('document returned during close is disposed before releasing source',
      () async {
    final opened = Completer<int>();
    final started = Completer<void>();
    final events = <String>[];
    final session = LeasedDocumentSession<int>(
      source: Future.value(SourceFileLease(File('unused'), () async {
        events.add('release');
      })),
      open: (_) {
        started.complete();
        return opened.future;
      },
      disposeDocument: (_) async => events.add('dispose'),
    );
    await started.future;
    final closing = session.close();
    expect(events, isEmpty);
    opened.complete(1);
    await closing;
    expect(events, ['dispose', 'release']);
  });

  test('closing before source arrives never opens the native document',
      () async {
    final source = Completer<SourceFileLease>();
    var released = false;
    final session = LeasedDocumentSession<int>(
      source: source.future,
      open: (_) async => fail('must not open'),
      disposeDocument: (_) async => fail('must not dispose'),
    );
    final closing = session.close();
    source
        .complete(SourceFileLease(File('unused'), () async => released = true));
    await closing;
    expect(released, isTrue);
  });

  test('open failure releases source and close remains safe', () async {
    var released = false;
    final session = LeasedDocumentSession<int>(
      source: Future.value(
          SourceFileLease(File('unused'), () async => released = true)),
      open: (_) async => throw const FormatException('bad pdf'),
      disposeDocument: (_) async => fail('no document exists'),
    );
    await expectLater(session.document, throwsFormatException);
    await session.close();
    expect(released, isTrue);
  });

  test('failed native dispose keeps its source lease alive', () async {
    var released = false;
    final session = LeasedDocumentSession<int>(
      source: Future.value(
          SourceFileLease(File('unused'), () async => released = true)),
      open: (_) async => 1,
      disposeDocument: (_) async =>
          throw StateError('native handle still in use'),
    );
    await session.document;
    await expectLater(session.close(), throwsStateError);
    expect(released, isFalse);
  });

  test('cleanup failure after failed open is reported by shutdown', () async {
    final session = LeasedDocumentSession<int>(
      source: Future.value(SourceFileLease(File('unused'), () async {
        throw const FileSystemException('cannot release');
      })),
      open: (_) async => throw const FormatException('bad pdf'),
      disposeDocument: (_) async => fail('no document exists'),
    );
    await expectLater(session.document, throwsA(isA<FileSystemException>()));
    await expectLater(session.close(), throwsA(isA<FileSystemException>()));
  });
}
