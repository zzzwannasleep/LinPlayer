import 'package:flutter/material.dart';

import '../../core/services/app_logger.dart';
import '../manager/plugin_extension_registry.dart';
import '../models/plugin_extension_point.dart';
import '../ui/plugin_settings_page_host.dart';
import 'plugin_host_bindings.dart';

/// 把插件的 ctx.ui.* 调用落地为真实 Flutter UI。
///
/// 依赖 [PluginHostBindings.instance.context]（由 App 通过 navigatorKey 提供）。
/// 当没有可用 context（如后台、未设置 navigatorKey）时安全降级。
class PluginUiHost {
  static final AppLogger _log = AppLogger();

  /// 由 App 注入：用于 openPage 查找已注册的设置页扩展。
  static PluginExtensionRegistry? registry;

  static BuildContext? get _context => PluginHostBindings.instance.context;

  static void showToast(String message, {Duration? duration}) {
    final ctx = _context;
    if (ctx == null) {
      _log.i('PluginUI', 'showToast(无UI上下文): $message');
      return;
    }
    final messenger = ScaffoldMessenger.maybeOf(ctx);
    if (messenger == null) {
      _log.i('PluginUI', 'showToast(无Messenger): $message');
      return;
    }
    messenger.showSnackBar(SnackBar(
      content: Text(message),
      duration: duration ?? const Duration(seconds: 2),
      behavior: SnackBarBehavior.floating,
    ));
  }

  /// 凭据访问逐次确认（M1）：插件每次调用 getCredentials 都弹此框，明确警告
  /// 密码将明文交给插件。用户点「允许本次」才返回 true；无 UI 上下文一律拒绝。
  static Future<bool> confirmCredentialAccess(String pluginName) async {
    final ctx = _context;
    if (ctx == null) {
      _log.w('PluginUI', '无UI上下文，拒绝插件读取凭据');
      return false;
    }
    final result = await showDialogGeneric<bool>(
      ctx,
      (context) => AlertDialog(
        title: const Text('允许插件读取账号密码？'),
        content: Text(
          '插件「$pluginName」请求读取你当前服务器的用户名与密码。\n\n'
          '⚠ 密码将以明文交给该插件，可能被用于登录其它网站或外发到网络。'
          '仅在你完全信任该插件时允许。',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('拒绝')),
          FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('允许本次')),
        ],
      ),
    );
    return result ?? false;
  }

  /// 弹出对话框，返回被点击按钮的 id（或 null）。
  static Future<String?> showAlert(Map options) async {
    final ctx = _context;
    if (ctx == null) return null;
    final title = '${options['title'] ?? '提示'}';
    final message = '${options['message'] ?? ''}';
    final buttonsRaw = options['buttons'];
    final buttons = <Map>[];
    if (buttonsRaw is List) {
      for (final b in buttonsRaw) {
        if (b is Map) buttons.add(b);
      }
    }
    if (buttons.isEmpty) {
      buttons.add({'id': 'ok', 'label': '确定'});
    }

    return showDialogGeneric<String>(
      ctx,
      (context) => AlertDialog(
        title: Text(title),
        content: message.isEmpty ? null : Text(message),
        actions: [
          for (final b in buttons)
            TextButton(
              onPressed: () => Navigator.of(context).pop('${b['id'] ?? ''}'),
              child: Text('${b['label'] ?? b['id'] ?? ''}'),
            ),
        ],
      ),
    );
  }

  /// 弹出表单，返回 {字段key: 值} 或 null（取消）。
  ///
  /// schema: { title, fields:[{key,label,type:text|password|number|switch,default,hint}],
  ///           submitLabel, cancelLabel }
  static Future<Map<String, dynamic>?> showForm(Map schema) async {
    final ctx = _context;
    if (ctx == null) return null;
    final fieldsRaw = schema['fields'];
    final fields = <Map>[];
    if (fieldsRaw is List) {
      for (final f in fieldsRaw) {
        if (f is Map) fields.add(f);
      }
    }
    return showDialogGeneric<Map<String, dynamic>>(
      ctx,
      (context) => _PluginFormDialog(schema: schema, fields: fields),
    );
  }

  /// 打开插件页面：当前以「设置页扩展」为载体。
  static Future<void> openPage(
      String pluginId, String pageId, Map params) async {
    final ctx = _context;
    final reg = registry;
    if (ctx == null || reg == null) return;
    PluginExtension? target;
    for (final ext in reg.byType(PluginExtensionType.settingsPages)) {
      if (ext.pluginId == pluginId && ext.id == pageId) {
        target = ext;
        break;
      }
    }
    if (target == null) {
      showToast('页面不存在: $pageId');
      return;
    }
    await Navigator.of(ctx).push(MaterialPageRoute(
      builder: (_) => PluginSettingsPageHost(extension: target!),
    ));
  }

  static Future<T?> showDialogGeneric<T>(
      BuildContext ctx, WidgetBuilder builder) {
    return showDialog<T>(context: ctx, builder: builder);
  }
}

class _PluginFormDialog extends StatefulWidget {
  final Map schema;
  final List<Map> fields;
  const _PluginFormDialog({required this.schema, required this.fields});

  @override
  State<_PluginFormDialog> createState() => _PluginFormDialogState();
}

class _PluginFormDialogState extends State<_PluginFormDialog> {
  final Map<String, TextEditingController> _controllers = {};
  final Map<String, bool> _switches = {};

  @override
  void initState() {
    super.initState();
    for (final f in widget.fields) {
      final key = '${f['key']}';
      final type = '${f['type'] ?? 'text'}';
      if (type == 'switch') {
        _switches[key] = f['default'] == true;
      } else {
        _controllers[key] =
            TextEditingController(text: f['default'] == null ? '' : '${f['default']}');
      }
    }
  }

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  Map<String, dynamic> _collect() {
    final out = <String, dynamic>{};
    for (final f in widget.fields) {
      final key = '${f['key']}';
      final type = '${f['type'] ?? 'text'}';
      if (type == 'switch') {
        out[key] = _switches[key] ?? false;
      } else if (type == 'number') {
        out[key] = num.tryParse(_controllers[key]?.text.trim() ?? '');
      } else {
        out[key] = _controllers[key]?.text ?? '';
      }
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('${widget.schema['title'] ?? '插件设置'}'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final f in widget.fields) _buildField(f),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text('${widget.schema['cancelLabel'] ?? '取消'}'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_collect()),
          child: Text('${widget.schema['submitLabel'] ?? '保存'}'),
        ),
      ],
    );
  }

  Widget _buildField(Map f) {
    final key = '${f['key']}';
    final label = '${f['label'] ?? key}';
    final type = '${f['type'] ?? 'text'}';
    if (type == 'switch') {
      return SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(label),
        value: _switches[key] ?? false,
        onChanged: (v) => setState(() => _switches[key] = v),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: TextField(
        controller: _controllers[key],
        obscureText: type == 'password',
        keyboardType:
            type == 'number' ? TextInputType.number : TextInputType.text,
        decoration: InputDecoration(
          labelText: label,
          hintText: f['hint'] == null ? null : '${f['hint']}',
          border: const OutlineInputBorder(),
        ),
      ),
    );
  }
}
