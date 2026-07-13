import 'package:flutter/material.dart';

class CollapseGripIcon extends StatelessWidget {
  const CollapseGripIcon({super.key, this.size = 18, this.color});

  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) => SizedBox.square(
        dimension: size,
        child: CustomPaint(
          painter: _CollapseGripPainter(
            color: color ?? IconTheme.of(context).color ?? Colors.white,
          ),
        ),
      );
}

class _CollapseGripPainter extends CustomPainter {
  const _CollapseGripPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.2
      ..strokeCap = StrokeCap.round;
    final center = size.width / 2;
    final top = size.height * .14;
    final bottom = size.height * .86;
    for (final offset in const [-4.0, 0.0, 4.0]) {
      canvas.drawLine(
          Offset(center + offset, top), Offset(center + offset, bottom), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _CollapseGripPainter oldDelegate) =>
      oldDelegate.color != color;
}
