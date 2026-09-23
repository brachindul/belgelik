part of 'reader_screen.dart';

ViewMode parseViewMode(String s) {
  switch (s) {
    case 'single':
      return ViewMode.single;
    case 'twoVertical':
      return ViewMode.twoVertical;
    default:
      return ViewMode.auto;
  }
}

PdfPageLayout buildPageLayout(
  List<PdfPage> pages,
  double margin,
  ViewMode mode,
) => buildPageLayoutForSizes(
      pages.map((p) => Size(p.width, p.height)).toList(),
      margin,
      mode,
    );

/// Listedeki en sik gorulen degeri dondurur (0.1 hassasiyetinde gruplayarak).
///
/// Kitaplarda birkac sayfa (kapak, tablo eki) govdeden farkli olcude olabiliyor.
/// Belge genisligini bunlara gore secmek butun kitabi kucultur; bu yuzden
/// "cogunluk" olcusu esas alinir.
double _mostCommon(List<double> values) {
  final counts = <int, int>{};
  for (final v in values) {
    final key = (v * 10).round();
    counts[key] = (counts[key] ?? 0) + 1;
  }
  var bestKey = counts.keys.first;
  var bestCount = 0;
  counts.forEach((key, count) {
    // Esitlikte genis olani sec: kirpma yerine kucultme tarafinda kal.
    if (count > bestCount || (count == bestCount && key > bestKey)) {
      bestKey = key;
      bestCount = count;
    }
  });
  return bestKey / 10;
}

/// [buildPageLayout]'in saf hali: PdfPage yerine sayfa olculeriyle calisir,
/// boylece test edilebilir.
///
/// Iki kural: (1) belgenin kenarinda yatay bosluk yoktur, (2) her satir belge
/// genisligini tam doldurur. Ikisi birlikte, sayfa ekrana sigdiginda yatayda
/// hic bos alan kalmamasini saglar - pdfrx bos alani kaydirilabilir yapiyor ve
/// sayfa parmakla saga sola oynuyordu.
PdfPageLayout buildPageLayoutForSizes(
  List<Size> pages,
  double margin,
  ViewMode mode,
) {
  final rects = <Rect>[];

  if (mode == ViewMode.single) {
    final docW = _mostCommon(pages.map((p) => p.width).toList());
    double y = margin;
    for (final p in pages) {
      final scale = docW / p.width;
      final h = p.height * scale;
      rects.add(Rect.fromLTWH(0, y, docW, h));
      y += h + margin;
    }
    return PdfPageLayout(pageLayouts: rects, documentSize: Size(docW, y));
  }

  // twoVertical: cift sayfa yan yana, spread'ler dikey akar (yatay kaydirma yok).
  const gap = 2.0;
  final spreadCount = (pages.length + 1) ~/ 2;

  Size leftOf(int s) => pages[s * 2];
  Size? rightOf(int s) => s * 2 + 1 < pages.length ? pages[s * 2 + 1] : null;

  // Spread'in dogal genisligi: iki sayfa + aralarindaki sirt. Tek kalan son
  // sayfa, cifti varmis gibi olculur ki sol yarida kalsin.
  final naturalW = <double>[
    for (var s = 0; s < spreadCount; s++)
      leftOf(s).width + gap + (rightOf(s)?.width ?? leftOf(s).width),
  ];
  final docW = _mostCommon(naturalW);

  double y = margin;
  for (var s = 0; s < spreadCount; s++) {
    final left = leftOf(s);
    final right = rightOf(s);
    // Her spread belge genisligine olceklenir; boylece govdeden farkli olcudeki
    // sayfalar da satiri tam doldurur, yanlarinda bosluk birakmaz.
    final scale = docW / naturalW[s];
    final leftW = left.width * scale;
    final leftH = left.height * scale;
    final rightW = (right?.width ?? 0) * scale;
    final rightH = (right?.height ?? 0) * scale;
    final rowH = max(leftH, rightH);

    rects.add(Rect.fromLTWH(0, y + (rowH - leftH) / 2, leftW, leftH));
    if (right != null) {
      rects.add(
        Rect.fromLTWH(
          leftW + gap * scale,
          y + (rowH - rightH) / 2,
          rightW,
          rightH,
        ),
      );
    }
    y += rowH + margin;
  }

  return PdfPageLayout(pageLayouts: rects, documentSize: Size(docW, y));
}

/// Fit zoom'a bu kadar yakin bir zoom "tam sigmis" sayilir ve fit'e oturtulur.
/// Pinch sirasinda olusan %1-2'lik sapmalar yatayda oynama olarak hissediliyor.
const _fitSnapTolerance = 0.02;

/// Goruntulenen alani belge sinirlarina oturtur.
///
/// pdfrx'in varsayilani, icerik ekrandan darsa artan boslugu kaydirilabilir
/// alan olarak veriyor (`_adjustBoundaryMargins`); bu yuzden ekrana sigan bir
/// spread parmakla saga sola oynayabiliyordu. Burada sigan eksen ortada
/// sabitlenir, tasan eksen ise normal sekilde belge icine kirpilir - yani
/// zoom yapildiginda yatay gezinme calismaya devam eder.
Matrix4 normalizeReaderMatrix(
  Matrix4 matrix,
  Size viewSize,
  PdfPageLayout layout,
  PdfViewerController? controller,
) {
  if (controller == null || !controller.isReady) return matrix;
  final doc = layout.documentSize;
  // boundaryMargin verilmedigi icin pdfrx'in varsayilanindaki gibi fit
  // zoom'un altina inilmesine izin verilmez.
  var zoom = max(matrix.zoom, controller.minScale);
  final fitZoom = doc.width > 0 ? viewSize.width / doc.width : zoom;
  if ((zoom - fitZoom).abs() <= fitZoom * _fitSnapTolerance) zoom = fitZoom;

  final pos = matrix.calcPosition(viewSize);
  final halfW = viewSize.width / 2 / zoom;
  final halfH = viewSize.height / 2 / zoom;
  // Kayan nokta hatasi yuzunden "tam sigan" durumun tasma sayilmamasi icin
  // yarim piksellik pay birakilir.
  final slackW = halfW * 2 - doc.width;
  final slackH = halfH * 2 - doc.height;
  final x = slackW > -0.5 ? doc.width / 2 : pos.dx.clamp(halfW, doc.width - halfW);
  final y =
      slackH > -0.5 ? doc.height / 2 : pos.dy.clamp(halfH, doc.height - halfH);
  return controller.calcMatrixFor(Offset(x, y), zoom: zoom, viewSize: viewSize);
}

// Kalem/fosforlu paletler ve varsayilan kalinliklar artık pen_palette.dart'ta
// tanimli; reader_screen.dart import eder (bu dosya onun 'part'ı oldugundan
// paylasir). Asagidaki sabitler oradan gelir: kPenPalette, kHighlightPalette,
// kDefaultPenWidth, kDefaultHighlightWidth.
