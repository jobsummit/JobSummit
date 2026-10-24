/// What an exam form wants for its photo, signature, thumb impression and
/// declaration: file size in KB and size in pixels. Pure (no I/O).
library;

import 'package:flutter/foundation.dart';

enum UploadKind {
  photo('photo', 'Photo'),
  signature('signature', 'Signature'),
  leftThumb('left_thumb', 'Left thumb impression'),
  declaration('declaration', 'Handwritten declaration');

  const UploadKind(this.wire, this.label);
  final String wire;
  final String label;

  static UploadKind? fromWire(Object? v) {
    for (final k in values) {
      if (k.wire == v) return k;
    }
    return null;
  }
}

@immutable
class UploadSpec {
  const UploadSpec(this.kind, {this.minKb, this.maxKb, this.width, this.height});

  final UploadKind kind;
  final int? minKb;
  final int? maxKb;
  final int? width;
  final int? height;

  static UploadSpec? fromJson(Object? j) {
    if (j is! Map) return null;
    final kind = UploadKind.fromWire(j['kind']);
    if (kind == null) return null;
    int? n(String k) => j[k] is num ? (j[k] as num).toInt() : null;
    return UploadSpec(kind, minKb: n('min_kb'), maxKb: n('max_kb'), width: n('width'), height: n('height'));
  }

  Map<String, Object?> toJson() =>
      {'kind': kind.wire, 'min_kb': minKb, 'max_kb': maxKb, 'width': width, 'height': height};

  /// "20–50 KB · 350 × 450 px"
  String get summary => [
        if (minKb != null && maxKb != null)
          '$minKb–$maxKb KB'
        else if (maxKb != null)
          'up to $maxKb KB'
        else if (minKb != null)
          'at least $minKb KB',
        if (width != null && height != null) '$width × $height px',
      ].join(' · ');

  @override
  bool operator ==(Object other) =>
      other is UploadSpec &&
      other.kind == kind &&
      other.minKb == minKb &&
      other.maxKb == maxKb &&
      other.width == width &&
      other.height == height;

  @override
  int get hashCode => Object.hash(kind, minKb, maxKb, width, height);
}

/// The rules a notification printed (jobs.json `uploads`), one per kind.
List<UploadSpec> uploadSpecsFrom(Object? json) {
  if (json is! List) return const [];
  final seen = <UploadKind>{};
  return [
    for (final j in json)
      if (UploadSpec.fromJson(j) case final s? when seen.add(s.kind)) s,
  ];
}

/// The usual sizes when the notification's own aren't known. Check them against
/// the notice: boards change them now and then.
const kUploadPresets = <String, List<UploadSpec>>{
  // One-time registration (2024 onward): photo 3.5 × 4.5 cm, signature 4.0 × 2.0 cm.
  'SSC': [
    UploadSpec(UploadKind.photo, minKb: 20, maxKb: 50, width: 350, height: 450),
    UploadSpec(UploadKind.signature, minKb: 10, maxKb: 20, width: 400, height: 200),
  ],
  'IBPS / SBI / RBI': [
    UploadSpec(UploadKind.photo, minKb: 20, maxKb: 50, width: 200, height: 230),
    UploadSpec(UploadKind.signature, minKb: 10, maxKb: 20, width: 140, height: 60),
    UploadSpec(UploadKind.leftThumb, minKb: 20, maxKb: 50, width: 240, height: 240),
    UploadSpec(UploadKind.declaration, minKb: 50, maxKb: 100, width: 800, height: 400),
  ],
};

/// The preset a board's name points to, if any.
String? presetFor(String? organization, String examName) {
  final t = '${organization ?? ''} $examName'.toLowerCase();
  if (RegExp(r'\bssc\b|staff selection').hasMatch(t)) return 'SSC';
  if (RegExp(r'\b(ibps|sbi|rbi|nabard)\b|banking personnel|state bank|reserve bank').hasMatch(t)) {
    return 'IBPS / SBI / RBI';
  }
  return null;
}
