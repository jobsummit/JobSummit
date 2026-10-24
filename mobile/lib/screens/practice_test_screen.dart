import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/practice.dart';
import '../domain/xp.dart';
import '../providers/practice_providers.dart';
import '../providers/xp_providers.dart';
import '../services/fx.dart';
import '../services/practice_store.dart';
import '../theme/app_theme.dart';
import '../utils/system_actions.dart';
import '../widgets/app_card.dart';
import '../widgets/celebrate.dart';
import '../widgets/common.dart';

/// One timed test: a question at a time, a clock that keeps running in the
/// background, a palette to jump between questions, then marks and every answer
/// explained. [instant]: each answer shows as soon as it's picked.
class PracticeTestScreen extends ConsumerStatefulWidget {
  const PracticeTestScreen({super.key, required this.plan, this.instant = false});

  final PracticePlan plan;
  final bool instant;

  static Future<void> open(BuildContext context, PracticePlan plan, {bool instant = false}) =>
      Navigator.of(context)
          .push(MaterialPageRoute<void>(builder: (_) => PracticeTestScreen(plan: plan, instant: instant)));

  @override
  ConsumerState<PracticeTestScreen> createState() => _PracticeTestScreenState();
}

class _PracticeTestScreenState extends ConsumerState<PracticeTestScreen> {
  List<PracticeQuestion>? _questions;
  List<int?> _chosen = const [];
  final _revealed = <int>{};
  int _at = 0;
  DateTime? _started;
  Timer? _tick;
  PracticeResult? _result;
  final _reported = <String>{};

  PracticePlan get plan => widget.plan;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final qs = await buildPracticeTest(ref.read(practiceBankProvider), plan);
    if (!mounted) return;
    setState(() {
      _questions = qs;
      _chosen = List.filled(qs.length, null);
      if (qs.isNotEmpty) _started = DateTime.now();
    });
    if (qs.isNotEmpty) {
      _tick = Timer.periodic(const Duration(seconds: 1), (_) {
        if (_left <= Duration.zero) {
          _submit();
        } else {
          setState(() {});
        }
      });
    }
  }

  Duration get _used => _started == null ? Duration.zero : DateTime.now().difference(_started!);
  Duration get _left => plan.time - _used;

  void _choose(int option) {
    if (_revealed.contains(_at)) return;
    final q = _questions![_at];
    setState(() {
      _chosen[_at] = _chosen[_at] == option && !widget.instant ? null : option;
      if (widget.instant) _revealed.add(_at);
    });
    if (widget.instant) option == q.answer ? Fx.done() : Fx.error();
  }

  Future<void> _submit() async {
    if (_result != null) return;
    _tick?.cancel();
    final qs = _questions!;
    final used = _used > plan.time ? plan.time : _used;
    final result = grade(plan, qs, _chosen, at: DateTime.now(), seconds: used.inSeconds);
    setState(() => _result = result);
    await ref.read(practiceHistoryProvider.notifier).add(result);
    Fx.done();
    if (result.counts) await ref.read(xpProvider.notifier).award(XpAction.practiced);
    if (result.share >= 0.8 && mounted) showConfetti(context);
  }

  Future<void> _askSubmit() async {
    final left = _chosen.where((c) => c == null).length;
    if (left > 0) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          backgroundColor: AppPalette.surface,
          title: const Text('Submit the test?'),
          content: Text('$left question${left == 1 ? '' : 's'} not answered.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Keep going')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Submit')),
          ],
        ),
      );
      if (ok != true) return;
    }
    await _submit();
  }

  Future<void> _askLeave() async {
    final leave = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        backgroundColor: AppPalette.surface,
        title: const Text('Leave this test?'),
        content: const Text('It won’t be saved.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Stay')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Leave')),
        ],
      ),
    );
    if (leave == true && mounted) {
      _tick?.cancel();
      Navigator.pop(context);
    }
  }

  Future<void> _palette() async {
    final qs = _questions!;
    final pick = await showModalBottomSheet<int>(
      context: context,
      useSafeArea: true,
      builder: (c) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Questions', style: Theme.of(c).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text('${_chosen.where((x) => x != null).length} of ${qs.length} answered',
                style: Theme.of(c).textTheme.bodySmall),
            const SizedBox(height: 14),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (var i = 0; i < qs.length; i++)
                  _PaletteDot(
                    n: i + 1,
                    answered: _chosen[i] != null,
                    current: i == _at,
                    onTap: () => Navigator.pop(c, i),
                  ),
              ],
            ),
            const SizedBox(height: 18),
            SizedBox(
              width: double.infinity,
              child: FilledButton(onPressed: () => Navigator.pop(c, -1), child: const Text('Submit test')),
            ),
          ],
        ),
      ),
    );
    if (pick == null || !mounted) return;
    if (pick == -1) {
      await _askSubmit();
    } else {
      setState(() => _at = pick);
    }
  }

  @override
  Widget build(BuildContext context) {
    final qs = _questions;
    final running = qs != null && qs.isNotEmpty && _result == null;
    return PopScope(
      canPop: !running,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _askLeave();
      },
      child: Scaffold(
        backgroundColor: AppPalette.background,
        appBar: AppBar(
          backgroundColor: AppPalette.background,
          title: Text(_result != null || qs == null || qs.isEmpty ? plan.title : '${_at + 1} of ${qs.length}'),
          actions: [
            if (running) Padding(padding: const EdgeInsets.only(right: 12), child: _Clock(left: _left, total: plan.time)),
          ],
        ),
        body: switch ((qs, _result)) {
          (null, _) => const Center(child: CircularProgressIndicator()),
          (final List<PracticeQuestion> list, _) when list.isEmpty => const _NoQuestions(),
          (final List<PracticeQuestion> list, final PracticeResult r?) => _ResultView(
              plan: plan,
              result: r,
              questions: list,
              chosen: _chosen,
              reported: _reported,
              onReport: (q) async {
                await PracticeStore.hide(q.id);
                setState(() => _reported.add(q.id));
                if (context.mounted) showCalmSnack(context, 'Reported. You won’t see it again.');
              },
              onAgain: () => Navigator.of(context).pushReplacement(MaterialPageRoute<void>(
                  builder: (_) => PracticeTestScreen(plan: plan, instant: widget.instant))),
            ),
          (final List<PracticeQuestion> list, _) => _questionView(context, list),
        },
      ),
    );
  }

  Widget _questionView(BuildContext context, List<PracticeQuestion> qs) {
    final q = qs[_at];
    final text = Theme.of(context).textTheme;
    final shown = _revealed.contains(_at);
    final answered = _chosen.where((c) => c != null).length;
    return Column(
      children: [
        LinearProgressIndicator(
          value: answered / qs.length,
          minHeight: 4,
          color: AppPalette.periwinkle,
          backgroundColor: AppPalette.surfaceVariant,
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
            children: [
              Text(
                plan.isMock ? '${q.section.short} · ${q.topic}' : q.topic,
                style: text.labelMedium?.copyWith(color: AppPalette.textMuted, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 8),
              Text(q.text, style: text.titleMedium?.copyWith(height: 1.35)),
              const SizedBox(height: 18),
              for (var i = 0; i < q.options.length; i++) ...[
                _OptionTile(
                  letter: 'ABCD'[i],
                  text: q.options[i],
                  look: !shown
                      ? (_chosen[_at] == i ? _Look.picked : _Look.plain)
                      : (i == q.answer ? _Look.right : (_chosen[_at] == i ? _Look.wrong : _Look.plain)),
                  onTap: () => _choose(i),
                ),
                const SizedBox(height: 10),
              ],
              if (shown && q.explanation.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(q.explanation, style: text.bodyMedium?.copyWith(color: AppPalette.textMuted)),
              ],
            ],
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
            child: Row(
              children: [
                IconButton(
                  tooltip: 'Previous',
                  onPressed: _at == 0 ? null : () => setState(() => _at--),
                  icon: const Icon(Icons.chevron_left_rounded),
                ),
                const SizedBox(width: 4),
                OutlinedButton.icon(
                  onPressed: _palette,
                  icon: const Icon(Icons.grid_view_rounded, size: 18),
                  label: Text('$answered/${qs.length}'),
                ),
                const Spacer(),
                if (_at < qs.length - 1)
                  FilledButton(
                    onPressed: () => setState(() => _at++),
                    child: Text(_chosen[_at] == null ? 'Skip' : 'Next'),
                  )
                else
                  FilledButton(onPressed: _askSubmit, child: const Text('Submit')),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

String _mmss(Duration d) {
  final s = d.inSeconds < 0 ? 0 : d.inSeconds;
  return '${s ~/ 60}:${'${s % 60}'.padLeft(2, '0')}';
}

class _Clock extends StatelessWidget {
  const _Clock({required this.left, required this.total});

  final Duration left;
  final Duration total;

  @override
  Widget build(BuildContext context) {
    final color = left.inSeconds <= 60
        ? AppPalette.terracotta
        : (left.inSeconds * 5 <= total.inSeconds ? AppPalette.honey : AppPalette.textPrimary);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(999)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.timer_outlined, size: 16, color: color),
          const SizedBox(width: 6),
          Text(_mmss(left),
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  color: color, fontWeight: FontWeight.w900, fontFeatures: const [FontFeature.tabularFigures()])),
        ],
      ),
    );
  }
}

enum _Look { plain, picked, right, wrong }

class _OptionTile extends StatelessWidget {
  const _OptionTile({required this.letter, required this.text, required this.look, required this.onTap});

  final String letter;
  final String text;
  final _Look look;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final accent = switch (look) {
      _Look.plain => null,
      _Look.picked => AppPalette.periwinkle,
      _Look.right => AppPalette.sage,
      _Look.wrong => AppPalette.terracotta,
    };
    final radius = BorderRadius.circular(AppRadii.control);
    return Material(
      color: accent?.withValues(alpha: 0.16) ?? AppPalette.surface,
      borderRadius: radius,
      child: InkWell(
        borderRadius: radius,
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
          decoration: BoxDecoration(
            borderRadius: radius,
            border: Border.all(color: accent ?? AppPalette.outline.withValues(alpha: 0.4), width: accent == null ? 1 : 2),
          ),
          child: Row(
            children: [
              CircleAvatar(
                radius: 14,
                backgroundColor: accent ?? AppPalette.surfaceVariant,
                child: Text(letter,
                    style: Theme.of(context).textTheme.labelLarge?.copyWith(
                        color: accent == null ? AppPalette.textPrimary : AppPalette.onAccent,
                        fontWeight: FontWeight.w900)),
              ),
              const SizedBox(width: 12),
              Expanded(child: Text(text, style: Theme.of(context).textTheme.bodyLarge)),
              if (look == _Look.right) Icon(Icons.check_circle_rounded, color: AppPalette.sage),
              if (look == _Look.wrong) Icon(Icons.cancel_rounded, color: AppPalette.terracotta),
            ],
          ),
        ),
      ),
    );
  }
}

class _PaletteDot extends StatelessWidget {
  const _PaletteDot({required this.n, required this.answered, required this.current, required this.onTap});

  final int n;
  final bool answered;
  final bool current;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Container(
          width: 40,
          height: 40,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: answered ? AppPalette.periwinkle : AppPalette.surfaceVariant,
            border: current ? Border.all(color: AppPalette.textPrimary, width: 2) : null,
          ),
          child: Text('$n',
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  color: answered ? AppPalette.onAccent : AppPalette.textPrimary, fontWeight: FontWeight.w800)),
        ),
      );
}

class _NoQuestions extends StatelessWidget {
  const _NoQuestions();

  @override
  Widget build(BuildContext context) => const Padding(
        padding: EdgeInsets.all(24),
        child: Center(
          child: MutedNote('No questions for this section on the phone yet. Connect to the internet once and try again.'),
        ),
      );
}

class _ResultView extends StatelessWidget {
  const _ResultView({
    required this.plan,
    required this.result,
    required this.questions,
    required this.chosen,
    required this.reported,
    required this.onReport,
    required this.onAgain,
  });

  final PracticePlan plan;
  final PracticeResult result;
  final List<PracticeQuestion> questions;
  final List<int?> chosen;
  final Set<String> reported;
  final ValueChanged<PracticeQuestion> onReport;
  final VoidCallback onAgain;

  @override
  Widget build(BuildContext context) {
    final r = result;
    final text = Theme.of(context).textTheme;
    final weak = [
      for (final e in r.topics.entries)
        if (e.value.$1 < e.value.$2) (e.key, e.value),
    ]..sort((a, b) => (a.$2.$1 / a.$2.$2).compareTo(b.$2.$1 / b.$2.$2));
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
      children: [
        Center(
          child: Text('${marksText(r.marks)} / ${r.total}',
              style: text.displaySmall?.copyWith(fontWeight: FontWeight.w900, color: AppPalette.periwinkle)),
        ),
        Center(child: Text('${(r.share * 100).round()}% · time ${_mmss(Duration(seconds: r.seconds))} of '
            '${plan.time.inMinutes} min', style: text.bodySmall)),
        const SizedBox(height: 14),
        Row(
          children: [
            Expanded(child: _Count('${r.right}', 'right', AppPalette.sage)),
            const SizedBox(width: 8),
            Expanded(child: _Count('${r.wrong}', 'wrong', AppPalette.terracotta)),
            const SizedBox(width: 8),
            Expanded(child: _Count('${r.skipped}', 'skipped', AppPalette.textMuted)),
          ],
        ),
        if (!r.counts) ...[
          const SizedBox(height: 10),
          const MutedNote('Answer at least half the questions to earn XP.'),
        ],
        if (weak.isNotEmpty) ...[
          const SizedBox(height: 14),
          Text('To work on: ${weak.take(3).map((w) => '${w.$1} (${w.$2.$1}/${w.$2.$2})').join(', ')}',
              style: text.bodyMedium),
        ],
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(child: OutlinedButton(onPressed: () => Navigator.pop(context), child: const Text('Done'))),
            const SizedBox(width: 10),
            Expanded(child: FilledButton(onPressed: onAgain, child: const Text('Another test'))),
          ],
        ),
        const SizedBox(height: 24),
        const SectionTitle('Answers'),
        const SizedBox(height: 10),
        for (final (i, q) in questions.indexed) ...[
          _Review(
            n: i + 1,
            question: q,
            chosen: i < chosen.length ? chosen[i] : null,
            reported: reported.contains(q.id),
            onReport: () => onReport(q),
          ),
          const SizedBox(height: 10),
        ],
      ],
    );
  }
}

class _Count extends StatelessWidget {
  const _Count(this.value, this.label, this.color);

  final String value;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return AppCard(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Column(
        children: [
          Text(value, style: text.headlineSmall?.copyWith(color: color, fontWeight: FontWeight.w900)),
          Text(label, style: text.labelSmall),
        ],
      ),
    );
  }
}

class _Review extends StatelessWidget {
  const _Review({
    required this.n,
    required this.question,
    required this.chosen,
    required this.reported,
    required this.onReport,
  });

  final int n;
  final PracticeQuestion question;
  final int? chosen;
  final bool reported;
  final VoidCallback onReport;

  @override
  Widget build(BuildContext context) {
    final q = question;
    final text = Theme.of(context).textTheme;
    final right = chosen == q.answer;
    final (mark, color) = chosen == null
        ? ('Skipped', AppPalette.textMuted)
        : (right ? ('Right', AppPalette.sage) : ('Wrong', AppPalette.terracotta));
    return AppCard(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text('Q$n · ${q.topic}',
                    style: text.labelMedium?.copyWith(color: AppPalette.textMuted, fontWeight: FontWeight.w800)),
              ),
              Text(mark, style: text.labelMedium?.copyWith(color: color, fontWeight: FontWeight.w900)),
            ],
          ),
          const SizedBox(height: 6),
          Text(q.text, style: text.bodyLarge),
          const SizedBox(height: 8),
          if (chosen != null && !right)
            Text('Your answer: ${q.options[chosen!]}', style: text.bodyMedium?.copyWith(color: AppPalette.terracotta)),
          Text('Answer: ${q.options[q.answer]}',
              style: text.bodyMedium?.copyWith(color: AppPalette.sage, fontWeight: FontWeight.w800)),
          if (q.explanation.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(q.explanation, style: text.bodySmall),
          ],
          if (q.fromBank)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: reported ? null : onReport,
                icon: const Icon(Icons.flag_outlined, size: 16),
                label: Text(reported ? 'Reported' : 'Wrong question?'),
              ),
            ),
          if (!q.fromBank) const SizedBox(height: 6),
        ],
      ),
    );
  }
}
