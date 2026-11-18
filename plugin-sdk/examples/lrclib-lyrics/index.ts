// LRCLIB 歌词插件示例：只实现了 `lyrics` 一个能力。
// 文档：https://lrclib.net/docs
import type { Host, LyricsParams, LyricsResult } from "@lekis/plugin-sdk";

declare const host: Host;

interface LrclibTrack {
  plainLyrics: string | null;
  syncedLyrics: string | null;
  duration: number;
}

export async function lyrics({ track }: LyricsParams): Promise<LyricsResult | null> {
  const res = await host.http.get("https://lrclib.net/api/get", {
    query: {
      track_name: track.title,
      artist_name: track.artists[0] ?? "",
      album_name: track.album,
      duration: track.durationMs ? Math.round(track.durationMs / 1000) : undefined,
    },
  });
  if (res.status === 404) return null;
  if (res.status !== 200) {
    host.log.warn("lrclib returned", res.status);
    return null;
  }

  const data = await res.json<LrclibTrack>();
  const preferSynced = host.setting<boolean>("preferSynced") ?? true;
  if (preferSynced && data.syncedLyrics) {
    return { format: "lrc", content: data.syncedLyrics, confidence: 0.9 };
  }
  if (data.plainLyrics) {
    return { format: "plain", content: data.plainLyrics, confidence: 0.8 };
  }
  return null;
}
