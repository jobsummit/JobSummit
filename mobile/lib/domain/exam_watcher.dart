/// Phase 2 on the phone: is this notice about *my* exam, and what does it announce?
/// A port of backend/app/services/exam_watcher.py + alert_matching.py (pure, no I/O).
///
/// The phone runs the watcher because it is in India: official portals (UPSC,
/// railway boards…) block GitHub's US servers but not you.
library;

import 'package:flutter/foundation.dart';

import '../models/links.dart';
import '../models/tracked_application.dart';
import 'exam_catalog.dart';
import 'feed_builder.dart' show advertKey;

/// Backend `ExamMilestone` wire values.
enum Milestone {
  postponed('postponed'),
  result('result'),
  answerKey('answer_key'),
  admitCard('admit_card'),

  /// The form's correction (edit) window: no stage of its own, but a deadline.
  correction('correction'),
  examSchedule('exam_schedule');

  const Milestone(this.wire);
  final String wire;

  static Milestone? fromWire(String? v) {
    for (final m in values) {
      if (m.wire == v) return m;
    }
    return null;
  }
}

RegExp _phrases(List<String> words) => RegExp('\\b(?:${words.join('|')})\\b', caseSensitive: false);

/// Checked in order, first match wins: the most specific / latest stage first,
/// so "Result along with Final Answer Key" is a result.
final List<(Milestone, RegExp)> milestonePatterns = [
  (Milestone.postponed, _phrases([r'postpone\w*', r're-?scheduled?', 'deferred', r'cancell?ed'])),
  (
    Milestone.result,
    _phrases([
      r'results?',
      r'merit lists?',
      r'select(?:ion)? lists?',
      r'cut[- ]?offs?',
      r'score ?cards?',
      'final selection',
      r'marks of (?:the )?candidates',
    ]),
  ),
  (
    Milestone.answerKey,
    _phrases([
      r'answer keys?',
      r'(?:provisional|tentative) keys?',
      r'response sheets?',
      r'objection\w*',
      r'question papers?'
    ]),
  ),
  (
    Milestone.admitCard,
    _phrases(
        [r'e-?admit cards?', r'admit cards?', r'hall tickets?', r'call letters?', 'admission certificate']),
  ),
  (
    Milestone.correction,
    _phrases([
      r'correction (?:window|facility|portal|link|module)',
      r'(?:application|form|online) (?:form )?correction',
      r'correction in (?:the )?(?:online )?application',
      r'modification (?:window|facility)',
      r'edit (?:window|facility|option)',
      r'rectification (?:window|facility)',
    ]),
  ),
  (
    Milestone.examSchedule,
    _phrases([
      r'exam(?:ination)? dates?',
      r'dates? of (?:the )?exam(?:ination)?',
      r'exam(?:ination)? schedule',
      r'schedule of (?:the )?exam(?:ination)?',
      r'exam(?:ination)? calendar',
      'exam city',
      'city intimation',
      'intimation slip',
      r'time ?table',
    ]),
  ),
];

Milestone? classifyMilestone(String text) {
  for (final (m, pattern) in milestonePatterns) {
    if (pattern.hasMatch(text)) return m;
  }
  return null;
}

const _monthNames = ['jan', 'feb', 'mar', 'apr', 'may', 'jun', 'jul', 'aug', 'sep', 'oct', 'nov', 'dec'];

// Pieces of the date patterns. Month names must be whole words, so "decision" or
// "mayor" never read as a month.
const _mon = r'(jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|june?|july?|aug(?:ust)?'
    r'|sep(?:t(?:ember)?)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)\b\.?';
const _ord = r'(?:st|nd|rd|th)?';
const _yr = r'((?:19|20)\d{2})';
const _to = r'\s*(?:to|till|until|-|–|—|&|and)\s*';
const _day = r'(?<![\w-])(\d{1,2})'; // not "Tier-1", not the "26" of "2026"

// Windows: "12.10.2026 to 19.10.2026", "12–19 October 2026", "28 Nov to 3 Dec",
// "October 12–19, 2026". Single dates: "14.12.2026", "3rd March 2027", "Oct 12, 2026".
final _numRange = RegExp('\\b(\\d{1,2})[./-](\\d{1,2})[./-]$_yr$_to(\\d{1,2})[./-](\\d{1,2})[./-]$_yr\\b',
    caseSensitive: false);
final _dayRange = RegExp('$_day$_ord(?:\\s+$_mon(?:,?\\s*$_yr)?)?$_to(\\d{1,2})$_ord\\s+$_mon(?:,?\\s*$_yr)?',
    caseSensitive: false);
final _monthRange =
    RegExp('\\b$_mon\\s+(\\d{1,2})$_ord$_to(\\d{1,2})$_ord(?:,?\\s*$_yr)?(?!\\d)', caseSensitive: false);
// "September 30, 2026 – October 30, 2026", "Sep 30 to Oct 30, 2026".
final _monthDayRange = RegExp(
    '\\b$_mon\\s+(\\d{1,2})$_ord(?:,?\\s*$_yr)?$_to$_mon\\s+(\\d{1,2})$_ord(?:,?\\s*$_yr)?(?!\\d)',
    caseSensitive: false);
final _numDate = RegExp('\\b(\\d{1,2})[./-](\\d{1,2})[./-]$_yr\\b', caseSensitive: false);
final _dayMonth = RegExp('$_day$_ord\\s+$_mon(?:,?\\s*$_yr)?', caseSensitive: false);
final _monthDay = RegExp('\\b$_mon\\s+(\\d{1,2})$_ord(?:,?\\s*$_yr)?(?!\\d)', caseSensitive: false);

/// Every pattern above, to blank dates out of a text.
final _dateRe = RegExp(
    [_numRange, _dayRange, _monthRange, _monthDayRange, _numDate, _dayMonth, _monthDay].map((r) => r.pattern).join('|'),
    caseSensitive: false);

/// An exam's dates as a notice prints them: one day, or a window ([end] set).
typedef EventWindow = ({DateTime start, DateTime? end});

int _month(String name) => _monthNames.indexOf(name.substring(0, 3).toLowerCase()) + 1;

DateTime? _valid(int y, int m, int d) {
  if (m < 1 || m > 12 || d < 1 || d > 31 || y < 2000 || y > 2100) return null;
  final date = DateTime(y, m, d);
  return date.month == m ? date : null; // 31 Feb
}

/// A year for a date printed without one: the one that puts it closest to [ref].
int _yearNear(int m, int d, DateTime ref) {
  var best = ref.year;
  var bestGap = 1 << 30;
  for (final y in [ref.year - 1, ref.year, ref.year + 1]) {
    final gap = DateTime(y, m, d).difference(ref).inDays.abs();
    if (gap < bestGap) {
      best = y;
      bestGap = gap;
    }
  }
  return best;
}

EventWindow? _window(DateTime? start, DateTime? end) {
  if (start == null) return null;
  if (end == null || end == start) return (start: start, end: null);
  if (end.isBefore(start) || end.difference(start).inDays > 62) return null; // not one exam window
  return (start: start, end: end);
}

/// From one range match: the end's month and year carry over to the start ("12–19
/// October"), stepping back a month or year when the start would come after the end.
EventWindow? _range(int d1, int? m1, int? y1, int d2, int m2, int? y2, DateTime ref) {
  final endYear = y2 ?? y1 ?? _yearNear(m2, d2, ref);
  final end = _valid(endYear, m2, d2);
  if (end == null) return null;
  var sm = m1 ?? m2;
  var sy = y1 ?? endYear;
  if (m1 == null && d1 > d2) sm -= 1; // "28 to 3 December"
  if (sm == 0) {
    sm = 12;
    sy -= 1;
  }
  if (y1 == null && DateTime(sy, sm, d1).isAfter(end)) sy -= 1; // "28 Dec to 3 Jan 2027"
  return _window(_valid(sy, sm, d1), end);
}

/// The exam date or window a notice prints first. Without a year, the year nearest
/// [reference] (default: today). Where a single date and a window overlap ("Tier 1
/// October 12–19"), the window wins.
EventWindow? extractEventWindow(String text, {DateTime? reference}) {
  final ref = reference ?? DateTime.now();
  int? n(String? g) => g == null ? null : int.parse(g);
  int? mon(String? g) => g == null ? null : _month(g);
  final found = <(int, int, bool, EventWindow)>[];
  void add(RegExpMatch m, EventWindow? w, {required bool range}) {
    if (w != null) found.add((m.start, m.end, range, w));
  }

  for (final m in _numRange.allMatches(text)) {
    final start = _valid(n(m[3])!, n(m[2])!, n(m[1])!);
    add(m, _window(start, _valid(n(m[6])!, n(m[5])!, n(m[4])!)), range: true);
  }
  for (final m in _dayRange.allMatches(text)) {
    add(m, _range(n(m[1])!, mon(m[2]), n(m[3]), n(m[4])!, mon(m[5])!, n(m[6]), ref), range: true);
  }
  for (final m in _monthRange.allMatches(text)) {
    add(m, _range(n(m[2])!, null, null, n(m[3])!, mon(m[1])!, n(m[4]), ref), range: true);
  }
  for (final m in _monthDayRange.allMatches(text)) {
    add(m, _range(n(m[2])!, mon(m[1]), n(m[3]), n(m[5])!, mon(m[4])!, n(m[6]), ref), range: true);
  }
  for (final m in _numDate.allMatches(text)) {
    add(m, _window(_valid(n(m[3])!, n(m[2])!, n(m[1])!), null), range: false);
  }
  for (final m in _dayMonth.allMatches(text)) {
    final mo = mon(m[2])!, d = n(m[1])!;
    add(m, _window(_valid(n(m[3]) ?? _yearNear(mo, d, ref), mo, d), null), range: false);
  }
  for (final m in _monthDay.allMatches(text)) {
    final mo = mon(m[1])!, d = n(m[2])!;
    add(m, _window(_valid(n(m[3]) ?? _yearNear(mo, d, ref), mo, d), null), range: false);
  }
  if (found.isEmpty) return null;
  found.sort((a, b) => a.$1 != b.$1 ? a.$1.compareTo(b.$1) : b.$2.compareTo(a.$2));
  final first = found.first;
  for (final f in found) {
    if (f.$3 && f.$1 < first.$2 && f.$2 > first.$1) return f.$4; // a window overlapping it
  }
  return first.$4;
}

/// First date printed in the notice ("Exam on 14.12.2026" -> 14 Dec 2026), day first.
/// For a window, its first day.
DateTime? extractEventDate(String text, {DateTime? reference}) =>
    extractEventWindow(text, reference: reference)?.start;

final _yearRe = RegExp(r'\b(20\d\d)\b');

/// Exam years named in the text; full dates (a notice's posting date) don't count.
Set<String> _years(String text) =>
    {for (final m in _yearRe.allMatches(text.replaceAll(_dateRe, ' '))) m.group(1)!};

// --- Alert ↔ exam matching (alert_matching.py) -------------------------------------

const _stopwords = {
  'the',
  'of',
  'and',
  'for',
  'in',
  'to',
  'a',
  'an',
  '&',
  'admit',
  'card',
  'cards',
  'call',
  'letter',
  'hall',
  'ticket',
  'exam',
  'examination',
  'recruitment',
  'online',
  'form',
  'notification',
  'post',
  'posts',
  'various',
  'out',
  'released',
  'download',
  'phase',
  'tier',
  'stage',
  'limited',
  'ltd',
  'india',
  'indian',
  'government',
  'govt',
  'advt',
  'no',
};
const _weak = {
  // Post words many recruitments share ("Group B Office Assistant", "Group-C
  // Technical Assistant").
  'group',
  'assistant',
  'assistants',
  'office',
  'officer',
  'officers',
  'clerk',
  'manager',
  'technical',
  'grade',
  'staff',
  'scale',
  'post',
  'combined',
  'level',
  'graduate',
  'graduates',
  'higher',
  'secondary',
  'senior',
  'junior',
  'general',
  'common',
  'entrance',
  'test',
  'selection',
};
final _yearToken = RegExp(r'^(19|20)\d\d$');

/// A round's numeral ("XV", "XVI"): says which round, not which exam.
final _romanToken = RegExp(r'^(?=[ivxl]{2,}$)l?x{0,3}(ix|iv|v?i{0,3})$');

/// IBPS's and RRB's words for "a round of": in every notice of theirs.
const _roundWords = {'crp', 'cen'};

Set<String> _tokens(String text) => {
      for (final m in RegExp('[a-z0-9]+').allMatches(text.toLowerCase()))
        if (m.group(0)!.length > 1 &&
            !_stopwords.contains(m.group(0)) &&
            !_roundWords.contains(m.group(0)) &&
            !_yearToken.hasMatch(m.group(0)!) &&
            !_romanToken.hasMatch(m.group(0)!))
          m.group(0)!,
    };

/// Both 'rrb' (all words) and 'rb' (without stopwords) for 'Railway Recruitment Board'.
Set<String> _acronyms(String name) {
  final words = [for (final m in RegExp('[A-Za-z]+').allMatches(name)) m.group(0)!];
  final full = words.map((w) => w[0]).join().toLowerCase();
  final short =
      words.where((w) => !_stopwords.contains(w.toLowerCase())).map((w) => w[0]).join().toLowerCase();
  return {
    for (final a in [full, short])
      if (a.length > 1) a
  };
}

/// True when the notice names this exam, not just the same organisation.
bool alertMatchesExam(String alertTitle, String examName, String? organization) {
  final alert = _tokens(alertTitle);
  final org = _tokens(organization ?? '').union(_acronyms(organization ?? ''));
  final examWords = _tokens(examName).difference(org);
  final strong = examWords.difference(_weak).union(_acronyms(examName).difference(org));
  final shared = alert.intersection(examWords.union(strong).union(org));
  if (shared.length < 2) return false;
  if (examWords.difference(_weak).isNotEmpty) return alert.intersection(strong).isNotEmpty;
  return alert.containsAll(examWords) || alert.intersection(strong).isNotEmpty;
}

/// About this exam, and not about another year's edition of it.
bool namesThisExam(String text, String examName, String? organization) {
  final examYears = _years(examName);
  final textYears = _years(text);
  if (examYears.isNotEmpty && textYears.isNotEmpty && examYears.intersection(textYears).isEmpty) return false;
  return _namesExam(text, examName, organization);
}

/// The notice names this exam (any year).
/// On the board's own page ([boardsPage]) the board goes without saying: IBPS's
/// "Result of CRP-SPL-XVI" is IBPS SO, SBI's "Recruitment of Junior Associates" is
/// SBI Clerk.
bool _namesExam(String text, String examName, String? organization, {bool boardsPage = false}) {
  // "SSC Combined Graduate Level Tier 1 Admit Card" is "SSC CGL": the exam list knows
  // both names (and needs the board named too, so look-alikes don't match). When it
  // knows yours, a notice naming another exam of the list is not yours ("NTPC
  // Graduate" for NTPC Undergraduate, "IBPS Clerk" for IBPS RRB Clerk), and one it
  // can't place must at least name your board.
  final mine = matchCatalogExam('$examName ${organization ?? ''}');
  if (mine != null) {
    final board = boardsPage ? ' ${mine.name.split(' ').first} ${mine.board}' : '';
    final theirs = matchCatalogExam('$text$board');
    if (theirs != null) return theirs.id == mine.id;
    if (!boardsPage && !_namesBoard(text, mine, organization)) return false;
  }
  return alertMatchesExam(text, examName, organization);
}

/// "IBPS", "Railway Recruitment Board", "RRB": the notice names the exam's board.
bool _namesBoard(String text, CatalogExam exam, String? organization) {
  final words = _tokens(text).union({for (final m in RegExp('[a-z0-9]+').allMatches(text.toLowerCase())) m[0]!});
  final code = exam.name.split(' ').first.toLowerCase();
  if (words.contains(code)) return true;
  for (final name in [exam.board, if (organization != null) organization]) {
    if (_acronyms(name).any(words.contains)) return true;
    final named = _tokens(name);
    if (named.isNotEmpty && words.containsAll(named)) return true;
  }
  return false;
}

const _romanStage = {'i': '1', 'ii': '2', 'iii': '3', 'iv': '4', 'v': '5'};

/// "tier-1", "cbt-2", "prelims", "mains", "interview", or null when none is named.
String? stageKey(String text) {
  final t = text.toLowerCase();
  final m = RegExp(r'\b(tier|phase|paper|cbt|stage)[\s-]*(iv|v|i{1,3}|\d)\b').firstMatch(t);
  if (m != null) return '${m.group(1)}-${_romanStage[m.group(2)] ?? m.group(2)}';
  if (RegExp(r'\b(?:prelim\w*|preliminary|pre)\b').hasMatch(t)) return 'prelims';
  if (RegExp(r'\bmains?\b').hasMatch(t)) return 'mains';
  if (RegExp(r'\b(?:interview|personality test)\b').hasMatch(t)) return 'interview';
  // RRB's typing / aptitude tests (CBTST, CBAT), SSC's skill tests (DEST, CPT).
  if (RegExp(r'\b(?:cbtst|cbat|typing|skill test|dest|cpt|aptitude test)\b').hasMatch(t)) return 'skill';
  if (RegExp(r'\b(?:document verification|dv)\b').hasMatch(t)) return 'dv';
  if (RegExp(r'^\s*medical\s*$|\bmedical (?:exam\w*|test)\b').hasMatch(t)) return 'medical';
  if (RegExp(r'\b(?:pet|pst|pe&mt|pet / pst|pet / pmt|physical (?:efficiency|standard|test))\b').hasMatch(t)) {
    return 'physical';
  }
  return null;
}

/// A notice about another stage than the one tracked ("Tier 1 Admit Card" for an
/// exam tracked at Tier-2). One naming no stage is about the whole exam.
bool namesAnotherStage(String text, String? trackedStage) {
  if (trackedStage == null) return false;
  final mine = stageKey(trackedStage);
  final theirs = stageKey(text);
  return mine != null && theirs != null && mine != theirs;
}

// --- Which round of the exam -----------------------------------------------------

/// "CEN 05/2024", "Advt No. 7/2026": the year of the recruitment a notice is about
/// (not a date: those have three parts).
final _cycleYearRe = RegExp(r'(?<![\d./-])\d{1,3}\s*/\s*((?:19|20)\d{2})\b');

Set<String> _cycleYears(String text) => {for (final m in _cycleYearRe.allMatches(text)) m.group(1)!};

/// "xv" of "IBPS CRP RRB XV" (not the "II" of "Scale II" or "CBT-II").
Set<String> roundNumerals(String text) => {
      for (final r in splitQuery(text).round)
        if (!_yearToken.hasMatch(r)) r,
    };

/// "Advertisement No: ...", "Advt. No. ...", "CEN 06/2025".
final _namesAnAdvert =
    RegExp(r'\b(?:advertisement|advt)\.?\s*(?:no|number)\b|\bcen\s*(?:no\.?\s*)?\d', caseSensitive: false);

/// Milestones that only come after the form closes.
const _afterForm = {Milestone.admitCard, Milestone.answerKey, Milestone.result};

/// What tells this round of an exam from earlier and later ones: its year and when
/// its form was open. A notice from another round (last year's result, a job site's
/// list of other exams) never moves the exam along.
@immutable
class ExamRound {
  const ExamRound({
    this.years = const {},
    this.formOpens,
    this.formCloses,
    this.knownDates = const [],
    this.advert,
    this.numerals = const {},
  });

  /// From the exam's name ("SSC CGL 2026"), else the year its form opened.
  factory ExamRound.of(TrackedApplication app) {
    final raw = app.timelineRaw ?? const <String, dynamic>{};
    DateTime? at(String key) => raw[key] is String ? DateTime.tryParse(raw[key] as String) : null;
    final opens = at('application_start');
    final closes = at('application_end') ?? (app.jobPostId != null ? app.deadline : null);
    final named = _years(app.examName);
    return ExamRound(
      years: named.isNotEmpty ? named : {if (opens != null) '${opens.year}'},
      formOpens: opens,
      formCloses: closes,
      knownDates: [
        for (final d in [app.timeline?.examStart, app.timeline?.examEnd, app.examAt]) if (d != null) d,
      ],
      advert: advertKey(raw['advertisement_no'] as String?),
      numerals: roundNumerals(app.examName),
    );
  }

  /// The round's year(s). Empty: the exam's name gives none (no year check).
  final Set<String> years;
  final DateTime? formOpens;
  final DateTime? formCloses;

  /// Its exam dates, once known: their years count too.
  final List<DateTime> knownDates;

  /// IBPS-style round numerals in its name ("XV" of "IBPS CRP RRB XV"): a notice
  /// naming other ones ("XVI") is another round.
  final Set<String> numerals;

  /// Its advertisement number ([advertKey] form), saved when you applied from the
  /// Jobs list: a notice naming another one ("CEN 06/2025", SBI's other "Specialist
  /// Cadre Officers" adverts) is another recruitment.
  final String? advert;

  /// Years a notice of this round may name: its own, the next one (a 2026
  /// recruitment's exam and result are often in 2027) and those of its dates.
  Set<String> get _allowed => {
        ...years,
        for (final y in years) '${int.parse(y) + 1}',
        for (final d in [formOpens, formCloses, ...knownDates]) if (d != null) '${d.year}',
      };

  /// [text] can be about this round: no other year or recruitment named, nothing
  /// after the form announced while the form was still open, no date from long
  /// before it opened. [at]: when it was posted, else when it was first seen.
  bool admits(String text, Milestone? milestone, DateTime at) {
    final advert = this.advert;
    if (advert != null && !'-${advertKey(text) ?? ''}-'.contains('-$advert-') && _namesAnAdvert.hasMatch(text)) {
      return false;
    }
    if (numerals.isNotEmpty) {
      final theirs = roundNumerals(text);
      if (theirs.isNotEmpty && theirs.intersection(numerals).isEmpty) return false;
    }
    if (years.isNotEmpty) {
      final cycle = _cycleYears(text);
      if (cycle.isNotEmpty && cycle.intersection(years).isEmpty) return false; // "CEN 05/2024"
      final named = _years(text);
      if (named.isNotEmpty && named.intersection(_allowed).isEmpty) return false; // "Result 2025"
    }
    final closes = formCloses;
    if (closes != null && _afterForm.contains(milestone) && at.isBefore(closes)) return false;
    final opens = formOpens;
    if (opens != null) {
      final w = extractEventWindow(text, reference: at);
      if (w != null && (w.end ?? w.start).isBefore(opens.subtract(const Duration(days: 120)))) return false;
    }
    return true;
  }
}

/// A recruitment's own page (".../cen-03-2026/") rather than a whole notice board:
/// notices there may just say "Download Admit Card". Never a job site's article:
/// its sidebars list other exams' admit cards and results.
bool isExamSpecificPage(String url) {
  if (isJobSite(url)) return false;
  // A number in the path ("cen-03-2026"): a section like /web/careers is a board.
  return RegExp(r'\d').hasMatch(Uri.tryParse(url)?.path ?? '');
}

// --- Links ---------------------------------------------------------------------------

/// A link on a page (or in notices.json) with the text around it.
/// What Mistral read a notice as (notices.json `about`): which exam of the app's
/// list, which round, which stage. Null fields: not printed, or not one of the list.
@immutable
class NoticeAbout {
  const NoticeAbout({this.exam, this.advert, this.year, this.numeral, this.stage});

  /// An exam list id ("rrb-ntpc-ug"), or null: none of the list.
  final String? exam;
  final String? advert;
  final String? year;
  final String? numeral;

  /// A [stageKey] key ("cbt-1", "skill", "mains").
  final String? stage;

  static NoticeAbout? fromJson(Object? j) {
    if (j is! Map) return null;
    String? s(String k) => j[k] is String && (j[k] as String).isNotEmpty ? j[k] as String : null;
    return NoticeAbout(exam: s('exam'), advert: s('advert'), year: s('year'), numeral: s('numeral'), stage: s('stage'));
  }

  /// The round it names, as text the round checks read ("CEN 06/2025 2026 XV").
  String get roundText => [advert, year, numeral].whereType<String>().join(' ');
}

@immutable
class PageLink {
  const PageLink({
    required this.url,
    required this.title,
    this.context = '',
    this.heading = '',
    this.link,
    this.publishedAt,
    this.about,
  });

  final String url;
  final String title;
  final String context;

  /// The title of the section the link is in (SBI's "Recruitment of Junior
  /// Associates ... Advertisement No: ..."): says which exam, not what's out.
  final String heading;

  /// notices.json: the official link the pipeline found on the notice's page.
  final String? link;

  /// notices.json: when the job site posted it.
  final DateTime? publishedAt;

  /// notices.json: Mistral's reading of it.
  final NoticeAbout? about;
}

final _tracking = RegExp(r'^(utm_|fbclid|gclid|ref$|amp$)');

/// Drop fragments and tracking parameters so one notice is never "new" twice.
String canonicalUrl(String url) {
  final u = Uri.tryParse(url.trim());
  if (u == null || !u.hasScheme) return url.trim();
  final query =
      u.query.split('&').where((kv) => kv.isNotEmpty && !_tracking.hasMatch(kv.split('=').first)).join('&');
  return Uri(
    scheme: u.scheme.toLowerCase(),
    host: u.host.toLowerCase(),
    port: u.hasPort ? u.port : null,
    path: u.path.isEmpty ? '/' : u.path,
    query: query.isEmpty ? null : query,
  ).toString();
}

enum UpdateSource { official, aggregator }

@immutable
class DetectedUpdate {
  const DetectedUpdate({
    required this.milestone,
    required this.title,
    required this.url,
    required this.source,
    this.eventDate,
    this.eventEnd,
    this.link,
    this.publishedAt,
    this.examId,
  });

  final Milestone milestone;
  final String title;
  final String url;
  final UpdateSource source;
  final DateTime? eventDate;
  final DateTime? publishedAt;

  /// The exam list id Mistral gave the notice, if any.
  final String? examId;

  /// The official link for it (admit card download, answer key, result), if known.
  final String? link;

  String get open => link ?? url;

  /// Last day, when the notice gives a window ("12–19 October").
  final DateTime? eventEnd;
}

/// New milestone notices for one exam among a page's links. [round] (default: the
/// year in [examName]) keeps out notices of other years and recruitments.
List<DetectedUpdate> detectUpdates(
  Iterable<PageLink> links, {
  required String examName,
  required String? organization,
  required UpdateSource source,
  required bool examSpecificPage,
  required Set<String> knownUrls,
  DateTime? now,
  String? stage,
  ExamRound? round,
  bool boardsOwnPage = false,
}) {
  final found = <DetectedUpdate>[];
  final seen = {...knownUrls};
  final at = now ?? DateTime.now();
  final thisRound = round ?? ExamRound(years: _years(examName), numerals: roundNumerals(examName));
  final mine = matchCatalogExam('$examName ${organization ?? ''}');
  for (final link in links) {
    final url = canonicalUrl(link.url);
    if (seen.contains(url)) continue;
    final text = '${link.title} ${link.context}'.trim();
    final milestone = classifyMilestone(text);
    if (milestone == null) continue;
    // What's out comes from the link and its row; which exam, from its section only
    // when the link itself names none ("Download call letter").
    final label = link.about;
    final about = [
      if (_bareLink(text)) '$text ${link.heading}'.trim() else text,
      if (label != null) label.roundText,
    ].join(' ').trim();
    if (!thisRound.admits(about, milestone, link.publishedAt ?? at)) continue;
    if (namesAnotherStage(text, stage)) continue; // a Tier 1 notice for an exam tracked at Tier-2
    if (label != null && _labelSaysOtherStage(label, stage)) continue;
    // Mistral's reading decides which exam when it names one of the list.
    final labelled = label?.exam != null && mine != null;
    if (labelled && label!.exam != mine.id) continue;
    // A job site's page is always about many exams: it has to name this one.
    final jobSite = isJobSite(url);
    if (!labelled &&
        (!examSpecificPage || jobSite) &&
        !_namesExam(about, examName, organization, boardsPage: boardsOwnPage && !jobSite)) {
      continue;
    }
    seen.add(url);
    final title = link.title.isEmpty ? text : link.title;
    final window = extractEventWindow(text, reference: now);
    found.add(DetectedUpdate(
      milestone: milestone,
      title: title.length > 300 ? title.substring(0, 300) : title,
      url: url,
      source: source,
      eventDate: window?.start,
      eventEnd: window?.end,
      link: link.link,
      publishedAt: link.publishedAt,
      examId: label?.exam,
    ));
  }
  return found;
}

bool _labelSaysOtherStage(NoticeAbout label, String? trackedStage) {
  final theirs = label.stage;
  final mine = trackedStage == null ? null : stageKey(trackedStage);
  return theirs != null && mine != null && theirs != mine;
}

const _bareWords = {
  'download', 'click', 'here', 'link', 'view', 'print', 'reprint', 'check', 'see', 'call', 'letter', 'letters', //
  'admit', 'card', 'cards', 'hall', 'ticket', 'result', 'results', 'answer', 'key', 'keys', 'objection',
  'examination', 'exam', 'exams', 'online', 'written', 'test', 'preliminary', 'prelims', 'pre', 'main', 'mains',
  'phase', 'final', 'select', 'selected', 'selection', 'list', 'wait', 'provisional', 'provisionally',
  'shortlisted', 'candidates', 'candidate', 'marks', 'secured', 'score', 'scores', 'scorecard', 'cut', 'off',
  'offs', 'cutoff', 'cutoffs', 'roll', 'nos', 'numbers', 'interview', 'schedule', 'notice', 'information',
  'handout', 'status', 'new', 'pdf', 'english', 'hindi', 'the', 'of', 'for', 'in', 'by', 'and', 'to', 'from', 'kb',
  'mb', 'date', 'dates', 'city', 'intimation', 'slip', 'psychometric', 'group', 'exercise', 'document',
  'verification', 'application', 'form', 'tier', 'stage', 'round', 'available', 'released', 'out', 'is', 'are',
};

/// A link that says only what is out ("DOWNLOAD PRELIMINARY EXAMINATION CALL
/// LETTER"), not which exam: its section's heading says that.
bool _bareLink(String text) => RegExp('[a-z]{3,}')
    .allMatches(text.toLowerCase())
    .every((m) => _bareWords.contains(m[0]) || _romanToken.hasMatch(m[0]!));

/// Not about this exam's round after all: found by an older, looser watcher, or
/// brought back by a backup from such a phone.
bool isStrayUpdate(TrackedApplication app, ExamUpdate u, {ExamRound? round}) {
  final milestone = Milestone.fromWire(u.milestone);
  if (milestone == null) return false;
  final labelled = u.examId;
  final mine = app.catalogExam;
  if (labelled != null && mine != null) {
    if (labelled != mine.id) return true;
  } else if (isJobSite(u.url) && !_namesExam(u.title, app.examName, app.organization)) {
    return true;
  }
  if (namesAnotherStage(u.title, app.tierName)) return true;
  final seen = u.detectedAt ?? app.createdAt;
  return !(round ?? ExamRound.of(app)).admits(u.title, milestone, u.publishedAt ?? seen);
}

DetectedUpdate _replay(ExamUpdate u, Milestone m, DateTime seen) {
  final w = extractEventWindow(u.title, reference: seen);
  return DetectedUpdate(
    milestone: m,
    title: u.title,
    url: u.url,
    source: u.source == UpdateSource.official.name ? UpdateSource.official : UpdateSource.aggregator,
    eventDate: w?.start,
    eventEnd: w?.end,
    link: u.link,
    publishedAt: u.publishedAt,
    examId: u.examId,
  );
}

/// [app]'s watcher findings without its stray notices ([isStrayUpdate]): the
/// status from what is left, and the timeline without what only the strays set.
/// Null when every notice is about this round.
({List<ExamUpdate> updates, TrackerStatus status, Map<String, dynamic> timeline})? withoutStrayUpdates(
    TrackedApplication app) {
  final round = ExamRound.of(app);
  final kept = <ExamUpdate>[], stray = <ExamUpdate>[];
  for (final u in app.updates) {
    (isStrayUpdate(app, u, round: round) ? stray : kept).add(u);
  }
  if (stray.isEmpty) return null;
  var t = <String, dynamic>{...?app.timelineRaw};
  t['job_post_id'] ??= app.jobPostId ?? app.id;
  for (final u in stray) {
    final m = Milestone.fromWire(u.milestone)!;
    final seen = u.detectedAt?.toLocal() ?? app.createdAt;
    final setByIt = fillTimeline(<String, dynamic>{}, _replay(u, m, seen), seen);
    setByIt.forEach((key, value) {
      if (t[key] == value) t.remove(key);
    });
  }
  // What the kept notices say goes back in, oldest first.
  for (final u in kept.reversed) {
    final m = Milestone.fromWire(u.milestone);
    if (m == null) continue;
    final seen = u.detectedAt?.toLocal() ?? app.createdAt;
    t = fillTimeline(t, _replay(u, m, seen), seen);
  }
  return (
    updates: kept,
    status: advanceStatus(TrackerStatus.applied, [
      for (final u in kept)
        if (Milestone.fromWire(u.milestone) case final m?) m,
    ]),
    timeline: t,
  );
}

const _statusFor = {
  Milestone.admitCard: TrackerStatus.admitCardLive,
  Milestone.examSchedule: TrackerStatus.examScheduled,
  Milestone.answerKey: TrackerStatus.answerKeyLive,
  Milestone.result: TrackerStatus.resultDeclared,
};

/// Highest status the milestones imply; never moves backwards.
TrackerStatus advanceStatus(TrackerStatus current, Iterable<Milestone> milestones) {
  var best = current;
  for (final m in milestones) {
    final target = _statusFor[m];
    if (target != null && target.index > best.index) best = target;
  }
  return best;
}

String _isoDate(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// Fills the exam's 5-stage timeline (the `timeline` JSON from jobs.json) from a new
/// notice. Newest link wins; a milestone's date is set on first sighting only.
Map<String, dynamic> fillTimeline(Map<String, dynamic> timeline, DetectedUpdate u, DateTime seenOn) {
  final t = {...timeline};
  final text = u.title.toLowerCase();
  final today = _isoDate(seenOn);
  void firstDate(String key) => t[key] ??= today;
  // Dates up to 60 days back still count: a notice first seen mid-window or just
  // after the exam is how the app learns the exam already happened.
  final start = u.eventDate;
  final end = u.eventEnd;
  final usable = start != null &&
      !(end ?? start).isBefore(DateTime(seenOn.year, seenOn.month, seenOn.day).subtract(const Duration(days: 60)));
  void setExam() {
    t['exam_start'] = _isoDate(start!);
    if (end != null) {
      t['exam_end'] = _isoDate(end);
    } else {
      t.remove('exam_end');
    }
  }

  switch (u.milestone) {
    case Milestone.admitCard:
      t['admit_card_url'] = u.open;
      firstDate('admit_card_release');
      // "Admit Card (Exam on 14.12.2026)": the printed date is the exam date, if none is known yet.
      if (usable && t['exam_start'] == null) setExam();
    case Milestone.examSchedule || Milestone.postponed:
      if (text.contains('city') || text.contains('intimation')) t['exam_city_slip_url'] = u.open;
      if (usable) setExam(); // a newer schedule/postponement notice wins
    case Milestone.answerKey:
      if (text.contains('objection') || text.contains('challenge')) {
        t['challenge_portal_url'] = u.open;
      } else if (text.contains('question paper')) {
        t['question_paper_url'] = u.open;
      } else {
        t['answer_key_url'] = u.open;
        firstDate('answer_key_release');
      }
    case Milestone.result:
      t[text.contains('score') ? 'scorecard_url' : 'merit_list_url'] = u.open;
      firstDate('result_date');
    case Milestone.correction:
      t['correction_url'] = u.open;
      if (start != null) {
        t['edit_window_start'] = _isoDate(start);
        t['edit_window_end'] = _isoDate(end ?? start);
      }
  }
  return t;
}

/// Reads the dates of the stored schedule and admit-card notices again (oldest
/// first, each as of when it was seen), so exams tracked before the date reader
/// understood windows ("12–19 October") get their real start and end. Also undoes
/// that older reader's slip of storing a window's last day as the exam date.
Map<String, dynamic> refreshExamDates(Map<String, dynamic> timeline, List<ExamUpdate> updates, DateTime now) {
  var t = {...timeline};
  for (final u in updates.reversed) {
    final m = Milestone.fromWire(u.milestone);
    if (m == null || m == Milestone.answerKey || m == Milestone.result || m == Milestone.correction) continue;
    final seen = u.detectedAt?.toLocal() ?? now;
    final w = extractEventWindow(u.title, reference: seen);
    if (w == null) continue;
    final end = w.end;
    if (m == Milestone.admitCard && end != null && t['exam_start'] == _isoDate(end) && t['exam_end'] == null) {
      t.remove('exam_start'); // the old reader's "19 October" for "12–19 October"
    }
    t = fillTimeline(
      t,
      DetectedUpdate(
          milestone: m,
          title: u.title,
          url: u.url,
          source: UpdateSource.aggregator,
          eventDate: w.start,
          eventEnd: end,
          link: u.link),
      seen,
    );
  }
  return t;
}

/// Notification text per milestone (matches the backend's push texts).
(String, String) notificationText(Milestone m, String examName, String noticeTitle) {
  final (title, body) = switch (m) {
    Milestone.admitCard => (
        '🎫 Admit card out: $examName',
        'Download it now — portals often close it before the exam.'
      ),
    Milestone.examSchedule => ('📅 Exam date update: $examName', noticeTitle),
    Milestone.postponed => ('⚠️ Exam rescheduled: $examName', noticeTitle),
    Milestone.correction => ('✏️ Form correction open: $examName', noticeTitle),
    Milestone.answerKey => (
        '📝 Answer key released: $examName',
        'Check your answers; objections have a deadline.'
      ),
    Milestone.result => ('🏁 Result declared: $examName', noticeTitle),
  };
  return (
    title.length > 120 ? title.substring(0, 120) : title,
    body.length > 240 ? body.substring(0, 240) : body
  );
}
