import 'package:flutter_test/flutter_test.dart';
import 'package:belgelik/mevzuat_citations.dart';

void main() {
  test('relative citation suffix variants resolve to current law', () {
    for (final suffix in ['nci', 'ncı', 'ncu', 'ncü', 'inci', 'ıncı', 'uncu', 'üncü']) {
      final hits = findLegislationCitations('bu Kanunun 12 $suffix maddesi uygulanır', '6098');
      expect(hits, hasLength(1), reason: suffix);
      expect(hits.single.lawNo, '6098');
      expect(hits.single.articleNo, '12');
    }
  });

  test('cross-law citation resolves explicit law and article', () {
    final hit = findLegislationCitations('6100 sayılı Kanunun 353 üncü maddesi', '6098').single;
    expect(hit.lawNo, '6100');
    expect(hit.articleNo, '353');
  });

  test('ambiguous same-article phrase is deliberately not linked', () {
    expect(findLegislationCitations('aynı maddenin ikinci fıkrası', '6098'), isEmpty);
  });
}
