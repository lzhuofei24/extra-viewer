import 'package:best_viewer/src/modules/sources/source_adapter.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('best_viewer/directory_picker');
  test('null SAF page is incomplete and closes the cursor', () async {
    var closed = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'openSourceDirectory') return 'cursor';
      if (call.method == 'closeSourceDirectory') closed = true;
      return null;
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));
    await expectLater(
        SafSourceAdapter().listDirectory('content://tree/root').toList(),
        throwsStateError);
    expect(closed, isTrue);
  });
}
