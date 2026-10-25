import 'package:flutter/material.dart';
import 'package:athena/core/theme/theme.dart';
import 'package:athena/core/widgets/athena_logo.dart';

enum AthenaExpression {
  thinking,
  surprised,
  happy,
  focused,
  wink,
  sleepy,
  neutral,
}

extension AthenaExpressionPath on AthenaExpression {
  String get assetPath {
    switch (this) {
      case AthenaExpression.thinking:
        return 'assets/avatars/athena-owl-thinking-black-transparent.png';
      case AthenaExpression.surprised:
        return 'assets/avatars/athena-owl-surprised-black-transparent.png';
      case AthenaExpression.happy:
        return 'assets/avatars/athena-owl-happy-black-transparent.png';
      case AthenaExpression.focused:
        return 'assets/avatars/athena-owl-focused-black-transparent.png';
      case AthenaExpression.wink:
        return 'assets/avatars/athena-owl-wink-black-transparent.png';
      case AthenaExpression.sleepy:
        return 'assets/avatars/athena-owl-sleepy-black-transparent.png';
      case AthenaExpression.neutral:
        return 'assets/avatars/athena-owl-neutral-black-transparent.png';
    }
  }

  String get label {
    switch (this) {
      case AthenaExpression.thinking:
        return 'Deep Synthesis';
      case AthenaExpression.surprised:
        return 'Epiphany & Discovery';
      case AthenaExpression.happy:
        return 'Ready to Read';
      case AthenaExpression.focused:
        return 'Active Focus';
      case AthenaExpression.wink:
        return 'Card Saved';
      case AthenaExpression.sleepy:
        return 'Quiet Rest';
      case AthenaExpression.neutral:
        return 'Athena Companion';
    }
  }
}

/// A living brand avatar for Athena with curated psychological expressions,
/// subtle organic breathing motion, and double-bezel framing.
class AthenaAvatar extends StatefulWidget {
  final AthenaExpression expression;
  final double size;
  final bool isBreathing;
  final bool showBezel;
  final VoidCallback? onTap;

  const AthenaAvatar({
    super.key,
    this.expression = AthenaExpression.neutral,
    this.size = 36.0,
    this.isBreathing = false,
    this.showBezel = false,
    this.onTap,
  });

  @override
  State<AthenaAvatar> createState() => _AthenaAvatarState();
}

class _AthenaAvatarState extends State<AthenaAvatar>
    with SingleTickerProviderStateMixin {
  AnimationController? _breathController;
  Animation<double>? _scaleAnim;

  @override
  void initState() {
    super.initState();
    if (widget.isBreathing) {
      _initBreathing();
    }
  }

  @override
  void didUpdateWidget(AthenaAvatar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isBreathing && !oldWidget.isBreathing) {
      _initBreathing();
    } else if (!widget.isBreathing && oldWidget.isBreathing) {
      _breathController?.dispose();
      _breathController = null;
    }
  }

  void _initBreathing() {
    _breathController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2400),
    )..repeat(reverse: true);

    _scaleAnim = Tween<double>(begin: 0.96, end: 1.04).animate(
      CurvedAnimation(
        parent: _breathController!,
        curve: Curves.easeInOutSine,
      ),
    );
  }

  @override
  void dispose() {
    _breathController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    Widget avatarImage = Image.asset(
      widget.expression.assetPath,
      width: widget.size,
      height: widget.size,
      fit: BoxFit.contain,
      errorBuilder: (ctx, err, stack) {
        // High-fidelity fallback to vector AthenaSymbol if asset pipeline is unavailable
        return AthenaSymbol(
          size: widget.size,
          color: AppTheme.figmaBlack,
        );
      },
    );

    if (widget.isBreathing && _scaleAnim != null) {
      avatarImage = ScaleTransition(
        scale: _scaleAnim!,
        child: avatarImage,
      );
    }

    if (widget.showBezel) {
      avatarImage = Container(
        width: widget.size + 14,
        height: widget.size + 14,
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          color: const Color(0xFFF7F6F2),
          shape: BoxShape.circle,
          border: Border.all(
            color: const Color(0xFFE8E5DE),
            width: 1.0,
          ),
          boxShadow: const [
            BoxShadow(
              color: Color(0x0A141714),
              blurRadius: 8,
              offset: Offset(0, 2),
            ),
          ],
        ),
        child: Container(
          decoration: const BoxDecoration(
            color: Colors.white,
            shape: BoxShape.circle,
          ),
          alignment: Alignment.center,
          child: avatarImage,
        ),
      );
    }

    if (widget.onTap != null) {
      avatarImage = GestureDetector(
        onTap: widget.onTap,
        child: avatarImage,
      );
    }

    return avatarImage;
  }
}
