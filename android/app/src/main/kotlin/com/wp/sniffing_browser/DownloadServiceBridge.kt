package com.wp.sniffing_browser

import android.Manifest
import android.app.Activity
import android.content.pm.PackageManager
import android.os.Build
import android.util.Log
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * 前台服务的 Dart 入口，双向通道：
 * - Dart -> 原生：start / stop / update（进度）
 * - 原生 -> Dart：pauseAll / resumeAll / cancelAll（通知按钮）
 *
 * 通知按钮在 broadcast receiver 里拿到静态 channel 反调 Dart，所以 channel
 * 必须在 MainActivity 注册时传进来。
 */
class DownloadServiceBridge(
    private val activity: Activity,
    private val channel: MethodChannel,
) : MethodChannel.MethodCallHandler {

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
            "update" -> {
                val done = call.argument<Number>("done")?.toLong() ?: 0L
                val total = call.argument<Number>("total")?.toLong() ?: 0L
                val speed = call.argument<Number>("speed")?.toDouble() ?: 0.0
                val count = call.argument<Number>("count")?.toInt() ?: 0
                DownloadForegroundService.update(done, total, speed, count)
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

    companion object {
        private const val NOTIFICATION_REQUEST_CODE = 41

        @Volatile
        private var sharedChannel: MethodChannel? = null

        /** MainActivity 注册时传入，供通知按钮反调 Dart。 */
        fun bind(channel: MethodChannel) {
            sharedChannel = channel
        }

        fun invokeDart(method: String) {
            try {
                sharedChannel?.invokeMethod(method, null)
            } catch (e: Exception) {
                Log.w(TAG, "invoke $method failed: ${e.message}")
            }
        }

        private const val TAG = "DownloadBridge"
    }
}
