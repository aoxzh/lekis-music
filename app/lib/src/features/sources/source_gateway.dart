// 音源 / 凭据操作的核心门面。单独抽出来是为了在单测里替换成内存实现，
// 不需要启动 Flutter 引擎或 Rust 核心。

import '../../rust/api/core.dart' as core;
import '../../rust/api/dto.dart';

abstract interface class SourceGateway {
  Future<int> addSource(SourceConfigDto source);
  Future<void> updateSource(SourceConfigDto source);
  Future<void> removeSource(int sourceId);
  Future<void> testSource(SourceConfigDto source);
  Future<void> setCredential(String credentialRef, String secret);
  Future<void> deleteCredential(String credentialRef);
  bool hasCredential(String credentialRef);
}

/// 真正调用 Rust 核心的实现。
class CoreSourceGateway implements SourceGateway {
  const CoreSourceGateway();

  @override
  Future<int> addSource(SourceConfigDto source) =>
      core.addSource(source: source);

  @override
  Future<void> updateSource(SourceConfigDto source) =>
      core.updateSource(source: source);

  @override
  Future<void> removeSource(int sourceId) =>
      core.removeSource(sourceId: sourceId);

  @override
  Future<void> testSource(SourceConfigDto source) =>
      core.testSource(source: source);

  @override
  Future<void> setCredential(String credentialRef, String secret) =>
      core.setCredential(credentialRef: credentialRef, secret: secret);

  @override
  Future<void> deleteCredential(String credentialRef) =>
      core.deleteCredential(credentialRef: credentialRef);

  @override
  bool hasCredential(String credentialRef) =>
      core.hasCredential(credentialRef: credentialRef);
}
