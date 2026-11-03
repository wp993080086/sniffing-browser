import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../diagnostics/presentation/diagnostics_page.dart';
import '../../downloader/presentation/download_page.dart';
import '../../sniffer/data/sniffer_service.dart';
import '../../sniffer/presentation/resource_panel.dart';
import '../providers/browser_provider.dart';
import 'address_bar.dart';
import 'webview_host.dart';

class BrowserPage extends ConsumerWidget {
  const BrowserPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final BrowserController browser = ref.read(browserProvider);

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 4,
        toolbarHeight: 52,
        title: AddressBar(
          onSubmit: (String value) => ref.read(browserProvider).navigate(value),
        ),
        actions: <Widget>[
          Consumer(
            builder: (BuildContext context, WidgetRef ref, Widget? child) {
              final int active = ref.watch(downloadQueueProvider).activeCount;
              return IconButton(
                tooltip: '下载',
                icon: active > 0
                    ? Badge(
                        label: Text('$active'),
                        child: const Icon(Icons.download_outlined),
                      )
                    : const Icon(Icons.download_outlined),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (BuildContext context) => const DownloadPage(),
                  ),
                ),
              );
            },
          ),
          IconButton(
            tooltip: '诊断日志',
            icon: const Icon(Icons.bug_report_outlined, size: 20),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (BuildContext context) => const DiagnosticsPage(),
              ),
            ),
          ),
          const SizedBox(width: 4),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(2),
          child: ValueListenableBuilder<double>(
            valueListenable: browser.progress,
            builder: (BuildContext context, double value, Widget? child) {
              if (value >= 1 || value <= 0) {
                return const SizedBox(height: 2);
              }
              return LinearProgressIndicator(value: value, minHeight: 2);
            },
          ),
        ),
      ),
      body: const WebViewHost(),
      floatingActionButton: Consumer(
        builder: (BuildContext context, WidgetRef ref, Widget? child) {
          final SnifferService sniffer = ref.watch(snifferProvider);
          final int count = sniffer.count;
          return FloatingActionButton.extended(
            heroTag: 'sniffer_fab',
            onPressed: () => showResourcePanel(context),
            icon: Icon(count > 0 ? Icons.radar : Icons.radar_outlined, size: 20),
            label: Text(
              count > 0 ? '$count 个资源' : '嗅探中',
              style: const TextStyle(fontSize: 12),
            ),
            elevation: 2,
          );
        },
      ),
    );
  }
}
