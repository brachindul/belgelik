# FAZ 16 — Sync Sağlamlığı + Durum Göstergesi

> **Ajana not:** Önce `ROADMAP-V2.md` FAZ 16'yı oku. Mevcut `SyncService` (init/isOnline/syncNow) ve offline-first deseni ÜZERİNE eklenir; mantığı bozma. DOĞRULAMA başarısızsa dur.

## Amaç
1. Uygulama açıkken **periyodik otomatik sync** + uygulama öne gelince sync.
2. **Bekleyen değişiklik sayısı** (dirty) + **son sync zamanı** + **durum** (senkron/senkronize ediliyor/çevrimdışı/hata) görünür.
3. Çevrimdışı yapılan değişiklikler online olunca otomatik gider (zaten dirty kalıyor; periyodik sync tetikler).

---

## ADIM 1 — `local_store.dart`: bekleyen sayısı
```dart
  static Future<int> pendingCount() async {
    final db = await database;
    const tables = [
      'local_positions',
      'local_annotations',
      'local_favorites',
      'local_recent',
      'local_reading_goals',
      'local_bookmarks',
    ];
    var total = 0;
    for (final t in tables) {
      final r = await db.rawQuery('SELECT COUNT(*) AS c FROM $t WHERE dirty = 1');
      total += (r.first['c'] as int?) ?? 0;
    }
    return total;
  }
```
> `local_bookmarks` FAZ 11'de eklendi; yoksa listeden çıkar.

## ADIM 2 — `sync_service.dart`: durum + otomatik sync
Sınıfa EKLE:
```dart
import 'dart:async';
import 'package:flutter/foundation.dart';

enum SyncPhase { idle, syncing, offline, error }

class SyncStatus {
  final SyncPhase phase;
  final int pending;
  final int lastSyncMs;
  const SyncStatus(this.phase, this.pending, this.lastSyncMs);
}
```
`SyncService` içine:
```dart
  static final ValueNotifier<SyncStatus> status =
      ValueNotifier(const SyncStatus(SyncPhase.idle, 0, 0));
  static Timer? _autoTimer;

  static Future<void> _refreshStatus(SyncPhase phase) async {
    final pending = await LocalStore.pendingCount();
    final last = int.tryParse(
            await LocalStore.getSyncState('last_sync_ms') ?? '') ??
        status.value.lastSyncMs;
    status.value = SyncStatus(phase, pending, last);
  }

  static void startAutoSync({Duration interval = const Duration(seconds: 30)}) {
    _autoTimer?.cancel();
    syncNow();
    _autoTimer = Timer.periodic(interval, (_) => syncNow());
  }

  static void stopAutoSync() {
    _autoTimer?.cancel();
    _autoTimer = null;
  }
```
`syncNow()`'u durum güncelleyecek şekilde sarmala (mevcut gövdeyi koru, başına/sonuna ekle):
```dart
  static Future<void> syncNow() async {
    if (_syncing) return;
    _syncing = true;
    await _refreshStatus(SyncPhase.syncing);
    try {
      final online = await isOnline();
      if (!online) {
        await _refreshStatus(SyncPhase.offline);
        return;
      }
      final pushed = await _pushDirty();
      if (!pushed) {
        await _refreshStatus(SyncPhase.error);
        return;
      }
      await _pull();
      await LocalStore.setSyncState(
          'last_sync_ms', DateTime.now().millisecondsSinceEpoch.toString());
      await _refreshStatus(SyncPhase.idle);
    } catch (_) {
      await _refreshStatus(SyncPhase.error);
    } finally {
      _syncing = false;
    }
  }
```
> Mevcut `_pushDirty`/`_pull`/`isOnline` aynen kalır.

## ADIM 3 — Otomatik sync'i başlat + yaşam döngüsü
`app/lib/main.dart`'ta `BelgelikApp`'i (veya `HomeShell`'i) `WidgetsBindingObserver` ile uygulama öne gelince sync edecek şekilde bağla. En temizi `HomeShell`'i StatefulWidget yapıp:
```dart
class _HomeShellState extends State<HomeShell> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    SyncService.startAutoSync();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    SyncService.stopAutoSync();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) SyncService.syncNow();
  }
  // ... mevcut build ...
}
```
> `HomeShell` zaten StatefulWidget ise sadece observer + startAutoSync ekle.

## ADIM 4 — Durum rozeti (kütüphane)
`library_screen.dart`'taki mevcut `_isOnline` bulut ikonunu `SyncService.status`'u dinleyen bir göstergeyle değiştir/zenginleştir:
```dart
                ValueListenableBuilder<SyncStatus>(
                  valueListenable: SyncService.status,
                  builder: (context, s, _) {
                    IconData icon;
                    Color color;
                    String tip;
                    switch (s.phase) {
                      case SyncPhase.syncing:
                        icon = Icons.sync;
                        color = Colors.blue;
                        tip = 'Senkronize ediliyor';
                      case SyncPhase.offline:
                        icon = Icons.cloud_off;
                        color = Colors.orange;
                        tip = 'Çevrimdışı';
                      case SyncPhase.error:
                        icon = Icons.sync_problem;
                        color = Colors.red;
                        tip = 'Sync hatası';
                      case SyncPhase.idle:
                        icon = Icons.cloud_done;
                        color = Colors.green;
                        tip = s.pending > 0
                            ? '${s.pending} değişiklik bekliyor'
                            : 'Senkron';
                    }
                    return IconButton(
                      tooltip: tip,
                      icon: Badge(
                        isLabelVisible: s.pending > 0,
                        label: Text('${s.pending}'),
                        child: Icon(icon, size: 20, color: color),
                      ),
                      onPressed: () => SyncService.syncNow(),
                    );
                  },
                ),
```
> Mevcut `_checkOnline`/`_isOnline` artık gereksizse kaldırılabilir (opsiyonel). Rozete dokununca elle sync.

## TEST
1. Uygulama açıkken ~30 sn'de bir sync olur (logla/gözlemle).
2. Çevrimdışıyken (sunucu kapalı) değişiklik yap (yer imi/çizim) → rozet "çevrimdışı / N bekliyor".
3. Sunucuyu aç → birkaç sn içinde otomatik gönderilir, rozet "Senkron"a döner, N=0.
4. Uygulamayı arka plana al, geri getir → sync tetiklenir.
5. Rozete dokununca elle sync olur.

## DOĞRULAMA
- [ ] Periyodik + resume sync çalışıyor
- [ ] Bekleyen sayısı doğru, son sync sonrası 0
- [ ] Durum ikonu doğru (senkron/ediliyor/çevrimdışı/hata)
- [ ] Çevrimdışı değişiklik online olunca otomatik gidiyor
- [ ] Regresyon yok

```powershell
cd <PROJE> && git add -A && git commit -m "Faz 16: sync saglamligi (periyodik + durum rozeti + bekleyen sayisi)"
```

## Ajan kuralları
1. Mevcut `syncNow/_pushDirty/_pull/isOnline` mantığını bozma; sadece sarmala/ekle.
2. `getSyncState/setSyncState` mevcut (sync_state tablosu). Yoksa raporla.
3. Periyodik aralığı makul tut (pil). Değişiklik yoksa erken çık (mevcut davranış korunur).
