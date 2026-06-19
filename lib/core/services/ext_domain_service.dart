import 'package:dio/dio.dart';

import '../app_identity.dart';

/// 扩展线路同步服务
/// 
/// 对接 emby_ext_domains 项目，通过 Emby Token 验证获取服务器线路列表
class ExtDomainService {
  final Dio _dio;
  
  ExtDomainService({Dio? dio}) : _dio = dio ?? Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 10),
    receiveTimeout: const Duration(seconds: 10),
  ));
  
  /// 获取扩展线路列表
  /// 
  /// [extDomainUrl] 扩展域名服务地址，如 https://ext.example.com
  /// [embyServerUrl] Emby 服务器地址
  /// [embyToken] Emby 认证 Token
  Future<List<ExtServerLine>> fetchExtDomains({
    required String extDomainUrl,
    required String embyServerUrl,
    required String embyToken,
  }) async {
    try {
      // 构建请求 URL
      final baseUrl = extDomainUrl.endsWith('/') ? extDomainUrl : '$extDomainUrl/';
      final url = '${baseUrl}emby/System/Ext/ServerDomains';
      
      final response = await _dio.get(
        url,
        queryParameters: {
          'X-Emby-Token': embyToken,
        },
        options: Options(
          headers: {
            'User-Agent': kAppUserAgent,
            'Accept': 'application/json',
          },
        ),
      );
      
      if (response.statusCode == 200) {
        final data = response.data as Map<String, dynamic>;
        if (data['ok'] == true && data['data'] != null) {
          final List<dynamic> lines = data['data'];
          return lines.map((e) => ExtServerLine.fromJson(e as Map<String, dynamic>)).toList();
        }
      }
      
      return [];
    } on DioException catch (e) {
      throw ExtDomainException(
        message: '获取线路列表失败: ${e.message}',
        statusCode: e.response?.statusCode,
      );
    } catch (e) {
      throw ExtDomainException(message: '获取线路列表失败: $e');
    }
  }
  
  /// 验证扩展服务是否可用
  Future<bool> checkServiceAvailable(String extDomainUrl) async {
    try {
      final baseUrl = extDomainUrl.endsWith('/') ? extDomainUrl : '$extDomainUrl/';
      final response = await _dio.get(
        '${baseUrl}emby/System/Ext/ServerDomains',
        options: Options(
          validateStatus: (status) => true,
        ),
      );
      return response.statusCode != null;
    } catch (_) {
      return false;
    }
  }
}

/// 扩展服务器线路
class ExtServerLine {
  final String name;
  final String url;
  final String? remark;
  
  ExtServerLine({
    required this.name,
    required this.url,
    this.remark,
  });
  
  factory ExtServerLine.fromJson(Map<String, dynamic> json) {
    return ExtServerLine(
      name: json['name'] as String? ?? '',
      url: json['url'] as String? ?? '',
      remark: json['remark'] as String?,
    );
  }
  
  Map<String, dynamic> toJson() {
    return {
      'name': name,
      'url': url,
      if (remark != null) 'remark': remark,
    };
  }
}

/// 扩展线路异常
class ExtDomainException implements Exception {
  final String message;
  final int? statusCode;
  
  ExtDomainException({required this.message, this.statusCode});
  
  @override
  String toString() => message;
}