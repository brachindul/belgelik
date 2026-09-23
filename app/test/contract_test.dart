import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:belgelik/models.dart';

/// Sozlesme testi: contract/ fixture'lari istemci modelleriyle parse edilebilmeli.
/// Sunucu bir alani silerse/tipini degistirirse ve fixture guncellenirse burada
/// (veya sunucu test_contract.py'de) kirilir -> sessiz ayrisma yakalanir.
Map<String, dynamic> _load(String name) {
  final f = File('../contract/$name');
  return jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
}

void main() {
  test('pdf_doc fixture PdfDoc.fromJson ile parse edilir', () {
    final d = PdfDoc.fromJson(_load('pdf_doc.json'));
    expect(d.id, 'doc-abc');
    expect(d.name, 'Idare Hukuku');
    expect(d.pageCount, 320);
    expect(d.kind, 'pdf');
  });

  test('video_doc fixture VideoDoc.fromJson ile parse edilir', () {
    final v = VideoDoc.fromJson(_load('video_doc.json'));
    expect(v.id, 'vid-abc');
    expect(v.durationSec, 3600);
    expect(v.positionSec, 120);
  });

  test('annotation fixture Stroke.fromJson ile parse edilir', () {
    final s = Stroke.fromJson(_load('annotation.json'));
    expect(s.strokeUuid, 'st-1');
    expect(s.kind, 'pen');
    expect(s.points.length, 2);
  });

  test('reading_goal fixture ReadingGoal.fromJson ile parse edilir', () {
    final g = ReadingGoal.fromJson(_load('reading_goal.json'));
    expect(g.docId, 'doc-abc');
    expect(g.targetPages, 50);
  });
}
