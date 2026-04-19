import 'package:flutter/material.dart';
import '../theme/monolith_theme.dart';

class MonolithCard extends StatelessWidget {
  final Widget child;
  final bool inverted;
  final bool hasShadow;
  final EdgeInsetsGeometry? padding;
  final VoidCallback? onTap;

  const MonolithCard({
    super.key,
    required this.child,
    this.inverted = false,
    this.hasShadow = true,
    this.padding,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: double.infinity,
        padding: padding ?? const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: inverted ? MonolithTheme.primary : MonolithTheme.surface,
          border: Border.all(
            color: MonolithTheme.primary,
            width: MonolithTheme.borderWidth,
          ),
          borderRadius: BorderRadius.zero,
          boxShadow: hasShadow ? MonolithTheme.hardShadow : null,
        ),
        child: child,
      ),
    );
  }
}

class MonolithStatCard extends StatelessWidget {
  final String title;
  final String value;
  final String subtitle;
  final IconData? icon;
  final bool inverted;

  const MonolithStatCard({
    super.key,
    required this.title,
    required this.value,
    required this.subtitle,
    this.icon,
    this.inverted = false,
  });

  @override
  Widget build(BuildContext context) {
    final textColor =
        inverted ? MonolithTheme.surface : MonolithTheme.primary;

    return MonolithCard(
      inverted: inverted,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                title.toUpperCase(),
                style: MonolithTheme.labelMedium.copyWith(color: textColor),
              ),
              if (icon != null) Icon(icon, color: textColor, size: 20),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            value,
            style: MonolithTheme.displayMedium.copyWith(color: textColor),
          ),
          const SizedBox(height: 4),
          Text(
            subtitle.toUpperCase(),
            style: MonolithTheme.labelSmall.copyWith(
              color: textColor.withValues(alpha: 0.7),
            ),
          ),
        ],
      ),
    );
  }
}
