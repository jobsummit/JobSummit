import 'package:flutter/foundation.dart';

/// A common recruitment exam: who runs it, its two links and its stages. Built
/// into the app (no server), so suggestions are instant and work offline.
@immutable
class CatalogExam {
  const CatalogExam(
    this.id,
    this.name,
    this.board, {
    required this.officialUrl,
    this.loginUrl,
    required this.stages,
    this.aliases = const [],
    this.watchUrls = const [],
  });

  final String id;
  final String name; // short, as people say it: "SSC CGL"
  final String board; // "Staff Selection Commission"

  /// The board's website and notice board (the exam watcher reads it).
  final String officialUrl;

  /// Candidate login: application form, admit card, result.
  final String? loginUrl;

  /// Tiers in order, e.g. Tier-1, Tier-2. One entry = a single-stage exam.
  final List<String> stages;

  /// Other names job sites use ("Combined Graduate Level"), for matching.
  final List<String> aliases;

  /// Where the board posts call letters and results when its home page doesn't
  /// (IBPS's CRP updates, SBI's current openings): read by the exam watcher too.
  final List<String> watchUrls;

  String get link => loginUrl ?? officialUrl;
}

// Boards that run many exams.
const _ssc = 'Staff Selection Commission';
const _sscWeb = 'https://ssc.gov.in';
const _sscLogin = 'https://ssc.gov.in/login';
const _upsc = 'Union Public Service Commission';
const _upscWeb = 'https://www.upsc.gov.in';
const _ibps = 'Institute of Banking Personnel Selection';
const _ibpsWeb = 'https://www.ibps.in';
const _ibpsWatch = ['https://www.ibps.in/index.php/crp-updates/'];
const _sbi = 'State Bank of India';
const _sbiWeb = 'https://sbi.bank.in/web/careers';
const _sbiWatch = ['https://sbi.bank.in/web/careers/current-openings'];
const _rrb = 'Railway Recruitment Boards';
const _rrbWeb = 'https://www.rrbcdg.gov.in';
const _rrbLogin = 'https://www.rrbapply.gov.in/#/auth/landing';
const _rbi = 'Reserve Bank of India';
const _rbiWeb = 'https://opportunities.rbi.org.in';
const _rbiWatch = [
  'https://opportunities.rbi.org.in/Scripts/CallLetters.aspx',
  'https://opportunities.rbi.org.in/Scripts/resultsnew.aspx',
];
const _nabardWatch = ['https://www.nabard.org/careers-notices1.aspx?cid=693&id=26'];

const _pcs = ['Prelims', 'Mains', 'Interview'];

const List<CatalogExam> examCatalog = [
  // ---- SSC
  CatalogExam('ssc-cgl', 'SSC CGL', _ssc,
      officialUrl: _sscWeb, loginUrl: _sscLogin, stages: ['Tier-1', 'Tier-2'],
      aliases: ['combined graduate level']),
  CatalogExam('ssc-chsl', 'SSC CHSL', _ssc,
      officialUrl: _sscWeb, loginUrl: _sscLogin, stages: ['Tier-1', 'Tier-2'],
      aliases: ['combined higher secondary']),
  CatalogExam('ssc-mts', 'SSC MTS', _ssc,
      officialUrl: _sscWeb, loginUrl: _sscLogin, stages: ['CBE', 'PET / PST'],
      aliases: ['multi tasking', 'multi-tasking', 'havaldar']),
  CatalogExam('ssc-je', 'SSC JE', _ssc,
      officialUrl: _sscWeb, loginUrl: _sscLogin, stages: ['Paper-1', 'Paper-2'],
      aliases: ['junior engineer ssc', 'ssc junior engineer']),
  CatalogExam('ssc-cpo', 'SSC CPO', _ssc,
      officialUrl: _sscWeb, loginUrl: _sscLogin, stages: ['Paper-1', 'PET / PST', 'Paper-2', 'Medical'],
      aliases: ['sub-inspector in delhi police', 'sub inspector in delhi police', 'central police organisation']),
  CatalogExam('ssc-gd', 'SSC GD Constable', _ssc,
      officialUrl: _sscWeb, loginUrl: _sscLogin, stages: ['CBE', 'PET / PST', 'Medical'],
      aliases: ['ssc gd', 'constable (gd)', 'constable gd']),
  CatalogExam('ssc-steno', 'SSC Stenographer', _ssc,
      officialUrl: _sscWeb, loginUrl: _sscLogin, stages: ['CBE', 'Skill test'],
      aliases: ['stenographer grade c', 'stenographer grade d']),
  CatalogExam('ssc-jht', 'SSC JHT', _ssc,
      officialUrl: _sscWeb, loginUrl: _sscLogin, stages: ['Paper-1', 'Paper-2'],
      aliases: ['junior hindi translator']),
  CatalogExam('ssc-selection-post', 'SSC Selection Post', _ssc,
      officialUrl: _sscWeb, loginUrl: _sscLogin, stages: ['CBE'], aliases: ['selection post phase']),
  CatalogExam('delhi-police-constable', 'Delhi Police Constable', _ssc,
      officialUrl: _sscWeb, loginUrl: _sscLogin, stages: ['CBE', 'PE&MT', 'Medical'],
      aliases: ['constable (executive)', 'delhi police constable']),

  // ---- UPSC
  CatalogExam('upsc-cse', 'UPSC Civil Services (IAS)', _upsc,
      officialUrl: _upscWeb, stages: _pcs,
      aliases: ['civil services examination', 'ias', 'upsc cse']),
  CatalogExam('upsc-ese', 'UPSC Engineering Services (ESE)', _upsc,
      officialUrl: _upscWeb, stages: ['Prelims', 'Mains', 'Personality test'],
      aliases: ['engineering services examination', 'upsc ies', 'upsc ese']),
  CatalogExam('upsc-cds', 'UPSC CDS', _upsc,
      officialUrl: _upscWeb, stages: ['Written exam', 'SSB interview'],
      aliases: ['combined defence services']),
  CatalogExam('upsc-nda', 'UPSC NDA', _upsc,
      officialUrl: _upscWeb, stages: ['Written exam', 'SSB interview'],
      aliases: ['national defence academy']),
  CatalogExam('upsc-capf', 'UPSC CAPF (AC)', _upsc,
      officialUrl: _upscWeb, stages: ['Written exam', 'PET / Medical', 'Interview'],
      aliases: ['central armed police forces', 'assistant commandant']),
  CatalogExam('upsc-cms', 'UPSC Combined Medical Services', _upsc,
      officialUrl: _upscWeb, stages: ['CBT', 'Personality test'],
      aliases: ['combined medical services', 'upsc cms']),
  CatalogExam('upsc-epfo', 'UPSC EPFO', _upsc,
      officialUrl: _upscWeb, stages: ['Recruitment test', 'Interview'],
      aliases: ['enforcement officer', 'accounts officer epfo', 'apfc']),
  CatalogExam('upsc-geo', 'UPSC Geo-Scientist', _upsc,
      officialUrl: _upscWeb, stages: _pcs, aliases: ['combined geo-scientist', 'geo scientist']),
  CatalogExam('upsc-ies-iss', 'UPSC IES / ISS', _upsc,
      officialUrl: _upscWeb, stages: ['Written exam', 'Interview'],
      aliases: ['indian economic service', 'indian statistical service']),

  // ---- Banking & insurance
  // IBPS's own pages name the round's code, not the exam: "CRP-PO/MTs-XVI",
  // "CRP-SPL-XVI", "CRP CSA-XVI", "CRP RRBs-XV".
  CatalogExam('ibps-po', 'IBPS PO', _ibps,
      officialUrl: _ibpsWeb, watchUrls: _ibpsWatch, stages: _pcs,
      aliases: ['probationary officer', 'crp po', 'po/mt', 'crp po/mt', 'crp po/mts']),
  CatalogExam('ibps-clerk', 'IBPS Clerk', _ibps,
      officialUrl: _ibpsWeb, watchUrls: _ibpsWatch, stages: ['Prelims', 'Mains', 'Language test'],
      aliases: ['crp clerk', 'crp clerks', 'crp csa', 'customer service associate', 'customer service associates']),
  CatalogExam('ibps-so', 'IBPS SO', _ibps,
      officialUrl: _ibpsWeb, watchUrls: _ibpsWatch, stages: _pcs,
      aliases: ['specialist officer', 'specialist officers', 'crp spl', 'crp so']),
  CatalogExam('ibps-rrb-po', 'IBPS RRB PO', _ibps,
      officialUrl: _ibpsWeb, watchUrls: _ibpsWatch, stages: _pcs,
      aliases: ['officer scale-i', 'officer scale i', 'rrb po', 'rrb officer']),
  CatalogExam('ibps-rrb-clerk', 'IBPS RRB Clerk', _ibps,
      officialUrl: _ibpsWeb, watchUrls: _ibpsWatch, stages: ['Prelims', 'Mains'],
      aliases: ['office assistant', 'office assistants', 'rrb clerk', 'rrb office assistant', 'oa multipurpose']),
  CatalogExam('ibps-rrb-scale-2', 'IBPS RRB Officer Scale II', _ibps,
      officialUrl: _ibpsWeb, watchUrls: _ibpsWatch, stages: ['Single exam', 'Interview'],
      aliases: ['officer scale-ii', 'officer scale ii', 'rrb scale 2', 'rrb so', 'generalist officer']),
  CatalogExam('ibps-rrb-scale-3', 'IBPS RRB Officer Scale III', _ibps,
      officialUrl: _ibpsWeb, watchUrls: _ibpsWatch, stages: ['Single exam', 'Interview'],
      aliases: ['officer scale-iii', 'officer scale iii', 'rrb scale 3']),
  // SBI's page names the post ("Recruitment of Junior Associates"); its call
  // letters are on IBPS's portal.
  CatalogExam('sbi-po', 'SBI PO', _sbi,
      officialUrl: _sbiWeb, watchUrls: _sbiWatch,
      stages: ['Prelims', 'Mains', 'Psychometric test & interview'],
      aliases: ['sbi probationary officer', 'probationary officers']),
  CatalogExam('sbi-clerk', 'SBI Clerk', _sbi,
      officialUrl: _sbiWeb, watchUrls: _sbiWatch, stages: ['Prelims', 'Mains', 'Language test'],
      aliases: ['junior associate', 'junior associates', 'sbi ja']),
  CatalogExam('sbi-so', 'SBI SO', _sbi,
      officialUrl: _sbiWeb, watchUrls: _sbiWatch, stages: ['Online test', 'Interview'],
      aliases: ['sbi specialist', 'specialist cadre officers']),
  CatalogExam('rbi-grade-b', 'RBI Grade B', _rbi,
      officialUrl: _rbiWeb, watchUrls: _rbiWatch, stages: ['Phase-1', 'Phase-2', 'Interview'],
      aliases: ['officers in grade b']),
  CatalogExam('rbi-assistant', 'RBI Assistant', _rbi,
      officialUrl: _rbiWeb, watchUrls: _rbiWatch, stages: ['Prelims', 'Mains', 'Language test'],
      aliases: ['post of assistant']),
  CatalogExam('nabard-grade-a', 'NABARD Grade A', 'NABARD',
      officialUrl: 'https://www.nabard.org', watchUrls: _nabardWatch, stages: ['Phase-1', 'Phase-2', 'Interview'],
      aliases: ['nabard assistant manager', 'grade a']),
  CatalogExam('nabard-da', 'NABARD Development Assistant', 'NABARD',
      officialUrl: 'https://www.nabard.org', watchUrls: _nabardWatch, stages: ['Prelims', 'Mains', 'Language test'],
      aliases: ['nabard office attendant', 'development assistant']),
  CatalogExam('rbi-office-attendant', 'RBI Office Attendant', _rbi,
      officialUrl: _rbiWeb, watchUrls: _rbiWatch, stages: ['Online test', 'Language test']),
  CatalogExam('lic-ado', 'LIC ADO', 'Life Insurance Corporation of India',
      officialUrl: 'https://licindia.in', stages: _pcs, aliases: ['apprentice development officer']),
  CatalogExam('lic-assistant', 'LIC Assistant', 'Life Insurance Corporation of India',
      officialUrl: 'https://licindia.in', stages: ['Prelims', 'Mains']),
  CatalogExam('niacl-assistant', 'NIACL Assistant', 'New India Assurance',
      officialUrl: 'https://www.newindia.co.in', stages: ['Prelims', 'Mains', 'Language test']),
  CatalogExam('sebi-grade-a', 'SEBI Grade A', 'Securities and Exchange Board of India',
      officialUrl: 'https://www.sebi.gov.in', stages: ['Phase-1', 'Phase-2', 'Interview']),
  CatalogExam('lic-aao', 'LIC AAO', 'Life Insurance Corporation of India',
      officialUrl: 'https://licindia.in', stages: _pcs, aliases: ['assistant administrative officer']),
  CatalogExam('niacl-ao', 'NIACL AO', 'New India Assurance',
      officialUrl: 'https://www.newindia.co.in', stages: _pcs, aliases: ['new india assurance']),

  // ---- Railways
  CatalogExam('rrb-ntpc-graduate', 'RRB NTPC (Graduate)', _rrb,
      officialUrl: _rrbWeb, loginUrl: _rrbLogin,
      stages: ['CBT-1', 'CBT-2', 'Skill test', 'Document verification', 'Medical'],
      aliases: ['ntpc graduate', 'non technical popular categories graduate', 'rrb ntpc']),
  CatalogExam('rrb-ntpc-ug', 'RRB NTPC (Under graduate)', _rrb,
      officialUrl: _rrbWeb, loginUrl: _rrbLogin,
      stages: ['CBT-1', 'CBT-2', 'Skill test', 'Document verification', 'Medical'],
      aliases: ['ntpc under graduate', 'ntpc undergraduate', 'ntpc 12th']),
  CatalogExam('rrb-group-d', 'RRB Group D', _rrb,
      officialUrl: _rrbWeb, loginUrl: _rrbLogin, stages: ['CBT', 'PET', 'Document verification'],
      aliases: ['level-1', 'level 1 posts', 'rrc group d']),
  CatalogExam('rrb-alp', 'RRB ALP', _rrb,
      officialUrl: _rrbWeb, loginUrl: _rrbLogin, stages: ['CBT-1', 'CBT-2', 'CBAT', 'Document verification'],
      aliases: ['assistant loco pilot']),
  CatalogExam('rrb-je', 'RRB JE', _rrb,
      officialUrl: _rrbWeb, loginUrl: _rrbLogin, stages: ['CBT-1', 'CBT-2', 'Document verification'],
      aliases: ['junior engineer rrb', 'rrb junior engineer']),
  CatalogExam('rrb-technician', 'RRB Technician', _rrb,
      officialUrl: _rrbWeb, loginUrl: _rrbLogin, stages: ['CBT', 'Document verification']),
  CatalogExam('rpf-constable', 'RPF Constable / SI', _rrb,
      officialUrl: _rrbWeb, loginUrl: _rrbLogin, stages: ['CBT', 'PET / PMT', 'Document verification'],
      aliases: ['railway protection force']),

  // ---- Defence
  CatalogExam('afcat', 'AFCAT', 'Indian Air Force',
      officialUrl: 'https://afcat.cdac.in', stages: ['Online test', 'AFSB interview', 'Medical'],
      aliases: ['air force common admission test']),
  CatalogExam('agniveer-army', 'Army Agniveer', 'Indian Army',
      officialUrl: 'https://joinindianarmy.nic.in', stages: ['CEE (online)', 'Rally (physical)', 'Medical'],
      aliases: ['agniveer army', 'agnipath army']),
  CatalogExam('agniveer-vayu', 'Agniveervayu', 'Indian Air Force',
      officialUrl: 'https://agnipathvayu.cdac.in', stages: ['Phase-1 (online)', 'Phase-2', 'Medical'],
      aliases: ['agniveer vayu', 'agnipath vayu']),
  CatalogExam('navy-agniveer', 'Navy Agniveer', 'Indian Navy',
      officialUrl: 'https://www.joinindiannavy.gov.in', stages: ['CBT', 'PFT & written', 'Medical'],
      aliases: ['agniveer navy', 'navy ssr', 'navy mr']),

  // ---- Teaching & other central
  CatalogExam('ctet', 'CTET', 'CBSE', officialUrl: 'https://ctet.nic.in', stages: ['Exam'],
      aliases: ['central teacher eligibility']),
  CatalogExam('ugc-net', 'UGC NET', 'National Testing Agency',
      officialUrl: 'https://ugcnet.nta.ac.in', stages: ['Exam']),
  CatalogExam('csir-net', 'CSIR NET', 'National Testing Agency',
      officialUrl: 'https://csirnet.nta.ac.in', stages: ['Exam']),
  CatalogExam('kvs', 'KVS Teacher / Staff', 'Kendriya Vidyalaya Sangathan',
      officialUrl: 'https://kvsangathan.nic.in', stages: ['CBT', 'Interview / skill test'],
      aliases: ['kendriya vidyalaya']),
  CatalogExam('nvs', 'NVS Teacher / Staff', 'Navodaya Vidyalaya Samiti',
      officialUrl: 'https://navodaya.gov.in', stages: ['CBT', 'Interview / skill test'],
      aliases: ['navodaya vidyalaya']),
  CatalogExam('dsssb', 'DSSSB', 'Delhi Subordinate Services Selection Board',
      officialUrl: 'https://dsssb.delhi.gov.in', loginUrl: 'https://dsssbonline.nic.in', stages: ['Tier-1', 'Tier-2'],
      aliases: ['delhi subordinate services']),
  CatalogExam('fci', 'FCI Category II / III', 'Food Corporation of India',
      officialUrl: 'https://fci.gov.in', stages: ['Phase-1', 'Phase-2'], aliases: ['food corporation of india']),
  CatalogExam('esic', 'ESIC', 'Employees’ State Insurance Corporation',
      officialUrl: 'https://www.esic.gov.in', stages: ['Prelims', 'Mains']),
  CatalogExam('india-post-gds', 'India Post GDS', 'India Post',
      officialUrl: 'https://indiapostgdsonline.gov.in', stages: ['Merit list', 'Document verification'],
      aliases: ['gramin dak sevak']),

  // ---- State PSCs and boards
  CatalogExam('uppsc', 'UPPSC PCS', 'Uttar Pradesh PSC',
      officialUrl: 'https://uppsc.up.nic.in', loginUrl: 'https://otr.pariksha.up.nic.in', stages: _pcs,
      aliases: ['uppsc', 'up pcs']),
  CatalogExam('upsssc-pet', 'UPSSSC PET', 'UP Subordinate Services Selection Commission',
      officialUrl: 'https://upsssc.gov.in', stages: ['Exam'], aliases: ['preliminary eligibility test']),
  CatalogExam('bpsc', 'BPSC CCE', 'Bihar PSC',
      officialUrl: 'https://bpsc.bihar.gov.in', loginUrl: 'https://onlinebpsc.bihar.gov.in', stages: _pcs,
      aliases: ['bpsc', 'bihar combined competitive']),
  CatalogExam('rpsc-ras', 'RPSC RAS', 'Rajasthan PSC',
      officialUrl: 'https://rpsc.rajasthan.gov.in', loginUrl: 'https://sso.rajasthan.gov.in', stages: _pcs,
      aliases: ['rpsc', 'ras/rts']),
  CatalogExam('mppsc', 'MPPSC State Service', 'Madhya Pradesh PSC',
      officialUrl: 'https://mppsc.mp.gov.in', stages: _pcs, aliases: ['mppsc']),
  CatalogExam('mpsc', 'MPSC Rajyaseva', 'Maharashtra PSC',
      officialUrl: 'https://mpsc.gov.in', loginUrl: 'https://mpsconline.gov.in', stages: _pcs,
      aliases: ['mpsc', 'rajyaseva']),
  CatalogExam('tnpsc', 'TNPSC Group 1 / 2 / 4', 'Tamil Nadu PSC',
      officialUrl: 'https://www.tnpsc.gov.in', loginUrl: 'https://apply.tnpscexams.in', stages: ['Prelims', 'Mains'],
      aliases: ['tnpsc']),
  CatalogExam('kpsc-kerala', 'Kerala PSC', 'Kerala PSC',
      officialUrl: 'https://www.keralapsc.gov.in', loginUrl: 'https://thulasi.psc.kerala.gov.in',
      stages: ['Exam', 'Interview'], aliases: ['kerala public service']),
  CatalogExam('kpsc', 'KPSC (Karnataka)', 'Karnataka PSC',
      officialUrl: 'https://kpsc.kar.nic.in', stages: _pcs, aliases: ['karnataka public service']),
  CatalogExam('wbpsc', 'WBPSC WBCS', 'West Bengal PSC',
      officialUrl: 'https://psc.wb.gov.in', stages: _pcs, aliases: ['wbcs', 'wbpsc']),
  CatalogExam('appsc', 'APPSC Group 1 / 2', 'Andhra Pradesh PSC',
      officialUrl: 'https://psc.ap.gov.in', stages: _pcs, aliases: ['appsc']),
  CatalogExam('tgpsc', 'TGPSC Group 1 / 2', 'Telangana PSC',
      officialUrl: 'https://websitenew.tgpsc.gov.in', stages: _pcs, aliases: ['tspsc', 'tgpsc']),
  CatalogExam('opsc', 'OPSC OCS', 'Odisha PSC', officialUrl: 'https://www.opsc.gov.in', stages: _pcs,
      aliases: ['opsc', 'odisha civil services']),
  CatalogExam('gpsc', 'GPSC Class 1 / 2', 'Gujarat PSC',
      officialUrl: 'https://gpsc.gujarat.gov.in', loginUrl: 'https://gpsc-ojas.gujarat.gov.in', stages: _pcs,
      aliases: ['gpsc']),
  CatalogExam('hpsc', 'HPSC HCS', 'Haryana PSC', officialUrl: 'https://hpsc.gov.in', stages: _pcs,
      aliases: ['hpsc', 'haryana civil services']),
  CatalogExam('ukpsc', 'UKPSC PCS', 'Uttarakhand PSC', officialUrl: 'https://psc.uk.gov.in', stages: _pcs,
      aliases: ['ukpsc']),
  CatalogExam('cgpsc', 'CGPSC State Service', 'Chhattisgarh PSC',
      officialUrl: 'https://psc.cg.gov.in', stages: _pcs, aliases: ['cgpsc']),
  CatalogExam('jpsc', 'JPSC Civil Services', 'Jharkhand PSC',
      officialUrl: 'https://www.jpsc.gov.in', stages: _pcs, aliases: ['jpsc']),
];

String _norm(String s) => s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9/&]+'), ' ').trim();

final _year = RegExp(r'^(19|20)\d\d$');
final _roman = RegExp(r'^(?=[ivxl]{2,}$)l?x{0,3}(ix|iv|v?i{0,3})$');
final _cycleWords = {'crp', 'cycle', 'cen', 'advt', 'no'};
const _postWords = {'scale', 'grade', 'group', 'tier', 'paper', 'class', 'phase'};

/// Splits what was typed into the words that name the exam and the ones that
/// only say which round it is: a year ("2026") or an IBPS-style cycle numeral
/// ("XV", "CRP-XIV"). A numeral after "Scale", "Grade", "Tier"... names the
/// post ("Officer Scale II"), and single letters ("Scale I") always do.
({List<String> words, List<String> round}) splitQuery(String query) {
  final words = <String>[], round = <String>[];
  var previous = '';
  for (final w in _norm(query).replaceAll('/', ' ').split(' ')) {
    if (w.isEmpty) continue;
    final namesPost = _postWords.contains(previous);
    previous = w;
    if (_year.hasMatch(w) || (_roman.hasMatch(w) && !namesPost)) {
      round.add(w);
    } else if (!_cycleWords.contains(w)) {
      words.add(w);
    }
  }
  return (words: words, round: round);
}

/// The name a picked suggestion is saved under: the exam plus its round, e.g.
/// "SSC CGL 2026" or "IBPS PO XV". Without a year or numeral typed, this year.
String trackedNameFor(CatalogExam exam, String typed, DateTime now) {
  final round = splitQuery(typed).round;
  final suffix = round.isEmpty ? '${now.year}' : round.map((r) => _year.hasMatch(r) ? r : r.toUpperCase()).join(' ');
  return '${exam.name} $suffix';
}

/// Suggestions while typing, best first: names starting with what was typed,
/// then a word of the name/board/aliases starting with it, then anywhere.
/// Years and cycle numerals are ignored ("ibps po xv" finds IBPS PO).
List<CatalogExam> suggestExams(String query, {int limit = 8}) {
  final q = splitQuery(query).words.join(' ');
  if (q.isEmpty) return const [];
  final scored = <(int, int, CatalogExam)>[];
  for (var i = 0; i < examCatalog.length; i++) {
    final e = examCatalog[i];
    final name = _norm(e.name);
    final words = [name, _norm(e.board), ...e.aliases.map(_norm)];
    final int? score;
    if (name.startsWith(q)) {
      score = 0;
    } else if (words.any((w) => w.startsWith(q) || w.contains(' $q'))) {
      score = 1;
    } else if (q.split(' ').every((part) => words.any((w) => w.contains(part)))) {
      score = 2;
    } else {
      score = null;
    }
    if (score != null) scored.add((score, i, e));
  }
  scored.sort((a, b) => a.$1 != b.$1 ? a.$1.compareTo(b.$1) : a.$2.compareTo(b.$2));
  return [for (final s in scored.take(limit)) s.$3];
}

/// The catalogue exam a tracked exam refers to (to fill in its stages and board
/// website), or null. Strict, since a wrong match would show the wrong website: a
/// whole alias or the exam's name must appear, and so must the board (its name or
/// the code the exam's name starts with, like "SSC"), so a High Court "Office
/// Assistant" is not taken for IBPS RRB Clerk. Pass the exam name plus organisation.
CatalogExam? matchCatalogExam(String text) {
  final t = ' ${_norm(text)} ';
  CatalogExam? best;
  var bestLength = 0;
  for (final e in examCatalog) {
    final code = _norm(e.name).split(' ').first;
    if (!t.contains(' $code ') && !t.contains(' ${_norm(e.board)} ')) continue;
    for (final phrase in [e.name, ...e.aliases]) {
      final p = _norm(phrase);
      if (p.length > bestLength && t.contains(' $p ')) {
        best = e;
        bestLength = p.length;
      }
    }
  }
  return best;
}
