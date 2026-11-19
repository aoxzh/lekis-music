// 音源凭据的读写顺序：先写凭据，再写配置；删除时先删音源，再删凭据。
//
// 这里刻意只把 `credential_ref` 放进数据库，密码只在 Dart 内存里短暂停留，
// 交给核心后立刻 `forgetSecret()`。编辑时没有输入新密码就沿用原来的引用，
// 不会、也无法把已保存的密码读回界面。

import 'dart:math';

import '../../rust/api/dto.dart';
import 'source_draft.dart';
import 'source_gateway.dart';

class SourceCredentialService {
  SourceCredentialService(this._gateway, {String Function()? newRef})
    : _newRef = newRef ?? _defaultRef;

  final SourceGateway _gateway;
  final String Function() _newRef;

  /// 新音源：有密码时先生成引用并写凭据，再保存配置。保存失败会清掉刚写的凭据。
  Future<int> add(SourceDraft draft) async {
    final secret = draft.secret;
    final usesSecret = draft.usesCredential && secret.isNotEmpty;
    final ref = usesSecret ? _newRef() : null;
    if (ref != null) {
      await _gateway.setCredential(ref, secret);
    }
    try {
      return await _gateway.addSource(draft.toConfig(credentialRef: ref));
    } catch (_) {
      if (ref != null) await _deleteQuietly(ref);
      rethrow;
    } finally {
      draft.forgetSecret();
    }
  }

  /// 编辑音源：没填新密码就保留旧引用；换了密码则覆盖同一个引用（或新建一个）。
  /// 改成访客 / 匿名访问时把旧凭据删掉，地址和 options 里仍然不放密码。
  Future<void> update(SourceConfigDto existing, SourceDraft draft) async {
    final oldRef = _nonEmpty(existing.credentialRef);
    final secret = draft.secret;
    final String? ref;
    final String? secretToWrite;
    if (!draft.usesCredential) {
      ref = null;
      secretToWrite = null;
    } else if (secret.isNotEmpty) {
      ref = oldRef ?? _newRef();
      secretToWrite = secret;
    } else {
      // 没有重新输入密码：沿用已保存的引用。即使旧配置没有引用，
      // 也不会凭空造一个空凭据。
      ref = oldRef;
      secretToWrite = null;
    }

    final createdRef = ref != null && ref != oldRef;
    if (secretToWrite != null) {
      await _gateway.setCredential(ref!, secretToWrite);
    }
    try {
      await _gateway.updateSource(
        draft.toConfig(id: existing.id, credentialRef: ref),
      );
    } catch (_) {
      // 新引用还没被任何音源使用，回滚掉；覆盖旧引用时无法还原旧密码，
      // 但音源配置没变，下次用户还可以再替换一次。
      if (createdRef) await _deleteQuietly(ref);
      rethrow;
    } finally {
      draft.forgetSecret();
    }

    if (oldRef != null && oldRef != ref) {
      await _gateway.deleteCredential(oldRef);
    }
  }

  /// 删除音源后清掉它的凭据。返回凭据是否清理成功；音源本身已经删掉时，
  /// 凭据清理失败不该把界面卡在“没删掉”的状态。
  Future<bool> delete(SourceConfigDto source) async {
    final id = source.id;
    if (id == null) return false;
    await _gateway.removeSource(id.toInt());
    final ref = _nonEmpty(source.credentialRef);
    if (ref == null) return true;
    try {
      await _gateway.deleteCredential(ref);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 详情页的“测试连接”：直接测已保存的配置，密码由核心按引用读取。
  Future<void> test(SourceConfigDto source) => _gateway.testSource(source);

  /// 表单里的“测试连接”：密码还没保存时用临时引用，测完立刻删掉，
  /// 不污染正式凭据，也不需要先把音源写进数据库。
  Future<void> testDraft(SourceDraft draft, {SourceConfigDto? existing}) async {
    final existingRef = _nonEmpty(existing?.credentialRef);
    final secret = draft.secret;
    final tempRef = draft.usesCredential && secret.isNotEmpty
        ? _newRef()
        : null;
    final ref = tempRef ?? (draft.usesCredential ? existingRef : null);
    if (tempRef != null) {
      await _gateway.setCredential(tempRef, secret);
    }
    try {
      await _gateway.testSource(draft.toConfig(credentialRef: ref));
    } finally {
      if (tempRef != null) await _deleteQuietly(tempRef);
    }
  }

  Future<void> _deleteQuietly(String ref) async {
    try {
      await _gateway.deleteCredential(ref);
    } catch (_) {
      // 清理失败时不在测试 / 保存失败的主错误上再盖一层错误。
    }
  }

  static String? _nonEmpty(String? value) {
    final trimmed = value?.trim() ?? '';
    return trimmed.isEmpty ? null : trimmed;
  }

  static String _defaultRef() {
    final random = Random.secure();
    final suffix = List.generate(4, (_) => random.nextInt(1 << 32)).join('.');
    return 'lekis.source.${DateTime.now().microsecondsSinceEpoch}.$suffix';
  }
}
