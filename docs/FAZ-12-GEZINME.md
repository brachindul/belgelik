# FAZ 12 — Gezinme: Sayfaya Git + Küçük Resim Izgarası

> **Ajana not:** Önce `ROADMAP-V2.md` FAZ 12'yi oku. Tamamen istemci tarafı (reader). Sunucu YOK. Büyük PDF'te çökmemeli — thumbnail'lar **lazy** (sadece görünür hücreler) render edilmeli. pdfrx `PdfPageView` API'si sürümde farklıysa DUR ve raporla.

## Amaç
1. Üst çubukta "12 / 340" sayfa göstergesi; dokununca sayfa numarası gir → atla.
2. Küçük resim ızgarası paneli; sayfaya dokununca o sayfaya atla.

---

## ADIM 1 — Sayfa göstergesi + sayfaya git (reader)
`reader_screen.dart`'ta state'te `_pageCount` zaten var; `_currentPage` var.

Üst başlığa (AppBar `title`) sayfa göstergesini ekleyebilirsin ama dar; **alt araç çubuğuna** küçük bir gösterge daha temiz. `_readerToolBar` Row'una (sağ uca) ekle:
```dart
            const Spacer(),
            InkWell(
              onTap: _goToPageDialog,
              borderRadius: BorderRadius.circular(6),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                child: Text(
                  _pageCount == null
                      ? '$_currentPage'
                      : '$_currentPage / $_pageCount',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
            ),
            IconButton(
              tooltip: 'Küçük resimler',
              iconSize: 22,
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 40, minHeight: 32),
              onPressed: _openThumbnails,
              icon: const Icon(Icons.grid_view),
            ),
```
> `_readerToolBar`'daki ana `Row`'un `mainAxisAlignment: MainAxisAlignment.center` ise, `Spacer` ile sağa itmek için `MainAxisAlignment.start` yapman veya yapıyı `Row` + `Expanded` ile düzenlemen gerekebilir. Pratik: tool butonlarını bir grupta tutup `Spacer()` sonrası göstergeyi koy.

Sayfaya git dialog:
```dart
  Future<void> _goToPageDialog() async {
    final ctrl = TextEditingController(text: '$_currentPage');
    final n = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Sayfaya git'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(
            labelText: _pageCount == null ? 'Sayfa' : 'Sayfa (1-$_pageCount)',
          ),
          onSubmitted: (v) => Navigator.pop(ctx, int.tryParse(v)),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('İptal')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, int.tryParse(ctrl.text)),
            child: const Text('Git'),
          ),
        ],
      ),
    );
    if (n == null) return;
    final total = _pageCount ?? n;
    final target = n.clamp(1, total);
    _controller.goToPage(pageNumber: target);
  }
```

---

## ADIM 2 — Küçük resim ızgarası
```dart
  void _openThumbnails() {
    final doc = _controller.document;
    final count = _pageCount ?? 0;
    if (count == 0) return;
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => FractionallySizedBox(
        heightFactor: 0.85,
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: GridView.builder(
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              childAspectRatio: 0.72,
              crossAxisSpacing: 8,
              mainAxisSpacing: 8,
            ),
            itemCount: count,
            itemBuilder: (context, i) {
              final pageNo = i + 1;
              return InkWell(
                onTap: () {
                  Navigator.pop(ctx);
                  _controller.goToPage(pageNumber: pageNo);
                },
                child: Column(
                  children: [
                    Expanded(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          border: Border.all(
                              color: pageNo == _currentPage
                                  ? Theme.of(context).colorScheme.primary
                                  : Theme.of(context).dividerColor),
                        ),
                        child: PdfPageView(
                          document: doc,
                          pageNumber: pageNo,
                        ),
                      ),
                    ),
                    Text('$pageNo', style: const TextStyle(fontSize: 11)),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }
```
> `PdfPageView` pdfrx'in tek sayfa render widget'ıdır; `GridView.builder` zaten **lazy** olduğu için yalnızca görünür hücreler render edilir → bellek dostu. `import 'package:pdfrx/pdfrx.dart';` zaten var. `_controller.document` erişimi sürüme göre farklıysa (örn. `documentRef`), DUR ve doğru erişimi raporla.

---

## TEST
1. Büyük PDF (örn. 340 sayfa) aç.
2. Alt çubukta "X / 340" göster; dokun → sayfa gir → atlar.
3. Izgara butonu → küçük resimler açılır, akıcı kaydırılır (takılmaz/çökmez), dokunulan sayfaya gider.
4. Geçerli sayfa ızgarada vurgulu.

## DOĞRULAMA
- [ ] Sayfa göstergesi doğru güncellenir
- [ ] Sayfaya git çalışır, sınır dışı değer kırpılır
- [ ] Izgara lazy render — büyük PDF'te OOM yok
- [ ] Çizim/sync/regresyon yok

```powershell
cd <PROJE> && git add -A && git commit -m "Faz 12: sayfaya git + kucuk resim izgarasi"
```
