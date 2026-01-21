package com.example.lin_player

import android.app.UiModeManager
import android.content.ComponentName
import android.content.Context
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.os.BatteryManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channelName = "linplayer/app_icon"
    private val deviceChannelName = "linplayer/device"

    private data class Alias(
        val id: String,
        val classNameSuffix: String,
        val manifestEnabled: Boolean,
    )

    private val aliases = listOf(
        Alias(id = "default", classNameSuffix = ".MainActivityDefault", manifestEnabled = true),
        Alias(id = "pink", classNameSuffix = ".MainActivityPink", manifestEnabled = false),
        Alias(id = "purple", classNameSuffix = ".MainActivityPurple", manifestEnabled = false),
        Alias(id = "miku", classNameSuffix = ".MainActivityMiku", manifestEnabled = false),
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

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, deviceChannelName).setMethodCallHandler { call, result ->
            when (call.method) {
                "isAndroidTv" -> result.success(isAndroidTv())
                "batteryLevel" -> result.success(batteryLevel())
                else -> result.notImplemented()
            }
        }
    }

    private fun isAndroidTv(): Boolean {
        val uiModeManager = getSystemService(Context.UI_MODE_SERVICE) as? UiModeManager
        if (uiModeManager?.currentModeType == Configuration.UI_MODE_TYPE_TELEVISION) return true

        val pm = applicationContext.packageManager
        return pm.hasSystemFeature(PackageManager.FEATURE_TELEVISION) ||
            pm.hasSystemFeature(PackageManager.FEATURE_LEANBACK)
    }

    private fun batteryLevel(): Int? {
        val bm = getSystemService(Context.BATTERY_SERVICE) as? BatteryManager ?: return null
        val level = bm.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY)
        if (level < 0) return null
        return level
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
