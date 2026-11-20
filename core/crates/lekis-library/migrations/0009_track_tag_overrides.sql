-- 用户手工编辑的标签覆盖层（LIB-13）。
-- 和 overlay_json 分开：补全结果可以整体替换，手工编辑的标签字段要能独立保留。
ALTER TABLE track ADD COLUMN tag_overrides_json TEXT;
