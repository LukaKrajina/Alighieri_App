import 'package:flutter/material.dart';

import '../widgets/widgets.dart';
import 'app_state.dart';

/// 引擎的阅读门槛错误是 `review.needRead:<have>:<need>:<scope>`。
///
/// 正常情况下按钮会被 UI 门槛挡住；这里兜住并发、直接调用等路径，
/// 并把内部错误串翻译成人话 —— 总比让用户研究错误码友好。
/// 作品评论与单话评论共用同一套错误格式。
void showReviewGateError(BuildContext context, AppState state, Object error) {
  final raw = error.toString();
  final m = RegExp(r'review\.needRead:(\d+):(\d+):(work|chapter)')
      .firstMatch(raw);
  if (m == null) {
    showError(context, error);
    return;
  }
  final text = state.t('review.needRead', {
    'have': m.group(1)!,
    'need': m.group(2)!,
    'scope': state.t('review.scope.${m.group(3)}'),
  });
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
}
