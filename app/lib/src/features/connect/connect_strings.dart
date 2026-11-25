// 「在其他设备上播放」（Lekis Connect）的界面文案（中英双语）。

import '../../l10n/app_l10n.dart';
import '../../rust/api/dto.dart' show MediaViaDto;

abstract final class ConnectStrings {
  static String get title => L10n.tr('在其他设备上播放', 'Play on Other Devices');

  // 本机
  static String get thisDevice => L10n.tr('这台设备', 'This Device');
  static String get listening => L10n.tr(
    '正在监听，局域网里的设备可以连过来',
    'Listening — devices on your LAN can connect',
  );
  static String get notListening => L10n.tr('没有在监听', 'Not listening');
  static String get portLabel => L10n.tr('端口', 'Port');
  static String get renamed => L10n.tr('改个名字', 'Rename');
  static String get renameTitle => L10n.tr('这台设备叫什么', 'Device Name');
  static String get renameHint =>
      L10n.tr('别的设备上会显示这个名字', 'Shown on other devices');
  static String get allowControl =>
      L10n.tr('允许其他设备控制这台设备', 'Allow Remote Control');
  static String get allowControlHint => L10n.tr(
    '关掉后会停止广播，并断开已经连上的设备',
    'Turning off stops discovery and disconnects active remotes',
  );
  static String get controlledBy => L10n.tr('正在被控制', 'Controlled Remotely');
  static String get incomingPairing => L10n.tr('配对请求', 'Pairing Request');
  static String get incomingPairingBody =>
      L10n.tr('在下面这台设备上输入这个配对码：', 'Enter this pairing code on the other device:');
  static String get pairingCode => L10n.tr('配对码', 'Pairing Code');
  static String get close => L10n.tr('关闭', 'Close');
  static String get paired => L10n.tr('已配对', 'Paired');

  // 设备
  static String get nearby => L10n.tr('局域网里的设备', 'Devices on LAN');
  static String get nearbyHint => L10n.tr(
    '两台设备都要打开 Lekis，并且连同一个网络',
    'Open Lekis on both devices on the same network',
  );
  static String get noDevices => L10n.tr(
    '还没发现设备。可以先在另一台设备上打开 Lekis，或者按地址添加。',
    'No devices found yet. Open Lekis on another device or add by IP address.',
  );
  static String get searching => L10n.tr('正在查找…', 'Searching…');
  static String get pair => L10n.tr('配对', 'Pair');
  static String get connect => L10n.tr('连接', 'Connect');
  static String get disconnect => L10n.tr('断开', 'Disconnect');
  static String get forget => L10n.tr('忘记', 'Forget');
  static String get connected => L10n.tr('已连接', 'Connected');
  static String get offline => L10n.tr('不在线', 'Offline');
  static String get playHere => L10n.tr('在这台设备上播放', 'Play on This Device');
  static String get remote => L10n.tr('遥控', 'Remote');
  static String get addByAddress => L10n.tr('按地址添加', 'Add by Address');
  static String get addByAddressHint => L10n.tr(
    '组播被路由器挡住时，用手动填 IP 和端口',
    'Enter IP and port manually if multicast is blocked',
  );
  static String get host => L10n.tr('地址', 'Host');
  static String get hostHint => L10n.tr('例如 192.168.1.20', 'e.g. 192.168.1.20');
  static String get port => L10n.tr('端口', 'Port');
  static String get add => L10n.tr('添加', 'Add');
  static String get cancel => L10n.tr('取消', 'Cancel');

  // 配对（控制端）
  static String get pairTitle => L10n.tr('在这台设备上配对', 'Pair Device');
  static String get pairBody => L10n.tr(
    '对方屏幕上会显示一个 6 位配对码，输进来就完成配对：',
    'Enter the 6-digit pairing code shown on the other device:',
  );
  static String get pairCodeLabel => L10n.tr('配对码', 'Pairing Code');
  static String get pairConfirm => L10n.tr('完成配对', 'Pair');
  static String get pairRetry => L10n.tr('配对码不对，再试一次', 'Wrong code, try again');
  static String get pairFailed => L10n.tr('配对失败', 'Pairing failed');
  static String get unreachable => L10n.tr(
    '连不上这台设备：请在它上面打开 Lekis（手机要在前台或正在播放），并确认两台设备在同一个网络',
    'Unable to reach device: keep Lekis open on the same network',
  );

  // 转移
  static String get transferTitle => L10n.tr('在这台设备上播放', 'Transfer Playback');
  static String get transferBody => L10n.tr(
    '把当前的队列和进度交给它，本机暂停。',
    'Hand off the current queue and position, pausing here.',
  );
  static String get nothingPlaying => L10n.tr('现在没有在播放的歌', 'Nothing playing');
  static String get transferDone =>
      L10n.tr('已经在另一台设备上播放', 'Playing on the other device');
  static String get transferPartial =>
      L10n.tr('部分曲目对方拿不到，已跳过', 'Some tracks were unavailable and skipped');
  static String get transferFailed => L10n.tr('转移失败', 'Transfer failed');
  static String get noDevicesToPlay =>
      L10n.tr('还没有配对好的设备', 'No paired devices yet');

  static String get devices => L10n.tr('设备', 'Devices');

  // 设备选择 / 遥控
  static String get pickerTooltip => L10n.tr('在其他设备上播放', 'Play on Other Devices');
  static String get pickerTitle => L10n.tr('在哪台设备上播放', 'Choose Playback Device');
  static String get pickerHint => L10n.tr(
    '点一台设备，把现在的播放交给它；点右边的遥控按钮只控制它，不转移。',
    'Tap a device to transfer playback, or tap Remote to control it without transferring.',
  );
  static String get pickerEmpty => L10n.tr(
    '局域网里还没发现别的 Lekis。在另一台设备上打开 Lekis（同一个网络），它就会出现在这里。',
    'No other Lekis devices found on your LAN yet.',
  );
  static String get thisDeviceNow =>
      L10n.tr('正在这台设备上播放', 'Playing on This Device');
  static String get backToThisDevice =>
      L10n.tr('回到这台设备', 'Switch Back Here');
  static String get controlOnly => L10n.tr('遥控', 'Remote');
  static String get notPaired => L10n.tr('未配对', 'Not paired');
  static String get playingOn => L10n.tr('正在播放于', 'Playing on');
  static String get nothingOnRemote =>
      L10n.tr('那台设备现在没有在播放', 'Nothing playing on that device');
  static String get upNext => L10n.tr('接下来', 'Up Next');
  static String get volume => L10n.tr('音量', 'Volume');
  static String get stopControlling => L10n.tr('停止遥控', 'Stop Controlling');
  static String get remoteOffline =>
      L10n.tr('和那台设备的连接断开了', 'Disconnected from remote device');
  static String playingOnDevice(String name) =>
      L10n.tr('正在 $name 上播放', 'Playing on $name');
  static String viaLabel(MediaViaDto via) => switch (via) {
    MediaViaDto.library_ => L10n.tr('来自它自己的资料库', 'From its own library'),
    MediaViaDto.sameSource => L10n.tr('来自同一个音源', 'From shared source'),
    MediaViaDto.stream => L10n.tr('由本机局域网串流', 'Streamed over LAN'),
  };

  // Chromecast / DLNA 投放
  static String get castSectionTitle =>
      L10n.tr('Chromecast / DLNA 音箱', 'Chromecast & DLNA Speakers');
  static String get castRefresh => L10n.tr('重新扫描投放设备', 'Scan cast devices');
  static String get castScanning =>
      L10n.tr('正在搜索局域网内的 Chromecast 与 DLNA 设备…', 'Scanning LAN for Chromecast & DLNA devices…');
  static String get castEmpty => L10n.tr(
    '未发现 Chromecast 或 DLNA 音箱/功放，请确认在同一局域网内并点右上角刷新。',
    'No Chromecast or DLNA speakers found on your LAN. Tap refresh to scan again.',
  );
  static String get castChromecast => 'Chromecast';
  static String get castDlna => 'DLNA / UPnP';
  static String castActiveOn(String name) =>
      L10n.tr('正在投放到 $name', 'Casting to $name');
  static String get castStop => L10n.tr('停止投放', 'Stop Casting');
  static String get castNothingPlaying =>
      L10n.tr('请先选择一首歌曲开始播放，再投放到音箱', 'Start playing a track before casting');
  static String get castFailed => L10n.tr('投放失败', 'Casting failed');
}
