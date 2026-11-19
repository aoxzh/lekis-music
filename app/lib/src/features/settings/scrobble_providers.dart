// 听歌记录上报（DIS-07）的设置状态：设置、状态、连接测试。
//
// 凭据永远不回读 Dart：`ScrobbleSettingsDto` 只有 has* 布尔值，保存时用
// `Option<String>` 语义（null = 保留已保存的值）。

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../rust/api/core.dart' as core;
import '../../rust/api/dto.dart';

@immutable
class ScrobbleState {
  const ScrobbleState({this.settings, this.status, this.testing = false});

  final ScrobbleSettingsDto? settings;
  final ScrobbleStatusDto? status;
  final bool testing;

  ScrobbleState copyWith({
    ScrobbleSettingsDto? settings,
    ScrobbleStatusDto? status,
    bool? testing,
  }) => ScrobbleState(
    settings: settings ?? this.settings,
    status: status ?? this.status,
    testing: testing ?? this.testing,
  );
}

final scrobbleProvider = NotifierProvider<ScrobbleNotifier, ScrobbleState>(
  ScrobbleNotifier.new,
);

class ScrobbleNotifier extends Notifier<ScrobbleState> {
  @override
  ScrobbleState build() => _read();

  ScrobbleState _read({bool testing = false}) {
    try {
      return ScrobbleState(
        settings: core.scrobbleSettings(),
        status: core.scrobbleStatus(),
        testing: testing,
      );
    } catch (_) {
      return ScrobbleState(testing: testing);
    }
  }

  void refresh() => state = _read(testing: state.testing);

  Future<void> save(ScrobbleSettingsInputDto input) async {
    final settings = await core.setScrobbleSettings(settings: input);
    state = ScrobbleState(
      settings: settings,
      status: core.scrobbleStatus(),
      testing: state.testing,
    );
  }

  /// 只读连接测试（不会产生 scrobble / now-playing）。
  Future<void> test() async {
    state = state.copyWith(testing: true);
    try {
      await core.testScrobble();
    } finally {
      state = _read();
    }
  }
}
