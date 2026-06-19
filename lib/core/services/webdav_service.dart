import 'dart:convert';
import 'package:dio/dio.dart';

import '../app_identity.dart';
import '../network/proxy_http_client.dart';

/// WebDAV 客户端服务
/// 
/// 支持基本的 WebDAV 操作：
/// - PROPFIND: 列出目录内容
/// - PUT: 上传文件
/// - GET: 下载文件
/// - MKCOL: 创建目录
class WebDAVService {
  final String serverUrl;
  final String username;
  final String password;
  late final Dio _dio;

  WebDAVService({
    required this.serverUrl,
    required this.username,
    required this.password,
  }) {
    // 确保 URL 以 / 结尾
    final normalizedUrl = serverUrl.endsWith('/') ? serverUrl : '$serverUrl/';
    
    _dio = Dio(BaseOptions(
      baseUrl: normalizedUrl,
      connectTimeout: const Duration(seconds: 30),
      receiveTimeout: const Duration(seconds: 60),
      headers: {
        'Authorization': 'Basic ${base64Encode(utf8.encode('$username:$password'))}',
        'Content-Type': 'application/xml',
        'Accept': '*/*',
        'User-Agent': kAppUserAgent,
      },
    ));
    applyProxyToDio(_dio);
  }

  /// 测试连接
  Future<bool> testConnection() async {
    try {
      final response = await _dio.request(
        '/',
        options: Options(method: 'PROPFIND'),
      );
      return response.statusCode == 207 || response.statusCode == 200;
    } catch (e) {
      return false;
    }
  }

  /// 列出目录内容
  Future<List<String>> listDirectory([String path = '/']) async {
    try {
      final response = await _dio.request(
        path,
        options: Options(method: 'PROPFIND'),
        data: '''<?xml version="1.0" encoding="utf-8"?>
<propfind xmlns="DAV:">
  <prop>
    <displayname/>
    <resourcetype/>
  </prop>
</propfind>''',
      );

      if (response.statusCode == 207) {
        // 解析 WebDAV 响应
        return _parsePropFindResponse(response.data.toString());
      }
      return [];
    } catch (e) {
      throw Exception('列出目录失败: $e');
    }
  }

  /// 上传文件
  Future<void> uploadFile(String remotePath, String content) async {
    try {
      await _dio.put(
        remotePath,
        data: content,
        options: Options(
          headers: {'Content-Type': 'application/octet-stream'},
        ),
      );
    } catch (e) {
      throw Exception('上传文件失败: $e');
    }
  }

  /// 下载文件
  Future<String> downloadFile(String remotePath) async {
    try {
      final response = await _dio.get(remotePath);
      return response.data.toString();
    } catch (e) {
      throw Exception('下载文件失败: $e');
    }
  }

  /// 创建目录
  Future<void> createDirectory(String path) async {
    try {
      await _dio.request(
        path,
        options: Options(method: 'MKCOL'),
      );
    } catch (e) {
      // 目录可能已存在，忽略错误
    }
  }

  /// 检查文件是否存在
  Future<bool> fileExists(String remotePath) async {
    try {
      final response = await _dio.head(remotePath);
      return response.statusCode == 200;
    } catch (e) {
      return false;
    }
  }

  /// 备份应用到 WebDAV
  Future<void> backupApp(String appData) async {
    // 创建应用专用目录
    await createDirectory('/LinPlayer');
    await createDirectory('/LinPlayer/backups');
    
    // 生成带时间戳的备份文件名
    final timestamp = DateTime.now().toIso8601String().replaceAll(':', '-');
    final backupPath = '/LinPlayer/backups/settings_$timestamp.json';
    
    // 同时更新最新备份
    const latestPath = '/LinPlayer/backups/settings_latest.json';
    
    await uploadFile(backupPath, appData);
    await uploadFile(latestPath, appData);
  }

  /// 从 WebDAV 还原应用
  Future<String> restoreApp() async {
    const latestPath = '/LinPlayer/backups/settings_latest.json';
    return await downloadFile(latestPath);
  }

  /// 解析 PROPFIND 响应
  List<String> _parsePropFindResponse(String xmlData) {
    final items = <String>[];
    
    // 简单的正则解析，提取 href
    final hrefRegex = RegExp(r'<href>(.*?)</href>');
    final matches = hrefRegex.allMatches(xmlData);
    
    for (final match in matches) {
      final href = match.group(1);
      if (href != null && href != '/') {
        // 去掉末尾的 /
        final cleanPath = href.endsWith('/') ? href.substring(0, href.length - 1) : href;
        final fileName = cleanPath.split('/').last;
        if (fileName.isNotEmpty) {
          items.add(fileName);
        }
      }
    }
    
    return items;
  }
}
