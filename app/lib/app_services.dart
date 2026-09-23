import 'api.dart';
export 'api.dart';

/// Basit kompozisyon koku: servis ornekleri tek yerde. Testler sahte
/// ApiClient enjekte etmek icin AppServices.instance'i degistirir.
/// (SyncService/LocalStore sonraki asamada instance'a cevrilecek.)
class AppServices {
  final ApiClient api;
  AppServices({required this.api});

  static late AppServices instance;
}
