class ServerProfile {
  ServerProfile({
    required this.id,
    required this.username,
    required this.name,
    required this.baseUrl,
    required this.token,
    required this.userId,
    this.remark,
    this.iconUrl,
    this.lastErrorCode,
    this.lastErrorMessage,
    Set<String>? hiddenLibraries,
    Map<String, String>? domainRemarks,
    List<CustomDomain>? customDomains,
  })  : hiddenLibraries = hiddenLibraries ?? <String>{},
        domainRemarks = domainRemarks ?? <String, String>{},
        customDomains = customDomains ?? <CustomDomain>[];

  final String id;
  String username;
  String name;
  String? remark;

  /// Display icon url (favicon or user-selected icon library entry).
  String? iconUrl;

  /// Current selected base url (may point to a "line"/domain).
  String baseUrl;

  String token;
  String userId;

  /// Last known error code for this server (typically HTTP status code).
  int? lastErrorCode;

  /// Last known error message for this server.
  String? lastErrorMessage;

  final Set<String> hiddenLibraries;

  /// User-defined remarks for domains/lines. Key is domain url.
  final Map<String, String> domainRemarks;

  /// User-defined custom lines (domains). Stored per server.
  final List<CustomDomain> customDomains;

  Map<String, dynamic> toJson() => {
        'id': id,
        'username': username,
        'name': name,
        'remark': remark,
        'iconUrl': iconUrl,
        'baseUrl': baseUrl,
        'token': token,
        'userId': userId,
        'lastErrorCode': lastErrorCode,
        'lastErrorMessage': lastErrorMessage,
        'hiddenLibraries': hiddenLibraries.toList(),
        'domainRemarks': domainRemarks,
        'customDomains': customDomains.map((e) => e.toJson()).toList(),
      };

  factory ServerProfile.fromJson(Map<String, dynamic> json) {
    return ServerProfile(
      id: json['id'] as String? ?? '',
      username: json['username'] as String? ?? '',
      name: json['name'] as String? ?? '',
      remark: json['remark'] as String?,
      iconUrl: json['iconUrl'] as String?,
      baseUrl: json['baseUrl'] as String? ?? '',
      token: json['token'] as String? ?? '',
      userId: json['userId'] as String? ?? '',
      lastErrorCode: json['lastErrorCode'] is int
          ? json['lastErrorCode'] as int
          : int.tryParse((json['lastErrorCode'] ?? '').toString()),
      lastErrorMessage: json['lastErrorMessage'] as String?,
      hiddenLibraries: ((json['hiddenLibraries'] as List?)?.cast<String>() ??
              const <String>[])
          .toSet(),
      domainRemarks: (json['domainRemarks'] as Map?)?.map(
            (key, value) => MapEntry(key.toString(), value.toString()),
          ) ??
          <String, String>{},
      customDomains: (json['customDomains'] as List?)
              ?.whereType<Map>()
              .map((e) => CustomDomain.fromJson(
                  e.map((k, v) => MapEntry(k.toString(), v))))
              .toList() ??
          <CustomDomain>[],
    );
  }
}

class CustomDomain {
  final String name;
  final String url;

  CustomDomain({required this.name, required this.url});

  Map<String, dynamic> toJson() => {
        'name': name,
        'url': url,
      };

  factory CustomDomain.fromJson(Map<String, dynamic> json) => CustomDomain(
        name: json['name'] as String? ?? '',
        url: json['url'] as String? ?? '',
      );
}
