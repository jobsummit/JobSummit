import 'package:flutter/material.dart';

import '../models/vault_entry.dart';
import 'app_icons.dart';

/// Application Tracker modal. Every field is optional: "Save" with nothing
/// typed is a valid, zero-friction choice. Returns null if dismissed.
/// [onPaidChanged]: shows a "Fee paid" switch (on) and reports each change at
/// once, so it counts even if the sheet is closed without saving.
Future<CredentialsInput?> showApplicationTrackerSheet(
  BuildContext context, {
  required String title,
  VaultEntry? initial,
  bool hasSavedPassword = false,
  ValueChanged<bool>? onPaidChanged,
}) =>
    showModalBottomSheet<CredentialsInput>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => _TrackerSheet(
          title: title, initial: initial, hasSavedPassword: hasSavedPassword, onPaidChanged: onPaidChanged),
    );

class _TrackerSheet extends StatefulWidget {
  const _TrackerSheet({required this.title, this.initial, this.hasSavedPassword = false, this.onPaidChanged});

  final String title;
  final VaultEntry? initial;
  final bool hasSavedPassword;
  final ValueChanged<bool>? onPaidChanged;

  @override
  State<_TrackerSheet> createState() => _TrackerSheetState();
}

class _TrackerSheetState extends State<_TrackerSheet> {
  late final _reg = TextEditingController(text: widget.initial?.registrationId);
  late final _roll = TextEditingController(text: widget.initial?.rollNumber);
  final _password = TextEditingController();
  bool _obscure = true;
  bool _paid = true;

  @override
  void dispose() {
    _reg.dispose();
    _roll.dispose();
    _password.dispose();
    super.dispose();
  }

  void _save() => Navigator.of(context).pop(
        CredentialsInput(registrationId: _reg.text, rollNumber: _roll.text, password: _password.text),
      );

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(widget.title, style: text.titleLarge),
            const SizedBox(height: 4),
            Text('Save what you have now. Everything here is optional and stays on this phone.',
                style: text.bodySmall),
            if (widget.onPaidChanged != null)
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _paid,
                onChanged: (paid) {
                  setState(() => _paid = paid);
                  widget.onPaidChanged!(paid);
                },
                title: const Text('Fee paid'),
                subtitle: _paid ? null : const Text('We’ll remind you the day before it closes'),
              ),
            const SizedBox(height: 20),
            TextField(
              controller: _reg,
              textInputAction: TextInputAction.next,
              autocorrect: false,
              decoration: const InputDecoration(labelText: 'Registration ID'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _roll,
              textInputAction: TextInputAction.next,
              autocorrect: false,
              decoration: const InputDecoration(labelText: 'Roll number'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _password,
              obscureText: _obscure,
              autocorrect: false,
              enableSuggestions: false,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _save(),
              decoration: InputDecoration(
                labelText: 'Portal password / PIN',
                helperText: widget.hasSavedPassword ? 'Leave blank to keep the saved one' : null,
                suffixIcon: IconButton(
                  tooltip: _obscure ? 'Show' : 'Hide',
                  icon: glyph(_obscure ? AppIcon.passwordShow : AppIcon.passwordHide),
                  onPressed: () => setState(() => _obscure = !_obscure),
                ),
              ),
            ),
            const SizedBox(height: 24),
            FilledButton(onPressed: _save, child: const Text('Save')),
          ],
        ),
      ),
    );
  }
}
