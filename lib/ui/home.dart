import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:share_plus/share_plus.dart';

import '../app_controller.dart';
import 'components.dart';
import 'settings.dart';
import 'test_page.dart';

class CanaryHome extends StatefulWidget {
  const CanaryHome({super.key, required this.controller});
  final AppController controller;
  @override
  State<CanaryHome> createState() => _CanaryHomeState();
}

class _CanaryHomeState extends State<CanaryHome> {
  int page = 0;
  static const _destinations = [
    (label: '测试', title: '域名测试', icon: Icons.travel_explore_rounded),
    (label: '历史', title: '测试历史', icon: Icons.history_rounded),
    (label: '设置', title: '测试设置', icon: Icons.tune_rounded),
  ];
  static const _contentWidth = 840.0;
  AppController get c => widget.controller;

  Future<void> _export() async {
    final report = c.report;
    if (report == null) return;
    try {
      final bytes = Uint8List.fromList(utf8.encode(report.json));
      final name = 'ech-canary-${report.id}.json';
      if (Platform.isAndroid || Platform.isIOS) {
        final box = context.findRenderObject() as RenderBox?;
        await SharePlus.instance.share(
          ShareParams(
            files: [
              XFile.fromData(bytes, mimeType: 'application/json', name: name),
            ],
            fileNameOverrides: [name],
            sharePositionOrigin: box == null
                ? null
                : box.localToGlobal(Offset.zero) & box.size,
          ),
        );
      } else {
        final location = await getSaveLocation(
          suggestedName: name,
          acceptedTypeGroups: [
            const XTypeGroup(label: 'JSON 报告', extensions: ['json']),
          ],
        );
        if (location == null) return;
        await XFile.fromData(
          bytes,
          mimeType: 'application/json',
          name: name,
        ).saveTo(location.path);
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(const SnackBar(content: Text('报告已导出')));
        }
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('导出失败，请重试')));
      }
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: c,
    builder: (context, _) {
      final colors = Theme.of(context).colorScheme;
      final wide = MediaQuery.sizeOf(context).width >= 1000;
      return Scaffold(
        backgroundColor: colors.surface,
        body: SafeArea(
          child: Row(
            children: [
              if (wide)
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(28),
                    child: M3ENavigationRail(
                      type: M3ENavigationRailType.alwaysExpand,
                      expandedWidth: 240,
                      background: colors.surfaceContainerLow,
                      selectedIndex: page,
                      onDestinationSelected: (i) => setState(() => page = i),
                      sections: [
                        M3ENavigationRailSection(
                          header: Padding(
                            padding: const EdgeInsets.fromLTRB(8, 24, 8, 36),
                            child: Row(
                              children: [
                                Icon(
                                  Icons.sensors_rounded,
                                  color: colors.primary,
                                ),
                                const SizedBox(width: 12),
                                Flexible(
                                  child: Text(
                                    'ECH Canary',
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleLarge,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          destinations: [
                            for (final destination in _destinations)
                              M3ENavigationRailDestination(
                                icon: Icon(destination.icon),
                                label: destination.label,
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              Expanded(
                child: Column(
                  children: [
                    _appBar(context),
                    Expanded(
                      child: c.loading
                          ? const Center(
                              child: M3ELoadingIndicator(semanticLabel: '读取设置'),
                            )
                          : IndexedStack(
                              index: page,
                              children: [
                                _scroll('test', TestPage(controller: c)),
                                _scroll('history', _history(context)),
                                _scroll(
                                  'settings',
                                  SettingsPage(
                                    key: ValueKey(c.config),
                                    config: c.config,
                                    running: c.running,
                                    onSave: c.saveConfig,
                                  ),
                                ),
                              ],
                            ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        bottomNavigationBar: wide
            ? null
            : M3ENavigationBar(
                selectedIndex: page,
                onDestinationSelected: (i) => setState(() => page = i),
                destinations: [
                  for (final destination in _destinations)
                    M3ENavigationBarDestination(
                      icon: Icon(destination.icon),
                      label: destination.label,
                    ),
                ],
              ),
      );
    },
  );

  Widget _appBar(BuildContext context) {
    const height = 64.0;
    final theme = Theme.of(context);
    return SizedBox(
      height: height,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: _contentWidth),
            child: AppBar(
              primary: false,
              automaticallyImplyLeading: false,
              centerTitle: false,
              titleSpacing: 0,
              toolbarHeight: height,
              elevation: 0,
              scrolledUnderElevation: 0,
              backgroundColor: theme.colorScheme.surface,
              title: Text(_destinations[page].title),
              titleTextStyle: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w600,
              ),
              actions: [
                if (page == 0 && c.report != null && !c.running)
                  IconButton(
                    onPressed: _export,
                    icon: const Icon(Icons.ios_share_rounded),
                    tooltip: '导出报告',
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _scroll(String name, Widget child) => SingleChildScrollView(
    key: ValueKey(name),
    padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
    child: Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: _contentWidth),
        child: SizedBox(width: double.infinity, child: child),
      ),
    ),
  );

  Widget _history(BuildContext context) {
    if (c.history.isEmpty) {
      return const EmptyPanel(icon: Icons.history_rounded, title: '无测试记录');
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: Text(
            '保留最近 20 次结果',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        ...c.history.map(
          (report) => Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Panel(
              padding: 4,
              radius: 24,
              child: ListTile(
                leading: Icon(
                  report.complete
                      ? Icons.receipt_long_outlined
                      : Icons.stop_circle_outlined,
                ),
                title: Text(Uri.parse(report.config.target).host),
                subtitle: Text(
                  '${dateLabel(report.startedAt)} · ${report.complete
                      ? '已完成'
                      : report.cancelled
                      ? '已停止'
                      : '未完成'}',
                ),
                trailing: const Icon(Icons.chevron_right_rounded),
                enabled: !c.running,
                onTap: () {
                  c.openReport(report);
                  setState(() => page = 0);
                },
              ),
            ),
          ),
        ),
      ],
    );
  }
}
