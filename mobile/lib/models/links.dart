/// The first of [preferred] and [fallback] that is an actual link.
String? preferredUrl(String? preferred, String? fallback) {
  for (final url in [preferred, fallback]) {
    if (url != null && url.trim().isNotEmpty) return url.trim();
  }
  return null;
}

/// Job sites and news sites: they write about every exam, and their pages carry
/// lists of other exams' admit cards and results.
const _jobSites = [
  'freejobalert.com',
  'sarkariresult.com',
  'sarkariresult.com.cm',
  'sarkariresult.app',
  'sarkariexam.com',
  'sarkarinaukri.com',
  'sarkarinaukriblog.com',
  'sarkariprep.in',
  'rojgarresult.com',
  'recruitmentresult.com',
  'freshersnow.com',
  'jagranjosh.com',
  'testbook.com',
  'adda247.com',
  'bankersadda.com',
  'sscadda.com',
  'careerpower.in',
  'oliveboard.in',
  'ixambee.com',
  'prepp.in',
  'indgovtjobs.in',
  'employmentnews.gov.in',
  'naukri.com',
  'shiksha.com',
  'careers360.com',
  'collegedunia.com',
  'timesofindia.indiatimes.com',
  'indianexpress.com',
  'hindustantimes.com',
  'ndtv.com',
  'news18.com',
  'jagran.com',
];

/// A job site's page, not the exam board's own.
bool isJobSite(String? url) {
  final host = Uri.tryParse((url ?? '').trim())?.host.toLowerCase() ?? '';
  return host.isNotEmpty && _jobSites.any((site) => host == site || host.endsWith('.$site'));
}
