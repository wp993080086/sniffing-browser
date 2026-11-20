package com.wp.sniffing_browser

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        val messenger = flutterEngine.dartExecutor.binaryMessenger

        MethodChannel(messenger, MEDIA_EXPORTER_CHANNEL)
            .setMethodCallHandler(MediaExporterHandler(this))

        val transcoderChannel = MethodChannel(messenger, TRANSCODER_CHANNEL)
        transcoderChannel.setMethodCallHandler(TranscodeBridge(transcoderChannel))

        MethodChannel(messenger, THUMBNAILER_CHANNEL)
            .setMethodCallHandler(ThumbnailBridge())

        MethodChannel(messenger, DOWNLOAD_SERVICE_CHANNEL)
            .setMethodCallHandler(DownloadServiceBridge(this))
    }

    private companion object {
        const val MEDIA_EXPORTER_CHANNEL = "sniffing_browser/media_exporter"
        const val TRANSCODER_CHANNEL = "sniffing_browser/transcoder"
        const val THUMBNAILER_CHANNEL = "sniffing_browser/thumbnailer"
        const val DOWNLOAD_SERVICE_CHANNEL = "sniffing_browser/download_service"
    }
}
