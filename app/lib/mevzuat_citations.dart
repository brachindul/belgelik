class LegislationCitation {
  final int start, end;
  final String text, lawNo, articleNo;
  const LegislationCitation({required this.start, required this.end, required this.text, required this.lawNo, required this.articleNo});
}

final RegExp _citationPattern = RegExp(
  r'(?:\b\d{4}\s+sayılı\s+Kanunun\s+\d+\s+(?:nci|ncı|ncu|ncü|inci|ıncı|uncu|üncü)\s+maddesi\b|\bbu\s+Kanunun\s+\d+\s+(?:nci|ncı|ncu|ncü|inci|ıncı|uncu|üncü)\s+maddesi\b)',
  caseSensitive: false,
);

List<LegislationCitation> findLegislationCitations(String text, String currentLawNo) {
  return [
    for (final match in _citationPattern.allMatches(text))
      (() {
        final citation = match.group(0)!;
        final numbers = RegExp(r'\d+').allMatches(citation).map((m) => m.group(0)!).toList();
        final relative = citation.toLowerCase().startsWith('bu');
        return LegislationCitation(start: match.start, end: match.end, text: citation, lawNo: relative ? currentLawNo : numbers.first, articleNo: relative ? numbers.first : numbers[1]);
      })(),
  ];
}
