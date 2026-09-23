import 'package:flutter/material.dart';

import '../app_services.dart';
import '../local_store.dart';
import '../models.dart';
import '../study_program.dart';

/// Yandan PDF acmak icin kutuphanedeki PDF'leri arama ile listeleyen secici.
/// [relatedVideo] verilirse, videonun konusuyla eslesen PDF'ler once
/// filtrelenmis olarak gosterilir (kullanici "Tümünü göster" ile kaldirabilir).
/// Secilen PdfDoc'u dondurur (iptal edilirse null).
Future<PdfDoc?> showPdfPicker(BuildContext context, {VideoDoc? relatedVideo}) {
  return showModalBottomSheet<PdfDoc>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => _PdfPickerSheet(relatedVideo: relatedVideo),
  );
}

class _PdfPickerSheet extends StatefulWidget {
  final VideoDoc? relatedVideo;

  const _PdfPickerSheet({this.relatedVideo});

  @override
  State<_PdfPickerSheet> createState() => _PdfPickerSheetState();
}

class _PdfPickerSheetState extends State<_PdfPickerSheet> {
  late Future<List<PdfDoc>> _future;
  String _query = '';
  String? _subject;
  bool _subjectFilterOn = true;

  @override
  void initState() {
    super.initState();
    final v = widget.relatedVideo;
    if (v != null) _subject = subjectForVideo(v);
    _future = _load();
  }

  Future<List<PdfDoc>> _load() async {
    final local = await LocalStore.listPdfDocs();
    if (local.isNotEmpty) return local;
    try {
      final docs = await AppServices.instance.api.listPdfs();
      await LocalStore.upsertPdfDocs(docs);
      return docs;
    } catch (_) {
      return local;
    }
  }

  List<PdfDoc> _filter(List<PdfDoc> docs) {
    var list = [...docs];
    list.sort((a, b) => trLower(a.relativePath).compareTo(trLower(b.relativePath)));
    final subject = _subject;
    if (subject != null && _subjectFilterOn) {
      list = filterPdfsForSubject(list, subject);
    }
    if (_query.trim().isEmpty) return list;
    final q = trLower(_query);
    return list
        .where((d) => trLower('${d.name} ${d.relativePath}').contains(q))
        .toList();
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
                      'Yanda açılacak PDF\'i seç',
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
                        _subjectFilterOn ? Icons.filter_alt : Icons.filter_alt_off,
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
                  hintText: 'PDF ara…',
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
              child: FutureBuilder<List<PdfDoc>>(
                future: _future,
                builder: (context, snap) {
                  if (snap.connectionState != ConnectionState.done) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  final docs = _filter(snap.data ?? const []);
                  if (docs.isEmpty) {
                    return Center(
                      child: _subject != null && _subjectFilterOn
                          ? const Text('Bu konuda PDF bulunamadı')
                          : const Text('PDF bulunamadı'),
                    );
                  }
                  return ListView.builder(
                    controller: scrollController,
                    itemCount: docs.length,
                    itemBuilder: (context, i) {
                      final d = docs[i];
                      return ListTile(
                        leading: Icon(Icons.picture_as_pdf, color: scheme.primary),
                        title: Text(
                          d.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          d.relativePath,
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
