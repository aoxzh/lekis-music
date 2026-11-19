-- 服务器源曲目的唯一性约束（SRC-04~06）。
--
-- 0001 里 track_file 的主键是 (track_id, source_id, file_id, external_id)，其中 file_id 对服务器源
-- 为 NULL；SQLite 的行主键表在唯一约束里遇到 NULL 时不认为两行相等，所以同一个 external_id
-- 反复同步会插入重复行。这里补一个只覆盖服务器行的部分唯一索引，让"一个源里的一个外部 ID
-- 只对应一行"由数据库保证。

-- 先清掉可能已经存在的重复行（保留质量分最高的那行，同分保留最小 rowid）。
DELETE FROM track_file
 WHERE external_id IS NOT NULL
   AND rowid NOT IN (
     SELECT MIN(rowid) FROM track_file
      WHERE external_id IS NOT NULL
      GROUP BY track_id, source_id, external_id
   );

CREATE UNIQUE INDEX idx_track_file_remote
    ON track_file(track_id, source_id, external_id)
 WHERE external_id IS NOT NULL;
