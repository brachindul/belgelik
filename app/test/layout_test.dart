import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:belgelik/screens/reader_screen.dart';

/// AKADEMI ANAYASA PDF'inin gercek olculeri: 260 sayfa govde, 2 sayfa buyuk.
const _govde = Size(566.9, 793.7);
const _buyuk = Size(600, 847);

void main() {
  group('buildPageLayoutForSizes - twoVertical', () {
    test('her spread belge genisligini tam doldurur', () {
      final layout = buildPageLayoutForSizes(
        List.filled(6, _govde),
        8,
        ViewMode.twoVertical,
      );
      final w = layout.documentSize.width;
      for (var s = 0; s < 3; s++) {
        expect(layout.pageLayouts[s * 2].left, 0);
        expect(layout.pageLayouts[s * 2 + 1].right, closeTo(w, 0.001));
      }
    });

    test('belge genisligi govde spreadinin dogal genisligidir', () {
      final layout = buildPageLayoutForSizes(
        List.filled(4, _govde),
        8,
        ViewMode.twoVertical,
      );
      expect(layout.documentSize.width, closeTo(566.9 * 2 + 2, 0.05));
    });

    test('iki sayfa arasinda yalnizca 2pt sirt boslugu var', () {
      final layout = buildPageLayoutForSizes(
        List.filled(2, _govde),
        8,
        ViewMode.twoVertical,
      );
      expect(
        layout.pageLayouts[1].left - layout.pageLayouts[0].right,
        closeTo(2, 0.01),
      );
    });

    test('birkac buyuk sayfa butun kitabi kucultmez', () {
      // Regresyon: belge genisligi en genis spreade gore secilince 260 sayfalik
      // govde %5.8 kuculup iki yaninda bosluk birakiyordu; pdfrx o boslugu
      // kaydirilabilir yaptigi icin sayfa parmakla saga sola oynuyordu.
      final pages = [
        ...List.filled(20, _govde),
        _buyuk,
        _buyuk,
        ...List.filled(20, _govde),
      ];
      final layout = buildPageLayoutForSizes(pages, 8, ViewMode.twoVertical);
      expect(layout.documentSize.width, closeTo(566.9 * 2 + 2, 0.05));
      // Govde sayfalari dogal olcusunde, kirpilmadan yerlesir.
      expect(layout.pageLayouts[0].width, closeTo(566.9, 0.05));
      // Buyuk spread satiri doldurmak icin kucultulur, disari tasmaz.
      final buyukSol = layout.pageLayouts[20];
      final buyukSag = layout.pageLayouts[21];
      expect(buyukSol.left, 0);
      expect(buyukSag.right, closeTo(layout.documentSize.width, 0.001));
      expect(buyukSol.width, lessThan(600));
      // Oran korunur.
      expect(buyukSol.height / buyukSol.width, closeTo(847 / 600, 0.001));
    });

    test('hicbir sayfa belge sinirlarinin disina tasmaz', () {
      final pages = [_govde, _buyuk, _buyuk, _govde, _govde, _govde];
      final layout = buildPageLayoutForSizes(pages, 8, ViewMode.twoVertical);
      for (final r in layout.pageLayouts) {
        expect(r.left, greaterThanOrEqualTo(-0.001));
        expect(r.right, lessThanOrEqualTo(layout.documentSize.width + 0.001));
      }
    });

    test('tek sayili belgede son sayfa sol yarida kalir', () {
      final layout = buildPageLayoutForSizes(
        List.filled(3, _govde),
        8,
        ViewMode.twoVertical,
      );
      expect(layout.pageLayouts.length, 3);
      expect(layout.pageLayouts[2].left, 0);
      expect(
        layout.pageLayouts[2].width,
        closeTo(layout.documentSize.width / 2, 2),
      );
    });

    test('spreadler dikeyde margin kadar aralikli akar', () {
      final layout = buildPageLayoutForSizes(
        List.filled(4, _govde),
        8,
        ViewMode.twoVertical,
      );
      expect(layout.pageLayouts[0].top, 8);
      expect(layout.pageLayouts[2].top, closeTo(8 + 793.7 + 8, 0.01));
    });
  });

  group('buildPageLayoutForSizes - single', () {
    test('sayfa belge genisligini tam doldurur, yatay bosluk yok', () {
      final layout = buildPageLayoutForSizes(
        [...List.filled(3, _govde), _buyuk],
        8,
        ViewMode.single,
      );
      expect(layout.documentSize.width, closeTo(566.9, 0.05));
      for (final r in layout.pageLayouts) {
        expect(r.left, 0);
        expect(r.width, closeTo(layout.documentSize.width, 0.001));
      }
    });
  });

  group('parseViewMode', () {
    test('bilinmeyen deger auto dondurur', () {
      expect(parseViewMode('single'), ViewMode.single);
      expect(parseViewMode('twoVertical'), ViewMode.twoVertical);
      expect(parseViewMode('sacma'), ViewMode.auto);
    });
  });
}
