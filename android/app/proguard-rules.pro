# ============================================================
# LinPlayer ProGuard / R8 keep 规则
#
# Flutter 的 release 构建默认开启 R8(代码压缩+混淆)。R8 看不见「只被 JNI 调用」
# 的 Java 方法,会把它们当成无用代码删掉/混淆,导致原生库在运行时按名反查失败。
# 典型崩溃:libplayer.so(mpv-android JNI 桥)在 MPVLib.create() 里通过
# GetStaticMethodID 反查 is.xyz.mpv.MPVLib 的回调:
#   eventProperty(Ljava/lang/String;)V / (Ljava/lang/String;Z)V / event(I)V / logMessage(...)
# 若被 R8 删除 → java.lang.NoSuchMethodError → 原生侧 SIGABRT(整个 App 崩)。
# ============================================================

# ---- mpv-android JNI 桥:整体保留 MPVLib(含被 JNI 反查的静态回调方法)----
-keep class is.xyz.mpv.MPVLib { *; }
-keep class is.xyz.mpv.MPVLib$* { *; }
-keep interface is.xyz.mpv.MPVLib$EventObserver { *; }
-keep interface is.xyz.mpv.MPVLib$LogObserver { *; }

# 任何实现了 MPVLib 观察者接口的类(如 MpvPlayerPlugin 内部观察者),
# 其 eventProperty/event/logMessage 重写方法由原生事件线程经接口回调,保留全部成员。
-keep class * implements is.xyz.mpv.MPVLib$EventObserver { *; }
-keep class * implements is.xyz.mpv.MPVLib$LogObserver { *; }

# ---- 通用:保留所有带 native 方法的类的 native 方法名(JNI 按名解析)----
-keepclasseswithmembernames,includedescriptorclasses class * {
    native <methods>;
}

# ---- 保留被 @Keep 标注的成员(以防其它反射/JNI 入口)----
-keep @androidx.annotation.Keep class * { *; }
-keepclassmembers class * {
    @androidx.annotation.Keep *;
}
