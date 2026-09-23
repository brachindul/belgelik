import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:belgelik/app_services.dart';
import 'package:belgelik/models.dart';

/// Bolum 10 kaniti: ApiClient artik enjekte edilebilir. Sahte istemci gercek
/// HTTP yapmadan UI'i besler; testte ag/sunucu gerekmez.
class _FakeApi extends ApiClient {
  @override
  Future<List<PdfDoc>> listPdfs() async => [
        PdfDoc(
          id: 'x',
          name: 'Sahte PDF',
          relativePath: 'x.pdf',
          size: 1,
          modified: 1,
          favorite: false,
        ),
      ];
}

void main() {
  testWidgets('enjekte edilen FakeApiClient UI\'i besler', (tester) async {
    AppServices.instance = AppServices(api: _FakeApi());

    await tester.pumpWidget(
      MaterialApp(
        home: FutureBuilder<List<PdfDoc>>(
          future: AppServices.instance.api.listPdfs(),
          builder: (context, snap) => snap.hasData
              ? Text(snap.data!.first.name)
              : const SizedBox.shrink(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Sahte PDF'), findsOneWidget);
  });
}
