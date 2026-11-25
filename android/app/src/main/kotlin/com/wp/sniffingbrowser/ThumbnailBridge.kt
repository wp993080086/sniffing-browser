package com.wp.sniffingbrowser

import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/**
 * sniffingbrowser/thumbnailer 的 Android 实现：从网络视频里抽第一帧当封面。
 *
 * 用 MediaMetadataRetriever 而不是 FFmpegKit：抽一帧只需要读 moov 和附近几个
 * 关键帧，MediaMetadataRetriever 内部按需 range 请求，比拉流快一个量级，
 * 也不会为了几十条资源把转码引擎占满。
 *
 * 两个必须注意的点：
 * 1. setDataSource(url, headers) 会同步做网络 IO，绝不能跑在主线程；
 * 2. 它没有超时参数，慢站点可能长时间不返回。所以线程池留两个线程，
 *    一条卡住不影响其他条目；Dart 侧另有 Future.timeout 兜底。
 */
class ThumbnailBridge : MethodChannel.MethodCallHandler {

    private val mainHandler = Handler(Looper.getMainLooper())

    /** 两个线程：一条慢请求不阻塞队列，也不会同时冲动几十个连接。 */
    private val executor = Executors.newFixedThreadPool(2) { runnable ->
        Thread(runnable, "thumb-frame").apply { isDaemon = true }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "extractFrame" -> extractFrame(call, result)
            else -> result.notImplemented()
        }
    }

    private fun extractFrame(call: MethodCall, result: MethodChannel.Result) {
        val args = call.arguments as? Map<*, *>
        val url = args?.get("url") as? String
        if (url.isNullOrEmpty()) {
            result.success(null)
            return
        }
        val maxWidth = (args["maxWidth"] as? Number)?.toInt() ?: 160
        val headers = readHeaders(args["headers"])

        // 只回复一次：线程跑完时 Dart 侧可能已经超时，重复 reply 会让引擎报错。
        val replied = AtomicBoolean(false)

        fun reply(bytes: ByteArray?) {
            if (!replied.compareAndSet(false, true)) return
            mainHandler.post { result.success(bytes) }
        }

        executor.execute {
            var retriever: MediaMetadataRetriever? = null
            try {
                retriever = MediaMetadataRetriever()
                retriever.setDataSource(url, headers)
                // API 27 起无参版本会挑“最能代表内容”的一帧（不是死死的第一帧），
                // 片头黑场多的时候比 getFrameAtTime(0) 好看得多。
                val frame = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
                    retriever.getFrameAtTime()
                } else {
                    retriever.getFrameAtTime(0)
                }
                if (frame == null) {
                    reply(null)
                    return@execute
                }

                val scaled = if (frame.width > maxWidth) {
                    val height = (frame.height * (maxWidth.toFloat() / frame.width))
                        .toInt().coerceAtLeast(1)
                    Bitmap.createScaledBitmap(frame, maxWidth, height, true)
                } else {
                    frame
                }

                val out = ByteArrayOutputStream()
                try {
                    scaled.compress(Bitmap.CompressFormat.PNG, 100, out)
                } finally {
                    if (scaled !== frame) scaled.recycle()
                    frame.recycle()
                }
                reply(out.toByteArray())
            } catch (t: Throwable) {
                // 抽不到封面是常态（403、非常规容器、只允许分片），不当成错误上报。
                Log.d(TAG, "抽帧失败 $url", t)
                reply(null)
            } finally {
                try {
                    retriever?.release()
                } catch (_: Throwable) {
                    // release 失败无所谓，retriever 由 GC 兜底。
                }
            }
        }
    }

    private fun readHeaders(raw: Any?): Map<String, String> {
        val map = raw as? Map<*, *> ?: return emptyMap()
        val result = HashMap<String, String>(map.size)
        for (entry in map.entries) {
            val key = entry.key as? String ?: continue
            val value = entry.value as? String ?: continue
            result[key] = value
        }
        return result
    }

    private companion object {
        const val TAG = "Thumbnail"
    }
}
