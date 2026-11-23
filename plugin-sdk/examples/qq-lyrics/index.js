// Anonymous QQ Music search and plain LRC. No account or proxy is used.
function normalize(value) {
  return (value || '').normalize('NFKC').toLowerCase().replace(/[\s\p{P}\p{S}]+/gu, '');
}

export async function lyrics({ track }) {
  const artist = track.artists && track.artists[0];
  if (!track.title || !artist) return null;
  const search = await host.http.get('https://c.y.qq.com/soso/fcgi-bin/client_search_cp', {
    query: { w: `${track.title} ${artist}`, format: 'json', n: 10, p: 1, aggr: 1 },
    timeoutMs: 5000,
  });
  if (search.status !== 200) return null;
  const data = await search.json();
  if (data.code !== 0) return null;
  const songs = data.data?.song?.list || [];
  const match = songs.find(song =>
    normalize(song.songname) === normalize(track.title) &&
    (song.singer || []).some(singer => normalize(singer.name) === normalize(artist)) &&
    (!track.durationMs || !song.interval || Math.abs(track.durationMs / 1000 - song.interval) <= 5)
  );
  if (!match?.songmid) return null;
  const response = await host.http.get('https://c.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg', {
    query: { songmid: match.songmid, format: 'json', nobase64: 1 },
    headers: { Referer: 'https://y.qq.com/' }, timeoutMs: 5000,
  });
  if (response.status !== 200) return null;
  const result = await response.json();
  if (result.code !== 0 || typeof result.lyric !== 'string' || !result.lyric.trim()) return null;
  return { format: /\[\d+:\d{2}/.test(result.lyric) ? 'lrc' : 'plain', content: result.lyric, confidence: 0.9 };
}
