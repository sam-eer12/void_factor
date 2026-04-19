import 'package:flutter/material.dart';
import '../theme/monolith_theme.dart';

enum MonolithButtonStyle { primary, secondary, tertiary }

class MonolithButton extends StatefulWidget {
  final String label;
  final VoidCallback? onPressed;
  final MonolithButtonStyle style;
  final bool isExpanded;
  final IconData? icon;

  const MonolithButton({
    super.key,
    required this.label,
    this.onPressed,
    this.style = MonolithButtonStyle.primary,
    this.isExpanded = true,
    this.icon,
  });

  @override
  State<MonolithButton> createState() => _MonolithButtonState();
}

class _MonolithButtonState extends State<MonolithButton> {
  bool _isPressed = false;

  Color get _bgColor {
    switch (widget.style) {
      case MonolithButtonStyle.primary:
        return MonolithTheme.primary;
      case MonolithButtonStyle.secondary:
        return MonolithTheme.surface;
      case MonolithButtonStyle.tertiary:
        return MonolithTheme.surface;
    }
  }

  Color get _textColor {
    switch (widget.style) {
      case MonolithButtonStyle.primary:
        return MonolithTheme.surface;
      case MonolithButtonStyle.secondary:
        return MonolithTheme.primary;
      case MonolithButtonStyle.tertiary:
        return MonolithTheme.primary;
    }
  }

  bool get _hasShadow => widget.style != MonolithButtonStyle.tertiary;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => setState(() => _isPressed = true),
      onTapUp: (_) {
        setState(() => _isPressed = false);
        widget.onPressed?.call();
      },
      onTapCancel: () => setState(() => _isPressed = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 80),
        transform: Matrix4.translationValues(
          _isPressed && _hasShadow ? 4 : 0,
          _isPressed && _hasShadow ? 4 : 0,
          0,
        ),
        width: widget.isExpanded ? double.infinity : null,
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
        decoration: BoxDecoration(
          color: widget.onPressed == null
              ? MonolithTheme.surfaceContainerHigh
              : _bgColor,
          border: Border.all(
            color: MonolithTheme.primary,
            width: MonolithTheme.borderWidth,
          ),
          borderRadius: BorderRadius.zero,
          boxShadow: _hasShadow && !_isPressed
              ? MonolithTheme.hardShadow
              : null,
        ),
        child: Row(
          mainAxisSize:
              widget.isExpanded ? MainAxisSize.max : MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (widget.icon != null) ...[
              Icon(widget.icon, color: _textColor, size: 20),
              const SizedBox(width: 8),
            ],
            Text(
              widget.label.toUpperCase(),
              style: MonolithTheme.labelLarge.copyWith(color: _textColor),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
