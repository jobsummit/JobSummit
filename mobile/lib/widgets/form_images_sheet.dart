import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../domain/upload_specs.dart';
import '../services/form_images.dart';
import '../theme/app_theme.dart';
import '../utils/system_actions.dart';
import 'common.dart';

/// "Photo & signature": your pictures, made to the sizes this exam's form wants
/// ([specs] from its notice), else to a board's usual sizes. Pick each picture
/// once; every exam after that is one tap.
Future<void> showFormImagesSheet(
  BuildContext context, {
  required String examName,
  String? organization,
  List<UploadSpec> specs = const [],
}) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => _FormImagesSheet(examName: examName, organization: organization, specs: specs),
    );

class _FormImagesSheet extends StatefulWidget {
  const _FormImagesSheet({required this.examName, this.organization, required this.specs});

  final String examName;
  final String? organization;
  final List<UploadSpec> specs;

  @override
  State<_FormImagesSheet> createState() => _FormImagesSheetState();
}

class _FormImagesSheetState extends State<_FormImagesSheet> {
  late String? _preset = widget.specs.isEmpty ? (presetFor(widget.organization, widget.examName) ?? 'SSC') : null;
  late List<UploadSpec> _specs = widget.specs.isNotEmpty ? widget.specs : kUploadPresets[_preset]!;

  void _usePreset(String name) => setState(() {
        _preset = name;
        _specs = kUploadPresets[name]!;
      });

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final fromNotice = widget.specs.isNotEmpty;
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(20, 0, 20, 24 + MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Photo & signature', style: text.titleLarge),
          const SizedBox(height: 4),
          Text(
            fromNotice
                ? 'Sizes from the ${widget.examName} notice.'
                : 'Usual sizes. Check them against the notice.',
            style: text.bodySmall,
          ),
          if (!fromNotice) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              children: [
                for (final name in kUploadPresets.keys)
                  ChoiceChip(label: Text(name), selected: _preset == name, onSelected: (_) => _usePreset(name)),
              ],
            ),
          ],
          const SizedBox(height: 8),
          for (final (i, spec) in _specs.indexed)
            _UploadRow(
              key: ValueKey(spec),
              spec: spec,
              examName: widget.examName,
              onSpec: (s) => setState(() => _specs = [..._specs]..[i] = s),
            ),
          const SizedBox(height: 8),
          const MutedNote('Your pictures stay on this phone. They aren’t backed up.'),
        ],
      ),
    );
  }
}

class _UploadRow extends StatefulWidget {
  const _UploadRow({super.key, required this.spec, required this.examName, required this.onSpec});

  final UploadSpec spec;
  final String examName;
  final ValueChanged<UploadSpec> onSpec;

  @override
  State<_UploadRow> createState() => _UploadRowState();
}

class _UploadRowState extends State<_UploadRow> {
  File? _original;
  Uint8List? _made;
  bool _busy = true;
  String? _error;

  UploadSpec get spec => widget.spec;
  String get _name => FormImages.fileName(widget.examName, spec.kind);

  @override
  void initState() {
    super.initState();
    FormImages.original(spec.kind).then((f) {
      if (!mounted) return;
      _original = f;
      f == null ? setState(() => _busy = false) : _make();
    });
  }

  Future<void> _make() async {
    final original = _original;
    if (original == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final made = await FormImages.make(original, spec);
      if (mounted) setState(() => _made = made);
    } catch (_) {
      if (mounted) setState(() => _error = 'Couldn’t read that picture. Choose another.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _choose() async {
    final f = await FormImages.choose(spec.kind);
    if (f == null || !mounted) return;
    _original = f;
    await _make();
  }

  Future<void> _save() async {
    final made = _made;
    if (made == null) return;
    try {
      final where = await FormImages.save(made, _name);
      if (!mounted) return;
      if (where == null) {
        showErrorSnack(context, 'Storage permission is off. Use Share instead.');
      } else {
        showCalmSnack(context, 'Saved to $where');
      }
    } catch (_) {
      if (mounted) showErrorSnack(context, 'Couldn’t save it. Use Share instead.');
    }
  }

  Future<void> _editSize() async {
    final s = await showDialog<UploadSpec>(context: context, builder: (_) => _SpecDialog(spec: spec));
    if (s != null) widget.onSpec(s);
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final made = _made;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              color: AppPalette.surfaceVariant,
              borderRadius: BorderRadius.circular(10),
            ),
            clipBehavior: Clip.antiAlias,
            child: _busy
                ? const Center(child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2)))
                : made != null
                    ? Image.memory(made, fit: BoxFit.contain)
                    : Icon(Icons.add_photo_alternate_outlined, color: AppPalette.textMuted),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(spec.kind.label, style: text.titleSmall),
                Text(
                  [
                    if (spec.summary.isNotEmpty) 'Needs ${spec.summary}',
                    if (made != null) 'Made: ${(made.length / 1024).toStringAsFixed(0)} KB',
                  ].join('\n'),
                  style: text.bodySmall,
                ),
                if (_error != null) Text(_error!, style: text.bodySmall?.copyWith(color: AppPalette.terracotta)),
                Wrap(
                  spacing: 4,
                  children: [
                    if (made != null) ...[
                      TextButton(onPressed: _save, child: const Text('Save')),
                      TextButton(onPressed: () => FormImages.share(made, _name), child: const Text('Share')),
                    ],
                    TextButton(
                      onPressed: _busy ? null : _choose,
                      child: Text(_original == null ? 'Choose picture' : 'Change'),
                    ),
                    TextButton(onPressed: _editSize, child: const Text('Size')),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Edit one upload's KB range and pixel size (blank = no rule).
class _SpecDialog extends StatefulWidget {
  const _SpecDialog({required this.spec});

  final UploadSpec spec;

  @override
  State<_SpecDialog> createState() => _SpecDialogState();
}

class _SpecDialogState extends State<_SpecDialog> {
  late final _min = TextEditingController(text: widget.spec.minKb?.toString() ?? '');
  late final _max = TextEditingController(text: widget.spec.maxKb?.toString() ?? '');
  late final _w = TextEditingController(text: widget.spec.width?.toString() ?? '');
  late final _h = TextEditingController(text: widget.spec.height?.toString() ?? '');

  @override
  void dispose() {
    for (final c in [_min, _max, _w, _h]) {
      c.dispose();
    }
    super.dispose();
  }

  int? _n(TextEditingController c) => int.tryParse(c.text.trim());

  Widget _field(TextEditingController c, String label) => Expanded(
        child: TextField(
          controller: c,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: InputDecoration(labelText: label),
        ),
      );

  @override
  Widget build(BuildContext context) => AlertDialog(
        backgroundColor: AppPalette.surface,
        title: Text(widget.spec.kind.label),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(children: [_field(_min, 'Min KB'), const SizedBox(width: 12), _field(_max, 'Max KB')]),
            Row(children: [_field(_w, 'Width px'), const SizedBox(width: 12), _field(_h, 'Height px')]),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(
              context,
              UploadSpec(widget.spec.kind, minKb: _n(_min), maxKb: _n(_max), width: _n(_w), height: _n(_h)),
            ),
            child: const Text('Use'),
          ),
        ],
      );
}
