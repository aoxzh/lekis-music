// 音源页面的全部双语文案。

import '../../l10n/app_l10n.dart';

abstract final class SourcesStrings {
  static String get title => L10n.tr('音源', 'Sources');
  static String get addSource => L10n.tr('添加音源', 'Add Source');
  static String get editSource => L10n.tr('编辑音源', 'Edit Source');
  static String get emptyTitle => L10n.tr('还没有音源', 'No Sources Yet');
  static String get emptyBody => L10n.tr(
    '添加一个本地文件夹、NAS 共享或媒体服务器，Lekis 会自动整理你的音乐。',
    'Add a local folder, NAS share, or media server and Lekis will organize your music automatically.',
  );
  static String get loadFailed => L10n.tr('读取音源列表失败', 'Failed to load sources');
  static String get retry => L10n.tr('重试', 'Retry');
  static String get selectHint => L10n.tr(
    '选择左侧的音源查看详情，或添加一个新的音源。',
    'Select a source on the left to inspect, or add a new one.',
  );

  // 状态
  static String get reachable => L10n.tr('在线', 'Online');
  static String get unreachable => L10n.tr('无法连接', 'Unreachable');
  static String get reachabilityUnknown => L10n.tr('未检测', 'Unknown');
  static String get disabled => L10n.tr('已停用', 'Disabled');
  static String get neverScanned => L10n.tr('尚未扫描', 'Never scanned');
  static String lastScanOk(String when) =>
      L10n.tr('$when 扫描完成', 'Scanned $when');
  static String lastScanFailed(String when, String why) =>
      L10n.tr('$when 扫描失败：$why', 'Scan failed $when: $why');
  static String lastScan(String when, int added, int updated, int removed) =>
      L10n.tr(
        '$when 扫描完成：新增 $added，更新 $updated，移除 $removed',
        'Scanned $when: +$added, ~$updated, -$removed',
      );
  static String get justNow => L10n.tr('刚刚', 'just now');
  static String minutesAgo(int m) => L10n.tr('$m 分钟前', '${m}m ago');
  static String hoursAgo(int h) => L10n.tr('$h 小时前', '${h}h ago');
  static String daysAgo(int d) => L10n.tr('$d 天前', '${d}d ago');
  static String get scanStarting => L10n.tr('准备扫描…', 'Starting scan…');
  static String scanCount(int done, int? total) => total == null
      ? L10n.tr('已处理 $done', 'Processed $done')
      : '$done / $total';
  static String scanEta(Duration left) {
    final minutes = left.inMinutes;
    if (minutes < 1) {
      final seconds = left.inSeconds.clamp(1, 59);
      return L10n.tr('剩余约 $seconds 秒', 'About ${seconds}s left');
    }
    if (minutes < 60) {
      return L10n.tr('剩余约 $minutes 分钟', 'About ${minutes}m left');
    }
    final hours = left.inHours;
    final rest = minutes % 60;
    return L10n.tr('剩余约 $hours 小时 $rest 分钟', 'About ${hours}h ${rest}m left');
  }

  static String get phaseWalking => L10n.tr('正在查找文件', 'Scanning files');
  static String get phaseReadingTags => L10n.tr('正在读取标签', 'Reading tags');
  static String get phaseArtwork => L10n.tr('正在处理封面', 'Processing artwork');
  static String get phaseWritingSharedIndex =>
      L10n.tr('正在写入共享索引', 'Writing shared index');
  static String get rescan => L10n.tr('重新扫描', 'Rescan');
  static String get scanAll => L10n.tr('扫描全部音源', 'Scan All Sources');
  static String get noEnabledSources =>
      L10n.tr('没有已启用的音源', 'No enabled sources');
  static String scanAllStarted(int count) =>
      L10n.tr('开始扫描 $count 个音源', 'Scanning $count sources');
  static String scanAllDone(int count, int failed) => failed == 0
      ? L10n.tr('已开始扫描 $count 个音源', 'Scanning $count sources')
      : L10n.tr(
          '已开始扫描 $count 个音源，$failed 个启动失败',
          'Scanning $count sources, $failed failed to start',
        );
  static String get syncNow => L10n.tr('立即同步', 'Sync Now');
  static String syncDone(int pushed, int pulled, int applied) => L10n.tr(
    '同步完成：推送 $pushed，拉取 $pulled，应用 $applied',
    'Sync complete: pushed $pushed, pulled $pulled, applied $applied',
  );
  static String get scanStarted => L10n.tr('已开始扫描', 'Scan started');

  // 详情
  static String get detailKind => L10n.tr('类型', 'Type');
  static String get detailAddress => L10n.tr('地址', 'Address');
  static String get detailPath => L10n.tr('路径', 'Path');
  static String get detailStatus => L10n.tr('状态', 'Status');
  static String get detailLastScan => L10n.tr('上次扫描', 'Last Scan');
  static String get detailCredential => L10n.tr('密码', 'Password');
  static String get detailUsername => L10n.tr('用户名', 'Username');
  static String get credentialSaved => L10n.tr('已保存', 'Saved');
  static String get credentialNotSet => L10n.tr('未保存', 'Not set');
  static String get credentialGuest =>
      L10n.tr('访客连接，无需密码', 'Guest (no password)');
  static String get credentialAnonymous =>
      L10n.tr('匿名访问，无需密码', 'Anonymous (no password)');

  // 详情页操作
  static String get testConnection => L10n.tr('测试连接', 'Test Connection');
  static String get testing => L10n.tr('正在测试…', 'Testing…');
  static String get testSuccess => L10n.tr('连接成功', 'Connection succeeded');
  static String get edit => L10n.tr('编辑', 'Edit');
  static String get deleteSource => L10n.tr('删除音源', 'Delete Source');
  static String get deleteTitle => L10n.tr('删除这个音源？', 'Delete this source?');
  static String deleteBody(String name) => L10n.tr(
    '“$name”和它的曲目索引会被删除，已保存的密码也会一并清掉。这个操作不能撤销。',
    '"$name", its indexed tracks, and saved credentials will be removed. This cannot be undone.',
  );
  static String get delete => L10n.tr('删除', 'Delete');
  static String get deleted => L10n.tr('音源已删除', 'Source deleted');
  static String get deletedCredentialLeft => L10n.tr(
    '音源已删除，但凭据没能清理干净',
    'Source deleted, but credentials could not be cleared',
  );

  // 类型
  static String get kindLocal => L10n.tr('本地文件夹', 'Local Folder');
  static String get kindSmb => L10n.tr('SMB 共享', 'SMB Share');
  static const kindWebDav = 'WebDAV';
  static const kindNfs = 'NFS';
  static const kindSftp = 'SFTP';
  static const kindOpenSubsonic = 'Navidrome / OpenSubsonic';
  static const kindJellyfin = 'Jellyfin';
  static const kindEmby = 'Emby';
  static const kindPlex = 'Plex';
  static String get kindRadio => L10n.tr('网络电台', 'Internet Radio');
  static String get kindPlugin => L10n.tr('插件', 'Plugin');

  static String get kindLocalHint =>
      L10n.tr('这台设备上的音乐文件夹', 'A music folder on this device');
  static String get kindSmbHint => L10n.tr(
    'Windows 共享、群晖 / 威联通等 NAS',
    'Windows shares, Synology / QNAP NAS',
  );
  static String get kindWebDavHint =>
      L10n.tr('NAS、网盘或任何 WebDAV 服务', 'NAS, cloud drive, or any WebDAV server');
  static String get kindOpenSubsonicHint =>
      L10n.tr('Navidrome、Gonic、Airsonic 等', 'Navidrome, Gonic, Airsonic, etc.');
  static String get kindJellyfinHint =>
      L10n.tr('用 API 密钥连接 Jellyfin 服务器', 'Connect to Jellyfin with an API key');
  static String get kindPlexHint =>
      L10n.tr('用 Plex Token 连接', 'Connect with a Plex Token');
  static String get kindNfsHint => L10n.tr(
    'Linux NAS、群晖 / TrueNAS 的 NFS 导出',
    'Linux NAS, Synology / TrueNAS NFS exports',
  );
  static String get kindSftpHint =>
      L10n.tr('通过 SSH 访问 NAS 或服务器上的文件夹', 'Access folders over SSH');

  // 添加流程
  static String get chooseKind => L10n.tr('你的音乐放在哪里？', 'Where is your music?');
  static String get chooseKindBody => L10n.tr(
    '大多数人从这台设备上的音乐文件夹开始。以后随时可以再添加 NAS 或媒体服务器。',
    'Start with a local folder on this device, or connect a NAS / media server anytime.',
  );
  static String get recommended => L10n.tr('推荐', 'Recommended');
  static String get kindLocalFeaturedHint => L10n.tr(
    '选一个放音乐的文件夹，Lekis 会扫描里面所有的子文件夹',
    'Pick a folder and Lekis will scan all subfolders',
  );
  static String get groupThisDevice => L10n.tr('这台设备', 'This Device');
  static String get groupNetwork => L10n.tr('网络上的音乐库', 'Network Libraries');
  static String get groupNetworkBody => L10n.tr(
    '家里的 NAS、电脑共享或 Navidrome / Jellyfin / Plex 服务器，需要地址和账号。',
    'Home NAS, computer shares, or Navidrome / Jellyfin / Plex servers.',
  );
  static String get groupNetworkShare => L10n.tr('网络共享', 'Network Shares');
  static String get groupMediaServer => L10n.tr('媒体服务器', 'Media Servers');
  static String get localFormBody => L10n.tr(
    '选一个放音乐的文件夹，Lekis 会扫描里面所有的子文件夹并自动整理。',
    'Pick a music folder and Lekis will scan and organize all subfolders.',
  );
  static String get addAndScan => L10n.tr('添加并扫描', 'Add & Scan');
  static String get adding => L10n.tr('正在添加…', 'Adding…');
  static String get moreOptions => L10n.tr('更多选项', 'More Options');
  static String get moreOptionsHint =>
      L10n.tr('备用地址等，不改也能正常使用', 'Alternate addresses and optional settings');
  static String get fieldAlternates =>
      L10n.tr('备用地址（可选）', 'Alternate Addresses (Optional)');
  static String get fieldAlternatesHint => L10n.tr(
    '每行一个，例如 Tailscale 或外网地址',
    'One per line, e.g. Tailscale or public URL',
  );
  static String get fieldAlternatesHelper =>
      L10n.tr('主地址连不上时按顺序尝试', 'Tried in order if the primary address fails');
  static String get detailAlternate => L10n.tr('备用地址', 'Alternate Addresses');
  static String get discoveryTitle =>
      L10n.tr('在你的网络上发现', 'Discover on Your Network');
  static String get discoveryBody => L10n.tr(
    '在同一网络里搜索 SMB、WebDAV 和 DLNA 设备。点一下结果就能预填表单。',
    'Search for SMB, WebDAV, and DLNA servers on your LAN.',
  );
  static String get discoveryNothingYet => L10n.tr(
    '没有发现设备。也可以在下面手动添加。',
    'No devices discovered yet. You can also add manually below.',
  );
  static String get scanLan => L10n.tr('扫描局域网', 'Scan LAN');
  static String get scanningLan => L10n.tr('正在扫描…', 'Scanning…');
  static String get scanAgain => L10n.tr('重新扫描', 'Scan Again');
  static String get discoveryScanningBody => L10n.tr(
    '正在搜索 mDNS、WS-Discovery 和 DLNA，最多需要几秒。',
    'Searching mDNS, WS-Discovery & DLNA…',
  );
  static String get discoveryEmpty => L10n.tr(
    '没有发现设备。确认 NAS 已开机、和这台设备在同一网络，或手动填写地址。',
    'No devices found. Ensure your NAS is on the same network or enter details manually.',
  );
  static String get discoveryError => L10n.tr('扫描失败', 'Scan failed');
  static String get discoveryDlnaNote => L10n.tr(
    'DLNA 媒体服务器，可能提供 SMB 共享',
    'DLNA server, may also offer SMB shares',
  );
  static String get discoveryPickHint =>
      L10n.tr('点一下结果，填好账号就能选共享', 'Tap a device to prefill its address');
  static String discoveryFoundCount(int n) =>
      L10n.tr('发现 $n 台设备', n == 1 ? 'Found 1 device' : 'Found $n devices');
  static const viaMdns = 'mDNS';
  static const viaWsDiscovery = 'WS-Discovery';
  static const viaSsdp = 'DLNA / SSDP';
  static const kindDlna = 'DLNA';
  static String get back => L10n.tr('返回', 'Back');
  static String get cancel => L10n.tr('取消', 'Cancel');
  static String get testAndSave => L10n.tr('连接并保存', 'Connect & Save');
  static String get saveChanges => L10n.tr('保存修改', 'Save Changes');
  static String get saving => L10n.tr('正在连接…', 'Connecting…');
  static String get savingChanges => L10n.tr('正在保存…', 'Saving…');
  static String get saved => L10n.tr('已添加，正在扫描', 'Added — scanning now');
  static String get savedChanges => L10n.tr('已保存', 'Saved');
  static String get savedButScanFailed => L10n.tr(
    '音源已保存，但第一次扫描没能开始',
    'Source saved, but initial scan failed to start',
  );

  // 表单
  static String get fieldName => L10n.tr('名称', 'Name');
  static String get fieldNameHint =>
      L10n.tr('留空则自动命名', 'Leave blank to auto-name');
  static String get fieldHost => L10n.tr('主机', 'Host');
  static String get fieldHostHint =>
      L10n.tr('例如 192.168.1.10 或 nas.local', 'e.g. 192.168.1.10 or nas.local');
  static String get fieldShare => L10n.tr('共享名', 'Share');
  static String get fieldShareHint => L10n.tr('例如 music', 'e.g. music');
  static String get fieldPath => L10n.tr('子文件夹（可选）', 'Subfolder (Optional)');
  static String get fieldPathHint =>
      L10n.tr('例如 FLAC/古典', 'e.g. FLAC/Classical');
  static String get fieldExport => L10n.tr('导出路径', 'Export Path');
  static String get fieldExportHint =>
      L10n.tr('例如 /volume1/music', 'e.g. /volume1/music');
  static String get fieldNfsHostHint => L10n.tr(
    '例如 192.168.1.10（需要 NFSv3）',
    'e.g. 192.168.1.10 (NFSv3 required)',
  );
  static String get nfsNotice => L10n.tr(
    'NFS 以匿名方式连接，需要在 NAS 的 NFS 权限里允许这台设备的 IP。',
    'NFS connects anonymously; allow this device IP in your NAS NFS rules.',
  );
  static String get fieldPort => L10n.tr('端口（可选）', 'Port (Optional)');
  static const fieldPortHint = '22';
  static String get fieldSftpPath => L10n.tr('文件夹（可选）', 'Folder (Optional)');
  static String get fieldSftpPathHint =>
      L10n.tr('例如 volume1/music，留空为根目录', 'e.g. volume1/music, blank for root');
  static String get authPassword => L10n.tr('密码', 'Password');
  static String get authKey => L10n.tr('私钥', 'Private Key');
  static String get fieldPrivateKey => L10n.tr('私钥', 'Private Key');
  static String get fieldPrivateKeyHint => L10n.tr(
    '粘贴 OpenSSH 格式的私钥全文，支持 Ed25519 / ECDSA',
    'Paste full OpenSSH private key (Ed25519 / ECDSA)',
  );
  static String get fieldKeyPassphrase =>
      L10n.tr('私钥密码（可选）', 'Key Passphrase (Optional)');
  static String get newPrivateKey => L10n.tr('新私钥', 'New Private Key');
  static String get keySavedNotice => L10n.tr(
    '私钥已保存，不需要重新粘贴。需要修改时点“替换私钥”。',
    'Private key is saved. Click "Replace Key" to update.',
  );
  static String get replaceKey => L10n.tr('替换私钥', 'Replace Key');
  static String get keepKey => L10n.tr('保留已保存的私钥', 'Keep Saved Key');

  // 共享列表 / 文件夹浏览
  static String get listShares => L10n.tr('列出共享', 'List Shares');
  static String get listExports => L10n.tr('列出导出', 'List Exports');
  static String get listingShares => L10n.tr('正在读取…', 'Loading…');
  static String get sharesHint => L10n.tr(
    '填好主机和账号（或打开访客）后，点“列出共享”直接选，不用手打。',
    'Enter host & credentials (or Guest), then tap "List Shares" to pick.',
  );
  static String get exportsHint => L10n.tr(
    '填好主机后，点“列出导出”直接选。',
    'Enter host, then tap "List Exports" to pick.',
  );
  static String get noShares =>
      L10n.tr('服务器没有返回可用的共享，请手动填写。', 'No shares returned; enter manually.');
  static String get sharesFailed =>
      L10n.tr('读取共享列表失败', 'Failed to list shares');
  static String get browseFolders => L10n.tr('浏览文件夹', 'Browse Folders');
  static String get browseTitle => L10n.tr('选择文件夹', 'Choose Folder');
  static String get browseRoot => L10n.tr('根目录', 'Root');
  static String get browseUp => L10n.tr('上一级', 'Up');
  static String get browseEmpty => L10n.tr('这里没有子文件夹', 'No subfolders here');
  static String get browseFailed => L10n.tr('读取文件夹失败', 'Failed to read folder');
  static String get browseUseThis => L10n.tr('选这个文件夹', 'Use This Folder');
  static String browseAudioCount(int n) => L10n.tr(
    n == 0 ? '这一层没有音乐文件' : '这一层有 $n 个音乐文件',
    n == 0 ? 'No audio files here' : '$n audio files here',
  );
  static String get browseNeedsHost => L10n.tr('先填好主机地址', 'Enter host first');
  static String get browseNeedsShare =>
      L10n.tr('先选好共享', 'Select a share first');
  static String get browseNeedsExport =>
      L10n.tr('先填好导出路径', 'Enter export path first');
  static String get browseNeedsUrl => L10n.tr('先填好地址', 'Enter URL first');
  static String get fieldUrl => L10n.tr('地址', 'URL');
  static String get fieldWebDavUrlHint => L10n.tr(
    '例如 https://nas.local:5006/music',
    'e.g. https://nas.local:5006/music',
  );
  static String get fieldServerUrlHint =>
      L10n.tr('例如 http://192.168.1.10:4533', 'e.g. http://192.168.1.10:4533');
  static String get fieldUsername => L10n.tr('用户名', 'Username');
  static String get fieldPassword => L10n.tr('密码', 'Password');
  static String get fieldApiKey => L10n.tr('API 密钥', 'API Key');
  static String get fieldApiKeyHint => L10n.tr(
    '在 Jellyfin 控制台 → API 密钥 中创建',
    'Create in Jellyfin Dashboard → API Keys',
  );
  static const fieldPlexToken = 'Plex Token';
  static String get fieldPlexTokenHint => L10n.tr(
    '在 Plex 网页版的媒体信息 → 查看 XML 中可以找到',
    'Found in Plex Web → Get Info → View XML',
  );
  static String get guest => L10n.tr('以访客身份连接', 'Connect as Guest');
  static String get guestHint =>
      L10n.tr('共享不需要账号密码时打开', 'Enable if the share requires no login');
  static String get showPassword => L10n.tr('显示密码', 'Show Password');
  static String get hidePassword => L10n.tr('隐藏密码', 'Hide Password');
  static String get credentialNotice => L10n.tr(
    '密码只交给 Lekis 核心保存，不会写进界面层的任何文件。',
    'Credentials are stored securely in the core, never in UI files.',
  );
  static String get credentialSavedNotice => L10n.tr(
    '密码已保存，不需要重新输入。需要修改时点“替换密码”。',
    'Password is saved. Click "Replace Password" to change it.',
  );
  static String get replacePassword => L10n.tr('替换密码', 'Replace Password');
  static String get keepPassword => L10n.tr('保留已保存的密码', 'Keep Saved Password');
  static String get newPassword => L10n.tr('新密码', 'New Password');

  // 校验
  static String get errHostRequired => L10n.tr('请填写主机地址', 'Host is required');
  static String get errHostInvalid =>
      L10n.tr('主机地址里不能有空格或斜杠', 'Host cannot contain spaces or slashes');
  static String get errShareRequired =>
      L10n.tr('请填写共享名', 'Share name is required');
  static String get errExportRequired =>
      L10n.tr('请填写导出路径', 'Export path is required');
  static String get errPortInvalid =>
      L10n.tr('端口需要是 1~65535 之间的数字', 'Port must be between 1 and 65535');
  static String get errPrivateKeyRequired =>
      L10n.tr('请粘贴私钥', 'Private key is required');
  static String get errPrivateKeyInvalid => L10n.tr(
    '这看起来不是私钥（应包含 PRIVATE KEY）',
    'Does not look like a private key (missing PRIVATE KEY)',
  );
  static String get errUrlRequired => L10n.tr('请填写地址', 'URL is required');
  static String get errUrlInvalid => L10n.tr(
    '地址需要以 http:// 或 https:// 开头',
    'URL must start with http:// or https://',
  );
  static String get errUsernameRequired =>
      L10n.tr('请填写用户名', 'Username is required');
  static String get errPasswordRequired =>
      L10n.tr('请填写密码', 'Password is required');
  static String get errApiKeyRequired =>
      L10n.tr('请填写 API 密钥', 'API key is required');
  static String get errTokenRequired =>
      L10n.tr('请填写 Token', 'Token is required');
  static String get errPathInvalid =>
      L10n.tr('路径里不能包含 ..', 'Path cannot contain ..');

  // 本地文件夹
  static String get pickFolder => L10n.tr('选择文件夹', 'Choose Folder');
  static String get pickingFolder =>
      L10n.tr('正在打开文件夹选择器…', 'Opening folder picker…');
  static String get folderPickFailed =>
      L10n.tr('无法打开文件夹选择器', 'Could not open folder picker');
  static String get audioPermissionDenied => L10n.tr(
    '需要“音乐和音频”权限才能读取本机音乐。请在系统设置里允许后再试。',
    'Audio permission is required to read local music. Enable it in System Settings.',
  );
  static String get androidContentUri => L10n.tr(
    '这个文件夹是通过系统存储框架选择的，Lekis 暂时还不能直接读取。请选择“内部存储”下的普通文件夹，例如 Music。',
    'Please choose a standard folder under Internal Storage (such as Music).',
  );
  static String get androidPermissionTitle =>
      L10n.tr('需要访问音乐文件', 'Audio Permission Needed');
  static String get androidPermissionBody => L10n.tr(
    'Lekis 需要“音乐和音频”权限才能读取这个文件夹。请在系统设置 → 应用 → Lekis → 权限 中允许，然后回来重新扫描。',
    'Allow Music & Audio permission in System Settings → Apps → Lekis → Permissions, then rescan.',
  );
  static String get ok => L10n.tr('知道了', 'OK');

  // 错误（按 CoreError.kind）
  static String get errNotFound =>
      L10n.tr('找不到对应的资源，请检查地址或路径', 'Resource not found; check address or path');
  static String get errInvalidArgument =>
      L10n.tr('填写的内容有误，请检查后再试', 'Invalid input; please review and try again');
  static String get errUnsupported =>
      L10n.tr('暂不支持这种音源', 'Unsupported source type');
  static String get errNotImplemented =>
      L10n.tr('这个功能还没做好', 'Not implemented yet');
  static String get errIo => L10n.tr('读写文件时出错', 'File I/O error');
  static String get errNetwork => L10n.tr(
    '连不上，请检查地址、端口和网络',
    'Connection failed; check host, port, and network',
  );
  static String get errAuth =>
      L10n.tr('用户名、密码或密钥不正确', 'Invalid username, password, or key');
  static String get errDatabase =>
      L10n.tr('资料库出错，请重启应用后再试', 'Database error; please restart Lekis');
  static String get errDecode =>
      L10n.tr('服务器返回了无法识别的内容', 'Unrecognized response from server');
  static String get errPlugin => L10n.tr('插件出错', 'Plugin error');
  static String get errPermissionDenied =>
      L10n.tr('没有访问权限', 'Permission denied');
  static String get errCancelled => L10n.tr('已取消', 'Cancelled');
  static String get errRateLimited =>
      L10n.tr('请求太频繁，请稍后再试', 'Rate limited; try again later');
  static String get errInternal =>
      L10n.tr('出现了意外错误', 'Unexpected internal error');
  static String get errUnknown => L10n.tr('操作失败', 'Operation failed');
}
