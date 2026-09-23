import 'package:flutter/material.dart';

import '../app_services.dart';
import '../local_store.dart';
import '../models.dart';
import 'reader_host_screen.dart';

class RecentScreen extends StatefulWidget {
  const RecentScreen({super.key});

  @override
  State<RecentScreen> createState() => _RecentScreenState();
}

class _RecentScreenState extends State<RecentScreen> {
  late Future<List<PdfDoc>> _future;
  final Set<String> _selected = {};

  @override
  void initState() {
    super.initState();
    _future = _loadRecent();
  }

  Future<List<PdfDoc>> _loadRecent() async {
    return LocalStore.getRecent(limit: 20);
  }

  void _refresh() {
    setState(() { _future = _loadRecent(); });
  }

  void _toggleSelection(PdfDoc doc) {
    setState(() {
      if (_selected.contains(doc.id)) {
        _selected.remove(doc.id);
      } else {
        _selected.add(doc.id);
      }
    });
  }

  Future<void> _deleteSelected() async {
    final ids = _selected.toList();
    if (ids.isEmpty) return;
    // Yereli sil, ekrani hemen yenile; sunucu silmeleri arka planda.
    for (final id in ids) {
      await LocalStore.removeRecent(id);
    }
    if (!mounted) return;
    setState(() {
      _selected.clear();
      _future = _loadRecent();
    });
    for (final id in ids) {
      AppServices.instance.api.deleteRecent(id).catchError((_) {});
    }
  }

  Future<void> _deleteOne(PdfDoc doc) async {
    await LocalStore.removeRecent(doc.id);
    if (!mounted) return;
    setState(() {
      _selected.remove(doc.id);
      _future = _loadRecent();
    });
    AppServices.instance.api.deleteRecent(doc.id).catchError((_) {});
  }

  Widget _pdfTile(PdfDoc doc) {
    final scheme = Theme.of(context).colorScheme;
    final selected = _selected.contains(doc.id);
    final progress = _progressLine(doc);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 1),
      child: Material(
        color: selected
            ? scheme.primaryContainer
            : scheme.surfaceContainerLowest,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(6),
          side: BorderSide(
            color: selected
                ? scheme.primary
                : scheme.outlineVariant.withAlpha(140),
          ),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: () =>
              _selected.isEmpty ? _openPdf(doc) : _toggleSelection(doc),
          onLongPress: () => _toggleSelection(doc),
          child: SizedBox(
            height: progress == null ? 40 : 58,
            child: Row(
              children: [
                const SizedBox(width: 8),
                Icon(
                  selected ? Icons.check_circle : Icons.history,
                  color: scheme.primary,
                  size: 18,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        doc.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 12,
                        ),
                      ),
                      const SizedBox(height: 1),
                      Text(
                        doc.relativePath,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 10,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                      ?progress,
                    ],
                  ),
                ),
                if (_selected.isEmpty)
                  IconButton(
                    tooltip: 'Listeden sil',
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 32,
                      minHeight: 32,
                    ),
                    onPressed: () => _deleteOne(doc),
                    icon: const Icon(Icons.close, size: 18),
                  )
                else
                  Checkbox(
                    value: selected,
                    visualDensity: VisualDensity.compact,
                    onChanged: (_) => _toggleSelection(doc),
                  ),
                const SizedBox(width: 4),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget? _progressLine(PdfDoc doc) {
    final total = doc.pageCount;
    final current = doc.currentPage;
    if (total == null || current == null || total <= 0) return null;
    final done = current >= total;
    final value = (current / total).clamp(0.0, 1.0);
    return Padding(
      padding: const EdgeInsets.only(top: 3),
      child: Row(
        children: [
          Expanded(child: LinearProgressIndicator(value: value, minHeight: 3)),
          const SizedBox(width: 6),
          Text(
            done ? 'Bitti' : '%${(value * 100).round()}',
            style: const TextStyle(fontSize: 9),
          ),
        ],
      ),
    );
  }

  Future<void> _openPdf(PdfDoc doc) async {
    await LocalStore.markRecent(doc.id);
    try {
      await AppServices.instance.api.markRecent(doc.id);
      await LocalStore.clearRecentDirty(doc.id);
    } catch (_) {}
    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => ReaderHostScreen(doc: doc)),
    );
    if (mounted) _refresh();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          _selected.isEmpty ? 'Son açılanlar' : '${_selected.length} seçildi',
        ),
        leading: _selected.isEmpty
            ? null
            : IconButton(
                tooltip: 'Seçimi kapat',
                onPressed: () => setState(_selected.clear),
                icon: const Icon(Icons.close),
              ),
        actions: [
          if (_selected.isNotEmpty)
            IconButton(
              tooltip: 'Listeden sil',
              onPressed: _deleteSelected,
              icon: const Icon(Icons.delete_outline),
            ),
        ],
      ),
      body: FutureBuilder<List<PdfDoc>>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(child: Text('Hata: ${snapshot.error}'));
          }
          final items = snapshot.data!;
          _selected.removeWhere((id) => !items.any((doc) => doc.id == id));
          if (items.isEmpty) {
            return const Center(child: Text('Son açılan PDF yok'));
          }
          return RefreshIndicator(
            onRefresh: () async => _refresh(),
            child: ListView(
              padding: const EdgeInsets.symmetric(vertical: 6),
              children: [for (final doc in items) _pdfTile(doc)],
            ),
          );
        },
      ),
    );
  }
}
