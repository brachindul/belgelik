import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'config.dart';
import 'local_store.dart';
import 'models.dart';

enum SyncPhase { idle, syncing, offline, error }

class SyncStatus {
  final SyncPhase phase;
  final int pending;
  final int lastSyncMs;
  const SyncStatus(this.phase, this.pending, this.lastSyncMs);
}

class SyncService {
  static bool _syncing = false;
  static int _lastPullMs = 0;
  static final ValueNotifier<SyncStatus> status = ValueNotifier(
    const SyncStatus(SyncPhase.idle, 0, 0),
  );
  static Timer? _autoTimer;

  static Future<void> _refreshStatus(SyncPhase phase) async {
    final pending = await LocalStore.pendingCount();
    final last =
        int.tryParse(await LocalStore.getSyncState('last_sync_ms') ?? '') ??
        status.value.lastSyncMs;
    status.value = SyncStatus(phase, pending, last);
  }

  static void startAutoSync({Duration interval = const Duration(minutes: 2)}) {
    _autoTimer?.cancel();
    syncNow();
    _autoTimer = Timer.periodic(interval, (_) => syncNow());
  }

  static void stopAutoSync() {
    _autoTimer?.cancel();
    _autoTimer = null;
  }

  static Future<void> init() async {
    await LocalStore.init();
    _lastPullMs =
        int.tryParse(await LocalStore.getSyncState('last_pull_ms') ?? '') ?? 0;
  }

  static Future<bool> isOnline() async {
    try {
      final res = await http
          .get(
            Uri.parse('${AppConfig.baseUrl}/health'),
            headers: {'X-Auth-Token': AppConfig.token},
          )
          .timeout(const Duration(seconds: 3));
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  static Future<void> syncNow() async {
    if (_syncing) return;
    _syncing = true;
    await _refreshStatus(SyncPhase.syncing);
    try {
      final online = await isOnline();
      if (!online) {
        await _refreshStatus(SyncPhase.offline);
        _syncing = false;
        return;
      }
      final pushOk = await _pushDirty();
      final pullOk = await _pull();
      if (!pushOk || !pullOk) {
        await _refreshStatus(SyncPhase.error);
        return;
      }
      await LocalStore.setSyncState(
        'last_sync_ms',
        DateTime.now().millisecondsSinceEpoch.toString(),
      );
      await _refreshStatus(SyncPhase.idle);
    } catch (e) {
      debugPrint('Sync failed: $e');
      await _refreshStatus(SyncPhase.error);
    } finally {
      _syncing = false;
    }
  }

  // Jenerik sync varlik listesi: her kayit tipi tek yerde tanimli. Yeni tip
  // eklemek 6-7 yerine tek satir. Sunucu /sync/v2 registry'siyle esler
  // (entity adlari birebir: position, annotation, ...).
  static List<_SyncEntity> _entities() => [
    _SyncEntity('position', LocalStore.getDirtyPositions, _positionPayload,
        (r) => LocalStore.clearPositionDirty(r['doc_id'] as String),
        _applyRemotePosition),
    _SyncEntity('annotation', LocalStore.getDirtyAnnotations, _annotationPayload,
        (r) => LocalStore.clearAnnotationDirty(r['stroke_uuid'] as String),
        LocalStore.applyRemoteAnnotation),
    _SyncEntity('favorite', LocalStore.getDirtyFavorites, _favoritePayload,
        (r) => LocalStore.clearFavoriteDirty(r['doc_id'] as String),
        LocalStore.applyRemoteFavorite),
    _SyncEntity('recent', LocalStore.getDirtyRecent, _recentPayload,
        (r) => LocalStore.clearRecentDirty(r['doc_id'] as String),
        LocalStore.applyRemoteRecent),
    _SyncEntity('reading_goal', LocalStore.getDirtyReadingGoals, _goalPayload,
        (r) => LocalStore.clearReadingGoalDirty(
            r['doc_id'] as String, r['date'] as String),
        (m) => LocalStore.upsertReadingGoal(ReadingGoal.fromJson(m), dirty: false)),
    _SyncEntity('bookmark', LocalStore.getDirtyBookmarks, _bookmarkPayload,
        (r) => LocalStore.clearBookmarkDirty(r['bookmark_uuid'] as String),
        LocalStore.applyRemoteBookmark),
    _SyncEntity('pomodoro', LocalStore.getDirtyPomodoroSessions, _pomodoroPayload,
        (r) => LocalStore.clearPomodoroDirty(r['session_uuid'] as String),
        LocalStore.applyRemotePomodoroSession),
    _SyncEntity('legislation_position', LocalStore.getDirtyLegislationPositions, _legislationPositionPayload,
        (r) => LocalStore.clearLegislationPositionDirty(r['mevzuat_no'] as String),
        LocalStore.applyRemoteLegislationPosition),
    _SyncEntity('madde_note', LocalStore.getDirtyMaddeNotes, _maddeNotePayload,
        (r) => LocalStore.clearMaddeNoteDirty(r['note_uuid'] as String),
        LocalStore.applyRemoteMaddeNote),
  ];

  static Future<bool> _pushDirty() async {
    try {
      final entities = _entities();
      final ops = <Map<String, dynamic>>[];
      final dirtyByEntity = <String, List<Map<String, dynamic>>>{};
      for (final e in entities) {
        final rows = await e.getDirty();
        dirtyByEntity[e.name] = rows;
        for (final r in rows) {
          ops.add({'entity': e.name, 'data': e.toPayload(r)});
        }
      }
      if (ops.isEmpty) return true;

      final res = await http
          .post(
            Uri.parse('${AppConfig.baseUrl}/sync/v2/push'),
            headers: {
              'X-Auth-Token': AppConfig.token,
              'Content-Type': 'application/json',
            },
            body: jsonEncode({'device_id': LocalStore.deviceId, 'ops': ops}),
          )
          .timeout(const Duration(seconds: 30));

      if (res.statusCode != 200) return false;

      for (final e in entities) {
        for (final r in dirtyByEntity[e.name]!) {
          await e.clearDirty(r);
        }
      }
      return true;
    } catch (e) {
      debugPrint('Sync push failed: $e');
      return false;
    }
  }

  /// Pozisyon icin LWW: sunucudaki daha yeniyse uygula (yereldeki dirty degilse).
  static Future<void> _applyRemotePosition(Map<String, dynamic> posMap) async {
    final docId = posMap['doc_id'] as String;
    final local = await LocalStore.getPosition(docId);
    final serverMs = posMap['updated_at_ms'] as int? ?? 0;
    if (local == null || serverMs > local.updatedAt) {
      await LocalStore.applyRemotePosition(posMap);
    }
  }

  static Map<String, dynamic> _positionPayload(Map<String, dynamic> r) => {
    'doc_id': r['doc_id'],
    'page': r['page'],
    'updated_at_ms': r['updated_at_ms'],
    'updated_by_device': r['updated_by_device'],
    'deleted_at_ms': r['deleted_at_ms'],
  };

  static Map<String, dynamic> _annotationPayload(Map<String, dynamic> r) => {
    'stroke_uuid': r['stroke_uuid'],
    'doc_id': r['doc_id'],
    'page': r['page'],
    'kind': r['kind'],
    'color': r['color'],
    'width': r['width'],
    'points': jsonDecode(r['points'] as String),
    'text': r['text'],
    'font_size': r['font_size'],
    'font_family': r['font_family'],
    'updated_at_ms': r['updated_at_ms'],
    'updated_by_device': r['updated_by_device'],
    'deleted_at_ms': r['deleted_at_ms'],
  };

  static Map<String, dynamic> _favoritePayload(Map<String, dynamic> r) => {
    'doc_id': r['doc_id'],
    'favorite': (r['favorite'] as int) == 1,
    'updated_at_ms': r['updated_at_ms'],
    'updated_by_device': r['updated_by_device'],
  };

  static Map<String, dynamic> _recentPayload(Map<String, dynamic> r) => {
    'doc_id': r['doc_id'],
    'opened_at_ms': r['opened_at_ms'],
    'updated_by_device': r['updated_by_device'],
  };

  static Map<String, dynamic> _goalPayload(Map<String, dynamic> r) => {
    'doc_id': r['doc_id'],
    'date': r['date'],
    'start_page': r['start_page'],
    'target_pages': r['target_pages'],
    'updated_at_ms': r['updated_at_ms'],
    'updated_by_device': r['updated_by_device'],
    'deleted_at_ms': r['deleted_at_ms'],
  };

  static Map<String, dynamic> _bookmarkPayload(Map<String, dynamic> r) => {
    'bookmark_uuid': r['bookmark_uuid'],
    'doc_id': r['doc_id'],
    'page': r['page'],
    'label': r['label'],
    'updated_at_ms': r['updated_at_ms'],
    'updated_by_device': r['updated_by_device'],
    'deleted_at_ms': r['deleted_at_ms'],
  };

  static Map<String, dynamic> _pomodoroPayload(Map<String, dynamic> r) => {
    'session_uuid': r['session_uuid'],
    'date': r['date'],
    'subject': r['subject'],
    'phase': r['phase'],
    'minutes': r['minutes'],
    'started_at_ms': r['started_at_ms'],
    'updated_at_ms': r['updated_at_ms'],
    'updated_by_device': r['updated_by_device'],
    'deleted_at_ms': r['deleted_at_ms'],
  };

  static Map<String, dynamic> _legislationPositionPayload(Map<String, dynamic> r) => {
    'mevzuat_no': r['mevzuat_no'],
    'madde_ref': r['madde_ref'],
    'updated_at_ms': r['updated_at_ms'],
    'updated_by_device': r['updated_by_device'],
    'deleted_at_ms': r['deleted_at_ms'],
  };

  static Map<String, dynamic> _maddeNotePayload(Map<String, dynamic> r) => {
    'note_uuid': r['note_uuid'],
    'madde_ref': r['madde_ref'],
    'kind': r['kind'],
    'renk': r['renk'],
    'secili_metin_araligi': r['secili_metin_araligi'],
    'text': r['text'],
    'updated_at_ms': r['updated_at_ms'],
    'updated_by_device': r['updated_by_device'],
    'deleted_at_ms': r['deleted_at_ms'],
  };

  static Future<bool> _pull() async {
    try {
      final res = await http
          .get(
            Uri.parse('${AppConfig.baseUrl}/sync/v2/pull?since_ms=$_lastPullMs'),
            headers: {'X-Auth-Token': AppConfig.token},
          )
          .timeout(const Duration(seconds: 30));
      if (res.statusCode != 200) {
        debugPrint('Sync pull failed: HTTP ${res.statusCode}');
        return false;
      }
      final data =
          jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;

      final apply = {for (final e in _entities()) e.name: e.applyRemote};
      if (data['ops'] != null) {
        for (final op in data['ops'] as List) {
          final m = op as Map<String, dynamic>;
          final handler = apply[m['entity']];
          if (handler != null) {
            await handler(m['data'] as Map<String, dynamic>);
          }
        }
      }
      if (data['deleted_docs'] != null) {
        for (final d in data['deleted_docs'] as List) {
          await LocalStore.applyRemoteDeletedDoc(d as Map<String, dynamic>);
        }
      }
      _lastPullMs = (data['server_time_ms'] as int?) ?? _lastPullMs;
      await LocalStore.setSyncState('last_pull_ms', _lastPullMs.toString());
      return true;
    } catch (e) {
      debugPrint('Sync pull failed: $e');
      return false;
    }
  }
}

/// Tek bir sync varlik tipinin tanimi: dirty okuma, sunucu payload'ina cevirme,
/// dirty temizleme ve sunucudan gelen kaydi yerele uygulama.
class _SyncEntity {
  final String name;
  final Future<List<Map<String, dynamic>>> Function() getDirty;
  final Map<String, dynamic> Function(Map<String, dynamic> row) toPayload;
  final Future<void> Function(Map<String, dynamic> row) clearDirty;
  final Future<void> Function(Map<String, dynamic> data) applyRemote;

  const _SyncEntity(
    this.name,
    this.getDirty,
    this.toPayload,
    this.clearDirty,
    this.applyRemote,
  );
}
