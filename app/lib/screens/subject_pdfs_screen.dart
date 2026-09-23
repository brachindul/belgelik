import 'package:flutter/material.dart';

import '../app_services.dart';
import '../local_store.dart';
import '../mevzuat_models.dart';
import '../models.dart';
import '../study_program.dart';
import 'content_search_screen.dart';
import 'home_shell.dart';
import 'legislation_screen.dart';
import 'reader_host_screen.dart';
import 'video_player_screen.dart';

class SubjectPdfsScreen extends StatefulWidget {
  final String subject;

  const SubjectPdfsScreen({super.key, required this.subject});

  @override
  State<SubjectPdfsScreen> createState() => _SubjectPdfsScreenState();
}

class _SubjectPdfsScreenState extends State<SubjectPdfsScreen> {
  late Future<({List<PdfDoc> pdfs, List<VideoDoc> videos})> _future;
  late Future<List<LegislationSummary>> _lawsFuture;
  final Set<String> _manualDocIds = {};

  List<String> get _terms => searchTermsForSubject(widget.subject);

  @override
  void initState() {
    super.initState();
    _future = _loadAll();
    _lawsFuture = _loadLaws();
    _refreshOnlineInBackground();
  }

  Future<List<LegislationSummary>> _loadLaws() async {
    final numbers = legislationForSubject(widget.subject);
    if (numbers.isEmpty) return const [];
    final local = await LocalStore.listLegislation();
    var laws = local.where((l) => numbers.contains(l.mevzuatNo)).toList();
    try {
      final remote = await AppServices.instance.api.listLegislation();
      final downloaded = {for (final x in local) x.mevzuatNo: x.downloadedAtMs};
      laws = remote
          .where((l) => numbers.contains(l.mevzuatNo))
          .map((x) => LegislationSummary(
                mevzuatNo: x.mevzuatNo,
                ad: x.ad,
                kisaAd: x.kisaAd,
                tur: x.tur,
                snapshotVersion: x.snapshotVersion,
                articleCount: x.articleCount,
                size: x.size,
                downloadedAtMs: downloaded[x.mevzuatNo],
              ))
          .toList();
    } catch (_) {}
    return laws;
  }

  Future<void> _openLaw(LegislationSummary law) async {
    if (law.downloadedAtMs == null) {
      final messenger = ScaffoldMessenger.of(context);
      try {
        messenger.showSnackBar(SnackBar(content: Text('${law.kisaAd} indiriliyor...')));
        final bundle = await AppServices.instance.api.downloadLegislationBundle(law.mevzuatNo);
        await LocalStore.installLegislation(bundle);
        if (mounted) setState(() { _lawsFuture = _loadLaws(); });
      } catch (e) {
        messenger.showSnackBar(SnackBar(content: Text('İndirme başarısız: $e')));
        return;
      }
    }
    if (!mounted) return;
    Navigator.push(context, MaterialPageRoute(builder: (_) => LegislationArticlesScreen(law: law)));
  }

  Widget _lawTile(LegislationSummary law) {
    final scheme = Theme.of(context).colorScheme;
    final downloaded = law.downloadedAtMs != null;
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
          leading: Icon(Icons.menu_book, color: scheme.primary),
          title: Text(
            '${law.kisaAd}  •  ${law.ad}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          subtitle: Text('${law.articleCount} madde${downloaded ? '  •  Çevrimdışı hazır' : '  •  İndirilecek'}'),
          trailing: Icon(downloaded ? Icons.chevron_right : Icons.download),
          onTap: () => _openLaw(law),
        ),
      ),
    );
  }

  Future<({List<PdfDoc> pdfs, List<VideoDoc> videos})> _loadAll() async {
    final pdfs = await _loadMatches();
    List<VideoDoc> videos = const [];
    try {
      final all = await AppServices.instance.api.listVideos();
      videos = filterVideosForSubject(all, widget.subject);
    } catch (_) {}
    return (pdfs: pdfs, videos: videos);
  }

  Future<List<PdfDoc>> _loadMatches() async {
    final localDocs = await LocalStore.listPdfDocs();
    final manualDocs = await LocalStore.getAssociatedPdfsForSubject(widget.subject);

    _manualDocIds.clear();
    for (final doc in manualDocs) {
      _manualDocIds.add(doc.id);
    }

    List<PdfDoc> baseDocs = localDocs;

    if (localDocs.isEmpty) {
      try {
        final docs = await AppServices.instance.api.listPdfs();
        await LocalStore.upsertPdfDocs(docs);
        baseDocs = docs;
      } catch (_) {}
    }

    final autoMatches = filterPdfsForSubject(baseDocs, widget.subject);

    // Combine and remove duplicates
    final combined = <String, PdfDoc>{};
    for (final doc in autoMatches) {
      combined[doc.id] = doc;
    }
    for (final doc in manualDocs) {
      combined[doc.id] = doc;
    }

    final sortedList = combined.values.toList();
    sortedList.sort((a, b) => trLower(a.name).compareTo(trLower(b.name)));
    return sortedList;
  }

  void _refreshOnlineInBackground() {
    AppServices.instance.api.listPdfs()
        .then((docs) async {
          await LocalStore.upsertPdfDocs(docs);
          if (!mounted) return;
          setState(() {
            _future = _loadAll();
          });
        })
        .catchError((_) {});
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
  }

  void _openContentSearch() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ContentSearchScreen(initialQuery: _terms.first),
      ),
    );
  }

  Future<void> _removePdf(String docId) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('İlişkiyi kaldır'),
        content: const Text('Bu PDF\'in bu dersle olan ilişkisini kaldırmak istiyor musunuz? (Dosya silinmez)'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('İptal'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Kaldır'),
          ),
        ],
      ),
    );
    if (confirm == true) {
      await LocalStore.removePdfFromSubject(widget.subject, docId);
      setState(() {
        _future = _loadAll();
      });
    }
  }

  Future<void> _showAddPdfDialog() async {
    final allDocs = await LocalStore.listPdfDocs();
    final currentDocs = (await _future).pdfs;
    final currentIds = currentDocs.map((d) => d.id).toSet();

    // Filter out PDFs that are already in the list
    final availableDocs = allDocs.where((d) => !currentIds.contains(d.id)).toList();

    if (!mounted) return;

    if (availableDocs.isEmpty) {
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Eklenecek PDF yok'),
          content: const Text('Kütüphanedeki tüm PDF\'ler zaten bu derse atanmış durumda.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Tamam'),
            ),
          ],
        ),
      );
      return;
    }

    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        return DraggableScrollableSheet(
          initialChildSize: 0.8,
          maxChildSize: 0.95,
          minChildSize: 0.5,
          expand: false,
          builder: (_, scrollController) {
            return Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Text(
                    'Derse PDF Ekle',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                  ),
                ),
                Expanded(
                  child: ListView.builder(
                    controller: scrollController,
                    itemCount: availableDocs.length,
                    itemBuilder: (context, index) {
                      final doc = availableDocs[index];
                      return ListTile(
                        leading: const Icon(Icons.picture_as_pdf_outlined),
                        title: Text(
                          doc.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(doc.relativePath),
                        onTap: () async {
                          await LocalStore.associatePdfWithSubject(
                            widget.subject,
                            doc.id,
                          );
                          if (!ctx.mounted) return;
                          Navigator.pop(ctx);
                          setState(() {
                            _future = _loadAll();
                          });
                        },
                      );
                    },
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _pdfTile(PdfDoc doc) {
    final scheme = Theme.of(context).colorScheme;
    final isManual = _manualDocIds.contains(doc.id);
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
          leading: Icon(Icons.picture_as_pdf, color: scheme.primary),
          title: Text(
            doc.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          subtitle: Text(
            '${(doc.size / 1024 / 1024).toStringAsFixed(1)} MB  -  ${doc.relativePath}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: isManual
              ? IconButton(
                  icon: const Icon(Icons.delete_outline, color: Colors.red),
                  onPressed: () => _removePdf(doc.id),
                )
              : const Icon(Icons.chevron_right),
          onTap: () => _openPdf(doc),
        ),
      ),
    );
  }

  void _openVideo(VideoDoc doc) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => VideoPlayerScreen(doc: doc)),
    );
  }

  Widget _videoTile(VideoDoc doc) {
    final scheme = Theme.of(context).colorScheme;
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
          leading: Icon(Icons.play_circle_outline, color: scheme.primary),
          title: Text(
            doc.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          subtitle: Text(
            '${(doc.size / 1024 / 1024).toStringAsFixed(1)} MB  -  ${doc.relativePath}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _openVideo(doc),
        ),
      ),
    );
  }

  Widget _sectionHeader(String title, int count, IconData icon) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 6),
      child: Row(
        children: [
          Icon(icon, size: 18, color: scheme.onSurfaceVariant),
          const SizedBox(width: 8),
          Text(
            title,
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                  color: scheme.onSurfaceVariant,
                ),
          ),
          const SizedBox(width: 6),
          Text(
            '($count)',
            style: TextStyle(color: scheme.onSurfaceVariant.withAlpha(150)),
          ),
        ],
      ),
    );
  }

  Widget _emptyState() {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.search_off, size: 48, color: scheme.outline),
            const SizedBox(height: 12),
            Text(
              'Bu ders için PDF bulunamadı',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              'Dosya adında şu terimler arandı: ${_terms.join(', ')}',
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 18),
            FilledButton.icon(
              onPressed: () {
                // Ana iskeletteki kutuphane sekmesine don (kopya ekran acma).
                Navigator.of(context).popUntil((r) => r.isFirst);
                HomeShell.tabRequest.value = 0;
              },
              icon: const Icon(Icons.search),
              label: const Text('Kütüphanede ara'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.subject),
        actions: [
          IconButton(
            tooltip: 'İçerikte ara',
            onPressed: _openContentSearch,
            icon: const Icon(Icons.manage_search),
          ),
        ],
      ),
      body: FutureBuilder<({List<PdfDoc> pdfs, List<VideoDoc> videos})>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return Center(child: Text('Hata: ${snap.error}'));
          }
          final pdfs = snap.data?.pdfs ?? const <PdfDoc>[];
          final videos = snap.data?.videos ?? const <VideoDoc>[];
          final hasLaws = legislationForSubject(widget.subject).isNotEmpty;
          if (pdfs.isEmpty && videos.isEmpty && !hasLaws) return _emptyState();
          final children = <Widget>[
            if (hasLaws)
              FutureBuilder<List<LegislationSummary>>(
                future: _lawsFuture,
                builder: (context, lawSnap) {
                  final laws = lawSnap.data ?? const <LegislationSummary>[];
                  if (laws.isEmpty) return const SizedBox.shrink();
                  return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    _sectionHeader('Kanunlar', laws.length, Icons.menu_book_outlined),
                    for (final law in laws) _lawTile(law),
                  ]);
                },
              ),
            if (videos.isNotEmpty) ...[
              _sectionHeader('Videolar', videos.length, Icons.video_library_outlined),
              for (final v in videos) _videoTile(v),
            ],
            if (pdfs.isNotEmpty) ...[
              _sectionHeader('PDF\'ler', pdfs.length, Icons.picture_as_pdf_outlined),
              for (final d in pdfs) _pdfTile(d),
            ],
          ];
          return ListView(
            padding: const EdgeInsets.fromLTRB(0, 4, 0, 80),
            children: children,
          );
        },
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _showAddPdfDialog,
        tooltip: 'PDF Ekle',
        child: const Icon(Icons.add),
      ),
    );
  }
}
