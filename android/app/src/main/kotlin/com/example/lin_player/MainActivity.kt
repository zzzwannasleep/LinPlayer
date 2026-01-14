package com.example.lin_player

import android.content.ComponentName
import android.content.pm.PackageManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channelName = "linplayer/app_icon"

    private data class Alias(
        val id: String,
        val classNameSuffix: String,
        val manifestEnabled: Boolean,
    )

    private val aliases = listOf(
        Alias(id = "default", classNameSuffix = ".MainActivityDefault", manifestEnabled = true),
        Alias(id = "warm", classNameSuffix = ".MainActivityWarm", manifestEnabled = false),
        Alias(id = "cool", classNameSuffix = ".MainActivityCool", manifestEnabled = false),
    )

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName).setMethodCallHandler { call, result ->
            when (call.method) {
                "getIcon" -> {
                    result.success(getCurrentIconId())
                }
                "setIcon" -> {
                    val id = call.argument<String>("id") ?: "default"
                    try {
                        setIconId(id)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("set_icon_failed", e.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun setIconId(id: String) {
        val target = aliases.firstOrNull { it.id == id } ?: throw IllegalArgumentException("Unknown icon id: $id")
        val pm = applicationContext.packageManager
        val pkg = applicationContext.packageName

        for (a in aliases) {
            val component = ComponentName(pkg, pkg + a.classNameSuffix)
            val state = if (a.id == target.id) {
                PackageManager.COMPONENT_ENABLED_STATE_ENABLED
            } else {
                PackageManager.COMPONENT_ENABLED_STATE_DISABLED
            }
            pm.setComponentEnabledSetting(component, state, PackageManager.DONT_KILL_APP)
        }
    }

    private fun getCurrentIconId(): String {
        val pm = applicationContext.packageManager
        val pkg = applicationContext.packageName
        for (a in aliases) {
            val component = ComponentName(pkg, pkg + a.classNameSuffix)
            val state = pm.getComponentEnabledSetting(component)
            val enabled = when (state) {
                PackageManager.COMPONENT_ENABLED_STATE_ENABLED -> true
                PackageManager.COMPONENT_ENABLED_STATE_DISABLED -> false
                PackageManager.COMPONENT_ENABLED_STATE_DEFAULT -> a.manifestEnabled
                else -> a.manifestEnabled
            }
            if (enabled) return a.id
        }
        return "default"
    }
}
