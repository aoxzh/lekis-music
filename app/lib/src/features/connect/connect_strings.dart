// 「在其他设备上播放」（Lekis Connect）的界面文案。

abstract final class ConnectStrings {
  static const title = '在其他设备上播放';

  // 本机
  static const thisDevice = '这台设备';
  static const listening = '正在监听，局域网里的设备可以连过来';
  static const notListening = '没有在监听';
  static const portLabel = '端口';
  static const renamed = '改个名字';
  static const renameTitle = '这台设备叫什么';
  static const renameHint = '别的设备上会显示这个名字';
  static const allowControl = '允许其他设备控制这台设备';
  static const allowControlHint = '关掉后会停止广播，并断开已经连上的设备';
  static const controlledBy = '正在被控制';
  static const incomingPairing = '配对请求';
  static const incomingPairingBody = '在下面这台设备上输入这个配对码：';
  static const pairingCode = '配对码';
  static const close = '关闭';
  static const paired = '已配对';

  // 设备
  static const nearby = '局域网里的设备';
  static const nearbyHint = '两台设备都要打开 Lekis，并且连同一个网络';
  static const noDevices = '还没发现设备。可以先在另一台设备上打开 Lekis，或者按地址添加。';
  static const searching = '正在查找…';
  static const pair = '配对';
  static const connect = '连接';
  static const disconnect = '断开';
  static const forget = '忘记';
  static const connected = '已连接';
  static const offline = '不在线';
  static const playHere = '在这台设备上播放';
  static const remote = '遥控';
  static const addByAddress = '按地址添加';
  static const addByAddressHint = '组播被路由器挡住时，用手动填 IP 和端口';
  static const host = '地址';
  static const hostHint = '例如 192.168.1.20';
  static const port = '端口';
  static const add = '添加';
  static const cancel = '取消';

  // 配对（控制端）
  static const pairTitle = '在这台设备上配对';
  static const pairBody = '对方屏幕上会显示一个 6 位配对码，输进来就完成配对：';
  static const pairCodeLabel = '配对码';
  static const pairConfirm = '完成配对';
  static const pairRetry = '配对码不对，再试一次';
  static const pairFailed = '配对失败';

  // 转移
  static const transferTitle = '在这台设备上播放';
  static const transferBody = '把当前的队列和进度交给它，本机暂停。';
  static const nothingPlaying = '现在没有在播放的歌';
  static const transferDone = '已经在另一台设备上播放';
  static const transferPartial = '部分曲目对方拿不到，已跳过';
  static const transferFailed = '转移失败';
  static const noDevicesToPlay = '还没有配对好的设备';

  static const devices = '设备';
}
