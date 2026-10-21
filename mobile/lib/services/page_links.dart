import 'package:html/dom.dart';
import 'package:html/parser.dart' as html_parser;

import '../domain/exam_watcher.dart';

/// Every content link on a page with its row/list text, like the backend's
/// `parse_generic`: navigation chrome is skipped, and a table row's or list
/// item's text becomes the link's context ("28/11/2026 | Admit Card | Click Here").
List<PageLink> extractPageLinks(String html, String baseUrl) {
  final doc = html_parser.parse(html);
  final base = Uri.parse(baseUrl);
  final seen = <String, PageLink>{};
  for (final a in doc.querySelectorAll('a[href]')) {
    final href = (a.attributes['href'] ?? '').trim();
    final lower = href.toLowerCase();
    if (href.isEmpty ||
        lower.startsWith('#') ||
        lower.startsWith('javascript:') ||
        lower.startsWith('mailto:') ||
        lower.startsWith('tel:')) {
      continue;
    }
    if (_inChrome(a)) continue;
    final Uri resolved;
    try {
      resolved = base.resolve(href);
    } on FormatException {
      continue;
    }
    if (resolved.scheme != 'http' && resolved.scheme != 'https') continue;
    final url = canonicalUrl(resolved.toString());
    final context = _clean(_container(a)?.text ?? '');
    var title = _clean(a.text);
    if (title.isEmpty) title = _clean(a.attributes['title'] ?? '');
    if (title.isEmpty) title = context.length > 300 ? context.substring(0, 300) : context;
    final prev = seen[url];
    if (prev == null || title.length > prev.title.length) {
      seen[url] = PageLink(
          url: url, title: _cap(title, 300), context: _cap(context, 500), heading: _cap(_heading(a) ?? '', 300));
    }
  }
  return seen.values.toList(growable: false);
}

final _headingClass = RegExp(r'accordion|heading|header|title', caseSensitive: false);

bool _isHeading(Element e) =>
    const {'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'summary', 'caption', 'legend', 'dt'}.contains(e.localName) ||
    _headingClass.hasMatch(e.attributes['class'] ?? '');

/// The title of the section a link sits in, for pages that list each recruitment
/// as a heading with its links under it ("RECRUITMENT OF JUNIOR ASSOCIATES ...
/// ADVERTISEMENT NO: CRPD/CR/2026-27/17", then "Download call letter").
String? _heading(Element a) {
  var depth = 0;
  for (Element? p = a; p != null && p.localName != 'body' && depth < 8; p = p.parent, depth++) {
    for (Element? s = p.previousElementSibling; s != null; s = s.previousElementSibling) {
      if (_isHeading(s)) {
        final text = _clean(s.text);
        if (text.isNotEmpty) return text;
      }
    }
  }
  return null;
}

bool _inChrome(Element el) {
  for (Element? p = el.parent; p != null; p = p.parent) {
    if (const {'nav', 'header', 'footer'}.contains(p.localName)) return true;
  }
  return false;
}

Element? _container(Element a) {
  for (Element? p = a.parent; p != null; p = p.parent) {
    if (p.localName == 'tr' || p.localName == 'li') return p;
  }
  return a.parent;
}

String _clean(String s) => s.replaceAll(RegExp(r'\s+'), ' ').trim();
String _cap(String s, int n) => s.length > n ? s.substring(0, n) : s;
