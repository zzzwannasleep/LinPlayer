import 'package:flutter/material.dart';

import 'state/app_state.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key, required this.appState});

  final AppState appState;

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _formKey = GlobalKey<FormState>();
  final _baseUrlCtrl = TextEditingController();
  final _userCtrl = TextEditingController();
  final _pwdCtrl = TextEditingController();

  @override
  void dispose() {
    _baseUrlCtrl.dispose();
    _userCtrl.dispose();
    _pwdCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    await widget.appState.login(
      baseUrl: _baseUrlCtrl.text.trim(),
      username: _userCtrl.text.trim(),
      password: _pwdCtrl.text,
    );
    if (widget.appState.error != null && mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(widget.appState.error!)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final loading = widget.appState.isLoading;
    return Scaffold(
      appBar: AppBar(
        title: const Text('登录'),
        centerTitle: true,
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextFormField(
                    controller: _baseUrlCtrl,
                    decoration: const InputDecoration(
                      labelText: '线路地址（示例：https://example.com）',
                      border: OutlineInputBorder(),
                    ),
                    keyboardType: TextInputType.url,
                    validator: (v) =>
                        (v == null || v.isEmpty) ? '请输入线路地址' : null,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _userCtrl,
                    decoration: const InputDecoration(
                      labelText: '账号',
                      border: OutlineInputBorder(),
                    ),
                    validator: (v) =>
                        (v == null || v.isEmpty) ? '请输入账号' : null,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _pwdCtrl,
                    decoration: const InputDecoration(
                      labelText: '密码',
                      border: OutlineInputBorder(),
                    ),
                    obscureText: true,
                    validator: (v) =>
                        (v == null || v.isEmpty) ? '请输入密码' : null,
                  ),
                  const SizedBox(height: 20),
                  FilledButton(
                    onPressed: loading ? null : _submit,
                    child:
                        loading ? const CircularProgressIndicator() : const Text('登录'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
