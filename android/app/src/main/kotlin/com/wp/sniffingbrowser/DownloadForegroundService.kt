package com.wp.sniffingbrowser

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.util.Log

/**
 * 下载期间的常驻前台服务。
 *
 * 三件事：把进程钉在前台状态、持有 PARTIAL_WAKE_LOCK、把下载进度和操作放进通知。
 *
 * 只挂通知不够。熄屏后 CPU 会进 Doze，Dart 的定时器和 TCP 连接一起冻住 ——
 * 表现是进度完全不动，亮屏后过一会儿才重新连上。前台服务只防进程被杀，
 * 防不了 CPU 休眠；必须有唤醒锁，传输才能真正在后台跑完。
 *
 * 进度由 Dart 每秒推一次 [update]，经静态引用更新 notification；通知上的
 * 暂停/继续/取消三个按钮发广播给 [actionReceiver]，再反调 Dart 队列。
 */
class DownloadForegroundService : Service() {

    private var wakeLock: PowerManager.WakeLock? = null
    private var receiverRegistered = false

    /** 通知上的聚合进度。Dart 的下载细节不进这里，只收四个数。 */
    private var progressDone = 0L
    private var progressTotal = 0L
    private var progressSpeed = 0.0
    private var progressCount = 0

    private val actionReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            val method = intent.getStringExtra(EXTRA_ACTION) ?: return
            // 按钮点的是「队列」不是某条任务：反调 Dart 由队列做全局暂停/继续/取消。
            DownloadServiceBridge.invokeDart(method)
        }
    }

    override fun onCreate() {
        super.onCreate()
        onServiceCreated(this)
        acquireWakeLock()
        val filter = IntentFilter(ACTION_NOTIFICATION)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(actionReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("UnspecifiedRegisterReceiverFlag")
            registerReceiver(actionReceiver, filter)
        }
        receiverRegistered = true
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun acquireWakeLock() {
        if (wakeLock?.isHeld == true) return
        val manager = getSystemService(Context.POWER_SERVICE) as PowerManager
        val lock = manager.newWakeLock(
            PowerManager.PARTIAL_WAKE_LOCK,
            "sniffingbrowser:download",
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
        onServiceDestroyed(this)
        releaseWakeLock()
        if (receiverRegistered) {
            unregisterReceiver(actionReceiver)
            receiverRegistered = false
        }
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

    /** 由桥接在收到 Dart 的 update 时调用。 */
    fun updateProgress(done: Long, total: Long, speed: Double, count: Int) {
        progressDone = done
        progressTotal = total
        progressSpeed = speed
        progressCount = count
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.notify(NOTIFICATION_ID, buildNotification())
    }

    private fun buildNotification(): Notification {
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        val title = if (progressCount > 1) "正在下载 $progressCount 个文件" else "正在下载"
        val text = buildProgressText()
        builder
            .setContentTitle(title)
            .setContentText(text)
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setContentIntent(openAppIntent())

        if (progressTotal > 0) {
            val percent = ((progressDone * 100) / progressTotal).coerceIn(0, 100).toInt()
            builder.setProgress(100, percent, false)
            builder.setSubText("$percent%")
        } else {
            builder.setProgress(0, 0, true)
        }

        builder.addAction(action("pause", "暂停"))
        builder.addAction(action("resume", "继续"))
        builder.addAction(action("cancel", "取消全部"))
        return builder.build()
    }

    private fun buildProgressText(): String {
        val speedText = formatSpeed(progressSpeed)
        return if (progressCount <= 0) {
            "准备中…"
        } else if (progressTotal > 0) {
            "$speedText · ${formatSize(progressDone)} / ${formatSize(progressTotal)}"
        } else {
            "$speedText · ${formatSize(progressDone)}"
        }
    }

    private fun action(method: String, label: String): Notification.Action {
        val intent = Intent(ACTION_NOTIFICATION).apply {
            setPackage(packageName)
            putExtra(EXTRA_ACTION, method)
        }
        val pi = PendingIntent.getBroadcast(
            this,
            method.hashCode(),
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            Notification.Action.Builder(null, label, pi).build()
        } else {
            @Suppress("DEPRECATION")
            Notification.Action.Builder(0, label, pi).build()
        }
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
        private const val ACTION_NOTIFICATION = "sniffingbrowser.download.action"
        private const val EXTRA_ACTION = "method"

        /** 当前存活的 service 实例，桥接收到 update 时转调。 */
        @Volatile
        private var instance: DownloadForegroundService? = null

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

        fun onServiceCreated(service: DownloadForegroundService) {
            instance = service
        }

        fun onServiceDestroyed(service: DownloadForegroundService) {
            if (instance === service) instance = null
        }

        fun update(done: Long, total: Long, speed: Double, count: Int) {
            instance?.updateProgress(done, total, speed, count)
        }

        fun formatSpeed(bytesPerSecond: Double): String =
            "${formatSize(bytesPerSecond.toLong())}/s"

        fun formatSize(bytes: Long): String = when {
            bytes >= 1024L * 1024 * 1024 ->
                String.format("%.1f GB", bytes / (1024.0 * 1024 * 1024))
            bytes >= 1024L * 1024 ->
                String.format("%.1f MB", bytes / (1024.0 * 1024))
            bytes >= 1024 -> String.format("%.0f KB", bytes / 1024.0)
            else -> "$bytes B"
        }
    }
}
