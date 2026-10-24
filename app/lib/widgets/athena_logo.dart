import 'package:flutter/material.dart';
import '../core/theme.dart';

/// Renders the official Athena "Owl A" brand mark natively via CustomPainter.
/// Per logo/athena-brand-guidelines.md:
/// - Flat-topped geometric A with owl eyes and beak inside.
/// - Switches to small-size cut (heavier strokes, larger eyes, no beak) when size < 24px.
class AthenaSymbol extends StatelessWidget {
  final double size;
  final Color color;

  const AthenaSymbol({
    super.key,
    this.size = 24.0,
    this.color = AppTheme.figmaBlack,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _AthenaSymbolPainter(
          color: color,
          isSmallCut: size < 24.0,
        ),
      ),
    );
  }
}

class _AthenaSymbolPainter extends CustomPainter {
  final Color color;
  final bool isSmallCut;

  _AthenaSymbolPainter({
    required this.color,
    required this.isSmallCut,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill
      ..isAntiAlias = true;

    canvas.save();
    // Base SVG coordinate space is 256x256 from athena-brand-kit-v3
    final scale = size.width / 256.0;
    canvas.scale(scale, scale);

    final path = Path()..fillType = PathFillType.evenOdd;

    // Body contour of the Open-Book Owl
    // M128 72 C150 60 176 34 212 10 C222 46 228 98 228 142 A100 100 0 0 1 128 242 A100 100 0 0 1 28 142 C28 98 34 46 44 10 C80 34 106 60 128 72 Z
    path.moveTo(128, 72);
    path.cubicTo(150, 60, 176, 34, 212, 10);
    path.cubicTo(222, 46, 228, 98, 228, 142);
    path.arcToPoint(
      const Offset(128, 242),
      radius: const Radius.circular(100),
      clockwise: true,
    );
    path.arcToPoint(
      const Offset(28, 142),
      radius: const Radius.circular(100),
      clockwise: true,
    );
    path.cubicTo(28, 98, 34, 46, 44, 10);
    path.cubicTo(80, 34, 106, 60, 128, 72);
    path.close();

    if (isSmallCut) {
      // Small-size cut (16–24px): larger eye rings (r=35), bigger pupils (r=19), no beak
      // M49 128 A35 35 0 1 1 119 128 A35 35 0 1 1 49 128 Z
      path.addOval(Rect.fromCircle(center: const Offset(84, 128), radius: 35));
      // M137 128 A35 35 0 1 1 207 128 A35 35 0 1 1 137 128 Z
      path.addOval(Rect.fromCircle(center: const Offset(172, 128), radius: 35));
      // M68 137 A19 19 0 1 1 106 137 A19 19 0 1 1 68 137 Z
      path.addOval(Rect.fromCircle(center: const Offset(87, 137), radius: 19));
      // M150 137 A19 19 0 1 1 188 137 A19 19 0 1 1 150 137 Z
      path.addOval(Rect.fromCircle(center: const Offset(169, 137), radius: 19));
    } else {
      // Master cut (>= 24px): eye rings (r=31), pupils (r=15) glancing down & inward, kite beak
      // M53 124 A31 31 0 1 1 115 124 A31 31 0 1 1 53 124 Z
      path.addOval(Rect.fromCircle(center: const Offset(84, 124), radius: 31));
      // M141 124 A31 31 0 1 1 203 124 A31 31 0 1 1 141 124 Z
      path.addOval(Rect.fromCircle(center: const Offset(172, 124), radius: 31));
      // M72 132 A15 15 0 1 1 102 132 A15 15 0 1 1 72 132 Z
      path.addOval(Rect.fromCircle(center: const Offset(87, 132), radius: 15));
      // M154 132 A15 15 0 1 1 184 132 A15 15 0 1 1 154 132 Z
      path.addOval(Rect.fromCircle(center: const Offset(169, 132), radius: 15));

      // Beak: M118 138 L128 168 L138 138 Q128 131 118 138 Z
      final beak = Path()
        ..moveTo(118, 138)
        ..lineTo(128, 168)
        ..lineTo(138, 138)
        ..quadraticBezierTo(128, 131, 118, 138)
        ..close();
      path.addPath(beak, Offset.zero);
    }

    canvas.drawPath(path, paint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _AthenaSymbolPainter oldDelegate) {
    return oldDelegate.color != color || oldDelegate.isSmallCut != isSmallCut;
  }
}

/// Official brand tile per ATHENA-BRAND-GUIDE.md:
/// - Primary: white owl on a black tile (#000000)
/// - Inverse: black owl on a white tile (#FFFFFF) with a 1px border (#EAEAEA)
enum AthenaTileStyle {
  blackPrimary,
  whiteInverse,
  minimal,
  // Backwards compatibility aliases
  limePrimary,
  charcoalReversed,
  paperMinimal,
}

class AthenaLogoTile extends StatelessWidget {
  final double size;
  final AthenaTileStyle style;
  final double? borderRadius;

  const AthenaLogoTile({
    super.key,
    this.size = 40.0,
    this.style = AthenaTileStyle.blackPrimary,
    this.borderRadius,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final Color bgColor;
    final Color markColor;
    final Border? border;

    switch (style) {
      case AthenaTileStyle.blackPrimary:
      case AthenaTileStyle.charcoalReversed:
      case AthenaTileStyle.limePrimary:
        bgColor = isDark ? const Color(0xFF222222) : AppTheme.ink;
        markColor = Colors.white;
        border = isDark ? Border.all(color: const Color(0xFF333333), width: 1.0) : null;
      case AthenaTileStyle.whiteInverse:
      case AthenaTileStyle.paperMinimal:
        bgColor = isDark ? const Color(0xFF181818) : Colors.white;
        markColor = isDark ? Colors.white : AppTheme.ink;
        border = Border.all(color: isDark ? const Color(0xFF2E2E2E) : AppTheme.border, width: 1.0);
      case AthenaTileStyle.minimal:
        bgColor = Colors.transparent;
        markColor = isDark ? Colors.white : AppTheme.ink;
        border = null;
    }

    // Squircle radius proportional to 57.6/256 ≈ 22.5%
    final radius = borderRadius ?? (size * 0.225);
    // Mark takes ~68% of the tile height
    final symbolSize = size * 0.68;

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(radius),
        border: border,
      ),
      child: Center(
        child: Padding(
          padding: EdgeInsets.only(bottom: size * 0.02), // 2% optical lift
          child: AthenaSymbol(
            size: symbolSize,
            color: markColor,
          ),
        ),
      ),
    );
  }
}

/// Header lockup with official brand typography:
/// ATHENA wordmark in DM Serif Display + companion tagline.
class AthenaHeaderBrand extends StatelessWidget {
  final double tileSize;
  final AthenaTileStyle tileStyle;
  final String? subtitle;

  const AthenaHeaderBrand({
    super.key,
    this.tileSize = 40.0,
    this.tileStyle = AthenaTileStyle.blackPrimary,
    this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        AthenaLogoTile(
          size: tileSize,
          style: tileStyle,
        ),
        const SizedBox(width: 14),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'ATHENA',
              style: TextStyle(
                fontFamily: AppTheme.fontDisplay,
                color: AppTheme.inkOf(context),
                fontSize: 20,
                fontWeight: FontWeight.w400,
                letterSpacing: 1.2,
                height: 1.0,
              ),
            ),
            const SizedBox(height: 3),
            Text(
              subtitle ?? 'Never read alone',
              style: TextStyle(
                fontFamily: AppTheme.fontUI,
                color: AppTheme.textMutedOf(context),
                fontSize: 11,
                fontWeight: FontWeight.w500,
                letterSpacing: 0.6,
                height: 1.0,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// Conditional Mascot with editorial breathing/pulse animation.
/// - When [isPulsing] is true (e.g. during daemon reconnection, background research, or processing),
///   it performs a gentle, subtle editorial breath (scale 0.95 -> 1.0, opacity 0.70 -> 1.0).
/// - When [isPulsing] is false, it stays static with zero CPU/animation overhead.
class AthenaAnimatedMascot extends StatefulWidget {
  final double size;
  final bool isPulsing;
  final AthenaTileStyle style;

  const AthenaAnimatedMascot({
    super.key,
    this.size = 38.0,
    this.isPulsing = false,
    this.style = AthenaTileStyle.blackPrimary,
  });

  @override
  State<AthenaAnimatedMascot> createState() => _AthenaAnimatedMascotState();
}

class _AthenaAnimatedMascotState extends State<AthenaAnimatedMascot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _scaleAnimation;
  late final Animation<double> _opacityAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    );
    _scaleAnimation = Tween<double>(begin: 0.95, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );
    _opacityAnimation = Tween<double>(begin: 0.70, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );

    if (widget.isPulsing) {
      _controller.repeat(reverse: true);
    }
  }

  @override
  void didUpdateWidget(covariant AthenaAnimatedMascot oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isPulsing != oldWidget.isPulsing) {
      if (widget.isPulsing) {
        _controller.repeat(reverse: true);
      } else {
        _controller.stop();
        _controller.value = 1.0;
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.isPulsing) {
      return AthenaLogoTile(
        size: widget.size,
        style: widget.style,
      );
    }

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return Transform.scale(
          scale: _scaleAnimation.value,
          child: Opacity(
            opacity: _opacityAnimation.value,
            child: child,
          ),
        );
      },
      child: AthenaLogoTile(
        size: widget.size,
        style: widget.style,
      ),
    );
  }
}
