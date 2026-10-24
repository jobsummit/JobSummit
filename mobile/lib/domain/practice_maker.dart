/// Maths and reasoning questions made on the phone, in the forms SSC, bank and RRB
/// papers use. Each is built from its answer (numbers chosen so it comes out
/// whole), so the key is right by construction, with wrong options taken from the
/// usual slips (simple instead of compound interest, m/s instead of km/h…).
library;

import 'dart:math';

import 'practice.dart';

/// [n] questions for [section] (maths or reasoning), topics taken in turn.
List<PracticeQuestion> makeQuestions(PracticeSection section, int n, Random r) {
  final makers = switch (section) {
    PracticeSection.quant => _quant,
    PracticeSection.reasoning => _reasoning,
    _ => throw ArgumentError('${section.name} comes from the question bank'),
  };
  final order = [...makers.keys]..shuffle(r);
  final out = <PracticeQuestion>[];
  final texts = <String>{};
  var i = 0, tries = 0;
  while (out.length < n && tries < n * 40) {
    tries++;
    final topic = order[i % order.length];
    final q = makers[topic]!(r);
    if (q == null || !texts.add(q.text)) continue;
    i++;
    out.add(q.toQuestion(section, topic, out.length, r));
  }
  return out;
}

/// The topics made for [section] (maths or reasoning).
List<String> madeTopics(PracticeSection section) => [...(section == PracticeSection.quant ? _quant : _reasoning).keys];

/// One question of [topic], or null when this try didn't come out whole (for tests).
PracticeQuestion? makeOne(PracticeSection section, String topic, Random r) =>
    (section == PracticeSection.quant ? _quant : _reasoning)[topic]!(r)?.toQuestion(section, topic, 0, r);

typedef _Maker = _Made? Function(Random r);

class _Made {
  _Made(this.text, this.answer, this.wrong, this.explanation);

  final String text;
  final String answer;
  final List<String> wrong;
  final String explanation;

  static final _zeroOrLess = RegExp(r'^₹?0(%|°| |$)|^−');

  /// Three different wrong options, or null when there aren't three (try again).
  /// No "0" or negative ones unless the answer is.
  List<String>? get options {
    final w = <String>[];
    final allowZero = _zeroOrLess.hasMatch(answer);
    for (final x in wrong) {
      if (!allowZero && _zeroOrLess.hasMatch(x)) continue;
      if (x != answer && !w.contains(x)) w.add(x);
      if (w.length == 3) return [answer, ...w];
    }
    return null;
  }

  PracticeQuestion toQuestion(PracticeSection section, String topic, int i, Random r) => PracticeQuestion(
        id: 'gen-${section.name}-$i-${text.hashCode}',
        section: section,
        topic: topic,
        text: text,
        options: options!,
        answer: 0,
        explanation: explanation,
      ).shuffled(r);
}

_Made? _q(String text, String answer, List<String> wrong, String explanation) {
  final m = _Made(text, answer, wrong, explanation);
  return m.options == null ? null : m;
}

int _in(Random r, int lo, int hi) => lo + r.nextInt(hi - lo + 1);
T _one<T>(Random r, List<T> xs) => xs[r.nextInt(xs.length)];
int _gcd(int a, int b) => b == 0 ? a.abs() : _gcd(b, a % b);
int _lcm(int a, int b) => a ~/ _gcd(a, b) * b;

/// 1,23,456 (Indian grouping).
String _g(int n) {
  if (n < 0) return '−${_g(-n)}';
  final s = '$n';
  if (s.length <= 3) return s;
  final last3 = s.substring(s.length - 3);
  var rest = s.substring(0, s.length - 3);
  final groups = <String>[];
  while (rest.length > 2) {
    groups.insert(0, rest.substring(rest.length - 2));
    rest = rest.substring(0, rest.length - 2);
  }
  if (rest.isNotEmpty) groups.insert(0, rest);
  return '${groups.join(',')},$last3';
}

String _rs(int n) => '₹${_g(n)}';

/// 12, 12.5, 16.67
String _d(num x) {
  final rounded = (x * 100).round() / 100;
  if (rounded == rounded.roundToDouble()) return _g(rounded.round());
  return rounded.toStringAsFixed(2).replaceFirst(RegExp(r'0$'), '');
}

String _pc(num x) => '${_d(x)}%';

// -----------------------------------------------------------------------------
// Quantitative aptitude
// -----------------------------------------------------------------------------

final Map<String, _Maker> _quant = {
  'Percentage': (r) {
    if (r.nextBool()) {
      final p = _one(r, [5, 12, 15, 25, 35, 45, 60, 75]);
      final b = 20 * _in(r, 6, 100);
      if (b * p % 100 != 0) return null;
      final a = b * p ~/ 100;
      return _q('What is $p% of ${_g(b)}?', _g(a), [
        if (b * (p + 5) % 100 == 0) _g(b * (p + 5) ~/ 100),
        if (b * (p - 5) % 100 == 0) _g(b * (p - 5) ~/ 100),
        _g(a + 10), _g(a - 10), _g(a + 20), //
      ], '$p% of ${_g(b)} = ${_g(b)} × $p ÷ 100 = ${_g(a)}.');
    }
    final old = 20 * _in(r, 10, 100);
    final p = _one(r, [10, 20, 25, 40, 50, 60, 75]);
    final now = old * (100 + p) ~/ 100;
    final change = now - old;
    return _q('A price rises from ${_rs(old)} to ${_rs(now)}. By what percent did it rise?', _pc(p), [
      _pc(change * 100 / now), _pc(p + 5), _pc(p - 5), _pc(p * 2), //
    ], 'Rise = ${_rs(change)}. Percent = ${_g(change)} ÷ ${_g(old)} × 100 = $p% (always of the old price).');
  },
  'Profit & loss': (r) {
    if (r.nextBool()) {
      final cp = 50 * _in(r, 4, 100);
      final p = _one(r, [5, 10, 12, 15, 20, 25, 30]);
      if (cp * p % 100 != 0) return null;
      final sp = cp * (100 + p) ~/ 100;
      return _q('An article bought for ${_rs(cp)} is sold at a profit of $p%. What is its selling price?', _rs(sp), [
        _rs(cp * (100 - p) ~/ 100), _rs(cp + p), _rs(sp + cp ~/ 20), _rs(sp - cp ~/ 20), //
      ], 'SP = CP × (100 + $p) ÷ 100 = ${_g(cp)} × ${100 + p} ÷ 100 = ${_rs(sp)}.');
    }
    final cp = 100 * _in(r, 4, 80);
    final l = _one(r, [5, 10, 20, 25]);
    final sp = cp * (100 - l) ~/ 100;
    final wrong = sp * (100 + l) / 100;
    return _q('After a loss of $l%, an article sells for ${_rs(sp)}. What did it cost?', _rs(cp), [
      if (wrong == wrong.roundToDouble()) _rs(wrong.round()), _rs(cp + 50), _rs(cp - 100), _rs(cp + 100), //
    ], 'CP = SP × 100 ÷ (100 − $l) = ${_g(sp)} × 100 ÷ ${100 - l} = ${_rs(cp)}.');
  },
  'Discount': (r) {
    if (r.nextBool()) {
      final mp = 100 * _in(r, 5, 80);
      final d = _one(r, [5, 10, 12, 15, 20, 25, 30, 40]);
      final sp = mp * (100 - d) ~/ 100;
      return _q('The marked price of a watch is ${_rs(mp)}. It is sold at a $d% discount. What is the selling price?',
          _rs(sp), [
        _rs(mp * d ~/ 100), _rs(mp - d), _rs(sp + mp ~/ 20), _rs(sp - mp ~/ 20), //
      ], 'Discount = $d% of ${_g(mp)} = ${_rs(mp * d ~/ 100)}. SP = ${_g(mp)} − ${_g(mp * d ~/ 100)} = ${_rs(sp)}.');
    }
    final a = _one(r, [10, 15, 20, 25, 30]), b = _one(r, [10, 20, 25, 30, 40]);
    final single = a + b - a * b / 100;
    return _q('Two successive discounts of $a% and $b% equal a single discount of:', _pc(single), [
      _pc(a + b), _pc(single - 2.5), _pc(single + 2.5), _pc(a * b / 100), //
    ], 'Single discount = $a + $b − ($a × $b ÷ 100) = ${_pc(single)}.');
  },
  'Simple interest': (r) {
    final p = 500 * _in(r, 2, 40), rate = _one(r, [4, 5, 6, 8, 10, 12]), t = _in(r, 2, 5);
    final si = p * rate * t ~/ 100;
    return _q('What is the simple interest on ${_rs(p)} at $rate% a year for $t years?', _rs(si), [
      _rs(p * rate * (t + 1) ~/ 100), _rs(p * rate ~/ 100), _rs(p + si), _rs(p * rate * (t - 1) ~/ 100), //
    ], 'SI = P × R × T ÷ 100 = ${_g(p)} × $rate × $t ÷ 100 = ${_rs(si)}.');
  },
  'Compound interest': (r) {
    final rate = _one(r, [5, 10, 20]);
    final step = switch (rate) { 5 => 400, 10 => 100, _ => 25 };
    final p = step * _in(r, (2000 / step).ceil(), 20000 ~/ step);
    final ci = p * ((100 + rate) * (100 + rate) - 10000) ~/ 10000;
    if (p * ((100 + rate) * (100 + rate) - 10000) % 10000 != 0) return null;
    final si = p * rate * 2 ~/ 100;
    return _q('What is the compound interest on ${_rs(p)} at $rate% a year for 2 years, compounded yearly?', _rs(ci), [
      _rs(si), _rs(p + ci), _rs(ci + p * rate ~/ 100), _rs(ci + 10), //
    ], 'Amount = ${_g(p)} × (1 + $rate/100)² = ${_rs(p + ci)}. CI = amount − principal = ${_rs(ci)}.');
  },
  'Ratio': (r) {
    final (a, b) = _one(r, [(2, 3), (3, 4), (3, 5), (4, 5), (5, 7), (2, 5), (4, 7), (5, 8)]);
    final m = 10 * _in(r, 5, 200 ~/ (a + b));
    final total = (a + b) * m;
    final who = _one(r, _pairs);
    return _q('${_rs(total)} is shared between ${who.$1} and ${who.$2} in the ratio $a : $b. What is ${who.$2}’s share?',
        _rs(b * m), [
      _rs(a * m), if (total.isEven) _rs(total ~/ 2), _rs(b * m + m), _rs(b * m - m), //
    ], 'One part = ${_g(total)} ÷ ${a + b} = ${_g(m)}. ${who.$2} gets $b parts = ${_rs(b * m)}.');
  },
  'Average': (r) {
    if (r.nextBool()) {
      final n = _in(r, 5, 7);
      final xs = [for (var i = 0; i < n - 1; i++) _in(r, 12, 98)];
      var last = _in(r, 12, 98);
      while ((xs.fold(0, (a, b) => a + b) + last) % n != 0) {
        last++;
      }
      xs.add(last);
      final sum = xs.fold(0, (a, b) => a + b);
      final avg = sum ~/ n;
      return _q('What is the average of ${xs.join(', ')}?', '$avg', [
        '${avg + 1}', '${avg - 1}', '${avg + 2}', '${avg - 2}', //
      ], 'Sum = $sum, and there are $n numbers: $sum ÷ $n = $avg.');
    }
    final n = _one(r, [5, 6, 8, 10]), a = _in(r, 20, 60), d = _in(r, 1, 4) * (r.nextBool() ? 1 : -1);
    final removed = n * a - (n - 1) * (a + d);
    if (removed <= 0) return null;
    return _q(
        'The average of $n numbers is $a. With one number taken out, the average of the rest is ${a + d}. '
            'Which number was taken out?',
        '$removed',
        ['${removed + n - 1}', '${removed - (n - 1)}', '${(n * d).abs()}', '${removed + 2 * d}'],
        'Total = $n × $a = ${n * a}. The rest = ${n - 1} × ${a + d} = ${(n - 1) * (a + d)}. '
            'Taken out: ${n * a} − ${(n - 1) * (a + d)} = $removed.');
  },
  'Time & work': (r) {
    final (a, b) = _one(r, const [
      (12, 24), (10, 15), (20, 30), (6, 12), (12, 36), (15, 30), (20, 60), (18, 36), (24, 48), //
      (10, 40), (30, 60), (21, 42), (4, 12), (12, 60), (40, 60), (28, 84), (36, 45), (30, 45), (15, 10),
    ]);
    final t = a * b ~/ (a + b);
    return _q(
        'A can finish a piece of work in $a days and B in $b days. Working together, how many days will they take?',
        '$t',
        [_d((a + b) / 2), '${t + 2}', '${t - 1}', '${(a - b).abs()}', '${t + 1}'],
        'In one day they do 1/$a + 1/$b = 1/$t of the work, so together they take $t days.');
  },
  'Speed & trains': (r) {
    switch (r.nextInt(3)) {
      case 0:
        final kmh = _one(r, [36, 54, 72, 90, 108]);
        final ms = kmh * 5 ~/ 18, t = _in(r, 8, 20), len = ms * t;
        return _q('A train ${_g(len)} m long passes a pole in $t seconds. What is its speed in km/h?', '$kmh', [
          '$ms', '${kmh + 18}', '${kmh - 18}', '${kmh + 9}', //
        ], 'Speed = ${_g(len)} ÷ $t = $ms m/s. In km/h: $ms × 18/5 = $kmh.');
      case 1:
        final ms = _one(r, [10, 15, 20, 25, 30]), t = _in(r, 12, 40);
        final total = ms * t, train = 10 * _in(r, 10, 30), platform = total - train;
        if (platform < 80) return null;
        return _q(
            'A train ${_g(train)} m long runs at ${ms * 18 ~/ 5} km/h. How many seconds does it take to cross a platform '
                '${_g(platform)} m long?',
            '$t',
            [_d(platform / ms), _d(train / ms), '${t + 5}', '${t - 4}', '${t + 2}'],
            'It covers train + platform = ${_g(total)} m at ${ms * 18 ~/ 5} × 5/18 = $ms m/s: ${_g(total)} ÷ $ms = $t s.');
      default:
        final (x, y) = _one(r, const [(40, 60), (30, 60), (20, 30), (60, 90), (45, 90), (36, 45), (30, 45), (60, 40)]);
        final avg = 2 * x * y ~/ (x + y);
        return _q('A car goes to a town at $x km/h and comes back the same way at $y km/h. What is its average speed for the trip?',
            '$avg km/h', [
          '${_d((x + y) / 2)} km/h', '${avg + 2} km/h', '${avg - 2} km/h', '${avg + 5} km/h', //
        ], 'Same distance both ways: average = 2 × $x × $y ÷ ($x + $y) = $avg km/h (not the plain average).');
    }
  },
  'Simplification': (r) {
    final e = _in(r, 2, 9), d = e * _in(r, 2, 12), a = _in(r, 5, 60), b = _in(r, 2, 15), c = _in(r, 2, 12);
    final ans = a + b * c - d ~/ e;
    final leftToRight = ((a + b) * c - d) / e;
    return _q('Simplify: $a + $b × $c − $d ÷ $e', '$ans', [
      if (leftToRight == leftToRight.roundToDouble()) _d(leftToRight),
      '${a + b * c + d ~/ e}', '${ans + 2}', '${ans - 3}', '${ans + 10}', //
    ], 'Multiply and divide first: $b × $c = ${b * c}, $d ÷ $e = ${d ~/ e}. Then $a + ${b * c} − ${d ~/ e} = $ans.');
  },
  'Squares & roots': (r) {
    if (r.nextBool()) {
      final n = _in(r, 21, 79);
      return _q('What is the square root of ${_g(n * n)}?', '$n', [
        '${n + 1}', '${n - 1}', '${n + 2}', '${n - 2}', //
      ], '$n × $n = ${_g(n * n)}.');
    }
    final x = _in(r, 15, 45), y = _in(r, 5, x - 3);
    final ans = x * x - y * y;
    return _q('What is $x² − $y²?', _g(ans), [
      _g((x - y) * (x - y)), _g(ans + 10), _g(ans - 10), _g(ans + 2 * y), //
    ], 'a² − b² = (a − b)(a + b) = ${x - y} × ${x + y} = ${_g(ans)}.');
  },
  'HCF & LCM': (r) {
    final base = _one(r, [2, 3, 4, 5, 6]);
    final ks = ([2, 3, 4, 5, 6, 7, 8, 9]..shuffle(r)).take(3).toList();
    final ns = [for (final k in ks) base * k];
    final hcf = ns.reduce(_gcd), lcm = ns.reduce(_lcm);
    if (r.nextBool()) {
      return _q('What is the LCM of ${ns.join(', ')}?', _g(lcm), [
        _g(hcf), _g(lcm * 2), if (lcm.isEven) _g(lcm ~/ 2), _g(ns.reduce((a, b) => a * b) ~/ hcf), _g(lcm + base), //
      ], 'The smallest number all of them divide: ${_g(lcm)}.');
    }
    return _q('What is the HCF of ${ns.join(', ')}?', '$hcf', [
      _g(lcm), '${hcf * 2}', if (hcf > 1) '1', '${hcf + 1}', '${hcf * 3}', //
    ], 'The largest number that divides all of them: $hcf.');
  },
  'Ages': (r) {
    final (a, b) = _one(r, const [(2, 3), (3, 4), (3, 5), (4, 5), (5, 7), (5, 6), (4, 7)]);
    final k = _in(r, 3, 9), n = _in(r, 4, 12);
    final x = a * k, y = b * k;
    final g = _gcd(x + n, y + n);
    final c = (x + n) ~/ g, d = (y + n) ~/ g;
    if (c == a || c > 30 || d > 30) return null;
    final who = _one(r, _pairs);
    return _q(
        'The ages of ${who.$1} and ${who.$2} are in the ratio $a : $b. In $n years the ratio will be $c : $d. '
            'How old is ${who.$2} now?',
        '$y years',
        ['$x years', '${y + n} years', '${y + k} years', '${y - k} years'],
        'Ages are ${a}k and ${b}k: (${a}k + $n) : (${b}k + $n) = $c : $d gives k = $k. ${who.$2} is $b × $k = $y.');
  },
  'Number system': (r) {
    final d = _one(r, [3, 4, 8, 9, 11]);
    final yes = d * _in(r, 1000 ~/ d + 1, 99999 ~/ d);
    final no = <int>{};
    while (no.length < 3) {
      final x = _in(r, 1000, 99999);
      if (x % d != 0) no.add(x);
    }
    final rule = switch (d) {
      3 => 'its digits add up to a multiple of 3',
      9 => 'its digits add up to a multiple of 9',
      4 => 'its last two digits make a multiple of 4',
      8 => 'its last three digits make a multiple of 8',
      _ => 'the difference of its alternate digit sums is 0 or a multiple of 11',
    };
    return _q('Which of these numbers is divisible by $d?', '$yes', [for (final x in no) '$x'],
        '$yes: a number is divisible by $d when $rule.');
  },
};

// -----------------------------------------------------------------------------
// Reasoning
// -----------------------------------------------------------------------------

const _male = ['Aarav', 'Rohan', 'Imran', 'Kabir', 'Arjun', 'Vikram', 'Rahul', 'Sameer', 'Joseph', 'Manish'];
const _female = ['Meena', 'Priya', 'Fatima', 'Ananya', 'Kavya', 'Sneha', 'Riya', 'Neha', 'Sara', 'Pooja'];
const _pairs = [('Asha', 'Bilal'), ('Ravi', 'Simran'), ('Kiran', 'Deepa'), ('Amit', 'Zoya'), ('Nikhil', 'Tara')];
const _people = [..._male, ..._female];

const _alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ';
String _letter(int pos) => _alphabet[pos - 1]; // 1 = A

const _codeWords = [
  'COLD', 'WARM', 'BOOK', 'DESK', 'LAMP', 'TRAIN', 'PLANT', 'RIVER', 'STONE', 'CLOUD', 'HOUSE', //
  'MANGO', 'CHAIR', 'BRICK', 'FLAME', 'GLASS', 'PAPER', 'SMILE', 'BREAD', 'LIGHT', 'GREEN', 'WATER',
];

const _dictionaryWords = {
  'C': ['CABIN', 'CABLE', 'CACTUS', 'CAMEL', 'CANDLE', 'CANOPY', 'CARBON', 'CAREER', 'CASTLE'],
  'P': ['PACE', 'PACKET', 'PADDLE', 'PALACE', 'PANEL', 'PAPER', 'PARADE', 'PARCEL', 'PARDON'],
  'S': ['SABLE', 'SADDLE', 'SAFETY', 'SAINT', 'SALAD', 'SALMON', 'SALUTE', 'SAMPLE'],
  'M': ['MAGNET', 'MAIDEN', 'MAJOR', 'MANGO', 'MANNER', 'MARBLE', 'MARKET', 'MASTER'],
  'T': ['TABLE', 'TABLET', 'TACKLE', 'TAILOR', 'TALENT', 'TANGLE', 'TARGET', 'TASSEL'],
};

const _days = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];

/// Months without February (a leap year would change the answer), with their days.
const _months = [
  ('January', 31), ('March', 31), ('April', 30), ('May', 31), ('June', 30), ('July', 31), //
  ('August', 31), ('September', 30), ('October', 31), ('November', 30),
];

String _shift(String word, int k) => String.fromCharCodes([for (final c in word.codeUnits) 65 + (c - 65 + k) % 26]);
String _mirror(String word) => String.fromCharCodes([for (final c in word.codeUnits) 90 - (c - 65)]);

/// N, S, E, W and the four in between, from a displacement.
String _heading(int dx, int dy) {
  final ns = dy > 0 ? 'North' : (dy < 0 ? 'South' : '');
  final ew = dx > 0 ? 'East' : (dx < 0 ? 'West' : '');
  return [ns, ew].where((s) => s.isNotEmpty).join('-');
}

bool _isPrime(int n) {
  if (n < 2) return false;
  for (var i = 2; i * i <= n; i++) {
    if (n % i == 0) return false;
  }
  return true;
}

/// Number rules for "if 3 → 10 and 5 → 26": a rule only counts when no other fits both.
final _rules = <String, int Function(int)>{
  'n²': (n) => n * n,
  'n³': (n) => n * n * n,
  'n² + 1': (n) => n * n + 1,
  'n² − 1': (n) => n * n - 1,
  '2n + 3': (n) => 2 * n + 3,
  '3n − 1': (n) => 3 * n - 1,
  'n(n + 1)': (n) => n * (n + 1),
  'n² + n + 1': (n) => n * n + n + 1,
};

final Map<String, _Maker> _reasoning = {
  'Number series': (r) {
    final List<int> s;
    final String why;
    switch (r.nextInt(6)) {
      case 0:
        final a = _in(r, 2, 40), d = _in(r, 3, 15);
        s = [for (var i = 0; i < 7; i++) a + d * i];
        why = 'Each term adds $d.';
      case 1:
        final a = _in(r, 1, 5), m = _one(r, [2, 3]);
        s = [for (var i = 0; i < 7; i++) a * pow(m, i).toInt()];
        why = 'Each term is $m times the one before.';
      case 2:
        final k = _in(r, 2, 9), c = _in(r, -2, 3);
        s = [for (var i = 0; i < 7; i++) (k + i) * (k + i) + c];
        why = c == 0 ? 'Squares: $k², ${k + 1}², …' : 'Squares ${c > 0 ? 'plus' : 'minus'} ${c.abs()}: $k² ${c > 0 ? '+' : '−'} ${c.abs()}, …';
      case 3:
        final a = _in(r, 1, 20), d = _in(r, 1, 4), step = _in(r, 1, 3);
        s = [a];
        for (var i = 0; i < 6; i++) {
          s.add(s.last + d + step * i);
        }
        why = 'The gaps grow by $step: +$d, +${d + step}, +${d + 2 * step}, …';
      case 4:
        final a = _in(r, 1, 6), c = _one(r, [1, 2, 3, -1]);
        s = [a];
        for (var i = 0; i < 6; i++) {
          s.add(s.last * 2 + c);
        }
        why = 'Each term is double the one before, ${c > 0 ? 'plus' : 'minus'} ${c.abs()}.';
      default:
        final a = _in(r, 2, 20), b = _in(r, 30, 60), p = _in(r, 2, 6), q = _in(r, 2, 6);
        s = [for (var i = 0; i < 7; i++) i.isEven ? a + p * (i ~/ 2) : b - q * (i ~/ 2)];
        why = 'Two series take turns: $a, ${a + p}, … (+$p) and $b, ${b - q}, … (−$q).';
    }
    final next = s.removeLast(); // seven made, six shown
    final lastGap = s[5] - s[4];
    return _q('What comes next? ${s.join(', ')}, ?', _g(next), [
      _g(s.last + lastGap), _g(next + 1), _g(next - 2), _g(next + 3), _g(next + lastGap), //
    ], why);
  },
  'Letter series': (r) {
    if (r.nextBool()) {
      final k = _in(r, 2, 5), start = _in(r, 1, 26 - 5 * k);
      final s = [for (var i = 0; i < 5; i++) _letter(start + k * i)];
      final next = start + 5 * k;
      return _q('What comes next? ${s.join(', ')}, ?', _letter(next), [
        _letter(next - 1), if (next < 26) _letter(next + 1), _letter(next - 2), if (next < 25) _letter(next + 2), //
      ], 'Each letter moves $k ahead.');
    }
    final k = _in(r, 1, 2), a = _in(r, 1, 6);
    String pair(int i) => '${_letter(a + k * i)}${_letter(27 - a - k * i)}';
    final next = pair(4);
    return _q('What comes next? ${pair(0)}, ${pair(1)}, ${pair(2)}, ${pair(3)}, ?', next, [
      '${_letter(a + k * 4)}${_letter(27 - a - k * 4 + 1)}', '${_letter(a + k * 4 + 1)}${_letter(27 - a - k * 4)}',
      '${_letter(27 - a - k * 4)}${_letter(a + k * 4)}', '${_letter(a + k * 5)}${_letter(27 - a - k * 5)}', //
    ], 'The first letter moves $k ahead, the second $k back from Z.');
  },
  'Coding-decoding': (r) {
    final words = ([..._codeWords]..shuffle(r)).take(2).toList();
    final (w1, w2) = (words[0], words[1]);
    if (r.nextInt(3) == 0) {
      return _q('In a code, $w1 is written as ${_mirror(w1)}. How is $w2 written in that code?', _mirror(w2), [
        _shift(w2, 1), _mirror(w2).split('').reversed.join(), _shift(_mirror(w2), 1), _shift(w2, -1), //
      ], 'Each letter becomes its opposite (A ↔ Z, B ↔ Y, …).');
    }
    final k = _one(r, [1, 2, 3, -1, -2]);
    return _q('In a code, $w1 is written as ${_shift(w1, k)}. How is $w2 written in that code?', _shift(w2, k), [
      for (final x in [_shift(w2, k + 1), _shift(w2, k - 1), _shift(w2, -k), _shift(w2, k).split('').reversed.join()])
        if (x != w2) x,
    ], 'Each letter moves ${k.abs()} ${k > 0 ? 'ahead' : 'back'} (Z wraps to A).');
  },
  'Alphabet': (r) {
    final fromLeft = r.nextBool();
    final y = _in(r, 3, 20), x = _in(r, 2, 6);
    final base = fromLeft ? y : 27 - y;
    final toRight = r.nextBool();
    final pos = toRight ? base + x : base - x;
    if (pos < 1 || pos > 26) return null;
    final ord = _ordinal;
    return _q(
        'In the English alphabet, which letter is ${ord(x)} to the ${toRight ? 'right' : 'left'} of the ${ord(y)} '
            'letter from the ${fromLeft ? 'left' : 'right'}?',
        _letter(pos),
        [
          if (pos > 1) _letter(pos - 1), if (pos < 26) _letter(pos + 1),
          if (toRight ? base - x >= 1 : base + x <= 26) _letter(toRight ? base - x : base + x),
          if (pos > 2) _letter(pos - 2), if (pos < 25) _letter(pos + 2),
        ],
        'The ${ord(y)} from the ${fromLeft ? 'left' : 'right'} is ${_letter(base)}; ${ord(x)} to its '
            '${toRight ? 'right' : 'left'} is ${_letter(pos)}.');
  },
  'Ranking': (r) {
    final name = _one(r, _people), left = _in(r, 4, 25), right = _in(r, 4, 25);
    final total = left + right - 1;
    if (r.nextBool()) {
      return _q('In a row, $name is ${_ordinal(left)} from the left and ${_ordinal(right)} from the right. '
          'How many people are in the row?', '$total', [
        '${total + 1}', '${total - 1}', '${total + 2}', //
      ], 'Total = $left + $right − 1 = $total ($name is counted twice).');
    }
    return _q('In a row of $total people, $name is ${_ordinal(left)} from the left. What is $name’s place from the right?',
        _ordinal(right), [
      _ordinal(right + 1), _ordinal(right - 1), _ordinal(right + 2), //
    ], 'From the right = $total − $left + 1 = $right.');
  },
  'Directions': (r) {
    const names = ['North', 'East', 'South', 'West'];
    const step = [(0, 1), (1, 0), (0, -1), (-1, 0)];
    var h = r.nextInt(4), x = 0, y = 0;
    final legs = <String>[];
    final n = _in(r, 2, 4);
    for (var i = 0; i < n; i++) {
      final right = r.nextBool();
      if (i > 0) h = (h + (right ? 1 : 3)) % 4;
      // The last leg is the length that makes the distance a whole number.
      final lengths = [for (var km = 2; km <= 12; km++) km]..shuffle(r);
      final km = i < n - 1
          ? lengths.first
          : lengths.where((km) {
              final (nx, ny) = (x + step[h].$1 * km, y + step[h].$2 * km);
              final d = sqrt(nx * nx + ny * ny).round();
              return d > 0 && d * d == nx * nx + ny * ny;
            }).firstOrNull;
      if (km == null) return null;
      legs.add(i == 0 ? 'walks $km km ${names[h]}' : 'turns ${right ? 'right' : 'left'} and walks $km km');
      x += step[h].$1 * km;
      y += step[h].$2 * km;
    }
    final d2 = x * x + y * y, d = sqrt(d2).round();
    final name = _one(r, _people);
    final where = _heading(x, y);
    return _q('$name ${legs.join(', then ')}. How far from the start is $name now, and in which direction?',
        '$d km $where', [
      '$d km ${_heading(-x, -y)}', '${x.abs() + y.abs()} km $where', '$d km ${_heading(y, -x)}', '$d km ${_heading(-y, x)}',
      '${d + 1} km $where', //
    ], x == 0 || y == 0
        ? 'Net: $d km $where.'
        : 'Net: ${x.abs()} km ${x > 0 ? 'East' : 'West'} and ${y.abs()} km ${y > 0 ? 'North' : 'South'}; '
            'straight-line distance √(${x * x} + ${y * y}) = $d km.');
  },
  'Calendar': (r) {
    final mi = r.nextInt(_months.length - 1);
    final (m1, len) = _months[mi];
    final d1 = _in(r, 1, 20), w = r.nextInt(7);
    final later = _in(r, 9, 40);
    var d2 = d1 + later;
    var m2 = m1;
    if (d2 > len) {
      final next = _months[mi + 1];
      if (_monthIndex(next.$1) != _monthIndex(m1) + 1) return null; // only back-to-back months
      d2 -= len;
      m2 = next.$1;
    }
    final ans = _days[(w + later) % 7];
    return _q('If $d1 $m1 is a ${_days[w]}, what day of the week is $d2 $m2 of the same year?', ans, [
      _days[(w + later + 1) % 7], _days[(w + later + 6) % 7], _days[(w + later + 2) % 7], //
    ], '$later days later: $later = ${later ~/ 7} weeks and ${later % 7} days, so ${later % 7} days on from ${_days[w]}.');
  },
  'Clocks': (r) {
    final h = _in(r, 1, 11), m = 5 * _in(r, 1, 11);
    final raw = (30 * h - 5.5 * m).abs();
    final angle = raw > 180 ? 360 - raw : raw;
    final rough = (30 * h - 6 * m).abs() % 360;
    return _q('What is the smaller angle between the hands of a clock at $h:${'$m'.padLeft(2, '0')}?', '${_d(angle)}°', [
      '${_d(rough > 180 ? 360 - rough : rough)}°', '${_d(180 - angle)}°', '${_d(angle + 15)}°', '${_d((angle - 10).abs())}°', //
    ], 'Angle = |30 × $h − 5.5 × $m| = ${_d(raw)}°${raw > 180 ? ', and the smaller side is 360 − ${_d(raw)} = ${_d(angle)}°' : ''}.');
  },
  'Odd one out': (r) {
    if (r.nextBool()) {
      final primes = [for (var n = 11; n < 98; n += 2) if (_isPrime(n)) n]..shuffle(r);
      final odd = _one(r, const [21, 27, 33, 39, 51, 57, 63, 69, 77, 87, 91, 93]);
      return _q('Which is the odd one out?', '$odd', [for (final p in primes.take(3)) '$p'],
          '$odd = ${_factor(odd)} is not a prime; the others are.');
    }
    final k = _in(r, 2, 4), breaks = _in(r, 1, 2);
    final groups = <String>[];
    while (groups.length < 3) {
      final s = _in(r, 1, 26 - 2 * k);
      final g = '${_letter(s)}${_letter(s + k)}${_letter(s + 2 * k)}';
      if (!groups.contains(g)) groups.add(g);
    }
    final s = _in(r, 1, 26 - 2 * k - breaks);
    final odd = '${_letter(s)}${_letter(s + k)}${_letter(s + 2 * k + breaks)}';
    return _q('Which group is the odd one out?', odd, groups,
        'In the others each letter is $k ahead of the one before; in $odd the last step is ${k + breaks}.');
  },
  'Number rule': (r) {
    final names = [..._rules.keys]..shuffle(r);
    final rule = names.first, f = _rules[rule]!;
    final xs = ([2, 3, 4, 5, 6, 7]..shuffle(r)).take(3).toList();
    final fits = [
      for (final e in _rules.entries)
        if (e.value(xs[0]) == f(xs[0]) && e.value(xs[1]) == f(xs[1])) e.key,
    ];
    if (fits.length != 1) return null;
    final ans = f(xs[2]);
    return _q('${xs[0]} → ${f(xs[0])} and ${xs[1]} → ${f(xs[1])}. Then ${xs[2]} → ?', _g(ans), [
      for (final e in _rules.entries) if (e.key != rule) _g(e.value(xs[2])),
    ], 'The rule is $rule.');
  },
  'Blood relations': (r) {
    final m = ([..._male]..shuffle(r)), f = ([..._female]..shuffle(r));
    final (text, ans, wrong, why) = switch (r.nextInt(10)) {
      0 => (
          'Pointing to a man, ${f[0]} said, “His mother is the only daughter of my mother.” How is ${f[0]} related to the man?',
          'Mother', ['Sister', 'Aunt', 'Grandmother'], 'The only daughter of ${f[0]}’s mother is ${f[0]} herself.'),
      1 => ('${m[0]} is the brother of ${f[0]}. ${f[0]} is the daughter of ${m[1]}. How is ${m[1]} related to ${m[0]}?',
          'Father', ['Uncle', 'Brother', 'Grandfather'], '${m[0]} and ${f[0]} are siblings, so ${f[0]}’s father is his too.'),
      2 => ('${f[0]} is the mother of ${m[0]}. ${m[0]} is the father of ${f[1]}. How is ${f[0]} related to ${f[1]}?',
          'Grandmother', ['Mother', 'Aunt', 'Sister'], 'Her son’s daughter: ${f[0]} is ${f[1]}’s grandmother.'),
      3 => ('Introducing a woman, ${m[0]} said, “She is the wife of my father’s only son.” How is the woman related to ${m[0]}?',
          'Wife', ['Sister', 'Mother', 'Sister-in-law'], 'His father’s only son is ${m[0]} himself.'),
      4 => ('${m[0]}’s father is the only son of ${m[1]}. How is ${m[1]} related to ${m[0]}?', 'Grandfather',
          ['Father', 'Uncle', 'Brother'], '${m[1]}’s son is ${m[0]}’s father.'),
      5 => ('${f[0]} is the sister of ${m[0]}. ${m[0]} is the son of ${f[1]}. How is ${f[1]} related to ${f[0]}?', 'Mother',
          ['Aunt', 'Sister', 'Grandmother'], '${f[0]} and ${m[0]} are siblings: ${f[1]} is mother to both.'),
      6 => ('${m[0]} is the husband of ${f[0]}. ${f[0]} is the sister of ${m[1]}. How is ${m[1]} related to ${m[0]}?',
          'Brother-in-law', ['Brother', 'Cousin', 'Uncle'], '${m[1]} is the brother of ${m[0]}’s wife.'),
      7 => ('${f[0]} is the daughter of the only brother of ${m[0]}. How is ${f[0]} related to ${m[0]}?', 'Niece',
          ['Daughter', 'Sister', 'Cousin'], 'His brother’s daughter is his niece.'),
      8 => ('${m[0]} is the son of the only son of ${f[0]}’s father. How is ${m[0]} related to ${f[0]}?', 'Nephew',
          ['Son', 'Brother', 'Cousin'], 'The only son of ${f[0]}’s father is her brother; his son is her nephew.'),
      _ => ('${m[0]}’s mother is the sister of ${f[0]}’s father. How is ${m[0]} related to ${f[0]}?', 'Cousin',
          ['Brother', 'Nephew', 'Uncle'], 'Their parents are siblings, so they are cousins.'),
    };
    return _q(text, ans, wrong, why);
  },
  'Symbols & operations': (r) {
    const shown = ['+', '−', '×', '÷'];
    final meant = [...shown]..shuffle(r);
    if (List.generate(4, (i) => meant[i] == shown[i]).where((same) => same).length > 1) return null;
    final ops = ([0, 1, 2, 3]..shuffle(r)).take(3).toList();
    final nums = [for (var i = 0; i < 4; i++) _in(r, 2, 20)];
    final real = _eval(nums, [for (final o in ops) meant[o]]);
    if (real == null || real < 0) return null;
    final plain = _eval(nums, [for (final o in ops) shown[o]]);
    final expr = [for (var i = 0; i < 4; i++) ...[if (i > 0) shown[ops[i - 1]], '${nums[i]}']].join(' ');
    final legend = [for (var i = 0; i < 4; i++) if (meant[i] != shown[i]) '‘${shown[i]}’ means ‘${meant[i]}’'];
    return _q('If ${legend.join(', ')}, what is $expr?', _g(real), [
      if (plain != null) _g(plain), _g(real + 2), _g(real - 1), _g(real + 5), _g(real * 2), //
    ], 'Swap the signs: ${[for (var i = 0; i < 4; i++) ...[if (i > 0) meant[ops[i - 1]], '${nums[i]}']].join(' ')} '
        '= ${_g(real)} (× and ÷ first).');
  },
  'Dictionary order': (r) {
    final letter = _one(r, [..._dictionaryWords.keys]);
    final words = ([..._dictionaryWords[letter]!]..shuffle(r)).take(4).toList();
    final sorted = [...words]..sort();
    final k = _in(r, 1, 4);
    return _q('Which word comes ${_ordinal(k)} in dictionary order? ${words.join(', ')}', sorted[k - 1],
        [for (final w in words) if (w != sorted[k - 1]) w], 'In order: ${sorted.join(', ')}.');
  },
};

int _monthIndex(String name) =>
    const ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December']
        .indexOf(name);

String _ordinal(int n) {
  final tail = n % 100;
  final suffix = tail >= 11 && tail <= 13 ? 'th' : switch (n % 10) { 1 => 'st', 2 => 'nd', 3 => 'rd', _ => 'th' };
  return '$n$suffix';
}

String _factor(int n) {
  for (var i = 2; i * i <= n; i++) {
    if (n % i == 0) return '$i × ${n ~/ i}';
  }
  return '$n';
}

/// Four numbers and three of + − × ÷, × and ÷ first; null unless every division is exact.
int? _eval(List<int> nums, List<String> ops) {
  final terms = <int>[nums[0]];
  final signs = <String>[];
  for (var i = 0; i < ops.length; i++) {
    final n = nums[i + 1];
    switch (ops[i]) {
      case '×':
        terms[terms.length - 1] = terms.last * n;
      case '÷':
        if (terms.last % n != 0) return null;
        terms[terms.length - 1] = terms.last ~/ n;
      default:
        signs.add(ops[i]);
        terms.add(n);
    }
  }
  var total = terms[0];
  for (var i = 0; i < signs.length; i++) {
    total = signs[i] == '+' ? total + terms[i + 1] : total - terms[i + 1];
  }
  return total;
}
