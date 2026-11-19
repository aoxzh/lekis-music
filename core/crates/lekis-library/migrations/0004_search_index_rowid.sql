-- 搜索索引改用确定的 rowid（LIB-07 性能）。
--
-- search_index 是 fts5 虚表，kind / ref_id 是 UNINDEXED 列：`WHERE kind = ? AND ref_id = ?`
-- 每次都全表扫描，逐首入库变成 O(n²)（10 万首要几十分钟）。从这一版起每行的 rowid 固定为
--   ref_id * 4 + 类型码（track = 1，album = 2，artist = 3），
-- 删除和判断存在都按 rowid 走主键。这里把已有的行按新规则重新写一遍（顺便去掉重复行）。

CREATE TEMP TABLE _search_index_old AS
  SELECT kind, ref_id, title, subtitle, keys FROM search_index;

DELETE FROM search_index;

INSERT INTO search_index (rowid, kind, ref_id, title, subtitle, keys)
  SELECT ref_id * 4 + CASE kind WHEN 'track' THEN 1 WHEN 'album' THEN 2 ELSE 3 END,
         kind, ref_id, title, subtitle, keys
    FROM _search_index_old
   WHERE kind IN ('track', 'album', 'artist')
   GROUP BY kind, ref_id;

DROP TABLE _search_index_old;
