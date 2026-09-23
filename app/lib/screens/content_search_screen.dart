import 'dart:async';

import 'package:flutter/material.dart';

import '../app_services.dart';
import '../models.dart';
import 'reader_host_screen.dart';

class ContentSearchScreen extends StatefulWidget {
  final String? initialQuery;

  const ContentSearchScreen({super.key, this.initialQuery});

  @override
  State<ContentSearchScreen> createState() => _ContentSearchScreenState();
}

class _ContentSearchScreenState extends State<ContentSearchScreen> {
  final _ctrl = TextEditingController();
  Timer? _debounce;
  Future<List<SearchHit>>? _future;

  @override
  void initState() {
    super.initState();
    final initial = widget.initialQuery?.trim();
    if (initial != null && initial.isNotEmpty) {
      _ctrl.text = initial;
      if (initial.length >= 2) {
        _future = AppServices.instance.api.searchContent(initial);
      }
    }
  }

  void _onChanged(String v) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), () {
      final q = v.trim();
      if (q.length < 2) {
        setState(() => _future = null);
        return;
      }
      setState(() => _future = AppServices.instance.api.searchContent(q));
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: TextField(
          controller: _ctrl,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'Tüm PDF’lerde ara...',
            border: InputBorder.none,
          ),
          onChanged: _onChanged,
        ),
      ),
      body: _future == null
          ? const Center(child: Text('En az 2 harf yazın'))
          : FutureBuilder<List<SearchHit>>(
              future: _future,
              builder: (context, snap) {
                if (snap.connectionState != ConnectionState.done) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (snap.hasError) {
                  return Center(child: Text('Hata: ${snap.error}'));
                }
                final hits = snap.data!;
                if (hits.isEmpty) {
                  return const Center(child: Text('Sonuç yok'));
                }
                return ListView.separated(
                  itemCount: hits.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, i) {
                    final h = hits[i];
                    return ListTile(
                      leading: const Icon(Icons.find_in_page),
                      title: Text(
                        '${h.name}  ·  s.${h.page}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        h.snippet,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => ReaderHostScreen(
                            doc: h.toPdfDoc(),
                            initialPage: h.page,
                          ),
                        ),
                      ),
                    );
                  },
                );
              },
            ),
    );
  }
}
