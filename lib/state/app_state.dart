import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/emby_api.dart';

class AppState extends ChangeNotifier {
  String? _baseUrl;
  String? _token;
  List<DomainInfo> _domains = [];
  bool _loading = false;
  String? _error;

  String? get baseUrl => _baseUrl;
  String? get token => _token;
  List<DomainInfo> get domains => _domains;
  bool get isLoading => _loading;
  String? get error => _error;

  Future<void> loadFromStorage() async {
    final prefs = await SharedPreferences.getInstance();
    _baseUrl = prefs.getString('baseUrl');
    _token = prefs.getString('token');
    notifyListeners();
  }

  Future<void> logout() async {
    _baseUrl = null;
    _token = null;
    _domains = [];
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('baseUrl');
    await prefs.remove('token');
    notifyListeners();
  }

  Future<void> login({
    required String baseUrl,
    required String username,
    required String password,
  }) async {
    _loading = true;
    _error = null;
    notifyListeners();

    try {
      final api = EmbyApi(baseUrl);
      final tk = await api.authenticate(username: username, password: password);
      final lines = await api.fetchDomains(tk);
      _baseUrl = baseUrl;
      _token = tk;
      _domains = lines;

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('baseUrl', baseUrl);
      await prefs.setString('token', tk);
    } catch (e) {
      _error = e.toString();
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  Future<void> refreshDomains() async {
    if (_baseUrl == null || _token == null) return;
    _loading = true;
    notifyListeners();
    try {
      final api = EmbyApi(_baseUrl!);
      _domains = await api.fetchDomains(_token!);
      _error = null;
    } catch (e) {
      _error = e.toString();
    } finally {
      _loading = false;
      notifyListeners();
    }
  }
}
