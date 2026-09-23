import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../app_services.dart';
import '../local_store.dart';
import '../models.dart';
import '../platform_adaptive.dart';
import '../sync_service.dart';
import 'folder_picker_screen.dart';
import 'note_editor_screen.dart';
import 'reader_host_screen.dart';
import 'settings_screen.dart';
import 'video_player_screen.dart';
import 'favorites_screen.dart';
import 'content_search_screen.dart';
import 'recent_screen.dart';
import 'legislation_screen.dart';

class LibraryScreen extends StatefulWidget {
  /// Masaüstünde reader gömülü açıldığında çağrılır. Null ise (mobil)
  /// Navigator.push ile tam ekran açılır.
  final void Function(PdfDoc doc)? onOpenDoc;
  /// Masaüstünde not gömülü açıldığında çağrılır (PDF akışından ayrı).
  final void Function(NoteListItem note)? onOpenNote;

  const LibraryScreen({super.key, this.onOpenDoc, this.onOpenNote});

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  String _path = '';
  final Set<String> _selectedDocIds = {};
  late Future<LibraryListing> _future;
  late Future<List<PdfDoc>> _recentFuture;
  late Future<List<VideoDoc>> _recentVideoFuture;
  bool _searching = false;
  String _query = '';
  TextEditingController? _searchCtrl;

  bool get _selectionMode => _selectedDocIds.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _future = _loadLibrary();
    _recentFuture = _loadRecent();
    _recentVideoFuture = _loadRecentVideos();
  }

  @override
  void dispose() {
    _searchCtrl?.dispose();
    super.dispose();
  }

  void _refresh() {
    setState(() {
      _future = _loadLibrary();
      _recentFuture = _loadRecent();
      _recentVideoFuture = _loadRecentVideos();
    });
  }

  Future<LibraryListing> _loadLibrary() async {
    final localListing = await _loadLocalLibrary();
    if (localListing.folders.isNotEmpty || localListing.pdfs.isNotEmpty) {
      _refreshOnlineLibraryInBackground();
      return localListing;
    }

    try {
      final listing = await AppServices.instance.api.getLibrary(_path);
      return listing;
    } catch (_) {
      return localListing;
    }
  }

  Future<List<PdfDoc>> _loadRecent() async {
    final local = await LocalStore.getRecent(limit: 5);
    if (local.isNotEmpty) {
      return local;
    }
    try {
      return await AppServices.instance.api.getRecent(limit: 5);
    } catch (_) {
      return local;
    }
  }

  // Son izlenen videolar: sunucudaki videolardan izlemeye baslanmislari,
  // son izleme zamanina gore. Cevrimdisi ise bos liste.
  Future<List<VideoDoc>> _loadRecentVideos() async {
    try {
      final all = await AppServices.instance.api.listVideos();
      final started = all.where((d) => d.started).toList()
        ..sort(
          (a, b) => (b.positionUpdatedAt ?? 0).compareTo(a.positionUpdatedAt ?? 0),
        );
      return started.take(10).toList();
    } catch (_) {
      return const <VideoDoc>[];
    }
  }

  Future<void> _openVideo(VideoDoc doc) async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => VideoPlayerScreen(doc: doc)),
    );
    if (mounted) _refresh();
  }

  Future<LibraryListing> _loadLocalLibrary() async {
    final localDocs = await LocalStore.listPdfDocs();
    final foldersByPath = <String, LibraryFolder>{};
    final pdfs = <PdfDoc>[];
    for (final doc in localDocs) {
      final parts = doc.relativePath.split('/');
      if (_path.isEmpty) {
        if (parts.length > 1) {
          foldersByPath[parts[0]] = LibraryFolder(
            name: parts[0],
            path: parts[0],
          );
        } else {
          pdfs.add(doc);
        }
      } else if (doc.relativePath.startsWith('$_path/')) {
        final sub = doc.relativePath.substring(_path.length + 1);
        if (sub.contains('/')) {
          final folderName = sub.split('/').first;
          final folderPath = '$_path/$folderName';
          foldersByPath[folderPath] = LibraryFolder(
            name: folderName,
            path: folderPath,
          );
        } else {
          pdfs.add(doc);
        }
      }
    }

    String? parent;
    if (_path.isNotEmpty) {
      final parts = _path.split('/');
      parent = parts.length <= 1
          ? ''
          : parts.sublist(0, parts.length - 1).join('/');
    }
    return LibraryListing(
      path: _path,
      parent: parent,
      folders: foldersByPath.values.toList()
        ..sort((a, b) => a.name.compareTo(b.name)),
      pdfs: pdfs,
    );
  }

  void _refreshOnlineLibraryInBackground() {
    AppServices.instance.api.getLibrary(_path)
        .then((listing) {
          if (!mounted) return;
          setState(() { _future = Future.value(listing); });
        })
        .catchError((_) {});
  }

  void _navigateTo(String path) {
    setState(() {
      _path = path;
      _selectedDocIds.clear();
      _future = _loadLibrary();
    });
  }

  void _navigateUp() {
    if (_path.isEmpty) return;
    final parts = _path.split('/');
    _navigateTo(
      parts.length <= 1 ? '' : parts.sublist(0, parts.length - 1).join('/'),
    );
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  void _clearSelection() {
    setState(_selectedDocIds.clear);
  }

  void _togglePdfSelection(PdfDoc doc) {
    setState(() {
      if (!_selectedDocIds.remove(doc.id)) {
        _selectedDocIds.add(doc.id);
      }
    });
  }

  Future<void> _openPdf(PdfDoc doc) async {
    await LocalStore.markRecent(doc.id);
    try {
      await AppServices.instance.api.markRecent(doc.id);
      await LocalStore.clearRecentDirty(doc.id);
    } catch (_) {}
    if (!mounted) return;
    // Masaüstünde reader gömülü açılır; mobilde tam ekran push.
    if (widget.onOpenDoc != null) {
      widget.onOpenDoc!(doc);
      return;
    }
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => ReaderHostScreen(doc: doc)),
    );
    if (mounted) _refresh();
  }

  // --- Notlar (Faz E) ---

  Future<void> _openNote(NoteListItem note) async {
    if (!mounted) return;
    // Masaüstünde not editoru gömülü açilir; mobilde tam ekran push.
    if (widget.onOpenNote != null) {
      widget.onOpenNote!(note);
      return;
    }
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => NoteEditorScreen(item: note)),
    );
    if (mounted) _refresh();
  }

  Future<void> _createNote() async {
    // Once ad sor, sonra sunucuda olusturup editoru ac.
    final ctrl = TextEditingController(text: 'Not');
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Yeni not'),
        content: TextField(
          controller: ctrl,
          decoration: const InputDecoration(labelText: 'Not adı'),
          autofocus: true,
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('İptal'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text),
            child: const Text('Oluştur'),
          ),
        ],
      ),
    );
    if (name == null) return;
    final clean = name.trim();
    if (clean.isEmpty) return;
    try {
      final item = await AppServices.instance.api.createNote(clean, folder: _path);
      if (!mounted) return;
      // Once listeyi yenile ki yeni not gorunsun, sonra editoru ac.
      _refresh();
      await _openNote(item);
    } catch (e) {
      _showSnack('Hata: $e');
    }
  }

  Future<void> _moveNote(NoteListItem note) async {
    final target = await _pickFolder();
    if (!mounted || target == null) return;
    try {
      await AppServices.instance.api.moveNote(note.id, target);
      if (!mounted) return;
      _showSnack('Not taşındı');
      _refresh();
    } catch (e) {
      _showSnack('Hata: $e');
    }
  }

  Future<void> _deleteNote(NoteListItem note) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Notu sil'),
        content: Text('"${note.displayName}" silinecek. Geri alınamaz.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('İptal'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Sil'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await AppServices.instance.api.deleteNote(note.id);
      if (!mounted) return;
      _showSnack('Not silindi');
      _refresh();
    } catch (e) {
      _showSnack('Hata: $e');
    }
  }

  Future<void> _removeRecent(PdfDoc doc) async {
    // Once yereli sil ve ekrani hemen yenile; sunucu silmesi arka planda.
    // Basarisiz olsa da local_recent_hidden tablosu kaydi gizli tutar.
    await LocalStore.removeRecent(doc.id);
    if (mounted) _refresh();
    AppServices.instance.api.deleteRecent(doc.id).catchError((_) {});
  }

  Future<void> _createFolderDialog() async {
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Klasör oluştur'),
        content: TextField(
          controller: ctrl,
          decoration: const InputDecoration(labelText: 'Klasör adı'),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('İptal'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Oluştur'),
          ),
        ],
      ),
    );
    if (ok == true && ctrl.text.trim().isNotEmpty) {
      try {
        await AppServices.instance.api.createFolder(_path, ctrl.text.trim());
        if (!mounted) return;
        _refresh();
      } catch (e) {
        _showSnack('Hata: $e');
      }
    }
  }

  Future<void> _renameFolderDialog(LibraryFolder folder) async {
    final ctrl = TextEditingController(text: folder.name);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Yeniden adlandir'),
        content: TextField(
          controller: ctrl,
          decoration: const InputDecoration(labelText: 'Yeni ad'),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('İptal'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Kaydet'),
          ),
        ],
      ),
    );
    if (ok == true && ctrl.text.trim().isNotEmpty) {
      try {
        await AppServices.instance.api.renameFolder(folder.path, ctrl.text.trim());
        if (!mounted) return;
        _refresh();
      } catch (e) {
        _showSnack('Hata: $e');
      }
    }
  }

  Future<void> _deleteFolderDialog(LibraryFolder folder) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Klasörü sil'),
        content: Text(
          '"${folder.name}" klasörü ve içindeki tüm PDF\'ler silinecek.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('İptal'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Sil'),
          ),
        ],
      ),
    );
    if (ok == true) {
      try {
        await AppServices.instance.api.deleteFolder(folder.path);
        if (!mounted) return;
        _refresh();
      } catch (e) {
        _showSnack('Hata: $e');
      }
    }
  }

  Future<void> _uploadPdf() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['pdf'],
        withData: true,
      );
      if (result == null) return;
      final f = result.files.single;
      final bytes =
          f.bytes ??
          (f.path != null ? await File(f.path!).readAsBytes() : null);
      if (bytes == null) {
        _showSnack('Dosya okunamadi');
        return;
      }
      _showSnack('Yükleniyor...');
      await AppServices.instance.api.uploadNewPdf(f.name, bytes, folder: _path);
      if (!mounted) return;
      _showSnack('PDF eklendi');
      _refresh();
    } catch (e) {
      _showSnack('Hata: $e');
    }
  }

  Future<void> _showAddMenu() async {
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.upload_file),
              title: const Text('PDF ekle'),
              onTap: () => Navigator.pop(ctx, 'pdf'),
            ),
            ListTile(
              leading: const Icon(Icons.edit_note),
              title: const Text('Not ekle'),
              onTap: () => Navigator.pop(ctx, 'note'),
            ),
            ListTile(
              leading: const Icon(Icons.create_new_folder),
              title: const Text('Klasör oluştur'),
              onTap: () => Navigator.pop(ctx, 'folder'),
            ),
          ],
        ),
      ),
    );
    if (action == 'pdf') {
      await _uploadPdf();
    } else if (action == 'note') {
      await _createNote();
    } else if (action == 'folder') {
      await _createFolderDialog();
    }
  }

  Future<String?> _pickFolder() {
    return Navigator.push<String>(
      context,
      MaterialPageRoute(
        builder: (_) => FolderPickerScreen(currentFolder: _path),
      ),
    );
  }

  Future<void> _movePdf(PdfDoc doc) async {
    final target = await _pickFolder();
    if (!mounted || target == null) return;
    try {
      await AppServices.instance.api.movePdf(doc.id, target);
      if (!mounted) return;
      _showSnack('PDF taşındı');
      _refresh();
    } catch (e) {
      _showSnack('Hata: $e');
    }
  }

  Future<void> _copyPdf(PdfDoc doc) async {
    final target = await _pickFolder();
    if (!mounted || target == null) return;
    try {
      await AppServices.instance.api.copyPdf(doc.id, target);
      if (!mounted) return;
      _showSnack('PDF kopyalandı');
      _refresh();
    } catch (e) {
      _showSnack('Hata: $e');
    }
  }

  Future<void> _deletePdf(PdfDoc doc) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('PDF sil'),
        content: Text('"${doc.name}" silinecek. Bu işlem geri alınamaz.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('İptal'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Sil'),
          ),
        ],
      ),
    );
    if (ok == true) {
      try {
        await AppServices.instance.api.deletePdf(doc.id);
        if (!mounted) return;
        _showSnack('PDF silindi');
        _refresh();
      } catch (e) {
        _showSnack('Hata: $e');
      }
    }
  }

  Future<void> _moveSelectedPdfs() async {
    final target = await _pickFolder();
    if (!mounted || target == null) return;

    final ids = List<String>.of(_selectedDocIds);
    try {
      for (final id in ids) {
        await AppServices.instance.api.movePdf(id, target);
      }
      if (!mounted) return;
      _clearSelection();
      _showSnack('${ids.length} PDF taşındı');
      _refresh();
    } catch (e) {
      _showSnack('Hata: $e');
      _refresh();
    }
  }

  Future<void> _deleteSelectedPdfs() async {
    final count = _selectedDocIds.length;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('PDFleri sil'),
        content: Text('$count PDF silinecek. Bu işlem geri alınamaz.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('İptal'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Sil'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    final ids = List<String>.of(_selectedDocIds);
    try {
      for (final id in ids) {
        await AppServices.instance.api.deletePdf(id);
      }
      if (!mounted) return;
      _clearSelection();
      _showSnack('${ids.length} PDF silindi');
      _refresh();
    } catch (e) {
      _showSnack('Hata: $e');
      _refresh();
    }
  }



  IconData _getFolderIcon(String folderName) {
    final name = folderName.toLowerCase();
    if (name.contains('anayasa')) return Icons.gavel;
    if (name.contains('ceza')) return Icons.balance;
    if (name.contains('medeni') ||
        name.contains('borc') ||
        name.contains('borç')) {
      return Icons.people_outline;
    }
    if (name.contains('idare')) return Icons.account_balance;
    if (name.contains('ticaret')) return Icons.business;
    if (name.contains('icra')) return Icons.assignment_turned_in;
    if (name.contains('usul') || name.contains('yargılama')) return Icons.rule;
    return Icons.folder_open;
  }

  Color _getFolderColor(String folderName) {
    final name = folderName.toLowerCase();
    if (name.contains('anayasa')) return const Color(0xFFE8F1FF);
    if (name.contains('ceza')) return const Color(0xFFFFECEC);
    if (name.contains('medeni') ||
        name.contains('borc') ||
        name.contains('borç')) {
      return const Color(0xFFF0E9FF);
    }
    if (name.contains('idare')) return const Color(0xFFEAF7F0);
    if (name.contains('ticaret')) return const Color(0xFFFFF4DD);
    if (name.contains('icra')) return const Color(0xFFEAF5FF);
    if (name.contains('usul') || name.contains('yargılama')) {
      return const Color(0xFFF4EEE6);
    }
    return const Color(0xFFF3F0EA);
  }

  Color _getFolderIconColor(String folderName) {
    final name = folderName.toLowerCase();
    if (name.contains('anayasa')) return const Color(0xFF2F68B8);
    if (name.contains('ceza')) return const Color(0xFFC44E4E);
    if (name.contains('medeni') ||
        name.contains('borc') ||
        name.contains('borç')) {
      return const Color(0xFF7257B7);
    }
    if (name.contains('idare')) return const Color(0xFF3D8C60);
    if (name.contains('ticaret')) return const Color(0xFFB7791F);
    if (name.contains('icra')) return const Color(0xFF357CA5);
    if (name.contains('usul') || name.contains('yargılama')) {
      return const Color(0xFF8A6A45);
    }
    return const Color(0xFFC5A880);
  }

  /// Üstteki dağınık tuş takımını toparlayan taşma menüsü.
  /// Senkron durumunu ikonuna yansıtır; menüyü mantıksal gruplara ayırır.
  Widget _buildOverflowMenu() {
    return ValueListenableBuilder<SyncStatus>(
      valueListenable: SyncService.status,
      builder: (context, s, _) {
        final isOffline = s.phase == SyncPhase.offline;
        final isError = s.phase == SyncPhase.error;
        final isSyncing = s.phase == SyncPhase.syncing;
        final pending = s.pending;

        // İkona durum rozeti: çevrimdışı/hata = renkli nokta, bekleyen = sayı.
        final showBadge = pending > 0 || isOffline || isError;
        final badgeColor = isError
            ? Colors.red
            : (isOffline ? Colors.orange : Colors.red);

        final syncLabel = switch (s.phase) {
          SyncPhase.syncing => 'Senkronize ediliyor…',
          SyncPhase.offline => 'Çevrimdışı',
          SyncPhase.error => 'Senkron hatası',
          SyncPhase.idle => pending > 0
              ? '$pending değişiklik bekliyor'
              : 'Senkronize',
        };
        final syncIcon = switch (s.phase) {
          SyncPhase.syncing => Icons.sync,
          SyncPhase.offline => Icons.cloud_off,
          SyncPhase.error => Icons.sync_problem,
          SyncPhase.idle => Icons.cloud_done,
        };

        return PopupMenuButton<String>(
          tooltip: 'Diğer',
          icon: Badge(
            isLabelVisible: showBadge,
            label: pending > 0 ? Text('$pending') : null,
            backgroundColor: badgeColor,
            child: Icon(
              isSyncing ? Icons.more_vert : Icons.more_vert,
              color: (isOffline || isError) ? badgeColor : null,
            ),
          ),
          onSelected: (value) async {
            switch (value) {
              case 'sync':
                SyncService.syncNow();
                break;
              case 'content_search':
                if (!mounted) return;
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const ContentSearchScreen(),
                  ),
                );
                break;
              case 'favorites':
                if (!mounted) return;
                await Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const FavoritesScreen()),
                );
                _refresh();
                break;
              case 'recent':
                if (!mounted) return;
                await Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const RecentScreen()),
                );
                _refresh();
                break;
              case 'settings':
                if (!mounted) return;
                final changed = await Navigator.push<bool>(
                  context,
                  MaterialPageRoute(builder: (_) => const SettingsScreen()),
                );
                if (!mounted) return;
                if (changed == true) _refresh();
                break;
            }
          },
          itemBuilder: (_) => [
            // Senkron durumu — ikon + etiketle tek satır.
            PopupMenuItem<String>(
              value: 'sync',
              child: Row(
                children: [
                  Icon(syncIcon, size: 20, color: badgeColor),
                  const SizedBox(width: 12),
                  Expanded(child: Text(syncLabel)),
                ],
              ),
            ),
            const PopupMenuDivider(),
            const PopupMenuItem<String>(
              value: 'favorites',
              child: Row(
                children: [
                  Icon(Icons.star_outline, size: 20),
                  SizedBox(width: 12),
                  Text('Favoriler'),
                ],
              ),
            ),
            const PopupMenuItem<String>(
              value: 'recent',
              child: Row(
                children: [
                  Icon(Icons.history, size: 20),
                  SizedBox(width: 12),
                  Text('Son açılanlar'),
                ],
              ),
            ),
            const PopupMenuItem<String>(
              value: 'content_search',
              child: Row(
                children: [
                  Icon(Icons.manage_search, size: 20),
                  SizedBox(width: 12),
                  Text('İçerikte ara'),
                ],
              ),
            ),
            const PopupMenuDivider(),
            const PopupMenuItem<String>(
              value: 'settings',
              child: Row(
                children: [
                  Icon(Icons.settings_outlined, size: 20),
                  SizedBox(width: 12),
                  Text('Ayarlar'),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _sectionTitle(BuildContext context, String title) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 12),
      child: Text(
        title,
        style: GoogleFonts.outfit(
          textStyle: Theme.of(context).textTheme.titleMedium,
          fontSize: 16,
          fontWeight: FontWeight.w800,
          color: scheme.primary,
        ),
      ),
    );
  }

  Widget _recentCard(PdfDoc doc) {
    final scheme = Theme.of(context).colorScheme;
    final progress = _progressLine(doc);
    const gold = Color(0xFFC5A880);
    return InkWell(
      onTap: () => _openPdf(doc),
      borderRadius: BorderRadius.circular(20),
      child: Container(
        width: 180,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerLowest,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: gold.withAlpha(70)),
          boxShadow: [
            BoxShadow(
              color: scheme.shadow.withAlpha(18),
              blurRadius: 18,
              offset: const Offset(0, 10),
            ),
          ],
        ),
        child: Stack(
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(
                        color: gold.withAlpha(36),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Icon(
                        Icons.picture_as_pdf_outlined,
                        size: 18,
                        color: gold,
                      ),
                    ),
                    const SizedBox(width: 32), // space for close button
                  ],
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      Text(
                        doc.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        doc.relativePath.contains('/')
                            ? doc.relativePath.split('/').first
                            : 'Kütüphane',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 10,
                          color: scheme.onSurfaceVariant.withAlpha(180),
                        ),
                      ),
                      const SizedBox(height: 6),
                      ?progress,
                    ],
                  ),
                ),
              ],
            ),
            Positioned(
              top: -6,
              right: -6,
              child: IconButton(
                tooltip: 'Kaldır',
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
                onPressed: () => _removeRecent(doc),
                icon: Icon(
                  Icons.close,
                  size: 14,
                  color: scheme.onSurfaceVariant.withAlpha(150),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // "Son açılanlar" altindaki satir etiketi (Videolar / PDF'ler).
  Widget _recentRowLabel(String text) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 6),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.3,
          color: scheme.onSurfaceVariant,
        ),
      ),
    );
  }

  Widget _recentVideoCard(VideoDoc doc) {
    final scheme = Theme.of(context).colorScheme;
    const gold = Color(0xFFC5A880);
    final pr = doc.progress;
    final pctText = doc.finished
        ? 'İzlendi'
        : (pr != null ? '%${(pr * 100).round()}' : '');
    return InkWell(
      onTap: () => _openVideo(doc),
      borderRadius: BorderRadius.circular(20),
      child: Container(
        width: 180,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerLowest,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: gold.withAlpha(70)),
          boxShadow: [
            BoxShadow(
              color: scheme.shadow.withAlpha(18),
              blurRadius: 18,
              offset: const Offset(0, 10),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: gold.withAlpha(36),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(
                    Icons.play_circle_fill,
                    size: 18,
                    color: gold,
                  ),
                ),
                if (pctText.isNotEmpty)
                  Text(
                    pctText,
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                      color: doc.finished
                          ? Colors.green
                          : scheme.onSurfaceVariant.withAlpha(180),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  Text(
                    doc.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                      height: 1.2,
                    ),
                  ),
                  const SizedBox(height: 6),
                  if (pr != null)
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: pr,
                        minHeight: 4,
                        backgroundColor: scheme.outlineVariant.withAlpha(100),
                        valueColor: AlwaysStoppedAnimation<Color>(
                          doc.finished ? Colors.green : gold,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // "Son açılanlar" bolumu: iki satir (Videolar + PDF'ler).
  Widget _recentBlock() {
    return FutureBuilder<List<VideoDoc>>(
      future: _recentVideoFuture,
      builder: (context, vsnap) {
        final videos = vsnap.data ?? const <VideoDoc>[];
        return FutureBuilder<List<PdfDoc>>(
          future: _recentFuture,
          builder: (context, psnap) {
            final pdfs = psnap.data ?? const <PdfDoc>[];
            if (videos.isEmpty && pdfs.isEmpty) {
              return const SizedBox.shrink();
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _sectionTitle(context, 'Son açılanlar'),
                if (videos.isNotEmpty) ...[
                  _recentRowLabel('Videolar'),
                  SizedBox(
                    height: 96,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      itemCount: videos.length,
                      separatorBuilder: (_, _) => const SizedBox(width: 8),
                      itemBuilder: (context, i) => _recentVideoCard(videos[i]),
                    ),
                  ),
                  const SizedBox(height: 8),
                ],
                if (pdfs.isNotEmpty) ...[
                  _recentRowLabel('PDF\'ler'),
                  SizedBox(
                    height: 128,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      itemCount: pdfs.length,
                      separatorBuilder: (_, _) => const SizedBox(width: 8),
                      itemBuilder: (context, i) => _recentCard(pdfs[i]),
                    ),
                  ),
                ],
                const SizedBox(height: 6),
              ],
            );
          },
        );
      },
    );
  }

  Widget _folderTile(LibraryFolder folder) {
    final scheme = Theme.of(context).colorScheme;
    final icon = _getFolderIcon(folder.name);
    final folderColor = _getFolderColor(folder.name);
    final folderIconColor = _getFolderIconColor(folder.name);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Material(
        color: _selectionMode
            ? scheme.surfaceContainerLow.withAlpha(120)
            : scheme.surfaceContainerLowest,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: scheme.outlineVariant, width: 1.0),
        ),
        child: ListTile(
          enabled: !_selectionMode,
          minLeadingWidth: 28,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 4,
          ),
          leading: Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: folderColor,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: folderIconColor, size: 22),
          ),
          title: Text(
            folder.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
          ),
          subtitle: Text(
            folder.path.isEmpty ? 'Kök Dizin' : folder.path,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 11,
              color: scheme.onSurfaceVariant.withAlpha(160),
            ),
          ),
          trailing: _selectionMode
              ? null
              : PopupMenuButton<String>(
                  onSelected: (action) {
                    if (action == 'rename') {
                      _renameFolderDialog(folder);
                    }
                    if (action == 'delete') {
                      _deleteFolderDialog(folder);
                    }
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(
                      value: 'rename',
                      child: Text('Yeniden adlandır'),
                    ),
                    PopupMenuItem(value: 'delete', child: Text('Sil')),
                  ],
                ),
          onTap: _selectionMode ? null : () => _navigateTo(folder.path),
        ),
      ),
    );
  }

  Widget _noteTile(NoteListItem note) {
    final scheme = Theme.of(context).colorScheme;
    const gold = Color(0xFFC5A880);
    final preview = note.title.trim().isEmpty
        ? 'Boş not'
        : note.title.trim().replaceAll('\n', ' ');
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Material(
        elevation: 1,
        shadowColor: scheme.shadow.withAlpha(28),
        color: scheme.surfaceContainerLowest,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: BorderSide(color: scheme.outlineVariant.withAlpha(150), width: 1.0),
        ),
        clipBehavior: Clip.antiAlias,
        child: ListTile(
          minLeadingWidth: 28,
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          leading: Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: gold.withAlpha(28),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(Icons.edit_note, color: gold, size: 22),
          ),
          title: Text(
            note.displayName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
          ),
          subtitle: Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              '${(note.size / 1024).round()} KB  •  $preview',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                color: scheme.onSurfaceVariant.withAlpha(160),
              ),
            ),
          ),
          trailing: PopupMenuButton<String>(
            onSelected: (action) {
              if (action == 'move') _moveNote(note);
              if (action == 'delete') _deleteNote(note);
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'move', child: Text('Taşı')),
              PopupMenuItem(value: 'delete', child: Text('Sil')),
            ],
          ),
          onTap: () => _openNote(note),
        ),
      ),
    );
  }

  Widget _pdfTile(PdfDoc doc) {
    final scheme = Theme.of(context).colorScheme;
    final selected = _selectedDocIds.contains(doc.id);
    final progress = _progressLine(doc);
    const gold = Color(0xFFC5A880);
    return GestureDetector(
      onSecondaryTap: () {
        if (PlatformAdaptive.isDesktop) _showPdfContextMenu(doc);
      },
      child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Material(
        elevation: selected ? 2 : 1,
        shadowColor: scheme.shadow.withAlpha(28),
        color: selected
            ? scheme.primaryContainer.withAlpha(120)
            : scheme.surfaceContainerLowest,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: BorderSide(
            color: selected ? gold : scheme.outlineVariant.withAlpha(150),
            width: selected ? 1.5 : 1.0,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: ListTile(
          selected: selected,
          minLeadingWidth: 28,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 6,
          ),
          leading: _selectionMode
              ? Checkbox(
                  value: selected,
                  onChanged: (_) => _togglePdfSelection(doc),
                )
              : Container(
                  padding: const EdgeInsets.all(4),
                  child: IconButton(
                    visualDensity: VisualDensity.compact,
                    tooltip: doc.favorite ? 'Favoriden çıkar' : 'Favoriye ekle',
                    icon: Icon(
                      doc.favorite ? Icons.star : Icons.star_border,
                      size: 22,
                    ),
                    color: doc.favorite ? gold : scheme.outline.withAlpha(150),
                    onPressed: () async {
                      final newFav = !doc.favorite;
                      await LocalStore.setFavorite(doc.id, newFav, dirty: true);
                      _refresh();
                      try {
                        await AppServices.instance.api.setFavorite(doc.id, newFav);
                        await LocalStore.clearFavoriteDirty(doc.id);
                      } catch (_) {}
                    },
                  ),
                ),
          title: Text(
            doc.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
          ),
          subtitle: Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '${(doc.size / 1024 / 1024).toStringAsFixed(1)} MB  •  ${doc.relativePath.contains('/') ? doc.relativePath.split('/').last : doc.relativePath}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    color: scheme.onSurfaceVariant.withAlpha(160),
                  ),
                ),
                ?progress,
              ],
            ),
          ),
          trailing: _selectionMode
              ? null
              : PopupMenuButton<String>(
                  onSelected: (action) {
                    if (action == 'move') _movePdf(doc);
                    if (action == 'copy') _copyPdf(doc);
                    if (action == 'delete') _deletePdf(doc);
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'move', child: Text('Taşı')),
                    PopupMenuItem(value: 'copy', child: Text('Kopyala')),
                    PopupMenuItem(value: 'delete', child: Text('Sil')),
                  ],
                ),
          onLongPress: () => _togglePdfSelection(doc),
          onTap: _selectionMode
              ? () => _togglePdfSelection(doc)
              : () => _openPdf(doc),
        ),
      ),
      ),
    );
  }

  /// Masaüstünde PDF'e sağ tıkla açılan bağlam menüsü.
  void _showPdfContextMenu(PdfDoc doc) {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox?;
    final size = overlay?.size ?? const Size(400, 400);
    showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        size.width / 2,
        size.height / 2,
        size.width / 2,
        size.height / 2,
      ),
      items: [
        const PopupMenuItem(value: 'move', child: Text('Taşı')),
        const PopupMenuItem(value: 'copy', child: Text('Kopyala')),
        const PopupMenuItem(value: 'delete', child: Text('Sil')),
        PopupMenuItem(
          value: 'favorite',
          child: Text(doc.favorite ? 'Favoriden çıkar' : 'Favoriye ekle'),
        ),
      ],
    ).then((action) {
      if (action == null) return;
      if (action == 'move') {
        _movePdf(doc);
      } else if (action == 'copy') {
        _copyPdf(doc);
      } else if (action == 'delete') {
        _deletePdf(doc);
      } else if (action == 'favorite') {
        LocalStore.setFavorite(doc.id, !doc.favorite, dirty: true).then((_) {
          _refresh();
        });
      }
    });
  }

  Widget? _progressLine(PdfDoc doc) {
    final total = doc.pageCount;
    final current = doc.currentPage;
    if (total == null || current == null || total <= 0) return null;
    final done = current >= total;
    final value = (current / total).clamp(0.0, 1.0);
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: value,
                minHeight: 4,
                backgroundColor: scheme.outlineVariant.withAlpha(100),
                valueColor: AlwaysStoppedAnimation<Color>(
                  done ? scheme.primary : const Color(0xFFC5A880),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            done ? 'Bitti' : '%${(value * 100).round()}',
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.bold,
              color: done ? scheme.primary : const Color(0xFFC5A880),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: _searching
            ? TextField(
                controller: _searchCtrl,
                autofocus: true,
                decoration: const InputDecoration(
                  hintText: 'Ara...',
                  border: InputBorder.none,
                ),
                onChanged: (v) => setState(() => _query = v.toLowerCase()),
              )
            : _selectionMode
            ? Text('${_selectedDocIds.length} PDF seçildi')
            : Tooltip(
                message: _path.isEmpty ? 'Kütüphane' : _path,
                child: Text(
                  _path.isEmpty ? 'Kütüphane' : _path,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
        leading: _searching
            ? IconButton(
                icon: const Icon(Icons.close),
                onPressed: () {
                  _searchCtrl?.dispose();
                  _searchCtrl = null;
                  setState(() {
                    _searching = false;
                    _query = '';
                  });
                },
              )
            : _selectionMode
            ? IconButton(
                icon: const Icon(Icons.close),
                onPressed: _clearSelection,
              )
            : _path.isNotEmpty
            ? IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: _navigateUp,
              )
            : null,
        actions: _selectionMode
            ? [
                IconButton(
                  icon: const Icon(Icons.drive_file_move),
                  tooltip: 'Seçilenleri taşı',
                  onPressed: _moveSelectedPdfs,
                ),
                IconButton(
                  icon: const Icon(Icons.delete),
                  tooltip: 'Seçilenleri sil',
                  onPressed: _deleteSelectedPdfs,
                ),
              ]
            : [
                if (!_searching)
                  IconButton(
                    icon: const Icon(Icons.menu_book_outlined),
                    tooltip: 'Mevzuat',
                    onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const LegislationScreen(),
                      ),
                    ),
                  ),
                if (!_searching)
                  IconButton(
                    icon: const Icon(Icons.search),
                    tooltip: 'Ara',
                    onPressed: () => setState(() {
                      _searching = true;
                      _searchCtrl = TextEditingController();
                    }),
                  ),
                if (!_searching) _buildOverflowMenu(),
              ],
      ),
      floatingActionButton: _selectionMode
          ? null
          : FloatingActionButton(
              onPressed: _showAddMenu,
              tooltip: 'Ekle',
              child: const Icon(Icons.add),
            ),
      body: FutureBuilder<LibraryListing>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(child: Text('Hata: ${snapshot.error}'));
          }
          final listing = snapshot.data!;
          var folders = listing.folders;
          var pdfs = listing.pdfs;
          var notes = listing.notes;
          if (_query.isNotEmpty) {
            folders = folders
                .where((f) => f.name.toLowerCase().contains(_query))
                .toList();
            pdfs = pdfs
                .where(
                  (p) =>
                      p.name.toLowerCase().contains(_query) ||
                      p.relativePath.toLowerCase().contains(_query),
                )
                .toList();
            notes = notes
                .where(
                  (n) =>
                      n.displayName.toLowerCase().contains(_query) ||
                      n.relativePath.toLowerCase().contains(_query),
                )
                .toList();
          }
          if (folders.isEmpty && pdfs.isEmpty && notes.isEmpty) {
            return Center(
              child: Text(_query.isNotEmpty ? 'Sonuç yok' : 'Bu klasör boş'),
            );
          }
          // PDF ve notlar tek listede, ada gore sirali (ayri baslik yok).
          final docTiles =
              <({String key, Widget tile})>[
                for (final doc in pdfs)
                  (key: doc.name.toLowerCase(), tile: _pdfTile(doc)),
                for (final note in notes)
                  (key: note.displayName.toLowerCase(), tile: _noteTile(note)),
              ]..sort((a, b) => a.key.compareTo(b.key));
          return RefreshIndicator(
            onRefresh: () async => _refresh(),
            child: ListView(
              children: [
                if (_path.isEmpty && !_searching) _recentBlock(),
                if (folders.isNotEmpty) _sectionTitle(context, 'Klasörler'),
                for (final folder in folders) _folderTile(folder),
                if (docTiles.isNotEmpty) _sectionTitle(context, 'Belgeler'),
                for (final e in docTiles) e.tile,
                const SizedBox(height: 88),
              ],
            ),
          );
        },
      ),
    );
  }
}
