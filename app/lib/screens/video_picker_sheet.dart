import 'package:flutter/material.dart';

import '../app_services.dart';
import '../models.dart';
import '../study_program.dart';

/// Yandan video acmak icin kutuphanedeki videolari arama ile listeleyen secici
/// (pdf_picker_sheet'in aynasi). [relatedPdf] verilirse, PDF'in konusuyla
/// eslesen videolar once filtrelenmis gosterilir ("Tümü" ile kaldirilabilir).
/// Secilen VideoDoc'u dondurur (iptal edilirse null).
Future<VideoDoc?> showVideoPicker(BuildContext context, {PdfDoc? relatedPdf}) {
  return showModalBottomSheet<VideoDoc>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => _VideoPickerSheet(relatedPdf: relatedPdf),
  );
}

class _VideoPickerSheet extends StatefulWidget {
  final PdfDoc? relatedPdf;

  const _VideoPickerSheet({this.relatedPdf});

  @override
  State<_VideoPickerSheet> createState() => _VideoPickerSheetState();
}

class _VideoPickerSheetState extends State<_VideoPickerSheet> {
  late Future<List<VideoDoc>> _future;
  String _query = '';
  String? _subject;
  bool _subjectFilterOn = true;

  @override
  void initState() {
    super.initState();
    final p = widget.relatedPdf;
    if (p != null) _subject = subjectForPdf(p);
    _future = AppServices.instance.api.listVideos();
  }

  List<VideoDoc> _filter(List<VideoDoc> docs) {
    var list = [...docs];
    list.sort(
      (a, b) => trLower(a.relativePath).compareTo(trLower(b.relativePath)),
    );
    final subject = _subject;
    if (subject != null && _subjectFilterOn) {
      list = filterVideosForSubject(list, subject);
    }
    if (_query.trim().isEmpty) return list;
    final q = trLower(_query);
    return list
        .where((d) => trLower('${d.name} ${d.relativePath}').contains(q))
        .toList();
  }

  static String _fmtDuration(int sec) {
    final h = sec ~/ 3600;
    final m = (sec % 3600) ~/ 60;
    return h > 0 ? '${h}s ${m}dk' : '${m}dk';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DraggableScrollableSheet(
      initialChildSize: 0.85,
      maxChildSize: 0.95,
      minChildSize: 0.5,
      expand: false,
      builder: (_, scrollController) {
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Yanda açılacak videoyu seç',
                      style: Theme.of(context)
                          .textTheme
                          .titleMedium
                          ?.copyWith(fontWeight: FontWeight.bold),
                    ),
                  ),
                  if (_subject != null)
                    FilterChip(
                      label: Text(
                        _subjectFilterOn ? _subject! : 'Tümü',
                      ),
                      selected: _subjectFilterOn,
                      avatar: Icon(
                        _subjectFilterOn
                            ? Icons.filter_alt
                            : Icons.filter_alt_off,
                        size: 16,
                      ),
                      onSelected: (v) => setState(() => _subjectFilterOn = v),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: TextField(
                autofocus: false,
                decoration: InputDecoration(
                  hintText: 'Video ara…',
                  prefixIcon: const Icon(Icons.search),
                  isDense: true,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                onChanged: (v) => setState(() => _query = v),
              ),
            ),
            Expanded(
              child: FutureBuilder<List<VideoDoc>>(
                future: _future,
                builder: (context, snap) {
                  if (snap.connectionState != ConnectionState.done) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  if (snap.hasError) {
                    return const Center(
                      child: Text('Video listesi alınamadı (sunucu kapalı?)'),
                    );
                  }
                  final docs = _filter(snap.data ?? const []);
                  if (docs.isEmpty) {
                    return Center(
                      child: _subject != null && _subjectFilterOn
                          ? const Text('Bu konuda video bulunamadı')
                          : const Text('Video bulunamadı'),
                    );
                  }
                  return ListView.builder(
                    controller: scrollController,
                    itemCount: docs.length,
                    itemBuilder: (context, i) {
                      final d = docs[i];
                      final dur = d.durationSec;
                      return ListTile(
                        leading: Icon(
                          Icons.play_circle_outline,
                          color: scheme.primary,
                        ),
                        title: Text(
                          d.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          dur == null
                              ? d.relativePath
                              : '${d.relativePath} · ${_fmtDuration(dur)}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        onTap: () => Navigator.pop(context, d),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }
}
