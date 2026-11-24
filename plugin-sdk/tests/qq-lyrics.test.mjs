import assert from 'node:assert/strict';
import { afterEach, test } from 'node:test';
import { lyrics } from '../examples/qq-lyrics/index.js';

const theme = '《葬送的芙莉莲》OP主题曲「勇者」YOASOBI【Hi-Res百万级录音棚试听】';
const hires = '【𝐇𝐢-𝐑𝐞𝐬无损音质】｜《The Spectre(渐入佳境)》-  RZZRKT -';
const song = (songname, artist, interval, songmid = 'match') => ({
  songname, singer: [{ name: artist }], interval, songmid,
});

async function lookup(title, artist, durationMs, rows) {
  const calls = [];
  globalThis.host = { http: { async get(url, options) {
    assert.equal(new URL(url).hostname, 'c.y.qq.com');
    calls.push(options.query);
    const payload = calls.length === 1
      ? { code: 0, data: { song: { list: rows } } }
      : { code: 0, lyric: '[00:01.00]fixture' };
    return { status: 200, json: async () => payload };
  } } };
  const result = await lyrics({ track: { title, artists: [artist], durationMs } });
  return { result, calls };
}

afterEach(() => { delete globalThis.host; });

test('anime theme uses the quoted song and credited artist, and only reads the matching recording', async () => {
  const { result, calls } = await lookup(theme, 'video uploader', 196000, [
    song('勇者 (Live)', 'YOASOBI', 194, 'live'),
    song('勇者', 'YOASOBI Cover Band', 194, 'cover'),
    song('勇者', 'YOASOBI (feat. Guest)', 194, 'collaboration'),
    song('勇者', 'YOASOBI (ヨアソビ)', 0, 'unknown-duration'),
    song('勇者', 'YOASOBI (ヨアソビ)', 194),
  ]);
  assert.equal(calls[0].w, '勇者 YOASOBI');
  assert.deepEqual(calls.map(call => call.songmid), [undefined, 'match']);
  assert.equal(result.format, 'lrc');
});

test('stylized Hi-Res caption preserves the parenthetical song title', async () => {
  const { result, calls } = await lookup(hires, 'video uploader', 204000, [
    song('The Spectre', 'RZZRKT', 203, 'other-title'),
    song('The Spectre(渐入佳境)', 'RZZRKT', 203),
  ]);
  assert.equal(calls[0].w, 'The Spectre(渐入佳境) RZZRKT');
  assert.equal(calls[1].songmid, 'match');
  assert.ok(result);
});

test('official MV with a long intro cannot borrow the album recording', async () => {
  const { result, calls } = await lookup('【官方MV】ZAYN - Let Me', 'Sundayman', 250000, [
    song('Let Me', 'ZAYN', 185), song('Let Me', 'ZAYN', 189),
  ]);
  assert.equal(calls[0].w, 'Let Me ZAYN');
  assert.equal(calls.length, 1);
  assert.equal(result, null);
});

test('title suffixes, punctuation and the duration boundary remain significant', async () => {
  const title = '【Hi-Res无损音质】｜《Kiss my soul》 - Viik潘唯奇 -';
  const { result, calls } = await lookup(title, 'uploader', 139000, [
    song('Kiss My Soul (I want you kiss kiss)', 'Viik潘唯奇', 138),
    song('Kiss My Soul!', 'Viik潘唯奇', 138),
    song('Kiss My Soul', 'Viik潘唯奇', 145),
  ]);
  assert.equal(result, null);
  assert.equal(calls.length, 1);
});

test('ambiguous commentary, unqualified uploads and missing duration keep the original query', async () => {
  for (const [title, duration] of [
    ['安溥anpu的新歌《你怎么想》写得太好了～', 222000],
    ['安溥 - 你怎麼想 （acoustic cover）附吉他譜', 263000],
    ['《电影》OP主题曲「A」「B」Artist', 120000],
    [theme, 0],
  ]) {
    const { result, calls } = await lookup(title, 'uploader', duration, [
      song('你怎么想', '安溥', 222), song('勇者', 'YOASOBI', 194),
    ]);
    assert.equal(calls[0].w, `${title} uploader`);
    assert.equal(calls.length, 1);
    assert.equal(result, null);
  }
});

test('ordinary tagged music retains the existing exact lookup with optional duration', async () => {
  const { result, calls } = await lookup('晴天', '周杰伦', 0, [song('晴天', '周杰伦', 0)]);
  assert.equal(calls[0].w, '晴天 周杰伦');
  assert.equal(result.content, '[00:01.00]fixture');
});
