import 'package:flutter/material.dart';

class TvoiceLogo extends StatelessWidget {
  const TvoiceLogo({
    super.key,
    this.size = 88,
    this.showWordmark = true,
    this.showShadow = true,
  });
  final double size;
  final bool showWordmark;
  final bool showShadow;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xff113bd1), Color(0xff039dff)],
          ),
          borderRadius: BorderRadius.circular(size * .25),
          boxShadow: showShadow ? [
            BoxShadow(
              color: const Color(0xff087dff).withValues(alpha: .25),
              blurRadius: 24,
              offset: const Offset(0, 10),
            ),
          ] : null,
        ),
        child: Stack(
          alignment: Alignment.center,
          children: [
            Text(
              'T',
              style: TextStyle(
                color: Colors.white,
                fontSize: size * .56,
                fontWeight: FontWeight.w900,
                fontStyle: FontStyle.italic,
              ),
            ),
            Positioned(
              right: size * .14,
              bottom: size * .18,
              child: Icon(
                Icons.graphic_eq_rounded,
                color: const Color(0xff20ddff),
                size: size * .32,
              ),
            ),
          ],
        ),
      ),
      if (showWordmark) ...[
        SizedBox(width: size * .2),
        Text(
          'Tvoice',
          style: TextStyle(
            fontSize: size * .48,
            height: 1,
            fontWeight: FontWeight.w900,
            letterSpacing: -2,
            color: Theme.of(context).colorScheme.onSurface,
          ),
        ),
      ],
    ],
  );
}
