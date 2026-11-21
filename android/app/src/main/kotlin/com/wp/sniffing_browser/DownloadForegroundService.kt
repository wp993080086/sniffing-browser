package com.wp.sniffing_browser

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.util.Log

/**
 * 下载期间的常驻前台服务。
 *
 * 两件事：把进程钉在前台状态，以及在传输期间持有 PARTIAL_WAKE_LOCK。
 *
 * 只挂通知不够。熄屏后 CPU 会进 Doze，Dart 的定时器和 TCP 连接一起冻住 ——
 * 表现是进度完全不动，亮屏后过一会儿才重新连上。前台服务只防进程被杀，
 * 防不了 CPU 休眠；必须有唤醒锁，传输才能真正在后台跑完。
 *
 * 唤醒锁的服务生命周期同步：Dart 侧第一个任务开跑时 start、全部结束时 stop，
 * 等待网络重试期间也持有（否则重试定时器同样被冻住，永远等不到恢复）。
 * 进程被系统杀掉时 Android 会自动释放它，不需要额外兜底。
 */
class DownloadForegroundService : Service() {

    private var wakeLock: PowerManager.WakeLock? = null

    override fun onCreate() {
        super.onCreate()
        acquireWakeLock()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun acquireWakeLock() {
        if (wakeLock?.isHeld == true) return
        val manager = getSystemService(Context.POWER_SERVICE) as PowerManager
        val lock = manager.newWakeLock(
            PowerManager.PARTIAL_WAKE_LOCK,
            "sniffing_browser:download",
        )
        try {
            // 不设超时：一个几百 MB 的视频可能要下很久，中途没法从 Dart 侧续期。
            // 释放点在 onDestroy，进程意外死亡时系统也会自动回收。
            lock.acquire()
            wakeLock = lock
            Log.i(TAG, "PARTIAL_WAKE_LOCK acquired")
        } catch (e: Exception) {
            // 拿不到锁不该让下载失败：前台服务还在，只是熄屏后仍会冻住。
            Log.w(TAG, "acquire wake lock failed: ${e.message}")
        }
    }

    private fun releaseWakeLock() {
        wakeLock?.let { lock ->
            if (lock.isHeld) lock.release()
            Log.i(TAG, "PARTIAL_WAKE_LOCK released")
        }
        wakeLock = null
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        ensureChannel(manager)
        startForeground(NOTIFICATION_ID, buildNotification())
        // 进程被系统杀掉就别自动重启了：Dart 侧的任务已经没了，
        // 拉起来只会留一条空通知。
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        releaseWakeLock()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
        super.onDestroy()
    }

    private fun ensureChannel(manager: NotificationManager) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            "下载",
            NotificationManager.IMPORTANCE_LOW,
        )
        channel.setShowBadge(false)
        manager.createNotificationChannel(channel)
    }

    private fun buildNotification(): Notification {
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            Notification.Builder(this)
        }
        return builder
            .setContentTitle("正在下载")
            .setContentText("下载完成后自动结束，切到后台也会继续")
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setContentIntent(openAppIntent())
            .build()
    }

    /** 点通知回到应用；应用还在栈里就直接切回去，不新建实例。 */
    private fun openAppIntent(): PendingIntent {
        val intent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
        }
        return PendingIntent.getActivity(
            this,
            0,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    companion object {
        private const val TAG = "DownloadFgService"
        private const val CHANNEL_ID = "download"
        private const val NOTIFICATION_ID = 1001

        fun start(context: Context) {
            val intent = Intent(context, DownloadForegroundService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, DownloadForegroundService::class.java))
        }
    }
}
