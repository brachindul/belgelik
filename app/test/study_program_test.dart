import 'package:flutter_test/flutter_test.dart';
import 'package:belgelik/models.dart';
import 'package:belgelik/study_program.dart';

void main() {
  test('trLower normalizes Turkish letters for matching', () {
    expect(trLower('İYUK'), 'iyuk');
    expect(trLower('IŞ İcra-İflas'), 'is icra-iflas');
    expect(trLower('Borçlar Özel MÖHUK'), 'borclar ozel mohuk');
  });

  test('filterPdfsForSubject matches any configured term', () {
    final docs = [
      PdfDoc(
        id: '1',
        name: 'Konu Anlatimi',
        relativePath: 'dersler/IYUK-ozet.pdf',
        size: 10,
        modified: 1,
        favorite: false,
      ),
      PdfDoc(
        id: '2',
        name: 'Medeni Hukuk',
        relativePath: 'medeni.pdf',
        size: 10,
        modified: 1,
        favorite: false,
      ),
    ];

    final matches = filterPdfsForSubject(docs, 'İYUK');

    expect(matches, hasLength(1));
    expect(matches.single.id, '1');
  });
}
