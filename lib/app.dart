import 'package:material_ui/material_ui.dart';
import 'package:material_3_expressive/material_3_expressive.dart';

import 'app_controller.dart';
import 'ui/home.dart';

class CanaryApp extends StatefulWidget {
  const CanaryApp({super.key});
  @override
  State<CanaryApp> createState() => _CanaryAppState();
}

class _CanaryAppState extends State<CanaryApp> {
  final _controller = AppController();
  @override
  void initState() {
    super.initState();
    _controller.initialize();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => M3EMaterialApp(
    title: 'ECH Canary',
    debugShowCheckedModeBanner: false,
    data: M3EThemeData.light(seedColor: const Color(0xFF566A32)),
    fontFamilyFallback: const [
      'Microsoft YaHei',
      'PingFang SC',
      'Noto Sans CJK SC',
    ],
    autoTheming: true,
    dynamicColoring: true,
    home: CanaryHome(controller: _controller),
  );
}
