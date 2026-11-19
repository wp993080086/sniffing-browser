package com.sniffing.sniffing_browser

import android.os.Handler
import android.os.Looper
import com.arthenica.ffmpegkit.FFmpegKit
import com.arthenica.ffmpegkit.FFmpegKitConfig
import com.arthenica.ffmpegkit.FFmpegSession
import com.arthenica.ffmpegkit.FFprobeKit
import com.arthenica.ffmpegkit.ReturnCode
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * sniffing_browser/transcoder 的 Android 实现。
 *
 * 契约：startTranscode 的 result 会一直挂起，直到 FFmpegKit 的 session 结束才回复，
 * 所以 Dart 侧 `await invokeMethod('startTranscode')` 天然等于「等这一路转码跑完」。
 * 进度通过同一个 channel 反向调用 onProgress 推给 Dart。
 *
 * 队列严格串行，同一时刻只有一个 session，因此只保存一个 activeSessionId。
 */
class TranscodeBridge(private val channel: MethodChannel) : MethodChannel.MethodCallHandler {

    private val mainHandler = Handler(Looper.getMainLooper())

    @Volatile
    private var activeSessionId: Long? = null

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "isAvailable" -> result.success(checkAvailable())
            "startTranscode" -> start(call, result)
            "cancelTranscode" -> {
                val id = activeSessionId
                if (id != null) FFmpegKit.cancel(id) else FFmpegKit.cancel()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    /** 真的加载一次 native 库，32 位 ABI 缺 so 时返回 false 而不是让转码崩掉。 */
    private fun checkAvailable(): Boolean = try {
        !FFmpegKitConfig.getFFmpegVersion().isNullOrEmpty()
    } catch (_: Throwable) {
        false
    }

    private fun start(call: MethodCall, result: MethodChannel.Result) {
        val input = call.argument<String>("input")
        val output = call.argument<String>("output")
        val kind = call.argument<String>("kind")
        val secondary = call.argument<String>("secondaryInput")

        if (input.isNullOrEmpty() || output.isNullOrEmpty() || kind.isNullOrEmpty()) {
            result.success(failed("转换参数缺失"))
            return
        }

        val args = buildArgs(kind, input, secondary, output)
        if (args == null) {
            result.success(failed("未知转换类型：$kind"))
            return
        }
        if (kind == "dashMerge" && secondary.isNullOrEmpty()) {
            result.success(failed("合并音视频缺少第二路输入"))
            return
        }

        // progress / probe 都要跑在后台：MethodChannel 回调在主线程，
        // FFprobeKit.getMediaInformation 是同步阻塞的，放主线程会卡 UI。
        Thread {
            val totalMs = probeDurationMs(input)
            // 只留尾部：整段日志可能有几 MB，不能一直堆在内存里。
            val logTail = StringBuffer()
            val session = FFmpegKit.executeWithArgumentsAsync(
                args,
                { finished ->
                    // complete callback 已在 FFmpegKit 的工作线程，日志解析放这里；
                    // 只有 MethodChannel 的回复必须切回主线程。
                    val logs = logTail.toString().ifEmpty {
                        finished.allLogsAsString.orEmpty()
                    }
                    val payload = buildResult(finished, output, logs)
                    activeSessionId = null
                    mainHandler.post { result.success(payload) }
                },
                { log ->
                    logTail.append(log.message).append('\n')
                    if (logTail.length > 8000) {
                        logTail.delete(0, logTail.length - 4000)
                    }
                },
                { statistics ->
                    if (totalMs > 0) {
                        val ratio = (statistics.time / totalMs).coerceIn(0.0, 0.99)
                        mainHandler.post {
                            channel.invokeMethod("onProgress", ratio, discardResult)
                        }
                    }
                },
            )
            activeSessionId = session.sessionId
        }.start()
    }

    /** 与桌面 SystemFfmpegEngine._argsFor 保持一致，避免两端命令走偏。 */
    private fun buildArgs(
        kind: String,
        input: String,
        secondary: String?,
        output: String,
    ): Array<String>? = when (kind) {
        "tsToMp4" -> arrayOf(
            "-y", "-hide_banner", "-i", input,
            "-c", "copy", "-movflags", "+faststart", output,
        )
        "audioToMp3" -> arrayOf(
            "-y", "-hide_banner", "-i", input,
            "-vn", "-map", "0:a:0",
            "-c:a", "libmp3lame", "-b:a", "192k", output,
        )
        "dashMerge" -> arrayOf(
            "-y", "-hide_banner", "-i", input, "-i", secondary ?: "",
            "-map", "0:v:0", "-map", "1:a:0",
            "-c", "copy", "-movflags", "+faststart", output,
        )
        else -> null
    }

    private fun buildResult(
        session: FFmpegSession,
        output: String,
        logs: String,
    ): Map<String, Any?> {
        val code = session.returnCode

        return when {
            ReturnCode.isCancel(code) -> mapOf("status" to "canceled")
            ReturnCode.isSuccess(code) && File(output).length() > 0 ->
                mapOf("status" to "done")
            ReturnCode.isSuccess(code) ->
                failed("转换没有产出文件")
            looksLikeNoAudioStream(logs) -> mapOf(
                "status" to "unsupported",
                "message" to "这个文件里没有音轨，无法提取 MP3（多半是纯视频轨或无声视频）",
            )
            else -> failed(extractError(logs))
        }
    }

    private fun probeDurationMs(path: String): Double = try {
        val info = FFprobeKit.getMediaInformation(path).mediaInformation ?: return 0.0
        (info.duration?.toDoubleOrNull() ?: return 0.0) * 1000.0
    } catch (_: Throwable) {
        0.0
    }

    private fun looksLikeNoAudioStream(text: String): Boolean {
        val lower = text.lowercase()
        return lower.contains("matches no streams") ||
            lower.contains("does not contain any stream") ||
            lower.contains("no audio stream") ||
            lower.contains("could not find codec parameters for stream 0 (audio")
    }

    /** 整段日志太长，挑最后一条带错误关键字的给用户看。 */
    private fun extractError(logs: String): String {
        val lines = logs.split(Regex("[\r\n]+"))
            .map { it.trim() }
            .filter { it.isNotEmpty() }
        for (line in lines.reversed()) {
            val lower = line.lowercase()
            if (lower.contains("error") || lower.contains("invalid") ||
                lower.contains("unable") || lower.contains("no such") ||
                lower.contains("could not")
            ) {
                return line.take(200)
            }
        }
        return lines.lastOrNull()?.take(200) ?: "转换失败，FFmpeg 未返回可用日志"
    }

    private fun failed(message: String): Map<String, Any?> =
        mapOf("status" to "failed", "message" to message)

    /** 反向调用不需要 Dart 回值，但 Result 不能为 null，否则会打未处理异常日志。 */
    private val discardResult = object : MethodChannel.Result {
        override fun success(result: Any?) {}
        override fun error(code: String, message: String?, details: Any?) {}
        override fun notImplemented() {}
    }
}
