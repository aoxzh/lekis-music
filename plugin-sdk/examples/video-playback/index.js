// 视频播放：把音源曲目映射到官方视频页。
//
// 这是“视频播放”兼容层的参考实现：音源插件自己导出 video 时优先用音源的
// 结果；没有导出的老插件（例如当前的 B 站插件）由这里补上。只返回页面地址，
// 不解析视频流，也不绕过登录、地区或风控。

const bilibili = /^(BV[0-9A-Za-z]{10})(?:\|([1-9][0-9]*))?$/;

async function bilibiliPage(bvid, cid) {
  if (!cid) return 1;
  try {
    const response = await host.http.get(
      `https://api.bilibili.com/x/web-interface/view?bvid=${bvid}`,
    );
    const body = await response.json();
    for (const part of body?.data?.pages || []) {
      if (String(part?.cid) === cid && Number.isInteger(part?.page) && part.page > 0) {
        return part.page;
      }
    }
  } catch (_) {
    // A metadata failure should not block the default part.
  }
  return 1;
}

export async function video({ sourcePluginId, externalId }) {
  if (sourcePluginId === "dev.mygo.bilibili") {
    const match = bilibili.exec(String(externalId || ""));
    if (!match) throw new Error("Unsupported Bilibili track ID");
    const page = await bilibiliPage(match[1], match[2]);
    return {
      url: `https://player.bilibili.com/player.html?bvid=${match[1]}&p=${page}`,
      title: "Bilibili",
    };
  }
  if (/youtube/i.test(String(sourcePluginId || ""))) {
    const id = String(externalId || "").split("|")[0];
    if (!id) throw new Error("Unsupported YouTube track ID");
    return {
      url: `https://www.youtube.com/watch?v=${encodeURIComponent(id)}`,
      title: "YouTube",
    };
  }
  throw new Error("Unsupported source");
}
