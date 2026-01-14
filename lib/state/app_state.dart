import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/emby_api.dart';

class AppState extends ChangeNotifier {
  String? _baseUrl;
  String? _token;
  String? _userId;
  List<DomainInfo> _domains = [];
  List<LibraryInfo> _libraries = [];
  final Map<String, List<MediaItem>> _itemsCache = {};
  final Map<String, int> _itemsTotal = {};
  final Map<String, List<MediaItem>> _homeSections = {};
  final Set<String> _hiddenLibraries = {};
  late final String _deviceId = _randomId();
  bool _loading = false;
  String? _error;

  static String _randomId() {
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    final rand = DateTime.now().microsecondsSinceEpoch;
    return List.generate(16, (i) => chars[(rand + i * 31) % chars.length]).join();
  }

  String? get baseUrl => _baseUrl;
  String? get token => _token;
  String? get userId => _userId;
  String get deviceId => _deviceId;
  List<DomainInfo> get domains => _domains;
  List<LibraryInfo> get libraries => _libraries;
  List<MediaItem> getItems(String parentId) => _itemsCache[parentId] ?? [];
  int getTotal(String parentId) => _itemsTotal[parentId] ?? 0;
  List<MediaItem> getHome(String key) => _homeSections[key] ?? [];
  Iterable<HomeEntry> get homeEntries sync* {
    for (final entry in _homeSections.entries) {
      if (entry.key.startsWith('lib_')) {
        final libId = entry.key.substring(4);
        final name = _libraries.firstWhere(
          (l) => l.id == libId,
          orElse: () => LibraryInfo(id: libId, name: '媒体库', type: ''),
        ).name;
        if (_hiddenLibraries.contains(libId)) continue;
        yield HomeEntry(key: entry.key, displayName: name, items: entry.value);
      }
    }
  }
  bool get isLoading => _loading;
  String? get error => _error;

  Future<void> loadFromStorage() async {
    final prefs = await SharedPreferences.getInstance();
    _baseUrl = prefs.getString('baseUrl');
    _token = prefs.getString('token');
    _userId = prefs.getString('userId');
    _hiddenLibraries
      ..clear()
      ..addAll(prefs.getStringList('hiddenLibs') ?? []);
    notifyListeners();
  }

  Future<void> logout() async {
    _baseUrl = null;
    _token = null;
    _userId = null;
    _domains = [];
    _libraries = [];
    _itemsCache.clear();
    _itemsTotal.clear();
    _homeSections.clear();
    _hiddenLibraries.clear();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('baseUrl');
    await prefs.remove('token');
    await prefs.remove('userId');
    await prefs.remove('hiddenLibs');
    notifyListeners();
  }

  Future<void> login({
    required String hostOrUrl,
    required String scheme,
    String? port,
    required String username,
    required String password,
  }) async {
    _loading = true;
    _error = null;
    notifyListeners();

    try {
      final api = EmbyApi(hostOrUrl: hostOrUrl, preferredScheme: scheme, port: port);
      final auth = await api.authenticate(
        username: username,
        password: password,
        deviceId: _deviceId,
      );
      final lines = await api.fetchDomains(auth.token, auth.baseUrlUsed, allowFailure: true);
      final libs = await api.fetchLibraries(
        token: auth.token,
        baseUrl: auth.baseUrlUsed,
        userId: auth.userId,
      );
      _baseUrl = auth.baseUrlUsed;
      _token = auth.token;
      _userId = auth.userId;
      _domains = lines;
      _libraries = libs;
      _itemsCache.clear();
      _itemsTotal.clear();
      _homeSections.clear();

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('baseUrl', auth.baseUrlUsed);
      await prefs.setString('token', auth.token);
      await prefs.setString('userId', auth.userId);
      await prefs.setStringList('hiddenLibs', _hiddenLibraries.toList());
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
      final api = EmbyApi(hostOrUrl: _baseUrl!, preferredScheme: 'https');
      _domains = await api.fetchDomains(_token!, _baseUrl!, allowFailure: true);
      _error = null;
    } catch (e) {
      _error = e.toString();
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  Future<void> refreshLibraries() async {
    if (_baseUrl == null || _token == null) return;
    _loading = true;
    notifyListeners();
    try {
      final api = EmbyApi(hostOrUrl: _baseUrl!, preferredScheme: 'https');
      _libraries = await api.fetchLibraries(
        token: _token!,
        baseUrl: _baseUrl!,
        userId: _userId!,
      );
      _itemsCache.clear();
      _itemsTotal.clear();
      _homeSections.clear();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList('hiddenLibs', _hiddenLibraries.toList());
      _error = null;
    } catch (e) {
      _error = e.toString();
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  Future<void> loadItems({
    required String parentId,
    int startIndex = 0,
    int limit = 30,
    String? includeItemTypes,
    String? searchTerm,
    bool recursive = false,
    bool excludeFolders = true,
    String? sortBy,
    String sortOrder = 'Descending',
  }) async {
    if (_baseUrl == null || _token == null || _userId == null) {
      throw Exception('未登录');
    }
    final api = EmbyApi(hostOrUrl: _baseUrl!, preferredScheme: 'https');
    final result = await api.fetchItems(
      token: _token!,
      baseUrl: _baseUrl!,
      userId: _userId!,
      parentId: parentId,
      startIndex: startIndex,
      limit: limit,
      includeItemTypes: includeItemTypes,
      searchTerm: searchTerm,
      recursive: recursive,
      excludeFolders: excludeFolders,
      sortBy: sortBy,
      sortOrder: sortOrder,
    );
    final list = _itemsCache[parentId] ?? [];
    if (startIndex == 0) {
      _itemsCache[parentId] = result.items;
    } else {
      list.addAll(result.items);
      _itemsCache[parentId] = list;
    }
    _itemsTotal[parentId] = result.total;
    notifyListeners();
  }

  Future<void> loadHome() async {
    if (_baseUrl == null || _token == null || _userId == null) return;
    final api = EmbyApi(hostOrUrl: _baseUrl!, preferredScheme: 'https');
    final Map<String, List<MediaItem>> libraryShows = {};
    for (final lib in _libraries) {
      try {
        final fetched = await api.fetchItems(
          token: _token!,
          baseUrl: _baseUrl!,
          userId: _userId!,
          parentId: lib.id,
          includeItemTypes: 'Series,Movie',
          recursive: true,
          excludeFolders: false,
          limit: 12,
          sortBy: 'DateCreated',
        );
        libraryShows['lib_${lib.id}'] = fetched.items;
      } catch (_) {
        // ignore failures per library
      }
    }
    _homeSections
      ..clear()
      ..addAll(libraryShows);
    notifyListeners();
  }

  void toggleLibraryHidden(String libId) async {
    if (_hiddenLibraries.contains(libId)) {
      _hiddenLibraries.remove(libId);
    } else {
      _hiddenLibraries.add(libId);
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('hiddenLibs', _hiddenLibraries.toList());
    notifyListeners();
  }

  bool isLibraryHidden(String libId) => _hiddenLibraries.contains(libId);

  void sortLibrariesByName() {
    _libraries.sort((a, b) => a.name.compareTo(b.name));
    notifyListeners();
  }
}

class HomeEntry {
  final String key;
  final String displayName;
  final List<MediaItem> items;
  HomeEntry({required this.key, required this.displayName, required this.items});
}
