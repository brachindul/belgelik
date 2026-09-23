// Kalem ve fosforlu renk paletleri ile varsayilan kalinliklar.
// Hem PDF okuyucu (reader_page_layout) hem not editoru (note_editor_screen)
// buradan beslenir, boylece ayni palet uygulamanin her yerinde kullanilir.

/// Metin/kalem icin renk paleti (ARGB int). reader_page_layout ile ayni.
const List<int> kPenPalette = [
  0xFFE53935,
  0xFFD81B60,
  0xFF8E24AA,
  0xFF5E35B1,
  0xFF1E88E5,
  0xFF00897B,
  0xFF43A047,
  0xFFF4511E,
  0xFFFB8C00,
  0xFF6D4C41,
  0xFF000000,
  0xFF546E7A,
];

/// Fosforlu renk paleti (yari saydam ARGB). reader_page_layout ile ayni.
const List<int> kHighlightPalette = [
  0x88FFC107,
  0x66FFEB3B,
  0x5566BB6A,
  0x5542A5F5,
  0x55EC407A,
  0x55FF7043,
  0x55AB47BC,
];

/// Kalem kalinligi: sayfa/blok genisliginin orani (0..1).
const double kDefaultPenWidth = 0.004;
const double kDefaultHighlightWidth = 0.022;

/// Not editorundeki el yazisi icin varsayilan blok yuksekligi (piksel).
const double kInkBlockHeight = 220.0;
