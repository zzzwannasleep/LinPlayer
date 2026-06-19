import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 壁纸裁剪页 —— 纯 Flutter 实现，无额外原生依赖。
///
/// 用户用 [InteractiveViewer] 平移/双指缩放图片，裁剪框 = 整个屏幕（即软件背景比例）。
/// 确定时把裁剪框内容用 [RenderRepaintBoundary.toImage] 截图为 PNG 写入 App 支持目录，
/// 返回保存后的路径（[Navigator.pop] 的结果）。只支持静态图片。
class WallpaperCropScreen extends StatefulWidget {
  final String sourcePath;

  const WallpaperCropScreen({super.key, required this.sourcePath});

  @override
  State<WallpaperCropScreen> createState() => _WallpaperCropScreenState();
}

class _WallpaperCropScreenState extends State<WallpaperCropScreen> {
  final GlobalKey _boundaryKey = GlobalKey();
  final TransformationController _controller = TransformationController();
  bool _saving = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _confirm() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final boundary = _boundaryKey.currentContext?.findRenderObject()
          as RenderRepaintBoundary?;
      if (boundary == null) {
        throw StateError('裁剪区域未就绪');
      }
      // 控制输出分辨率：最长边约 1600px，兼顾清晰与文件体积。
      final size = boundary.size;
      final maxLogical = math.max(size.width, size.height);
      final pixelRatio = maxLogical <= 0
          ? 1.0
          : (1600.0 / maxLogical).clamp(1.0, 3.0).toDouble();

      final image = await boundary.toImage(pixelRatio: pixelRatio);
      final byteData =
          await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      if (byteData == null) {
        throw StateError('图片编码失败');
      }

      final dir = await getApplicationSupportDirectory();
      // 用唯一文件名避免 Flutter 按路径缓存旧壁纸。
      final fileName =
          'wallpaper_${DateTime.now().millisecondsSinceEpoch}.png';
      final file = File(p.join(dir.path, fileName));
      await file.writeAsBytes(byteData.buffer.asUint8List(), flush: true);

      if (!mounted) return;
      Navigator.of(context).pop(file.path);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('裁剪失败：$e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // 裁剪框 = 整个屏幕，截图只取这块区域。
          Positioned.fill(
            child: RepaintBoundary(
              key: _boundaryKey,
              child: ClipRect(
                child: InteractiveViewer(
                  transformationController: _controller,
                  minScale: 1.0,
                  maxScale: 6.0,
                  clipBehavior: Clip.hardEdge,
                  child: SizedBox.expand(
                    child: Image.file(
                      File(widget.sourcePath),
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => const ColoredBox(
                        color: Colors.black,
                        child: Center(
                          child: Icon(Icons.broken_image,
                              color: Colors.white54, size: 48),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          // 顶部操作栏（在 RepaintBoundary 之外，不会被截进壁纸）。
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white),
                    onPressed:
                        _saving ? null : () => Navigator.of(context).pop(),
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: _saving ? null : _confirm,
                    style: TextButton.styleFrom(
                      foregroundColor: Colors.white,
                      backgroundColor: const Color(0xFF5B8DEF),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 20, vertical: 10),
                    ),
                    child: _saving
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white),
                          )
                        : const Text('确定'),
                  ),
                ],
              ),
            ),
          ),
          // 底部提示。
          const Positioned(
            left: 0,
            right: 0,
            bottom: 32,
            child: IgnorePointer(
              child: Center(
                child: Text(
                  '拖动 / 双指缩放调整画面，确定后作为软件背景',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    shadows: [Shadow(blurRadius: 6, color: Colors.black)],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
