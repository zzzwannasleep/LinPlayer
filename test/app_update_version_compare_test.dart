import 'package:flutter_test/flutter_test.dart';
import 'package:linplayer_mobile/core/services/update/app_update_service.dart';

void main() {
  int cmp(String a, String b) => AppUpdateService.compareVersions(a, b);

  group('AppUpdateService.compareVersions', () {
    test('回归：同一 x.y.z 的预览版迭代靠构建号区分（旧实现漏检的核心）', () {
      // 已安装 v1.2.0-build88，远端新出 v1.2.0-build91-pre：必须判为有更新。
      expect(cmp('v1.2.0-build91-pre', '1.2.0-build88'), 1);
      // 反向：远端构建号更旧 → 无更新。
      expect(cmp('v1.2.0-build80-pre', '1.2.0-build88'), -1);
    });

    test('完全相同（含构建号）判为相等，不重复提示', () {
      expect(cmp('1.2.0-build88', '1.2.0-build88'), 0);
      expect(cmp('v1.2.0-build88', 'v1.2.0-build88'), 0);
      // 远端预览版 vs 已装同号稳定版：不应把稳定版「降级」回 pre。
      expect(cmp('v1.2.0-build88-pre', '1.2.0-build88'), -1);
    });

    test('主/次/修订号优先于构建号', () {
      expect(cmp('v1.3.0-build1-pre', '1.2.0-build999'), 1);
      expect(cmp('v2.0.0', '1.9.9-build999'), 1);
      expect(cmp('v1.2.1-build1', '1.2.0-build999'), 1);
    });

    test('同构建号下稳定版优于预览版（晋升关系）', () {
      // 预览版晋升为正式版：同号同构建，稳定版更「新」。
      expect(cmp('v1.2.0-build88', 'v1.2.0-build88-pre'), 1);
      expect(cmp('v1.2.0-build88-pre', 'v1.2.0-build88'), -1);
    });

    test('稳定版同号同构建已安装则无更新', () {
      // 安装的是晋升后的稳定版 1.2.0-build88，远端 latest 同物 → 0。
      expect(cmp('v1.2.0-build88', '1.2.0-build88'), 0);
    });

    test('无构建号 / 默认版本兜底', () {
      expect(cmp('v1.2.0', '1.0.0'), 1);
      expect(cmp('v1.0.0', '1.0.0'), 0);
    });
  });
}
