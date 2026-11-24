// Anonymous QQ Music search and plain LRC. No account or proxy is used.
export { lyrics };

function normalize(value) {
  return (value || '').normalize('NFKC').toLowerCase().replace(/[\s\p{P}\p{S}]+/gu, '');
}

function captionText(value) {
  return (value || '').normalize('NFKC').trim().toLowerCase().replace(/\s+/g, ' ');
}

function captionIdentity(track) {
  if (!Number.isFinite(track.durationMs) || track.durationMs <= 0) return null;
  const caption = track.title.normalize('NFKC').trim();
  const theme = /^《[^《》「」]{1,80}》\s*(?:OP|ED)(?:主题曲|主題曲)?\s*「([^「」《》]{1,100})」\s*([^【】《》「」|]{1,80}?)(?:\s*【Hi-Res百万级录音棚试听】)?$/i.exec(caption);
  const hires = /^【Hi-Res(?:·?无损(?:音质)?)】\s*\|?\s*《([^《》]{1,100})》\s*-\s*([^《》【】|]{1,80}?)\s*-\s*$/i.exec(caption);
  const video = /^【官方MV】\s*([^【】|]{1,80}?)\s+-\s+([^【】|]{1,100})$/i.exec(caption);
  const pair = theme || hires;
  if (pair) return { title: pair[1].trim(), artist: pair[2].trim() };
  if (video) return { title: video[2].trim(), artist: video[1].trim() };
  return null;
}

function matchesCaption(song, identity, durationMs) {
  if (captionText(song.songname) !== captionText(identity.title) ||
      !(song.interval > 0) || Math.abs(durationMs / 1000 - song.interval) > 5) return false;
  return (song.singer || []).some(singer => {
    const name = captionText(singer.name);
    const artist = captionText(identity.artist);
    if (name === artist) return true;
    const alias = /^([a-z0-9][a-z0-9 .'-]*) \(([\u3040-\u30ffー・]+)\)$/.exec(name);
    return alias !== null && alias[1] === artist;
  });
}

async function lyrics({ track }) {
  const artist = track.artists && track.artists[0];
  if (!track.title || !artist) return null;
  const identity = captionIdentity(track);
  const search = await host.http.get('https://c.y.qq.com/soso/fcgi-bin/client_search_cp', {
    query: { w: identity ? `${identity.title} ${identity.artist}` : `${track.title} ${artist}`, format: 'json', n: 10, p: 1, aggr: 1 },
    timeoutMs: 5000,
  });
  if (search.status !== 200) return null;
  const data = await search.json();
  if (data.code !== 0) return null;
  const songs = data.data?.song?.list || [];
  const match = songs.find(song => identity ? matchesCaption(song, identity, track.durationMs) :
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
