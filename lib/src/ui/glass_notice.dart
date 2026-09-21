import 'dart:async';

import 'package:flutter/material.dart';

import 'app_sidebar.dart';

class GlassNoticeController extends ChangeNotifier {
  GlassNoticeController._();
  static final instance = GlassNoticeController._();

  Timer? _timer;
  String? _message;
  String? _dedupeKey;
  String? get message => _message;

  void show(String message, {String? dedupeKey}) {
    final normalized = message.trim();
    if (normalized.isEmpty) return;
    final same = _message == normalized && _dedupeKey == dedupeKey;
    _message = normalized;
    _dedupeKey = dedupeKey;
    _timer?.cancel();
    _timer = Timer(const Duration(seconds: 1), _clear);
    if (!same) notifyListeners();
  }

  void _clear() {
    _timer = null;
    _message = null;
    _dedupeKey = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _timer = null;
    super.dispose();
  }
}

class GlassNoticeHost extends StatelessWidget {
  const GlassNoticeHost({super.key, this.controller});
  final GlassNoticeController? controller;

  @override
  Widget build(BuildContext context) {
    final activeController = controller ?? GlassNoticeController.instance;
    return ListenableBuilder(
      listenable: activeController,
      builder: (context, _) {
        final message = activeController.message;
        if (message == null) return const SizedBox.shrink();
        return IgnorePointer(
          child: SafeArea(
            bottom: false,
            child: Align(
              alignment: Alignment.topCenter,
              child: Semantics(
                liveRegion: true,
                label: message,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 480),
                    child: FloatingGlassSurface(
                      role: GlassSurfaceRole.panel,
                      borderRadius: 18,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 18, vertical: 12),
                      child: Text(message, textAlign: TextAlign.center),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
