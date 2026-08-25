import 'package:flutter/material.dart';

/// Exact Flutter counterpart of the vector marks used by Android 0.17.3.
class AndroidTvoiceMark extends StatelessWidget {
  const AndroidTvoiceMark({super.key, this.size = 72});
  final double size;

  @override
  Widget build(BuildContext context) =>
      CustomPaint(size: Size.square(size), painter: _TvoiceMarkPainter());
}

class TojiktelecomBrand extends StatelessWidget {
  const TojiktelecomBrand({super.key, this.compact = false});
  final bool compact;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      CustomPaint(
        size: Size.square(compact ? 32 : 38),
        painter: _TojikMarkPainter(),
      ),
      SizedBox(width: compact ? 7 : 9),
      Text(
        'TOJIKTELECOM',
        style: TextStyle(
          color: const Color(0xff0a84ff),
          fontSize: compact ? 18 : 24,
          height: 1,
          fontWeight: FontWeight.w800,
          letterSpacing: -.6,
        ),
      ),
    ],
  );
}

class _TvoiceMarkPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.width / 108;
    canvas.save();
    canvas.scale(scale);
    final background = RRect.fromRectAndRadius(
      const Rect.fromLTWH(12, 12, 84, 84),
      const Radius.circular(19),
    );
    canvas.drawRRect(
      background,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xff1264f3), Color(0xff0b3ccb)],
        ).createShader(const Rect.fromLTWH(12, 12, 84, 84)),
    );
    final t = Path()
      ..moveTo(28, 31)
      ..lineTo(70, 31)
      ..lineTo(67.5, 41.5)
      ..lineTo(54, 41.5)
      ..lineTo(46.5, 78)
      ..lineTo(34, 78)
      ..lineTo(41.5, 41.5)
      ..lineTo(25.5, 41.5)
      ..close();
    canvas.drawPath(t, Paint()..color = Colors.white);
    final bars = Paint()
      ..color = const Color(0xff19c9f2)
      ..strokeWidth = 3.2
      ..strokeCap = StrokeCap.round;
    for (final points in const [
      [52.0, 66.0, 52.0, 72.0],
      [57.0, 62.0, 57.0, 76.0],
      [62.0, 58.0, 62.0, 79.0],
      [67.0, 61.0, 67.0, 76.0],
      [72.0, 64.0, 72.0, 73.0],
      [77.0, 67.0, 77.0, 71.0],
    ]) {
      canvas.drawLine(
        Offset(points[0], points[1]),
        Offset(points[2], points[3]),
        bars,
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _TojikMarkPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.width / 44;
    canvas.save();
    canvas.scale(scale);
    final path = Path()
      ..moveTo(11, 8)
      ..lineTo(37, 8)
      ..lineTo(35.3, 12.2)
      ..lineTo(24.5, 12.2)
      ..lineTo(22.8, 17)
      ..lineTo(33.5, 17)
      ..lineTo(31.8, 21.2)
      ..lineTo(21.2, 21.2)
      ..lineTo(17.4, 31.8)
      ..cubicTo(16.4, 34.6, 14.2, 36.3, 11.5, 36.3)
      ..cubicTo(8.5, 36.3, 6.4, 34.4, 6.4, 31.8)
      ..cubicTo(6.4, 30.8, 6.6, 29.8, 7, 28.8)
      ..lineTo(9.6, 21.2)
      ..lineTo(3, 21.2)
      ..lineTo(4.7, 17)
      ..lineTo(11.1, 17)
      ..lineTo(12.8, 12.2)
      ..lineTo(9.3, 12.2)
      ..close();
    canvas.drawPath(path, Paint()..color = const Color(0xff149be5));
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
