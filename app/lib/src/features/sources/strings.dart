// 音源页面的全部文案。先写死简体中文，之后换 i18n 时只改这一个文件。

abstract final class SourcesStrings {
  static const title = '音源';
  static const addSource = '添加音源';
  static const editSource = '编辑音源';
  static const emptyTitle = '还没有音源';
  static const emptyBody = '添加一个本地文件夹、NAS 共享或媒体服务器，Lekis 会自动整理你的音乐。';
  static const loadFailed = '读取音源列表失败';
  static const retry = '重试';
  static const selectHint = '选择左侧的音源查看详情，或添加一个新的音源。';

  // 状态
  static const reachable = '在线';
  static const unreachable = '无法连接';
  static const reachabilityUnknown = '未检测';
  static const disabled = '已停用';
  static const neverScanned = '尚未扫描';
  static String lastScanOk(String when) => '$when 扫描完成';
  static String lastScanFailed(String when, String why) => '$when 扫描失败：$why';
  static String lastScan(String when, int added, int updated, int removed) =>
      '$when 扫描完成：新增 $added，更新 $updated，移除 $removed';
  static const justNow = '刚刚';
  static String minutesAgo(int m) => '$m 分钟前';
  static String hoursAgo(int h) => '$h 小时前';
  static String daysAgo(int d) => '$d 天前';
  static const scanStarting = '准备扫描…';
  static String scanCount(int done, int? total) =>
      total == null ? '已处理 $done' : '$done / $total';
  static const phaseWalking = '正在查找文件';
  static const phaseReadingTags = '正在读取标签';
  static const phaseArtwork = '正在处理封面';
  static const phaseWritingSharedIndex = '正在写入共享索引';
  static const rescan = '重新扫描';
  static const syncNow = '立即同步';
  static String syncDone(int pushed, int pulled, int applied) =>
      '同步完成：推送 $pushed，拉取 $pulled，应用 $applied';
  static const scanStarted = '已开始扫描';

  // 详情
  static const detailKind = '类型';
  static const detailAddress = '地址';
  static const detailPath = '路径';
  static const detailStatus = '状态';
  static const detailLastScan = '上次扫描';
  static const detailCredential = '密码';
  static const detailUsername = '用户名';
  static const credentialSaved = '已保存';
  static const credentialNotSet = '未保存';
  static const credentialGuest = '访客连接，无需密码';
  static const credentialAnonymous = '匿名访问，无需密码';

  // 详情页操作
  static const testConnection = '测试连接';
  static const testing = '正在测试…';
  static const testSuccess = '连接成功';
  static const edit = '编辑';
  static const deleteSource = '删除音源';
  static const deleteTitle = '删除这个音源？';
  static String deleteBody(String name) =>
      '“$name”和它的曲目索引会被删除，已保存的密码也会一并清掉。这个操作不能撤销。';
  static const delete = '删除';
  static const deleted = '音源已删除';
  static const deletedCredentialLeft = '音源已删除，但凭据没能清理干净';

  // 类型
  static const kindLocal = '本地文件夹';
  static const kindSmb = 'SMB 共享';
  static const kindWebDav = 'WebDAV';
  static const kindNfs = 'NFS';
  static const kindSftp = 'SFTP';
  static const kindOpenSubsonic = 'Navidrome / OpenSubsonic';
  static const kindJellyfin = 'Jellyfin';
  static const kindEmby = 'Emby';
  static const kindPlex = 'Plex';
  static const kindRadio = '网络电台';
  static const kindPlugin = '插件';

  static const kindLocalHint = '这台设备上的音乐文件夹';
  static const kindSmbHint = 'Windows 共享、群晖 / 威联通等 NAS';
  static const kindWebDavHint = 'NAS、网盘或任何 WebDAV 服务';
  static const kindOpenSubsonicHint = 'Navidrome、Gonic、Airsonic 等';
  static const kindJellyfinHint = '用 API 密钥连接 Jellyfin 服务器';
  static const kindPlexHint = '用 Plex Token 连接';
  static const kindNfsHint = 'Linux NAS、群晖 / TrueNAS 的 NFS 导出';
  static const kindSftpHint = '通过 SSH 访问 NAS 或服务器上的文件夹';

  // 添加流程
  static const chooseKind = '你的音乐放在哪里？';
  static const chooseKindBody = '大多数人从这台设备上的音乐文件夹开始。以后随时可以再添加 NAS 或媒体服务器。';
  static const recommended = '推荐';
  static const kindLocalFeaturedHint = '选一个放音乐的文件夹，Lekis 会扫描里面所有的子文件夹';
  static const groupThisDevice = '这台设备';
  static const groupNetwork = '网络上的音乐库';
  static const groupNetworkBody =
      '家里的 NAS、电脑共享或 Navidrome / Jellyfin / Plex 服务器，需要地址和账号。';
  static const groupNetworkShare = '网络共享';
  static const groupMediaServer = '媒体服务器';
  static const localFormBody = '选一个放音乐的文件夹，Lekis 会扫描里面所有的子文件夹并自动整理。';
  static const addAndScan = '添加并扫描';
  static const adding = '正在添加…';
  static const moreOptions = '更多选项';
  static const moreOptionsHint = '备用地址等，不改也能正常使用';
  static const fieldAlternates = '备用地址（可选）';
  static const fieldAlternatesHint = '每行一个，例如 Tailscale 或外网地址';
  static const fieldAlternatesHelper = '主地址连不上时按顺序尝试';
  static const detailAlternate = '备用地址';
  static const discoveryTitle = '在你的网络上发现';
  static const discoveryBody = '在同一网络里搜索 SMB、WebDAV 和 DLNA 设备。点一下结果就能预填表单。';
  static const discoveryNothingYet = '没有发现设备。也可以在下面手动添加。';
  static const scanLan = '扫描局域网';
  static const scanningLan = '正在扫描…';
  static const scanAgain = '重新扫描';
  static const discoveryScanningBody = '正在搜索 mDNS、WS-Discovery 和 DLNA，最多需要几秒。';
  static const discoveryEmpty = '没有发现设备。确认 NAS 已开机、和这台设备在同一网络，或手动填写地址。';
  static const discoveryError = '扫描失败';
  static const discoveryDlnaNote = 'DLNA 媒体服务器，可能提供 SMB 共享';
  static const discoveryPickHint = '点一下结果，填好账号就能选共享';
  static String discoveryFoundCount(int n) => '发现 $n 台设备';
  static const viaMdns = 'mDNS';
  static const viaWsDiscovery = 'WS-Discovery';
  static const viaSsdp = 'DLNA / SSDP';
  static const kindDlna = 'DLNA';
  static const back = '返回';
  static const cancel = '取消';
  static const testAndSave = '连接并保存';
  static const saveChanges = '保存修改';
  static const saving = '正在连接…';
  static const savingChanges = '正在保存…';
  static const saved = '已添加，正在扫描';
  static const savedChanges = '已保存';
  static const savedButScanFailed = '音源已保存，但第一次扫描没能开始';

  // 表单
  static const fieldName = '名称';
  static const fieldNameHint = '留空则自动命名';
  static const fieldHost = '主机';
  static const fieldHostHint = '例如 192.168.1.10 或 nas.local';
  static const fieldShare = '共享名';
  static const fieldShareHint = '例如 music';
  static const fieldPath = '子文件夹（可选）';
  static const fieldPathHint = '例如 FLAC/古典';
  static const fieldExport = '导出路径';
  static const fieldExportHint = '例如 /volume1/music';
  static const fieldNfsHostHint = '例如 192.168.1.10（需要 NFSv3）';
  static const nfsNotice = 'NFS 以匿名方式连接，需要在 NAS 的 NFS 权限里允许这台设备的 IP。';
  static const fieldPort = '端口（可选）';
  static const fieldPortHint = '22';
  static const fieldSftpPath = '文件夹（可选）';
  static const fieldSftpPathHint = '例如 volume1/music，留空为根目录';
  static const authPassword = '密码';
  static const authKey = '私钥';
  static const fieldPrivateKey = '私钥';
  static const fieldPrivateKeyHint = '粘贴 OpenSSH 格式的私钥全文，支持 Ed25519 / ECDSA';
  static const fieldKeyPassphrase = '私钥密码（可选）';
  static const newPrivateKey = '新私钥';
  static const keySavedNotice = '私钥已保存，不需要重新粘贴。需要修改时点“替换私钥”。';
  static const replaceKey = '替换私钥';
  static const keepKey = '保留已保存的私钥';

  // 共享列表 / 文件夹浏览
  static const listShares = '列出共享';
  static const listExports = '列出导出';
  static const listingShares = '正在读取…';
  static const sharesHint = '填好主机和账号（或打开访客）后，点“列出共享”直接选，不用手打。';
  static const exportsHint = '填好主机后，点“列出导出”直接选。';
  static const noShares = '服务器没有返回可用的共享，请手动填写。';
  static const sharesFailed = '读取共享列表失败';
  static const browseFolders = '浏览文件夹';
  static const browseTitle = '选择文件夹';
  static const browseRoot = '根目录';
  static const browseUp = '上一级';
  static const browseEmpty = '这里没有子文件夹';
  static const browseFailed = '读取文件夹失败';
  static const browseUseThis = '选这个文件夹';
  static String browseAudioCount(int n) =>
      n == 0 ? '这一层没有音乐文件' : '这一层有 $n 个音乐文件';
  static const browseNeedsHost = '先填好主机地址';
  static const browseNeedsShare = '先选好共享';
  static const browseNeedsExport = '先填好导出路径';
  static const browseNeedsUrl = '先填好地址';
  static const fieldUrl = '地址';
  static const fieldWebDavUrlHint = '例如 https://nas.local:5006/music';
  static const fieldServerUrlHint = '例如 http://192.168.1.10:4533';
  static const fieldUsername = '用户名';
  static const fieldPassword = '密码';
  static const fieldApiKey = 'API 密钥';
  static const fieldApiKeyHint = '在 Jellyfin 控制台 → API 密钥 中创建';
  static const fieldPlexToken = 'Plex Token';
  static const fieldPlexTokenHint = '在 Plex 网页版的媒体信息 → 查看 XML 中可以找到';
  static const guest = '以访客身份连接';
  static const guestHint = '共享不需要账号密码时打开';
  static const showPassword = '显示密码';
  static const hidePassword = '隐藏密码';
  static const credentialNotice = '密码只交给 Lekis 核心保存，不会写进界面层的任何文件。';
  static const credentialSavedNotice = '密码已保存，不需要重新输入。需要修改时点“替换密码”。';
  static const replacePassword = '替换密码';
  static const keepPassword = '保留已保存的密码';
  static const newPassword = '新密码';

  // 校验
  static const errHostRequired = '请填写主机地址';
  static const errHostInvalid = '主机地址里不能有空格或斜杠';
  static const errShareRequired = '请填写共享名';
  static const errExportRequired = '请填写导出路径';
  static const errPortInvalid = '端口需要是 1~65535 之间的数字';
  static const errPrivateKeyRequired = '请粘贴私钥';
  static const errPrivateKeyInvalid = '这看起来不是私钥（应包含 PRIVATE KEY）';
  static const errUrlRequired = '请填写地址';
  static const errUrlInvalid = '地址需要以 http:// 或 https:// 开头';
  static const errUsernameRequired = '请填写用户名';
  static const errPasswordRequired = '请填写密码';
  static const errApiKeyRequired = '请填写 API 密钥';
  static const errTokenRequired = '请填写 Token';
  static const errPathInvalid = '路径里不能包含 ..';

  // 本地文件夹
  static const pickFolder = '选择文件夹';
  static const pickingFolder = '正在打开文件夹选择器…';
  static const folderPickFailed = '无法打开文件夹选择器';
  static const audioPermissionDenied = '需要“音乐和音频”权限才能读取本机音乐。请在系统设置里允许后再试。';
  static const androidContentUri =
      '这个文件夹是通过系统存储框架选择的，Lekis 暂时还不能直接读取。请选择“内部存储”下的普通文件夹，例如 Music。';
  static const androidPermissionTitle = '需要访问音乐文件';
  static const androidPermissionBody =
      'Lekis 需要“音乐和音频”权限才能读取这个文件夹。请在系统设置 → 应用 → Lekis → 权限 中允许，然后回来重新扫描。';
  static const ok = '知道了';

  // 错误（按 CoreError.kind）
  static const errNotFound = '找不到对应的资源，请检查地址或路径';
  static const errInvalidArgument = '填写的内容有误，请检查后再试';
  static const errUnsupported = '暂不支持这种音源';
  static const errNotImplemented = '这个功能还没做好';
  static const errIo = '读写文件时出错';
  static const errNetwork = '连不上，请检查地址、端口和网络';
  static const errAuth = '用户名、密码或密钥不正确';
  static const errDatabase = '资料库出错，请重启应用后再试';
  static const errDecode = '服务器返回了无法识别的内容';
  static const errPlugin = '插件出错';
  static const errPermissionDenied = '没有访问权限';
  static const errCancelled = '已取消';
  static const errRateLimited = '请求太频繁，请稍后再试';
  static const errInternal = '出现了意外错误';
  static const errUnknown = '操作失败';
}
