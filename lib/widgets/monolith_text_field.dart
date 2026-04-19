import 'package:flutter/material.dart';
import '../theme/monolith_theme.dart';

class MonolithTextField extends StatefulWidget {
  final String label;
  final String? hint;
  final TextEditingController? controller;
  final bool obscureText;
  final TextInputType? keyboardType;
  final String? Function(String?)? validator;
  final int maxLines;
  final Widget? suffixIcon;

  const MonolithTextField({
    super.key,
    required this.label,
    this.hint,
    this.controller,
    this.obscureText = false,
    this.keyboardType,
    this.validator,
    this.maxLines = 1,
    this.suffixIcon,
  });

  @override
  State<MonolithTextField> createState() => _MonolithTextFieldState();
}

class _MonolithTextFieldState extends State<MonolithTextField> {
  bool _isFocused = false;
  late FocusNode _focusNode;

  @override
  void initState() {
    super.initState();
    _focusNode = FocusNode();
    _focusNode.addListener(() {
      setState(() => _isFocused = _focusNode.hasFocus);
    });
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          widget.label.toUpperCase(),
          style: MonolithTheme.labelMedium,
        ),
        const SizedBox(height: 8),
        AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          decoration: BoxDecoration(
            color: _isFocused
                ? MonolithTheme.primary
                : MonolithTheme.surface,
            border: Border.all(
              color: MonolithTheme.primary,
              width: _isFocused
                  ? MonolithTheme.heroBorderWidth
                  : MonolithTheme.borderWidth,
            ),
            borderRadius: BorderRadius.zero,
          ),
          child: TextFormField(
            focusNode: _focusNode,
            controller: widget.controller,
            obscureText: widget.obscureText,
            keyboardType: widget.keyboardType,
            validator: widget.validator,
            maxLines: widget.maxLines,
            style: MonolithTheme.bodyLarge.copyWith(
              color: _isFocused
                  ? MonolithTheme.surface
                  : MonolithTheme.primary,
            ),
            cursorColor: _isFocused
                ? MonolithTheme.surface
                : MonolithTheme.primary,
            decoration: InputDecoration(
              hintText: widget.hint,
              hintStyle: MonolithTheme.bodyMedium.copyWith(
                color: _isFocused
                    ? MonolithTheme.surfaceContainerHigh
                    : MonolithTheme.outline,
              ),
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              errorBorder: InputBorder.none,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 14,
              ),
              suffixIcon: widget.suffixIcon,
            ),
          ),
        ),
      ],
    );
  }
}
