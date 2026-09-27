import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../domain/models.dart';

class ScanStore {
  Future<ScanConfig> loadConfig() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('scan_config_v1');
    if (raw == null) return const ScanConfig();
    final config = ScanConfig.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    if (config.validate(requireTarget: false) != null) {
      throw const FormatException('保存的配置无效');
    }
    return config;
  }

  Future<void> saveConfig(ScanConfig config) async {
    final prefs = await SharedPreferences.getInstance();
    if (!await prefs.setString('scan_config_v1', jsonEncode(config.toJson()))) {
      throw const FileSystemException('配置保存失败');
    }
  }

  Future<Directory> _directory() async {
    final root = await getApplicationSupportDirectory();
    return Directory('${root.path}/reports').create(recursive: true);
  }

  Future<List<ScanReport>> loadReports() async {
    final directory = await _directory();
    final files = await directory
        .list()
        .where((f) => f is File && f.path.endsWith('.json'))
        .cast<File>()
        .toList();
    files.sort((a, b) => b.path.compareTo(a.path));
    final reports = <ScanReport>[];
    for (final file in files.take(20)) {
      reports.add(
        ScanReport.fromJson(
          jsonDecode(await file.readAsString()) as Map<String, dynamic>,
        ),
      );
    }
    return reports;
  }

  Future<void> saveReport(ScanReport report) async {
    final directory = await _directory();
    final temporary = File('${directory.path}/${report.id}.tmp');
    await temporary.writeAsString(report.json, flush: true);
    await temporary.rename('${directory.path}/${report.id}.json');
    final files = await directory
        .list()
        .where((f) => f is File && f.path.endsWith('.json'))
        .cast<File>()
        .toList();
    files.sort((a, b) => b.path.compareTo(a.path));
    for (final old in files.skip(20)) {
      await old.delete();
    }
  }
}
