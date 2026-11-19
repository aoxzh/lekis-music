// 音源页面的全部文案。先写死简体中文，之后换 i18n 时只改这一个文件。

abstract final class SourcesStrings {
  static const title = '音源';
  static const addSource = '添加音源';
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
  static const neverScanned = '本次启动后尚未扫描';
  static String lastScan(String when, int added, int updated, int removed) =>
      '$when 扫描完成：新增 $added，更新 $updated，移除 $removed';
  static const justNow = '刚刚';
  static String minutesAgo(int m) => '$m 分钟前';
  static String hoursAgo(int h) => '$h 小时前';
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

  // 添加流程
  static const chooseKind = '你的音乐放在哪里？';
  static const groupThisDevice = '这台设备';
  static const groupNetworkShare = '网络共享';
  static const groupMediaServer = '媒体服务器';
  static const discoveryTitle = '局域网里的设备';
  static const discoveryBody = '在同一网络里搜索 SMB、WebDAV 和 DLNA 设备。点一下结果就能预填表单。';
  static const scanLan = '扫描局域网';
  static const scanningLan = '正在扫描…';
  static const scanAgain = '重新扫描';
  static const discoveryScanningBody = '正在搜索 mDNS、WS-Discovery 和 DLNA，最多需要几秒。';
  static const discoveryEmpty = '没有发现设备。确认 NAS 已开机、和这台设备在同一网络，或手动填写地址。';
  static const discoveryError = '扫描失败';
  static const discoveryDlnaNote = 'DLNA 媒体服务器，可能提供 SMB 共享';
  static const discoveryPickHint = '点一下结果，继续填写账号和共享名';
  static String discoveryFoundCount(int n) => '发现 $n 台设备';
  static const viaMdns = 'mDNS';
  static const viaWsDiscovery = 'WS-Discovery';
  static const viaSsdp = 'DLNA / SSDP';
  static const kindDlna = 'DLNA';
  static const back = '返回';
  static const cancel = '取消';
  static const testAndSave = '连接并保存';
  static const saving = '正在连接…';
  static const saved = '已添加，正在扫描';
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

  // 校验
  static const errHostRequired = '请填写主机地址';
  static const errHostInvalid = '主机地址里不能有空格或斜杠';
  static const errShareRequired = '请填写共享名';
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
