import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../app_services.dart';
import '../local_store.dart';
import '../models.dart';
import '../study_program.dart';
import 'reader_host_screen.dart';
import 'video_player_screen.dart';

/// Tum video kutuphanesi (sunucudaki video-kutuphane klasoru).
/// - Ust kisimda "Son acilanlar" (izlemeye baslanmis videolar, son izlemeye gore).
/// - Her video adinin altinda izleme ilerleme cubugu.
class VideoLibraryScreen extends StatefulWidget {
  const VideoLibraryScreen({super.key});

  @override
  State<VideoLibraryScreen> createState() => _VideoLibraryScreenState();
}

class _VideoLibraryScreenState extends State<VideoLibraryScreen> {
  late Future<List<VideoDoc>> _future;
  late Future<List<PdfDoc>> _pdfFuture;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _future = AppServices.instance.api.listVideos();
    _pdfFuture = LocalStore.recentPdfDocs();
  }

  Future<void> _refresh() async {
    final f = AppServices.instance.api.listVideos();
    final pf = LocalStore.recentPdfDocs();
    setState(() {
      _future = f;
      _pdfFuture = pf;
    });
    await f;
  }

  Future<void> _openPdf(PdfDoc doc) async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => ReaderHostScreen(doc: doc)),
    );
    if (mounted) _refresh();
  }

  List<VideoDoc> _applyQuery(List<VideoDoc> docs) {
    if (_query.trim().isEmpty) return docs;
    final q = trLower(_query);
    return docs
        .where((d) => trLower('${d.name} ${d.relativePath}').contains(q))
        .toList();
  }

  List<VideoDoc> _recent(List<VideoDoc> docs) {
    final started = docs.where((d) => d.started).toList();
    started.sort(
      (a, b) =>
          (b.positionUpdatedAt ?? 0).compareTo(a.positionUpdatedAt ?? 0),
    );
    return started.take(10).toList();
  }

  Future<void> _open(VideoDoc doc) async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => VideoPlayerScreen(doc: doc)),
    );
    // Donunce ilerlemeler guncellensin.
    if (mounted) _refresh();
  }

  // ---- Video yukleme ----
  // Mobilde sistem video secici; masaustunde belirli uzanti filtresi.
  Future<void> _pickAndUploadVideo() async {
    bool isDesktop;
    try {
      // Windows/masaustu: Platform.windows || linux || macos.
      isDesktop = Platform.isWindows || Platform.isLinux || Platform.isMacOS;
    } catch (_) {
      isDesktop = false;
    }
    FilePickerResult? result;
    try {
      result = await FilePicker.platform.pickFiles(
        type: isDesktop
            ? FileType.custom
            : FileType.video,
        allowedExtensions: isDesktop
            ? const ['mp4', 'mkv', 'mov', 'm4v', 'webm']
            : null,
        withData: false,
      );
    } on Exception catch (e) {
      // Bazı Android cihazlarda video secici desteklenmez; genel dosyaya dus.
      debugPrint('Video secici acilmadi, dosya secici deneniyor: $e');
      try {
        result = await FilePicker.platform.pickFiles(
          type: FileType.any,
          withData: false,
        );
      } catch (_) {
        result = null;
      }
    }
    if (result == null) return;
    final picked = result.files.single;
    final path = picked.path;
    if (path == null) {
      _showSnack('Dosya yolu alınamadı');
      return;
    }
    final file = File(path);
    if (!file.existsSync()) {
      _showSnack('Dosya bulunamadı');
      return;
    }
    await _doUpload(file, picked.name);
  }

  Future<void> _doUpload(File file, String displayName) async {
    final messenger = ScaffoldMessenger.of(context);
    // Ilerleme SnackBar'i: kapatilana kadar guncellenir.
    final progress = ValueNotifier<double>(0.0);
    SnackBar? snackBar;
    void close() {
      if (snackBar != null) messenger.clearSnackBars();
    }

    snackBar = SnackBar(
      content: ValueListenableBuilder<double>(
        valueListenable: progress,
        builder: (_, value, _) => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              value >= 1.0
                  ? 'İşleniyor…'
                  : 'Yükleniyor: %${(value * 100).round()}',
            ),
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: value >= 1.0 ? null : value,
                minHeight: 6,
              ),
            ),
          ],
        ),
      ),
      duration: const Duration(days: 1), // bitince elle kapatilir
    );
    messenger.showSnackBar(snackBar);

    try {
      await AppServices.instance.api.uploadNewVideo(
        displayName,
        file,
        onProgress: (p) => progress.value = p,
      );
      close();
      if (!mounted) return;
      messenger.showSnackBar(
        const SnackBar(content: Text('Video eklendi')),
      );
      _refresh();
    } catch (e) {
      close();
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: Text('Hata: $e')));
    } finally {
      progress.dispose();
    }
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  static String _pctText(VideoDoc d) {
    final pr = d.progress;
    if (pr == null) return '';
    if (d.finished) return 'İzlendi';
    return '%${(pr * 100).round()}';
  }

  Widget _progressBar(VideoDoc d, ColorScheme scheme) {
    final pr = d.progress;
    if (pr == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: LinearProgressIndicator(
          value: pr,
          minHeight: 4,
          backgroundColor: scheme.surfaceContainerHighest,
          valueColor: AlwaysStoppedAnimation(
            d.finished ? Colors.green : scheme.primary,
          ),
        ),
      ),
    );
  }

  // ---- Son acilanlar yatay kart ----
  Widget _recentCard(VideoDoc d, ColorScheme scheme) {
    return Padding(
      padding: const EdgeInsets.only(right: 10),
      child: SizedBox(
        width: 190,
        child: Material(
          color: scheme.surfaceContainerLowest,
          borderRadius: BorderRadius.circular(10),
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () => _open(d),
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Icon(Icons.play_circle_fill,
                          color: scheme.primary, size: 22),
                      const Spacer(),
                      Text(
                        _pctText(d),
                        style: TextStyle(
                          fontSize: 11,
                          color: d.finished
                              ? Colors.green
                              : scheme.onSurfaceVariant,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    d.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 13,
                      height: 1.2,
                    ),
                  ),
                  _progressBar(d, scheme),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _sectionLabel(String text) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 8),
      child: Text(
        text,
        style: Theme.of(context).textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.bold,
            ),
      ),
    );
  }

  // ---- Son acilan PDF yatay kart ----
  Widget _pdfCard(PdfDoc d, ColorScheme scheme) {
    return Padding(
      padding: const EdgeInsets.only(right: 10),
      child: SizedBox(
        width: 190,
        child: Material(
          color: scheme.surfaceContainerLowest,
          borderRadius: BorderRadius.circular(10),
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () => _openPdf(d),
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.picture_as_pdf, color: scheme.primary, size: 22),
                  const SizedBox(height: 8),
                  Text(
                    d.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 13,
                      height: 1.2,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    d.relativePath,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _recentPdfSection(ColorScheme scheme) {
    return FutureBuilder<List<PdfDoc>>(
      future: _pdfFuture,
      builder: (context, snap) {
        final pdfs = snap.data ?? const <PdfDoc>[];
        if (pdfs.isEmpty) return const SizedBox.shrink();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _sectionLabel('Son açılan PDF\'ler'),
            SizedBox(
              height: 116,
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 14),
                itemCount: pdfs.length,
                itemBuilder: (_, i) => _pdfCard(pdfs[i], scheme),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _recentSection(List<VideoDoc> recent, ColorScheme scheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _recentPdfSection(scheme),
        if (recent.isNotEmpty) ...[
          _sectionLabel('Son açılan videolar'),
          SizedBox(
            height: 118,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              itemCount: recent.length,
              itemBuilder: (_, i) => _recentCard(recent[i], scheme),
            ),
          ),
        ],
        const Padding(
          padding: EdgeInsets.fromLTRB(14, 14, 14, 6),
          child: Text(
            'Tüm videolar',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
          ),
        ),
      ],
    );
  }

  // ---- Tum videolar dikey satir ----
  Widget _tile(VideoDoc doc, ColorScheme scheme) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Material(
        color: scheme.surfaceContainerLowest,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(color: scheme.outlineVariant.withAlpha(140)),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => _open(doc),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
            child: Row(
              children: [
                Icon(Icons.play_circle_outline, color: scheme.primary),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        doc.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              '${(doc.size / 1024 / 1024).toStringAsFixed(1)} MB  -  ${doc.relativePath}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 12,
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            doc.started ? _pctText(doc) : doc.durationText,
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: doc.finished
                                  ? Colors.green
                                  : scheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                      _progressBar(doc, scheme),
                    ],
                  ),
                ),
                const SizedBox(width: 6),
                Icon(Icons.chevron_right, color: scheme.outline),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Videolar'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(56),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: TextField(
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
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.upload),
        label: const Text('Video yükle'),
        onPressed: _pickAndUploadVideo,
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: FutureBuilder<List<VideoDoc>>(
          future: _future,
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snap.hasError) {
              return ListView(
                children: [
                  const SizedBox(height: 120),
                  Center(child: Text('Hata: ${snap.error}')),
                ],
              );
            }
            final all = snap.data ?? const <VideoDoc>[];
            final docs = _applyQuery(all);
            if (docs.isEmpty) {
              return ListView(
                children: const [
                  SizedBox(height: 140),
                  Center(child: Text('Video bulunamadı')),
                ],
              );
            }

            final searching = _query.trim().isNotEmpty;
            final recent = searching ? const <VideoDoc>[] : _recent(all);
            // Arama yokken header'i hep goster (son acilan PDF/video + baslik).
            final showHeader = !searching;

            return ListView.builder(
              padding: const EdgeInsets.only(bottom: 80),
              itemCount: docs.length + (showHeader ? 1 : 0),
              itemBuilder: (context, index) {
                if (showHeader && index == 0) {
                  return _recentSection(recent, scheme);
                }
                final d = docs[index - (showHeader ? 1 : 0)];
                return _tile(d, scheme);
              },
            );
          },
        ),
      ),
    );
  }
}
