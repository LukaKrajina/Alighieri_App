import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'app.dart';
import 'src/rust/frb_generated.dart';
import 'state/app_state.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 加载 Rust 核心。失败时界面照常起来（只是读不到副本）——
  // 白屏一出现，用户只会以为是我们没做完。
  try {
    await Alighieri.init();
  } catch (e) {
    debugPrint('[alighieri] Rust 核心加载失败：$e');
  }
  final state = AppState();
  await state.init();
  runApp(
    ChangeNotifierProvider.value(value: state, child: const AlighieriApp()),
  );
}
