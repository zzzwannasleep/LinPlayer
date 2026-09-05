# ☠ 只被 JNI 调用的东西 R8 看不到调用点,会当死代码裁掉。
#   表现是 release 崩 NoSuchMethodError -> SIGABRT,而 debug 一切正常。
#   本仓栽过一次(旧 Rust 栈的 MPVLib)。

# native 方法声明本身(Native.kt 里那些 external fun)
-keepclasseswithmembernames,includedescriptorclasses class * {
    native <methods>;
}

# ★ 上面那条**不够**:它只保住「有 native 方法的类里的 native 方法」。
#   被 C 侧 **回调**回来的普通方法不在其中 —— 那才是当年被裁掉的那一类。
#   本层现在没有 C→Kotlin 的回调(事件走 nextEvent 轮询,不走回调),
#   但 Native 整个类必须保住:JNI 按 `Java_xyz_linplayer_app_core_Native_*`
#   这个名字找函数,类名一混淆就对不上了。
-keep class xyz.linplayer.app.core.Native { *; }

# kotlinx.serialization 的生成序列化器
-keepclassmembers class kotlinx.serialization.json.** { *** Companion; }
-keepclasseswithmembers class kotlinx.serialization.json.** {
    kotlinx.serialization.KSerializer serializer(...);
}
-keep,includedescriptorclasses class xyz.linplayer.app.**$$serializer { *; }
-keepclassmembers class xyz.linplayer.app.** {
    *** Companion;
    kotlinx.serialization.KSerializer serializer(...);
}
