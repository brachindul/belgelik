import 'package:flutter_test/flutter_test.dart';
import 'package:belgelik/models.dart';

void main() {
  test('Stroke JSON round-trip', () {
    final s = Stroke(
      page: 3,
      kind: 'pen',
      color: 0xFFE53935,
      width: 0.004,
      points: [const Offset(0.1, 0.2), const Offset(0.3, 0.4)],
    );
    final json = s.toJson();
    expect(json['page'], 3);
    expect(json['kind'], 'pen');
    expect((json['points'] as List).length, 2);
    // Basincsiz darbe [x, y] ciftleri uretir (eski format korunur).
    expect((json['points'] as List).first, hasLength(2));
  });

  test('Stroke basinc JSON round-trip ([x,y,p] uclusu)', () {
    final s = Stroke(
      page: 1,
      kind: 'pen',
      color: 0xFF000000,
      width: 0.004,
      points: [const Offset(0.1, 0.2), const Offset(0.3, 0.4)],
      pressures: [0.3, 0.8],
    );
    final json = s.toJson();
    final points = json['points'] as List;
    expect(points.first, hasLength(3));
    expect(points[1][2], 0.8);

    final parsed = Stroke.fromJson({
      'page': 1,
      'kind': 'pen',
      'color': 0xFF000000,
      'width': 0.004,
      'points': points,
    });
    expect(parsed.pressures, isNotNull);
    expect(parsed.pressures![0], closeTo(0.3, 1e-9));
    expect(parsed.points[1].dy, closeTo(0.4, 1e-9));
  });

  test('Stroke.fromJson eski [x,y] formati basincsiz okunur', () {
    final parsed = Stroke.fromJson({
      'page': 1,
      'kind': 'pen',
      'color': 0xFF000000,
      'width': 0.004,
      'points': [
        [0.1, 0.2],
        [0.3, 0.4],
      ],
    });
    expect(parsed.pressures, isNull);
    expect(parsed.points.length, 2);
  });

  test('PdfDoc.fromJson', () {
    final d = PdfDoc.fromJson({
      'id': 'abc',
      'name': 'Test',
      'relative_path': 'x/Test.pdf',
      'size': 100,
      'modified': 123,
    });
    expect(d.id, 'abc');
    expect(d.relativePath, 'x/Test.pdf');
  });

  test('PdfDoc progress fields parse', () {
    final d = PdfDoc.fromJson({
      'id': 'abc',
      'name': 'Test',
      'relative_path': 'x/Test.pdf',
      'size': 100,
      'modified': 123,
      'page_count': 200,
      'current_page': 50,
    });
    expect(d.pageCount, 200);
    expect(d.currentPage, 50);
  });

  test('ServerStatus parses health response', () {
    final s = ServerStatus.fromJson({
      'server_time_ms': 1,
      'uptime_s': 2,
      'db_size_bytes': 3,
      'pdf_count': 4,
      'pdf_total_bytes': 5,
      'indexed_docs': 6,
      'last_backup': null,
    }, 12);
    expect(s.reachable, isTrue);
    expect(s.latencyMs, 12);
    expect(s.pdfCount, 4);
  });

  test('SearchHit.toPdfDoc', () {
    final h = SearchHit(
      docId: 'id1',
      page: 5,
      snippet: '...',
      name: 'Ders',
      relativePath: 'a/Ders.pdf',
      size: 10,
      modified: 1,
    );
    final d = h.toPdfDoc();
    expect(d.id, 'id1');
    expect(d.name, 'Ders');
  });
}
