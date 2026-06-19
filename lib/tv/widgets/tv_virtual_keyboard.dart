import 'package:flutter/material.dart';
import '../theme/tv_design_tokens.dart';
import '../theme/tv_metrics.dart';
import 'tv_focusable.dart';

/// TV 虚拟键盘（26键 QWERTY 布局）
/// 左右键在同行移动，上下键换行
class TvVirtualKeyboard extends StatefulWidget {
  final ValueChanged<String> onTextChanged;
  final VoidCallback? onSubmit;
  final VoidCallback? onClear;
  final String initialText;

  const TvVirtualKeyboard({
    super.key,
    required this.onTextChanged,
    this.onSubmit,
    this.onClear,
    this.initialText = '',
  });

  @override
  State<TvVirtualKeyboard> createState() => _TvVirtualKeyboardState();
}

class _TvVirtualKeyboardState extends State<TvVirtualKeyboard> {
  late String _text;
  bool _isUpperCase = false;

  @override
  void initState() {
    super.initState();
    _text = widget.initialText;
  }

  void _onKeyPress(String key) {
    setState(() {
      _text += _isUpperCase ? key.toUpperCase() : key;
    });
    widget.onTextChanged(_text);
  }

  void _onBackspace() {
    if (_text.isNotEmpty) {
      setState(() {
        _text = _text.substring(0, _text.length - 1);
      });
      widget.onTextChanged(_text);
    }
  }

  void _onClear() {
    setState(() => _text = '');
    widget.onTextChanged('');
    widget.onClear?.call();
  }

  void _toggleCase() {
    setState(() => _isUpperCase = !_isUpperCase);
  }

  void _onSubmit() {
    widget.onSubmit?.call();
  }

  @override
  Widget build(BuildContext context) {
    final m = context.tv;
    final rows = [
      ['q', 'w', 'e', 'r', 't', 'y', 'u', 'i', 'o', 'p'],
      ['a', 's', 'd', 'f', 'g', 'h', 'j', 'k', 'l'],
      ['z', 'x', 'c', 'v', 'b', 'n', 'm'],
    ];

    return Column(
      children: [
        // 显示当前输入
        Container(
          padding: EdgeInsets.all(m.spacingMd),
          decoration: BoxDecoration(
            color: TvDesignTokens.surface,
            borderRadius: BorderRadius.circular(m.posterRadius),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  _text.isEmpty ? '输入搜索内容...' : _text,
                  style: TextStyle(
                    fontSize: m.fontSizeMd,
                    color: _text.isEmpty ? TvDesignTokens.textDisabled : TvDesignTokens.textPrimary,
                  ),
                ),
              ),
              if (_text.isNotEmpty)
                TvFocusable(
                  onSelect: _onBackspace,
                  child: Icon(
                    Icons.backspace,
                    color: TvDesignTokens.textSecondary,
                    size: m.s(28),
                  ),
                ),
            ],
          ),
        ),
        SizedBox(height: m.spacingMd),
        // 键盘行
        ...rows.map((row) {
          return Padding(
            padding: EdgeInsets.only(bottom: m.keyboardKeySpacing),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: row.map((key) {
                return Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: m.keyboardKeySpacing,
                  ),
                  child: TvFocusable(
                    onSelect: () => _onKeyPress(key),
                    child: Container(
                      width: m.keyboardKeyWidth,
                      height: m.keyboardKeyHeight,
                      decoration: BoxDecoration(
                        color: TvDesignTokens.surface,
                        borderRadius: BorderRadius.circular(m.posterRadius),
                      ),
                      child: Center(
                        child: Text(
                          _isUpperCase ? key.toUpperCase() : key,
                          style: TextStyle(
                            fontSize: m.keyboardFontSize,
                            color: TvDesignTokens.textPrimary,
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
          );
        }),
        // 功能行
        Padding(
          padding: EdgeInsets.only(top: m.spacingMd),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              TvFocusable(
                onSelect: _toggleCase,
                child: Container(
                  padding: EdgeInsets.symmetric(
                    horizontal: m.spacingMd,
                    vertical: m.spacingSm,
                  ),
                  decoration: BoxDecoration(
                    color: TvDesignTokens.surface,
                    borderRadius: BorderRadius.circular(m.posterRadius),
                  ),
                  child: Icon(
                    _isUpperCase ? Icons.arrow_upward : Icons.arrow_upward_outlined,
                    color: TvDesignTokens.textPrimary,
                    size: m.s(28),
                  ),
                ),
              ),
              SizedBox(width: m.spacingMd),
              TvFocusable(
                onSelect: _onClear,
                child: Container(
                  padding: EdgeInsets.symmetric(
                    horizontal: m.spacingMd,
                    vertical: m.spacingSm,
                  ),
                  decoration: BoxDecoration(
                    color: TvDesignTokens.surface,
                    borderRadius: BorderRadius.circular(m.posterRadius),
                  ),
                  child: Text(
                    '清除',
                    style: TextStyle(
                      fontSize: m.fontSizeSm,
                      color: TvDesignTokens.textPrimary,
                    ),
                  ),
                ),
              ),
              SizedBox(width: m.spacingMd),
              TvFocusable(
                onSelect: _onSubmit,
                child: Container(
                  padding: EdgeInsets.symmetric(
                    horizontal: m.spacingLg,
                    vertical: m.spacingSm,
                  ),
                  decoration: BoxDecoration(
                    color: TvDesignTokens.brand,
                    borderRadius: BorderRadius.circular(m.posterRadius),
                  ),
                  child: Text(
                    '搜索',
                    style: TextStyle(
                      fontSize: m.fontSizeMd,
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
