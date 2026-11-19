-- 播放会话（PLY：重启后接着听）。
--
-- 单行表：队列只保留本机 track.id，不跨设备同步。曲目被删除时，
-- 读取侧会把不存在的 ID 丢掉并修正游标（见 playback_state.rs）。

CREATE TABLE playback_state (
  id           INTEGER PRIMARY KEY CHECK (id = 1),
  queue_json   TEXT    NOT NULL,               -- JSON 数组：track.id，按播放顺序
  queue_index  INTEGER NOT NULL DEFAULT 0,     -- 当前曲目在队列里的下标
  position_ms  INTEGER NOT NULL DEFAULT 0,     -- 当前曲目进度
  shuffle      TEXT    NOT NULL DEFAULT 'off', -- off / random / smart
  repeat_mode  TEXT    NOT NULL DEFAULT 'off', -- off / all / one
  volume       REAL    NOT NULL DEFAULT 1.0,
  updated_at   INTEGER NOT NULL
);
