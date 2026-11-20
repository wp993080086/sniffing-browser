package com.wp.sniffing_browser

import android.Manifest
import android.app.Activity
import android.content.pm.PackageManager
import android.os.Build
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * 前台服务的 Dart 入口。
 *
 * 下载队列在「第一个任务开跑」时 start、「全部跑完」时 stop，中间不做任何事。
 */
class DownloadServiceBridge(private val activity: Activity) :
    MethodChannel.MethodCallHandler {

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "start" -> {
                askNotificationPermission()
                try {
                    DownloadForegroundService.start(activity)
                    result.success(null)
                } catch (e: Exception) {
                    // Android 12+ 不允许从后台启动前台服务。这里不当作致命错误：
                    // 下载本身照跑，只是切后台可能被冻结。
                    result.error("unavailable", e.message, null)
                }
            }
            "stop" -> {
                DownloadForegroundService.stop(activity)
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    /**
     * Android 13+ 即使不授权也能起前台服务，只是通知不显示；
     * Android 14 起前台服务通知必须可见才合理，所以顺手要一次权限，
     * 用户拒绝也不影响下载。
     */
    private fun askNotificationPermission() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return
        val granted = activity.checkSelfPermission(
            Manifest.permission.POST_NOTIFICATIONS,
        ) == PackageManager.PERMISSION_GRANTED
        if (granted) return
        activity.requestPermissions(
            arrayOf(Manifest.permission.POST_NOTIFICATIONS),
            NOTIFICATION_REQUEST_CODE,
        )
    }

    private companion object {
        const val NOTIFICATION_REQUEST_CODE = 41
    }
}
