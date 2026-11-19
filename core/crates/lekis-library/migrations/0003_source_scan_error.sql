-- 音源最近一次扫描的失败信息（UI 在音源列表里显示"上次扫描失败：……"）。
--
-- 语义：
-- - `last_scan_at`（0001 已有）：最近一次扫描**结束**的时间，不论成功还是失败；
-- - `last_scan_error_code`：失败时的稳定错误码（ErrorCode 的 snake_case），成功时清空；
-- - `last_scan_error`：失败时给开发者看的详情（不直接展示给用户），成功时清空。
--
-- 只存错误码和详情，不存凭据：详情来自 LekisError 的 message，各协议实现已经保证不带密码。

ALTER TABLE source ADD COLUMN last_scan_error_code TEXT;
ALTER TABLE source ADD COLUMN last_scan_error TEXT;
