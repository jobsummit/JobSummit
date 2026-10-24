import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/exam_catalog.dart';
import '../providers/providers.dart';
import '../theme/app_theme.dart';
import 'app_icons.dart';

/// Track an exam applied to outside the feed. Typing suggests common exams
/// (built into the app, so instant and offline); picking one fills in its name,
/// candidate login, board website and stages. Anything else: a custom exam.
/// [name]: what to start with (a shared job's title).
Future<void> showAddExamSheet(BuildContext context, {String name = ''}) => showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => _AddExamSheet(name: name),
    );

class _AddExamSheet extends ConsumerStatefulWidget {
  const _AddExamSheet({this.name = ''});

  final String name;

  @override
  ConsumerState<_AddExamSheet> createState() => _AddExamSheetState();
}

class _AddExamSheetState extends ConsumerState<_AddExamSheet> {
  late final _name = TextEditingController(text: widget.name);
  final _login = TextEditingController();
  final _official = TextEditingController();
  CatalogExam? _picked;
  bool _custom = false;
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _login.dispose();
    _official.dispose();
    super.dispose();
  }

  List<CatalogExam> get _suggestions => _picked != null || _custom ? const [] : suggestExams(_name.text, limit: 6);

  void _pick(CatalogExam exam) {
    setState(() {
      _picked = exam;
      _error = null;
      _name.text = trackedNameFor(exam, _name.text, DateTime.now());
      _login.text = exam.loginUrl ?? '';
      _official.text = exam.officialUrl;
    });
  }

  void _goCustom() => setState(() {
        _custom = true;
        _picked = null;
        _error = null;
      });

  void _reset() => setState(() {
        _picked = null;
        _custom = false;
        _login.clear();
        _official.clear();
      });

  static String? _normalised(TextEditingController c) {
    final raw = c.text.trim();
    if (raw.isEmpty) return null;
    return raw.startsWith(RegExp('https?://', caseSensitive: false)) ? raw : 'https://$raw';
  }

  static bool _looksLikeLink(String? link) => link == null || Uri.tryParse(link)?.host.contains('.') == true;

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.length < 3) {
      setState(() => _error = 'Type the exam name, e.g. SSC CGL 2026.');
      return;
    }
    final login = _normalised(_login);
    final official = _normalised(_official);
    if (!_looksLikeLink(login) || !_looksLikeLink(official)) {
      setState(() => _error = 'A link doesn’t look right. Leave it empty if unsure.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final picked = _picked;
    try {
      await ref.read(trackedAppsProvider.notifier).addManual(
            examName: name,
            portalUrl: official,
            applyUrl: login,
            organization: picked?.board,
            tiers: picked != null && picked.stages.length > 1 ? picked.stages : const [],
          );
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      Navigator.of(context).pop();
      messenger.showSnackBar(
        const SnackBar(content: Text('Added. We’ll watch for its admit card, dates and results.')),
      );
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not add it right now. Try again.');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final suggestions = _suggestions;
    final typed = _name.text.trim().length >= 2;
    final showLinks = _picked != null || _custom;

    return Padding(
      padding: EdgeInsets.fromLTRB(20, 0, 20, 16 + MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Add an exam you applied to', style: text.titleLarge),
            const SizedBox(height: 4),
            Text('Start typing, like “SSC” or “IBPS PO”. We fill in the links and stages.', style: text.bodySmall),
            const SizedBox(height: 16),
            TextField(
              controller: _name,
              autofocus: true,
              textInputAction: showLinks ? TextInputAction.next : TextInputAction.search,
              maxLength: 300,
              onChanged: (_) => setState(() => _error = null),
              onSubmitted: (_) {
                if (!showLinks && suggestions.isNotEmpty) _pick(suggestions.first);
              },
              decoration: InputDecoration(
                labelText: 'Exam name',
                hintText: 'e.g. SSC CGL 2026',
                counterText: '',
                prefixIcon: const Icon(Icons.search_rounded),
                suffixIcon: _picked != null
                    ? IconButton(tooltip: 'Pick a different exam', onPressed: _reset, icon: const Icon(Icons.close_rounded))
                    : null,
              ),
            ),
            if (suggestions.isNotEmpty) ...[
              const SizedBox(height: 6),
              for (final e in suggestions) _SuggestionTile(exam: e, onTap: () => _pick(e)),
            ],
            if (!showLinks && typed)
              ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                leading: DuoIcon(AppIcon.addExam, color: AppPalette.periwinkle),
                title: Text(suggestions.isEmpty ? 'Can’t find your exam? Track a custom exam' : 'Not listed? Track a custom exam'),
                onTap: _goCustom,
              ),
            if (_picked != null) ...[
              const SizedBox(height: 10),
              _PickedSummary(exam: _picked!),
            ],
            if (showLinks) ...[
              const SizedBox(height: 14),
              TextField(
                controller: _login,
                keyboardType: TextInputType.url,
                autocorrect: false,
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(
                  labelText: 'Candidate login (optional)',
                  hintText: 'Where you log in for the form, admit card, result',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _official,
                keyboardType: TextInputType.url,
                autocorrect: false,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _save(),
                decoration: const InputDecoration(
                  labelText: 'Official website (optional)',
                  hintText: 'e.g. ssc.gov.in',
                ),
              ),
              const SizedBox(height: 6),
              Text(
                _picked != null
                    ? 'Filled in from our exam list. Change them if your notice says otherwise.'
                    : 'We watch the official website for notices. Without it we rely on trusted job sites.',
                style: text.bodySmall,
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(_error!, style: text.bodyMedium?.copyWith(color: AppPalette.terracotta)),
            ],
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _saving || !showLinks ? null : _save,
              child: _saving
                  ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('Start tracking'),
            ),
            TextButton(
              onPressed: _saving ? null : () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
          ],
        ),
      ),
    );
  }
}

class _SuggestionTile extends StatelessWidget {
  const _SuggestionTile({required this.exam, required this.onTap});

  final CatalogExam exam;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
      leading: DuoIcon(AppIcon.answerKey, color: AppPalette.periwinkle),
      title: Text(exam.name),
      subtitle: Text(
        '${exam.board} · ${exam.stages.join(' → ')}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: text.bodySmall,
      ),
      onTap: onTap,
    );
  }
}

/// What picking a suggestion filled in: board and stages.
class _PickedSummary extends StatelessWidget {
  const _PickedSummary({required this.exam});

  final CatalogExam exam;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final sage = AppPalette.sage;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: sage.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(AppRadii.control),
        border: Border.all(color: sage.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(exam.board, style: text.titleSmall),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final s in exam.stages)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: AppPalette.surfaceVariant,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(s, style: text.labelMedium),
                ),
            ],
          ),
          if (exam.stages.length > 1) ...[
            const SizedBox(height: 8),
            Text('When a stage’s result is out, one tap starts tracking the next.', style: text.bodySmall),
          ],
        ],
      ),
    );
  }
}

/// Quiet "+ Add exam" link for the Tracking header.
class AddExamButton extends StatelessWidget {
  const AddExamButton({super.key});

  @override
  Widget build(BuildContext context) => TextButton.icon(
        onPressed: () => showAddExamSheet(context),
        icon: const Icon(Icons.add_rounded, size: 18),
        label: const Text('Add exam'),
      );
}
