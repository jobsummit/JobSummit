import 'package:exam_tracker/domain/upload_specs.dart';
import 'package:exam_tracker/models/jobs_data.dart';
import 'package:exam_tracker/services/form_images.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('jobs.json upload rules are read, one per kind, unknown kinds dropped', () {
    final job = PublishedJob.fromJson({
      'id': 'j',
      'uploads': [
        {'kind': 'photo', 'min_kb': 20, 'max_kb': 50, 'width': 350, 'height': 450},
        {'kind': 'photo', 'max_kb': 999},
        {'kind': 'aadhaar', 'max_kb': 100},
        {'kind': 'signature', 'min_kb': null, 'max_kb': 20, 'width': null, 'height': null},
      ],
    });
    expect(job.uploads.map((u) => u.kind), [UploadKind.photo, UploadKind.signature]);
    expect(job.uploads.first.summary, '20–50 KB · 350 × 450 px');
    expect(job.uploads.last.summary, 'up to 20 KB');
  });

  test('a board points to its usual sizes', () {
    expect(presetFor('Staff Selection Commission', 'CGL 2026'), 'SSC');
    expect(presetFor('Institute of Banking Personnel Selection', 'CRP PO XVI'), 'IBPS / SBI / RBI');
    expect(presetFor('Railway Recruitment Boards', 'NTPC'), isNull);
  });

  test('file names say which exam and what', () {
    expect(FormImages.fileName('SSC CGL 2026 · Tier-1', UploadKind.leftThumb), 'ssc-cgl-2026-tier-1-left-thumb.jpg');
  });
}
