import 'package:flutter/material.dart';

import '../../theme/monolith_theme.dart';
import '../../widgets/monolith_text_field.dart';

/// The last thing between the user and an irreversible deletion.
///
/// The typed word is the whole point: an account deletion reached by two taps is
/// an account deletion reached by accident, and there is no undo to fall back
/// on. Nothing here performs the deletion — it only reports whether the user
/// asked for it.
class DeleteAccountDialog extends StatefulWidget {
  const DeleteAccountDialog({super.key});

  static const String title = 'DELETE ACCOUNT?';

  /// Typed verbatim to arm the action. Uppercase, and checked case-sensitively.
  static const String confirmWord = 'DELETE';

  static const String confirmLabel = 'DELETE ACCOUNT';
  static const String cancelLabel = 'CANCEL';

  /// Named one by one rather than summarised as "your data". The food logs in
  /// particular live only on this device, so this dialog is the only warning
  /// the user gets that they are about to go.
  static const List<String> destroyedItems = [
    'YOUR SIGN-IN AND ACCOUNT',
    'YOUR PROFILE, GOALS AND METRICS',
    'EVERY FOOD LOG ON THIS DEVICE',
  ];

  /// Shows the dialog and resolves to whether the user confirmed.
  ///
  /// A dismissal — barrier tap or back — comes back from `showDialog` as null,
  /// which is folded into `false` here so no caller can mistake an absence of an
  /// answer for a yes.
  static Future<bool> show(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => const DeleteAccountDialog(),
    );
    return confirmed ?? false;
  }

  @override
  State<DeleteAccountDialog> createState() => _DeleteAccountDialogState();
}

class _DeleteAccountDialogState extends State<DeleteAccountDialog> {
  final _controller = TextEditingController();

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onTyped);
  }

  @override
  void dispose() {
    _controller.removeListener(_onTyped);
    _controller.dispose();
    super.dispose();
  }

  void _onTyped() => setState(() {});

  /// Whitespace is trimmed because a pasted word often carries a space and the
  /// difference is invisible on screen — a button that stayed dead would read as
  /// broken. Case is not relaxed: that is what makes typing it deliberate.
  bool get _isArmed =>
      _controller.text.trim() == DeleteAccountDialog.confirmWord;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: MonolithTheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.zero,
        // Framed in error to match the DANGER ZONE the dialog was opened from.
        side: BorderSide(
          color: MonolithTheme.error,
          width: MonolithTheme.borderWidth,
        ),
      ),
      title: Text(
        DeleteAccountDialog.title,
        style: MonolithTheme.headlineMedium
            .copyWith(color: MonolithTheme.error),
      ),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('THIS CANNOT BE UNDONE. IT DESTROYS:',
                style: MonolithTheme.bodyMedium),
            const SizedBox(height: 12),
            for (final item in DeleteAccountDialog.destroyedItems) ...[
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 6,
                    height: 6,
                    margin: const EdgeInsets.only(top: 5, right: 10),
                    color: MonolithTheme.error,
                  ),
                  Expanded(
                    child: Text(item, style: MonolithTheme.labelSmall),
                  ),
                ],
              ),
              const SizedBox(height: 8),
            ],
            const SizedBox(height: 12),
            MonolithTextField(
              label: 'TYPE ${DeleteAccountDialog.confirmWord} TO CONFIRM',
              hint: DeleteAccountDialog.confirmWord,
              controller: _controller,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text(
            DeleteAccountDialog.cancelLabel,
            style:
                MonolithTheme.labelMedium.copyWith(color: MonolithTheme.primary),
          ),
        ),
        TextButton(
          // Null until the word matches, which is what disables the button.
          onPressed: _isArmed ? () => Navigator.pop(context, true) : null,
          child: Text(
            DeleteAccountDialog.confirmLabel,
            style: MonolithTheme.labelMedium.copyWith(
              color: _isArmed
                  ? MonolithTheme.error
                  : MonolithTheme.surfaceContainerHigh,
            ),
          ),
        ),
      ],
    );
  }
}
