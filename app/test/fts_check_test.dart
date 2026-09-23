import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:belgelik/local_store.dart';

// Mevzuat FTS katmani: masaustu (ffi) SQLite'inde fts5, Android'in yerlesik
// SQLite'inde ise yalnizca fts4 bulunur. LocalStore hangisi varsa onu kurar.
// Bu test ffi uzerinde tam akisi dogrular: kurulum (migration dahil),
// paket yukleme ve snippet'li arama.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final dir = await Directory.systemTemp.createTemp('belgelik_fts_test');
    await databaseFactory.setDatabasesPath(dir.path);
    await LocalStore.init();
  });

  test('mevzuat paketi kurulur ve FTS aramasi snippet dondurur', () async {
    await LocalStore.installLegislation({
      'mevzuat': {
        'mevzuat_no': '5237',
        'ad': 'Türk Ceza Kanunu',
        'kisa_ad': 'TCK',
        'tur': 'Kanun',
        'snapshot_version': 'v1',
      },
      'articles': [
        {
          'id': '5237/1',
          'sira': 1,
          'baslik': 'Amaç',
          'madde_no_raw': 'Madde 1',
          'metin': 'Ceza Kanununun amacı; kişi hak ve özgürlüklerini korumaktır.',
          'metadata': <String, dynamic>{},
          'snapshot_version': 'v1',
        },
        {
          'id': '5237/2',
          'sira': 2,
          'baslik': 'Suçta ve cezada kanunilik ilkesi',
          'madde_no_raw': 'Madde 2',
          'metin': 'Kanunun açıkça suç saymadığı bir fiil için kimseye ceza verilemez.',
          'metadata': <String, dynamic>{},
          'snapshot_version': 'v1',
        },
      ],
    });

    final hits = await LocalStore.searchLegislation('kanunilik');
    expect(hits, hasLength(1));
    expect(hits.first['madde_ref'], '5237/2');
    expect(hits.first['snippet'], contains('['));

    // On-ek aramasi ve birden fazla sonuc.
    final prefixHits = await LocalStore.searchLegislation('ceza');
    expect(prefixHits.length, 2);

    // Ozel karakterler sorguyu bozmamali (temizlenip aranmali).
    final weird = await LocalStore.searchLegislation('"kanun*" (ilkesi)');
    expect(weird, hasLength(1));
    expect(weird.first['madde_ref'], '5237/2');
  });
}
