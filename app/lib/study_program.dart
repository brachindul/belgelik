import 'models.dart';

class ProgramDay {
  final int number;
  final String weekday;
  final String subject;

  const ProgramDay(this.number, this.weekday, this.subject);
}

final DateTime studyCycleStart = DateTime(2026, 6, 8);

const List<ProgramDay> studyProgramDays = [
  ProgramDay(1, 'Pazartesi', 'Anayasa'),
  ProgramDay(2, 'Salı', 'İdare'),
  ProgramDay(3, 'Çarşamba', 'İYUK'),
  ProgramDay(4, 'Perşembe', 'Medeni'),
  ProgramDay(5, 'Cuma', 'Borçlar Genel + Özel'),
  ProgramDay(6, 'Cumartesi', 'Ticaret'),
  ProgramDay(7, 'Pazar', 'Tarih'),
  ProgramDay(8, 'Pazartesi', 'HMK'),
  ProgramDay(9, 'Salı', 'İcra-İflas'),
  ProgramDay(10, 'Çarşamba', 'Ceza Genel'),
  ProgramDay(11, 'Perşembe', 'Ceza Özel'),
  ProgramDay(12, 'Cuma', 'CMK'),
  ProgramDay(13, 'Cumartesi', 'İş'),
  ProgramDay(14, 'Pazar', 'Milletlerarası'),
];

const Map<String, List<String>> subjectSearchTerms = {
  'Anayasa': ['anayasa'],
  'İdare': ['idare', 'idari'],
  'İYUK': ['iyuk', 'idari yargılama'],
  'Medeni': ['medeni', 'tmk'],
  'Borçlar Genel + Özel': ['borçlar', 'tbk'],
  'Ticaret': ['ticaret', 'ttk'],
  'Tarih': ['tarih', 'inkılap'],
  'HMK': ['hmk', 'hukuk muhakemeleri', 'usul'],
  'İcra-İflas': ['icra', 'iflas', 'iik'],
  'Ceza Genel': ['ceza genel', 'tck genel'],
  'Ceza Özel': ['ceza özel', 'tck özel'],
  'CMK': ['cmk', 'ceza muhakeme'],
  'İş': ['iş hukuku', 'iş kanunu', 'iş kamp'],
  'Milletlerarası': ['milletlerarası', 'devletler', 'möhuk'],
};

/// Ders programı konusu → ilgili mevzuat numaraları (mevzuat kütüphanesi).
/// İdare ve Tarih için müstakil kanun yok.
const Map<String, List<String>> subjectLegislation = {
  'Anayasa': ['2709'],
  'İYUK': ['2577'],
  'Medeni': ['4721'],
  'Borçlar Genel + Özel': ['6098'],
  'Ticaret': ['6102'],
  'HMK': ['6100'],
  'İcra-İflas': ['2004'],
  'Ceza Genel': ['5237'],
  'Ceza Özel': ['5237'],
  'CMK': ['5271'],
  'İş': ['4857'],
  'Milletlerarası': ['5718'],
};

List<String> legislationForSubject(String subject) =>
    subjectLegislation[subject] ?? const [];

int activeProgramIndex(DateTime now) {
  final today = DateTime(now.year, now.month, now.day);
  final start = DateTime(
    studyCycleStart.year,
    studyCycleStart.month,
    studyCycleStart.day,
  );
  final diff = today.difference(start).inDays;
  return diff.remainder(studyProgramDays.length);
}

String todaysSubject([DateTime? now]) =>
    studyProgramDays[activeProgramIndex(now ?? DateTime.now())].subject;

String trLower(String value) {
  return value
      .replaceAll('İ', 'i')
      .replaceAll('I', 'i')
      .replaceAll('ı', 'i')
      .replaceAll('Ğ', 'g')
      .replaceAll('ğ', 'g')
      .replaceAll('Ü', 'u')
      .replaceAll('ü', 'u')
      .replaceAll('Ş', 's')
      .replaceAll('ş', 's')
      .replaceAll('Ö', 'o')
      .replaceAll('ö', 'o')
      .replaceAll('Ç', 'c')
      .replaceAll('ç', 'c')
      .toLowerCase()
      .replaceAll('\u0307', '');
}

List<String> searchTermsForSubject(String subject) =>
    subjectSearchTerms[subject] ?? [subject];

bool pdfMatchesSubject(PdfDoc doc, String subject) {
  final haystack = trLower('${doc.name} ${doc.relativePath}');
  return searchTermsForSubject(
    subject,
  ).any((term) => haystack.contains(trLower(term)));
}

List<PdfDoc> filterPdfsForSubject(List<PdfDoc> docs, String subject) {
  final matches = docs.where((doc) => pdfMatchesSubject(doc, subject)).toList();
  matches.sort(
    (a, b) => trLower(a.relativePath).compareTo(trLower(b.relativePath)),
  );
  return matches;
}

bool videoMatchesSubject(VideoDoc doc, String subject) {
  final haystack = trLower('${doc.name} ${doc.relativePath}');
  return searchTermsForSubject(
    subject,
  ).any((term) => haystack.contains(trLower(term)));
}

List<VideoDoc> filterVideosForSubject(List<VideoDoc> docs, String subject) {
  final matches =
      docs.where((doc) => videoMatchesSubject(doc, subject)).toList();
  matches.sort(
    (a, b) => trLower(a.relativePath).compareTo(trLower(b.relativePath)),
  );
  return matches;
}

/// Bir video adi/yoluna bakarak ders programindaki konulardan hangisine ait
/// oldugunu tahmin eder (anahtar kelime eslesmesi). Eslesme yoksa null.
String? subjectForVideo(VideoDoc doc) {
  for (final day in studyProgramDays) {
    if (videoMatchesSubject(doc, day.subject)) return day.subject;
  }
  return null;
}

/// PDF adi/yolundan konuyu tahmin eder (subjectForVideo'nun aynasi).
String? subjectForPdf(PdfDoc doc) {
  for (final day in studyProgramDays) {
    if (pdfMatchesSubject(doc, day.subject)) return day.subject;
  }
  return null;
}
