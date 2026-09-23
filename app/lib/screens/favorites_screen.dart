import 'package:flutter/material.dart';

import '../app_services.dart';
import '../local_store.dart';
import '../models.dart';
import 'reader_host_screen.dart';

class FavoritesScreen extends StatefulWidget {
  const FavoritesScreen({super.key});

  @override
  State<FavoritesScreen> createState() => _FavoritesScreenState();
}

class _FavoritesScreenState extends State<FavoritesScreen> {
  late Future<List<PdfDoc>> _future;

  @override
  void initState() {
    super.initState();
    _future = AppServices.instance.api.getFavorites();
  }

  void _refresh() {
    setState(() => _future = AppServices.instance.api.getFavorites());
  }

  Widget _pdfTile(PdfDoc doc) {
    final scheme = Theme.of(context).colorScheme;
    final progress = _progressLine(doc);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Material(
        color: scheme.surfaceContainerLowest,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(color: scheme.outlineVariant.withAlpha(140)),
        ),
        child: ListTile(
          minLeadingWidth: 32,
          leading: IconButton(
            tooltip: 'Favoriden cikar',
            icon: const Icon(Icons.star),
            color: Colors.amber.shade700,
            onPressed: () async {
              await LocalStore.setFavorite(doc.id, false, dirty: true);
              _refresh();
              try {
                await AppServices.instance.api.setFavorite(doc.id, false);
                await LocalStore.clearFavoriteDirty(doc.id);
              } catch (_) {}
            },
          ),
          title: Text(
            doc.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                doc.relativePath,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              ?progress,
            ],
          ),
          trailing: Icon(Icons.chevron_right, color: scheme.outline),
          onTap: () => _openPdf(doc),
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
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        children: [
          Expanded(child: LinearProgressIndicator(value: value)),
          const SizedBox(width: 8),
          Text(
            done ? 'Bitti' : '%${(value * 100).round()}',
            style: const TextStyle(fontSize: 11),
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
      appBar: AppBar(title: const Text('Favoriler')),
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
          if (items.isEmpty) {
            return const Center(child: Text('Favori PDF yok'));
          }
          return RefreshIndicator(
            onRefresh: () async => _refresh(),
            child: ListView(
              padding: const EdgeInsets.symmetric(vertical: 8),
              children: [for (final doc in items) _pdfTile(doc)],
            ),
          );
        },
      ),
    );
  }
}
