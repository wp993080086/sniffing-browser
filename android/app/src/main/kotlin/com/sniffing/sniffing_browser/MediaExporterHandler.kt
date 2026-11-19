package com.sniffing.sniffing_browser

import android.annotation.SuppressLint
import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.webkit.MimeTypeMap
import androidx.core.content.FileProvider
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * sniffing_browser/media_exporter 的 Android 实现。
 *
 * 下载产物落在应用私有目录，这里把它复制进系统媒体库，让相册 / 音乐 App 能看见。
 * API 29+ 用 MediaStore + IS_PENDING，不申请任何存储权限；API <= 28 退回公共目录
 * 写文件 + 媒体扫描（需要 WRITE_EXTERNAL_STORAGE，manifest 里限定 maxSdkVersion=28）。
 */
@SuppressLint("NewApi", "Deprecation")
class MediaExporterHandler(private val context: Context) : MethodChannel.MethodCallHandler {

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method == "openMedia") {
            result.success(openMedia(call.argument<String>("uri")))
            return
        }
        if (call.method == "shareMedia") {
            result.success(shareMedia(call.argument<String>("path")))
            return
        }
        if (call.method != "exportMedia") {
            result.notImplemented()
            return
        }

        val path = call.argument<String>("path")
        val name = call.argument<String>("name")
        val target = call.argument<String>("target") ?: "gallery"
        val mimeType = call.argument<String>("mimeType")

        if (path.isNullOrEmpty() || name.isNullOrEmpty()) {
            result.success(failed("导出参数缺失"))
            return
        }

        val source = File(path)
        if (!source.exists() || !source.isFile) {
            result.success(failed("源文件不存在"))
            return
        }

        try {
            val outcome = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                exportWithMediaStore(source, name, target, mimeType)
            } else {
                exportLegacy(source, name, target)
            }
            result.success(outcome)
        } catch (e: Exception) {
            result.success(failed(e.message ?: "导出失败"))
        }
    }

    /**
     * 用系统默认程序打开产物。
     *
     * 两种入参都支持：入库后的 `content://media/...`，以及下载目录里的绝对路径
     * （未导出过的产物）。后者由 [toShareUri] 换成 FileProvider 的 content Uri ——
     * Android 7+ 把 file:// 交给外部应用会抛 `FileUriExposedException`。
     *
     * 返回值表示「Intent 有没有发出去」，没有匹配的播放器时给 false，
     * 由 Dart 侧提示一句而不是抛异常。
     */
    private fun openMedia(raw: String?): Boolean {
        if (raw.isNullOrEmpty()) return false

        return try {
            val uri = toShareUri(raw)
            launch(
                Intent(Intent.ACTION_VIEW).apply {
                    setDataAndType(uri, mimeOf(uri, raw))
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                },
            )
            true
        } catch (_: ActivityNotFoundException) {
            false
        } catch (_: Exception) {
            false
        }
    }

    /** 调系统分享面板把产物发给别的应用（ACTION_SEND）。 */
    private fun shareMedia(raw: String?): Boolean {
        if (raw.isNullOrEmpty()) return false

        val file = File(raw)
        if (!file.exists() || !file.isFile) return false

        return try {
            val uri = toShareUri(raw)
            val send = Intent(Intent.ACTION_SEND).apply {
                type = mimeOf(uri, raw)
                putExtra(Intent.EXTRA_STREAM, uri)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            // chooser 也要带授权，否则接收方拿不到读权限。
            launch(
                Intent.createChooser(send, null).apply {
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                },
            )
            true
        } catch (_: Exception) {
            false
        }
    }

    /**
     * 把 Dart 侧传来的目标换成可以交给外部应用的 Uri。
     *
     * `content://`（媒体库）原样返回；绝对路径走 FileProvider。路径不在
     * `file_paths.xml` 声明的目录内时会抛异常，此时退回 file Uri —— 现在的下载目录
     * 都在声明范围内，这条分支只是兜底，真走到这里说明路径规则变了。
     */
    private fun toShareUri(raw: String): Uri {
        if (!raw.startsWith("/")) return Uri.parse(raw)
        return try {
            FileProvider.getUriForFile(
                context,
                "${context.packageName}.fileprovider",
                File(raw),
            )
        } catch (_: Exception) {
            Uri.fromFile(File(raw))
        }
    }

    /** 优先问 ContentResolver，其次按扩展名猜，最后给通用二进制。 */
    private fun mimeOf(uri: Uri, pathHint: String): String {
        if (uri.scheme == "content") {
            val fromResolver = context.contentResolver.getType(uri)
            if (!fromResolver.isNullOrEmpty()) return fromResolver
        }
        val ext = pathHint.substringAfterLast('.', "").lowercase()
        return MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext)
            ?: "application/octet-stream"
    }

    /** 非 Activity 的 Context 起 Activity 必须带 NEW_TASK。 */
    private fun launch(intent: Intent) {
        if (context !is Activity) intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        context.startActivity(intent)
    }

    private fun exportWithMediaStore(
        source: File,
        name: String,
        target: String,
        mimeType: String?,
    ): Map<String, Any?> {
        val safeName = sanitize(name)
        val mime = normalizeMime(source, mimeType)
        val (collection, relativePath) = destination(target, mime)

        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, safeName)
            put(MediaStore.MediaColumns.MIME_TYPE, mime)
            put(MediaStore.MediaColumns.RELATIVE_PATH, relativePath)
            put(MediaStore.MediaColumns.IS_PENDING, 1)
        }

        val resolver = context.contentResolver
        val uri: Uri = resolver.insert(collection, values)
            ?: return failed("无法在媒体库创建条目")

        try {
            val stream = resolver.openOutputStream(uri)
                ?: throw IllegalStateException("无法打开媒体库输出流")
            stream.use { output ->
                source.inputStream().use { input -> input.copyTo(output) }
            }

            // 置回 0，否则该条目对其它应用不可见。
            values.clear()
            values.put(MediaStore.MediaColumns.IS_PENDING, 0)
            resolver.update(uri, values, null, null)

            return mapOf("status" to "done", "uri" to uri.toString())
        } catch (e: Exception) {
            // 半截文件不能留在媒体库里。
            resolver.delete(uri, null, null)
            throw e
        }
    }

    private fun destination(target: String, mime: String): Pair<Uri, String> {
        val folder = "SniffingBrowser"
        when (target) {
            "music" -> return MediaStore.Audio.Media.EXTERNAL_CONTENT_URI to
                "${Environment.DIRECTORY_MUSIC}/$folder"
            "file" -> return MediaStore.Downloads.EXTERNAL_CONTENT_URI to
                "${Environment.DIRECTORY_DOWNLOADS}/$folder"
            "gallery" -> {
                if (mime.startsWith("video/")) {
                    return MediaStore.Video.Media.EXTERNAL_CONTENT_URI to
                        "${Environment.DIRECTORY_MOVIES}/$folder"
                }
                return MediaStore.Images.Media.EXTERNAL_CONTENT_URI to
                    "${Environment.DIRECTORY_PICTURES}/$folder"
            }
        }
        // 未知 target：按 mime 猜一个合理的集合，别直接失败。
        return when {
            mime.startsWith("audio/") -> MediaStore.Audio.Media.EXTERNAL_CONTENT_URI to
                "${Environment.DIRECTORY_MUSIC}/$folder"
            mime.startsWith("video/") -> MediaStore.Video.Media.EXTERNAL_CONTENT_URI to
                "${Environment.DIRECTORY_MOVIES}/$folder"
            mime.startsWith("image/") -> MediaStore.Images.Media.EXTERNAL_CONTENT_URI to
                "${Environment.DIRECTORY_PICTURES}/$folder"
            else -> MediaStore.Downloads.EXTERNAL_CONTENT_URI to
                "${Environment.DIRECTORY_DOWNLOADS}/$folder"
        }
    }

    /**
     * Dart 侧按扩展名拼的 mime 偶尔不标准（image/jpg、video/m4s），
     * MediaStore 会据此挑错集合，这里统一按 Android 的映射表纠正。
     */
    private fun normalizeMime(source: File, fallback: String?): String {
        val ext = source.extension.lowercase()
        val mapped = MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext)
        if (!mapped.isNullOrEmpty()) return mapped
        return fallback?.takeIf { it.isNotEmpty() && it.contains('/') }
            ?: "application/octet-stream"
    }

    /** API <= 28：直接写公共目录，再通知媒体扫描。 */
    private fun exportLegacy(source: File, name: String, target: String): Map<String, Any?> {
        if (context.checkSelfPermission(
                android.Manifest.permission.WRITE_EXTERNAL_STORAGE,
            ) != PackageManager.PERMISSION_GRANTED
        ) {
            return failed("系统版本较旧，需要授予存储权限后才能导出")
        }

        val subDir = when (target) {
            "music" -> Environment.DIRECTORY_MUSIC
            "file" -> Environment.DIRECTORY_DOWNLOADS
            else -> if (source.extension.lowercase() in VIDEO_EXTENSIONS) {
                Environment.DIRECTORY_MOVIES
            } else {
                Environment.DIRECTORY_PICTURES
            }
        }

        val dir = File(
            Environment.getExternalStoragePublicDirectory(subDir),
            "SniffingBrowser",
        )
        if (!dir.exists() && !dir.mkdirs()) {
            return failed("无法创建导出目录")
        }

        var dest = File(dir, sanitize(name))
        var index = 1
        while (dest.exists()) {
            val base = dest.nameWithoutExtension
            val ext = dest.extension
            dest = File(dir, if (ext.isEmpty()) "$base ($index)" else "$base ($index).$ext")
            index++
        }

        source.inputStream().use { input ->
            dest.outputStream().use { output -> input.copyTo(output) }
        }
        MediaScannerConnection.scanFile(context, arrayOf(dest.absolutePath), null, null)
        return mapOf("status" to "done", "uri" to dest.absolutePath)
    }

    private fun sanitize(name: String): String =
        name.replace(Regex("[\\\\/:*?\"<>|\\x00-\\x1F]"), "_")
            .trim()
            .ifEmpty { "unnamed" }

    private fun failed(message: String): Map<String, Any?> =
        mapOf("status" to "failed", "message" to message)

    private companion object {
        val VIDEO_EXTENSIONS = setOf(
            "mp4", "mov", "m4v", "mkv", "webm", "flv", "avi", "wmv", "3gp", "ts", "m2ts",
        )
    }
}
