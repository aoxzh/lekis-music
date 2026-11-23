// Independently maps MyGO README shapes to Lekis source API shapes.
(() => {
  "use strict";
  const source = globalThis.__mygo_exports, out = {};
  const unsupported = text => { throw new PluginError("unsupported", text); };
  const picture = url => typeof url === "string" ? url.replace(/\{size\}|%7Bsize%7D/gi, "600") : undefined;
  const artists = list => (list || []).map(a => typeof a === "string" ? a : a.name).filter(Boolean);
  const track = t => ({ id: String(t.id), title: t.name || t.title || "", artists: artists(t.artists), album: t.album?.name, durationMs: t.duration, artworkUrl: picture(t.imageUrl || t.album?.imageUrl), requiresSignIn: t.requiresSignIn });
  const album = a => ({ id: String(a.id), title: a.name || a.title || "", artists: artists(a.artists), artworkUrl: picture(a.imageUrl), year: a.year });
  const artist = a => ({ id: String(a.id), name: a.name || "", imageUrl: picture(a.imageUrl) });
  const playlist = p => ({ id: String(p.id), title: p.name || p.title || "", description: p.description, artworkUrl: picture(p.imageUrl), tracks: (p.tracks || []).map(track) });
  if (typeof source.search === "function") out.search = async p => {
    const plural = { track: "tracks", album: "albums", artist: "artists", playlist: "playlists" }[p.type || "track"];
    if (!plural) unsupported("This MyGO search category is not supported");
    const offset = p.cursor === undefined ? 0 : Number(p.cursor);
    if (!Number.isSafeInteger(offset) || offset < 0) throw new PluginError("setup", "Invalid MyGO search cursor");
    const result = await source.search({ query: p.query, kind: plural, offset });
    const items = (result?.[plural] || []).map({ tracks: track, albums: album, artists: artist, playlists: playlist }[plural]);
    return { items, next: result?.more && items.length ? String(offset + items.length) : undefined };
  };
  if (typeof source.stream === "function") out.stream = async p => {
    const result = await source.stream({ id: p.id, quality: p.quality === "lossless" ? "lossless" : p.quality === "high" ? "high" : "standard" });
    if (!result?.url) throw new PluginError("unavailable", "MyGO source returned no stream URL");
    return { url: result.url, headers: result.headers, expiresAt: result.expiresAt, mimeType: { mp3: "audio/mpeg", flac: "audio/flac", ogg: "audio/ogg", wav: "audio/wav", m4a: "audio/mp4", aac: "audio/aac" }[result.type] };
  };
  if (typeof source.lyrics === "function") out.lyrics = async p => {
    const id = p.id || p.track?.id;
    if (!id) unsupported("MyGO lyrics requires a source track ID");
    const result = await source.lyrics({ id });
    const rows = [];
    let wordTimed = false;
    const validTime = ms => Number.isSafeInteger(ms) && ms >= 0 && ms < 60000000;
    const stamp = ms => `${String(Math.floor(ms / 60000)).padStart(2, "0")}:${String(Math.floor(ms / 1000) % 60).padStart(2, "0")}.${String(ms % 1000).padStart(3, "0")}`;
    const text = value => typeof value === "string" ? value.replace(/[\r\n]+/g, " ") : "";
    for (const line of Array.isArray(result?.lines) ? result.lines : []) {
      if (!validTime(line?.start)) continue;
      const words = Array.isArray(line.words) ? line.words : [];
      const joined = words.map(w => text(w?.text)).join("");
      let body = text(line.text) || joined;
      if (!body.trim()) continue;
      if (words.length && joined === body && words.every((w, i) =>
        validTime(w?.start) && w.start >= (i ? words[i - 1].start : line.start))) {
        body = words.map(w => `<${stamp(w.start)}>${text(w.text)}`).join("");
        wordTimed = true;
      }
      const prefix = `[${stamp(line.start)}]`;
      rows.push(prefix + body);
      if (text(line.translation).trim()) rows.push(prefix + text(line.translation));
    }
    // Structured lyrics can originate from video subtitles. Let the listener
    // preview them before replacing another version for the same recording.
    if (rows.length) return {format: wordTimed ? "enhanced_lrc" : "lrc", content: rows.join("\n"), confidence: 0.8};
    if (typeof result?.lrc !== "string" || !result.lrc.trim()) unsupported("MyGO source returned no lyrics");
    const translation = typeof result.translation === "string" ? result.translation.trim() : "";
    return {format: "lrc", content: translation ? `${result.lrc}\n${translation}` : result.lrc};
  };
  if (typeof source.album === "function") out.album = async p => { const value = await source.album({id:p.id}); return {...album(value.album), tracks:(value.tracks || []).map(track)}; };
  if (typeof source.artist === "function") out.artist = async p => { const value = await source.artist({id:p.id}); return {...artist(value.artist), tracks:(value.tracks || []).map(track), albums:(value.albums || []).map(album)}; };
  if (typeof source.playlist === "function") out.playlist = async p => playlist(await source.playlist({id:p.id}));
  const folder = (prefix, item) => ({kind:"folder",id:`${prefix}:${item.id}`,title:item.name || item.title || "",artworkUrl:picture(item.imageUrl),subtitle:item.description});
  const entries = value => {
    const items = [];
    for (const section of value.sections || [value]) {
      items.push(...(section.tracks || []).map(t => ({kind:"track",...track(t)})));
      for (const type of ["album","artist","playlist"]) items.push(...(section[type + "s"] || []).map(item => folder(type,item)));
      items.push(...(section.links || []).map(link => ({kind:"folder",id:`page:${link.page}`,title:link.title || "",subtitle:link.subtitle,artworkUrl:picture(link.imageUrl)})));
      if (section.morePage) items.push({kind:"folder",id:`page:${section.morePage}`,title:section.title || "More"});
    }
    return items;
  };
  if (["home","browse","album","artist","playlist"].some(name => typeof source[name] === "function")) out.browse = async p => {
    if (p.cursor) unsupported("MyGO browse cursor is not supported by this public contract");
    const path = p.path || "";
    let value;
    if (!path) {
      if (typeof source.home !== "function") unsupported("MyGO source does not export home");
      value = await source.home();
    } else {
      const colon = path.indexOf(":"), type = path.slice(0,colon), id = path.slice(colon+1);
      if (type === "page") {
        if (typeof source.browse !== "function") unsupported("MyGO source does not export browse");
        value = await source.browse({page:id});
      } else if (["album","artist","playlist"].includes(type)) {
        if (typeof source[type] !== "function") unsupported(`MyGO source does not export ${type}`);
        value = await source[type]({id});
      } else unsupported("Unknown MyGO browse path");
    }
    return {items:entries(value || {})};
  };
  return out;
})();
