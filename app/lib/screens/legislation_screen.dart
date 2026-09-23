import 'dart:convert';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_services.dart';
import '../local_store.dart';
import '../mevzuat_models.dart';
import '../mevzuat_citations.dart';

class LegislationScreen extends StatefulWidget {
  const LegislationScreen({super.key});
  @override
  State<LegislationScreen> createState() => _LegislationScreenState();
}

class _LegislationScreenState extends State<LegislationScreen> {
  late Future<List<LegislationSummary>> _future;
  final _search = TextEditingController();
  String _query = '';

  @override
  void initState() { super.initState(); _future = _load(); _search.addListener(() => setState(() => _query = _search.text.trim().toLowerCase())); }
  @override
  void dispose() { _search.dispose(); super.dispose(); }

  Future<List<LegislationSummary>> _load() async {
    final local = await LocalStore.listLegislation();
    try {
      final remote = await AppServices.instance.api.listLegislation();
      final downloaded = {for (final x in local) x.mevzuatNo: x.downloadedAtMs};
      return remote.map((x) => LegislationSummary(mevzuatNo: x.mevzuatNo, ad: x.ad, kisaAd: x.kisaAd, tur: x.tur, snapshotVersion: x.snapshotVersion, articleCount: x.articleCount, size: x.size, downloadedAtMs: downloaded[x.mevzuatNo])).toList();
    } catch (_) { return local; }
  }

  Future<void> _download(LegislationSummary law) async {
    try {
      final installed = await LocalStore.getLegislation(law.mevzuatNo);
      if (installed != null && installed.snapshotVersion == law.snapshotVersion) {
        if (mounted) _snack('${law.kisaAd} zaten güncel');
        return;
      }
      final bundle = await AppServices.instance.api.downloadLegislationBundle(law.mevzuatNo);
      await LocalStore.installLegislation(bundle);
      if (mounted) { setState(() { _future = _load(); }); _snack('${law.kisaAd} indirildi'); }
    } catch (e) { if (mounted) _snack('İndirme başarısız: $e'); }
  }

  Future<void> _delete(LegislationSummary law) async {
    await LocalStore.deleteLegislation(law.mevzuatNo);
    if (mounted) { setState(() { _future = _load(); }); _snack('${law.kisaAd} silindi'); }
  }

  void _snack(String text) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Mevzuat'), actions: [IconButton(icon: const Icon(Icons.refresh), onPressed: () => setState(() { _future = _load(); }))]),
    body: Column(children: [
      Padding(padding: const EdgeInsets.fromLTRB(16, 12, 16, 4), child: TextField(controller: _search, decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Kanun ara', border: OutlineInputBorder()))),
      Expanded(child: FutureBuilder<List<LegislationSummary>>(future: _future, builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) return const Center(child: CircularProgressIndicator());
        if (_query.isNotEmpty) {
          return FutureBuilder<List<Map<String, dynamic>>>(future: LocalStore.searchLegislation(_query), builder: (context, result) {
            if (result.connectionState != ConnectionState.done) return const Center(child: CircularProgressIndicator());
            final hits = result.data ?? const <Map<String, dynamic>>[];
            if (hits.isEmpty) return const Center(child: Text('İndirilen mevzuatta sonuç yok'));
            return ListView(children: [const ListTile(title: Text('İndirilen mevzuatta madde sonuçları')), for (final hit in hits) ListTile(title: Text('${hit['mevzuat_no']} • ${hit['madde_ref']}'), subtitle: Text(hit['snippet'] as String? ?? '', maxLines: 3, overflow: TextOverflow.ellipsis), onTap: () async { final navigator = Navigator.of(context); final article = await LocalStore.getLegislationArticle(hit['madde_ref'] as String); if (article != null) navigator.push(MaterialPageRoute(builder: (_) => LegislationArticleScreen(article: article))); })]);
          });
        }
        final laws = (snap.data ?? const <LegislationSummary>[]).toList();
        if (laws.isEmpty) return const Center(child: Text('Mevzuat listesi alınamadı veya boş.'));
        return ListView.builder(itemCount: laws.length, itemBuilder: (_, i) => _tile(laws[i]));
      })),
    ]),
  );

  Widget _tile(LegislationSummary law) {
    final downloaded = law.downloadedAtMs != null;
    return ListTile(
      leading: CircleAvatar(child: Text(law.kisaAd.isEmpty ? 'M' : law.kisaAd.substring(0, 1))),
      title: Text('${law.kisaAd}  •  ${law.ad}'),
      subtitle: Text('${law.mevzuatNo} sayılı ${law.tur}  •  ${law.articleCount} madde${downloaded ? '  •  Çevrimdışı hazır' : ''}'),
      trailing: downloaded ? PopupMenuButton<String>(onSelected: (v) { if (v == 'open') Navigator.push(context, MaterialPageRoute(builder: (_) => LegislationArticlesScreen(law: law))); if (v == 'update') _download(law); if (v == 'delete') _delete(law); }, itemBuilder: (_) => const [PopupMenuItem(value: 'open', child: Text('Aç')), PopupMenuItem(value: 'update', child: Text('Güncelle')), PopupMenuItem(value: 'delete', child: Text('Cihazdan sil'))]) : FilledButton(onPressed: () => _download(law), child: const Text('İndir')),
      onTap: downloaded ? () => Navigator.push(context, MaterialPageRoute(builder: (_) => LegislationArticlesScreen(law: law))) : null,
    );
  }
}

class LegislationArticlesScreen extends StatefulWidget {
  final LegislationSummary law;
  const LegislationArticlesScreen({super.key, required this.law});
  @override State<LegislationArticlesScreen> createState() => _LegislationArticlesScreenState();
}

class _LegislationArticlesScreenState extends State<LegislationArticlesScreen> {
  late Future<List<LegislationArticle>> _future;
  late Future<List<LegislationChange>> _changesFuture;
  final _search = TextEditingController();
  String _query = '';
  @override void initState() { super.initState(); _future = LocalStore.listLegislationArticles(widget.law.mevzuatNo); _changesFuture = LocalStore.listLegislationChanges(widget.law.mevzuatNo); _search.addListener(() => setState(() => _query = _search.text.trim())); }
  @override void dispose() { _search.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(widget.law.kisaAd),
      bottom: PreferredSize(
        preferredSize: const Size.fromHeight(64),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
          child: TextField(controller: _search, decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Madde veya metin ara', filled: true, border: OutlineInputBorder())),
        ),
      ),
    ),
    body: FutureBuilder<List<LegislationArticle>>(
      future: _future,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) return const Center(child: CircularProgressIndicator());
        final articles = snap.data ?? const <LegislationArticle>[];
        return FutureBuilder<List<LegislationChange>>(
          future: _changesFuture,
          builder: (context, changeSnap) {
            final changed = {for (final c in changeSnap.data ?? const <LegislationChange>[]) c.maddeRef};
            return _query.isEmpty ? _articleList(articles, changed: changed) : _searchResults(articles, changed);
          },
        );
      },
    ),
  );

  Widget _searchResults(List<LegislationArticle> articles, Set<String> changed) => FutureBuilder<List<Map<String, dynamic>>>(future: LocalStore.searchLegislation(_query), builder: (context, result) {
    if (result.connectionState != ConnectionState.done) return const Center(child: CircularProgressIndicator());
    final refs = {for (final r in result.data ?? const []) r['madde_ref'] as String: r['snippet'] as String? ?? ''};
    return _articleList(articles.where((a) => refs.containsKey(a.id)).toList(), snippets: refs, changed: changed);
  });

  Widget _articleList(List<LegislationArticle> articles, {Map<String, String> snippets = const {}, Set<String> changed = const {}}) => ListView.builder(itemCount: articles.length, itemBuilder: (_, i) {
    final a = articles[i];
    return ListTile(title: Row(children: [Expanded(child: Text('Madde ${a.maddeNoRaw}${a.baslik.isEmpty ? '' : ' — ${a.baslik}'}')), if (changed.contains(a.id)) const Chip(label: Text('Değişti'))]), subtitle: Text(snippets[a.id] ?? a.metin, maxLines: 2, overflow: TextOverflow.ellipsis), onTap: () async { await LocalStore.putLegislationPosition(widget.law.mevzuatNo, a.id, dirty: true); if (mounted) Navigator.push(context, MaterialPageRoute(builder: (_) => LegislationArticleScreen(article: a))); });
  });
}

/// Madde okuyucu: ayni kanunun sirali madde listesini yukler ve sola/saga
/// kaydirarak onceki/sonraki maddeye gecisi saglar. Nereden acilirsa
/// acilsin (liste, arama, atif linki) kaydirma calisir.
class LegislationArticleScreen extends StatefulWidget {
  final LegislationArticle article;
  const LegislationArticleScreen({super.key, required this.article});
  @override State<LegislationArticleScreen> createState() => _LegislationArticleScreenState();
}

class _LegislationArticleScreenState extends State<LegislationArticleScreen> {
  List<LegislationArticle>? _articles;
  PageController? _controller;

  @override
  void initState() {
    super.initState();
    _loadSiblings();
  }

  Future<void> _loadSiblings() async {
    final lawNo = widget.article.id.split('/').first;
    final all = await LocalStore.listLegislationArticles(lawNo);
    final idx = all.indexWhere((a) => a.id == widget.article.id);
    if (!mounted) return;
    setState(() {
      _articles = idx < 0 ? [widget.article] : all;
      _controller = PageController(initialPage: idx < 0 ? 0 : idx);
    });
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final articles = _articles;
    // Liste yuklenene kadar tek madde goster; yuklenince ayni maddeden
    // baslayan PageView'a gecilir (gorsel sicrama olmaz).
    if (articles == null) return _ArticleView(article: widget.article);
    return PageView.builder(
      controller: _controller,
      itemCount: articles.length,
      onPageChanged: (i) => LocalStore.putLegislationPosition(
        articles[i].id.split('/').first,
        articles[i].id,
        dirty: true,
      ),
      itemBuilder: (_, i) =>
          _ArticleView(key: ValueKey(articles[i].id), article: articles[i]),
    );
  }
}

class _ArticleView extends StatefulWidget {
  final LegislationArticle article;
  const _ArticleView({super.key, required this.article});
  @override State<_ArticleView> createState() => _ArticleViewState();
}

class _ArticleViewState extends State<_ArticleView> {
  String? _selectedText;
  int? _selectedStart, _selectedEnd;
  List<MaddeNote> _notes = const [];
  LegislationChange? _change;
  final List<TapGestureRecognizer> _citationRecognizers = [];

  LegislationArticle get article => widget.article;
  @override void initState() { super.initState(); _loadNotes(); _loadChange(); }
  @override void dispose() { for (final r in _citationRecognizers) { r.dispose(); } super.dispose(); }
  Future<void> _loadNotes() async { final notes = await LocalStore.notesForArticle(article.id); if (mounted) setState(() => _notes = notes); }
  Future<void> _loadChange() async { final change = await LocalStore.changeForArticle(article.id); if (mounted) setState(() => _change = change); }

  Future<void> _openCitation(String lawNo, String articleNo) async {
    final ref = '$lawNo/m.$articleNo';
    final target = await LocalStore.getLegislationArticle(ref);
    if (!mounted) return;
    if (target == null) { ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Hedef kanun cihazda indirilmemiş'))); return; }
    Navigator.push(context, MaterialPageRoute(builder: (_) => LegislationArticleScreen(article: target)));
  }

  // Satır başındaki fıkra numaraları ("(1)", "1.", "2)") ve bent harfleri ("a)", "ç)") kalın gösterilir.
  static final _markerRe = RegExp(r'^[ \t]*(\(\d+\)|\d+[.)]|[a-zçğıöşü][.)])(?=[ \t])', multiLine: true);

  List<TextSpan> _plainSpans(String text, int offset, List<RegExpMatch> markers) {
    final spans = <TextSpan>[];
    final end = offset + text.length;
    var cur = offset;
    for (final m in markers) {
      if (m.end <= cur || m.start >= end) continue;
      final s = m.start < cur ? cur : m.start;
      final e = m.end > end ? end : m.end;
      if (s > cur) spans.add(TextSpan(text: text.substring(cur - offset, s - offset)));
      spans.add(TextSpan(text: text.substring(s - offset, e - offset), style: const TextStyle(fontWeight: FontWeight.bold)));
      cur = e;
    }
    if (cur < end) spans.add(TextSpan(text: text.substring(cur - offset)));
    return spans;
  }

  Widget _citationText(String text) {
    for (final r in _citationRecognizers) { r.dispose(); }
    _citationRecognizers.clear();
    final markers = _markerRe.allMatches(text).toList();
    final spans = <TextSpan>[];
    var cursor = 0;
    for (final citation in findLegislationCitations(text, article.id.split('/').first)) {
      if (citation.start > cursor) spans.addAll(_plainSpans(text.substring(cursor, citation.start), cursor, markers));
      final recognizer = TapGestureRecognizer()..onTap = () => _openCitation(citation.lawNo, citation.articleNo);
      _citationRecognizers.add(recognizer);
      spans.add(TextSpan(text: citation.text, style: TextStyle(color: Theme.of(context).colorScheme.primary, decoration: TextDecoration.underline), recognizer: recognizer));
      cursor = citation.end;
    }
    if (cursor < text.length) spans.addAll(_plainSpans(text.substring(cursor), cursor, markers));
    return SelectableText.rich(TextSpan(children: spans), onSelectionChanged: (selection, _) { if (!selection.isCollapsed) setState(() { _selectedStart = selection.start; _selectedEnd = selection.end; _selectedText = text.substring(selection.start, selection.end); }); });
  }

  Future<void> _saveSelection(String kind) async {
    final selected = _selectedText?.trim();
    if (selected == null || selected.isEmpty) return;
    var noteText = '';
    if (kind == 'note') {
      final controller = TextEditingController();
      noteText = await showDialog<String>(context: context, builder: (ctx) => AlertDialog(title: const Text('Madde notu'), content: TextField(controller: controller, maxLines: 4, autofocus: true, decoration: const InputDecoration(hintText: 'Notunuzu yazın')), actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('İptal')), FilledButton(onPressed: () => Navigator.pop(ctx, controller.text.trim()), child: const Text('Kaydet'))])) ?? '';
      if (noteText.isEmpty) return;
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    final note = MaddeNote(noteUuid: 'mn-$now-${DateTime.now().microsecondsSinceEpoch % 100000}', maddeRef: article.id, kind: kind, renk: kind == 'highlight' ? 0xFFFFD740 : null, seciliMetinAraligi: '{"start":${_selectedStart ?? 0},"end":${_selectedEnd ?? 0},"text":${jsonEncode(selected)}}', text: noteText, updatedAtMs: now, updatedByDevice: LocalStore.deviceId);
    await LocalStore.upsertMaddeNote(note, dirty: true);
    if (mounted) { setState(() { _selectedText = null; _notes = [..._notes, note]; }); ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(kind == 'highlight' ? 'Metin vurgulandı' : 'Not kaydedildi'))); }
  }

  Future<void> _toggleBookmark() async {
    final old = _notes.where((n) => n.kind == 'bookmark').toList();
    if (old.isNotEmpty) { await LocalStore.markMaddeNoteDeleted(old.first.noteUuid); await _loadNotes(); return; }
    final now = DateTime.now().millisecondsSinceEpoch;
    final note = MaddeNote(noteUuid: 'mn-$now-${DateTime.now().microsecondsSinceEpoch % 100000}', maddeRef: article.id, kind: 'bookmark', text: '', updatedAtMs: now, updatedByDevice: LocalStore.deviceId);
    await LocalStore.upsertMaddeNote(note, dirty: true); await _loadNotes();
  }

  @override Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text('Madde ${article.maddeNoRaw}'), actions: [if (_change != null) IconButton(tooltip: 'Değişiklik detayı', icon: const Icon(Icons.compare_arrows), onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => LegislationDiffScreen(change: _change!)))), IconButton(tooltip: 'Notlar', icon: const Icon(Icons.sticky_note_2_outlined), onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => MaddeNotesScreen(lawNo: article.id.split('/').first)))), IconButton(tooltip: 'Yer imi', icon: Icon(_notes.any((n) => n.kind == 'bookmark') ? Icons.bookmark : Icons.bookmark_border), onPressed: _toggleBookmark)]),
    body: ListView(padding: const EdgeInsets.all(20), children: [
      GestureDetector(onLongPress: () { Clipboard.setData(ClipboardData(text: article.id)); ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${article.id} kopyalandı'))); }, child: Text(article.id, style: TextStyle(color: Theme.of(context).colorScheme.primary, fontWeight: FontWeight.bold))),
      if (_selectedText != null) Padding(padding: const EdgeInsets.symmetric(vertical: 12), child: Wrap(spacing: 8, children: [FilledButton.icon(onPressed: () => _saveSelection('highlight'), icon: const Icon(Icons.highlight), label: const Text('Vurgula')), OutlinedButton.icon(onPressed: () => _saveSelection('note'), icon: const Icon(Icons.note_add), label: const Text('Not ekle'))])),
      if (article.baslik.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 18, bottom: 10), child: Text(article.baslik, style: Theme.of(context).textTheme.titleLarge)),
      ...article.paragraphs.asMap().entries.map((e) { final value = e.value; final display = '${value['number'] ?? ''}${value['number'] == null ? '' : '. '} ${value['text'] ?? ''}'; return Padding(padding: const EdgeInsets.only(bottom: 14), child: _citationText(display)); }),
      if (article.paragraphs.isEmpty) _citationText(article.metin),
      if ((article.metadata['degisiklik_notlari'] as List?)?.isNotEmpty == true) ExpansionTile(title: const Text('Değişiklik notları'), children: [for (final n in (article.metadata['degisiklik_notlari'] as List)) ListTile(title: Text(n.toString()))]),
    ]),
  );
}

class LegislationDiffScreen extends StatelessWidget {
  final LegislationChange change;
  const LegislationDiffScreen({super.key, required this.change});
  @override Widget build(BuildContext context) => Scaffold(appBar: AppBar(title: Text('${change.maddeRef} değişikliği')), body: ListView(padding: const EdgeInsets.all(16), children: [Text(change.summary, style: Theme.of(context).textTheme.titleMedium), const SizedBox(height: 16), const Text('Önceki sürüm', style: TextStyle(fontWeight: FontWeight.bold)), SelectableText(change.oldText ?? 'Madde önceki sürümde yoktu'), const SizedBox(height: 20), const Text('Yeni sürüm', style: TextStyle(fontWeight: FontWeight.bold)), SelectableText(change.newText ?? 'Madde yeni sürümde yok') ]));
}

class MaddeNotesScreen extends StatelessWidget {
  final String lawNo;
  const MaddeNotesScreen({super.key, required this.lawNo});
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('$lawNo notları')),
      body: FutureBuilder<List<MaddeNote>>(
        future: LocalStore.listMaddeNotes(lawNo),
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          final notes = snap.data ?? const <MaddeNote>[];
          if (notes.isEmpty) return const Center(child: Text('Bu kanunda henüz not yok'));
          return ListView.builder(
            itemCount: notes.length,
            itemBuilder: (_, i) {
              final n = notes[i];
              return ListTile(
                leading: Icon(n.kind == 'bookmark' ? Icons.bookmark : n.kind == 'highlight' ? Icons.highlight : Icons.note),
                title: Text(n.maddeRef),
                subtitle: Text(n.text.isEmpty ? (n.seciliMetinAraligi ?? 'Seçili metin') : n.text, maxLines: 2, overflow: TextOverflow.ellipsis),
              );
            },
          );
        },
      ),
    );
  }
}
