import 'package:exam_tracker/domain/exam_catalog.dart';
import 'package:exam_tracker/domain/exam_watcher.dart';
import 'package:exam_tracker/services/page_links.dart';
import 'package:flutter_test/flutter_test.dart';

// Shaped like SBI's Current Openings: a heading per recruitment, its links below.
const sbiPage = '''
<div id="jobLinks">
 <div class="card">
  <div class="accordion lateral"><p>RECRUITMENT OF JUNIOR ASSOCIATES (CUSTOMER SUPPORT &amp; SALES)</p>
   <p>ADVERTISEMENT NO: CRPD/CR/2026-27/17</p></div>
  <div class="accordion-content"><ul class="text-link">
   <li><a href="https://ibpsreg.ibps.in/sbijajul26/oecla_sep26/login.php">DOWNLOAD PRELIMINARY EXAMINATION CALL LETTER</a></li>
   <li><a href="https://ibpsreg.ibps.in/sbijajul26/oecla_nov26/login.php">DOWNLOAD MAINS EXAMINATION CALL LETTER</a></li>
  </ul></div>
 </div>
 <div class="card">
  <div class="accordion lateral"><p>JUNIOR ASSOCIATES - SPECIAL RECRUITMENT DRIVE</p>
   <p>ADVERTISEMENT NO: CRPD/CR/2026-27/09</p></div>
  <div class="accordion-content"><ul class="text-link">
   <li><a href="https://ibpsreg.ibps.in/sbijasrdjl26/oecla_sep26/login.php">DOWNLOAD PRELIMINARY EXAMINATION CALL LETTER</a></li>
  </ul></div>
 </div>
 <div class="card">
  <div class="accordion lateral"><p>RECRUITMENT OF PROBATIONARY OFFICERS</p>
   <p>ADVERTISEMENT NO: CRPD/PO/2026-27/04</p></div>
  <div class="accordion-content"><ul class="text-link">
   <li><a href="/webfiles/uploads/files_2627/10/SBIPO2026-Main-WTRESULT.pdf">MAIN EXAMINATION RESULT</a></li>
  </ul></div>
 </div>
</div>
''';

// Shaped like IBPS's CRP updates: the round's code, not the exam's name.
const ibpsPage = '''
<ul>
 <li>15 Oct 26 <a href="http://ibpsreg.ibps.in/crpspxvimy26/presta_oct26/login.php">Result Status of Online Preliminary Examination for CRP-SPL-XVI</a></li>
 <li>24 Sep 26 <a href="http://ibpsreg.ibps.in/crppoxvijn26/oecla_sep26/login.php">Download Online Main Examination Call Letter for CRP-PO/MTs-XVI</a></li>
</ul>
''';

void main() {
  final now = DateTime.utc(2026, 10, 21);
  final closed = DateTime.utc(2026, 8, 31);

  List<DetectedUpdate> watch(String html, String base, String exam, String org,
          {String? stage, String? advert}) =>
      detectUpdates(
        extractPageLinks(html, base),
        examName: exam,
        organization: org,
        source: UpdateSource.official,
        examSpecificPage: isExamSpecificPage(base),
        boardsOwnPage: true,
        knownUrls: const {},
        now: now,
        stage: stage,
        round: ExamRound(years: const {'2026'}, formCloses: closed, advert: advert),
      );

  const sbiUrl = 'https://sbi.bank.in/web/careers/current-openings';
  const sbi = 'State Bank of India';

  test('a link takes its section heading', () {
    final link = extractPageLinks(sbiPage, sbiUrl).first;
    expect(link.heading, contains('JUNIOR ASSOCIATES'));
    expect(link.heading, contains('CRPD/CR/2026-27/17'));
  });

  test('SBI careers is a board page, not one exam\'s', () {
    expect(isExamSpecificPage(sbiUrl), isFalse);
    expect(isExamSpecificPage('https://www.rrbcdg.gov.in/cen-03-2026'), isTrue);
  });

  test('SBI Clerk: its own call letter, not the special drive\'s nor the PO result', () {
    final found = watch(sbiPage, sbiUrl, 'SBI Clerk 2026', sbi, stage: 'Prelims', advert: 'crpd-cr-2026-27-17');
    expect([for (final u in found) u.url], ['https://ibpsreg.ibps.in/sbijajul26/oecla_sep26/login.php']);
    expect(found.single.milestone, Milestone.admitCard);
  });

  test('SBI PO at Mains: the Mains result', () {
    final found = watch(sbiPage, sbiUrl, 'SBI PO 2026', sbi, stage: 'Mains');
    expect(found.single.milestone, Milestone.result);
  });

  test('IBPS codes: CRP-SPL is SO, CRP-PO/MTs is PO', () {
    const ibps = 'Institute of Banking Personnel Selection';
    const url = 'https://www.ibps.in/index.php/crp-updates/';
    expect(watch(ibpsPage, url, 'IBPS SO 2026', ibps, stage: 'Prelims').single.milestone, Milestone.result);
    expect(watch(ibpsPage, url, 'IBPS PO 2026', ibps, stage: 'Mains').single.milestone, Milestone.admitCard);
  });

  test('a job site naming another recruitment\'s CEN number is not this one', () {
    const round = ExamRound(years: {'2026'}, advert: 'cen-6-2026');
    expect(round.admits('RRB NTPC Graduate CBT 2 City Slip 2026 Out, CEN 06/2025', Milestone.examSchedule, now),
        isFalse);
    expect(round.admits('RRB NTPC Graduate Exam Date 2026 Out, CEN 06/2026', Milestone.examSchedule, now), isTrue);
    expect(round.admits('RRB NTPC Graduate Exam Date Out', Milestone.examSchedule, now), isTrue);
  });

  test('every bank exam watches its board\'s notice page', () {
    for (final id in ['ibps-po', 'ibps-clerk', 'sbi-po', 'sbi-clerk', 'nabard-grade-a', 'rbi-grade-b']) {
      final exam = examCatalog.firstWhere((e) => e.id == id);
      expect(exam.watchUrls, isNotEmpty, reason: id);
    }
  });
}
