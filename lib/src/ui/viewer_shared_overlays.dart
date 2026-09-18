part of 'builtin_media_page.dart';

class _MissingSourceNotice extends StatelessWidget {
  const _MissingSourceNotice({required this.path});

  final String path;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text('文件不存在：$path', textAlign: TextAlign.center),
      ),
    );
  }
}

class _LibraryOverlayBackdrop extends StatelessWidget {
  const _LibraryOverlayBackdrop();

  @override
  Widget build(BuildContext context) {
    return const IgnorePointer(
      child: ColoredBox(color: Color(0xc9000000)),
    );
  }
}

class _LibraryOverlayCenterStage extends StatelessWidget {
  const _LibraryOverlayCenterStage({
    required this.enabled,
    required this.child,
  });

  final bool enabled;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!enabled) return child;
    // The image starts with a contain fit, but its interactive canvas must
    // remain viewport-sized so zooming is never clipped to that initial fit.
    return Stack(
      fit: StackFit.expand,
      children: [
        child,
        const IgnorePointer(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: Alignment.center,
                radius: 1.2,
                colors: [Color(0x00000000), Color(0x4a000000)],
                stops: [.62, 1],
              ),
            ),
          ),
        ),
      ],
    );
  }
}
