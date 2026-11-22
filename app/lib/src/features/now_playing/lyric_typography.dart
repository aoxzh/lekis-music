// 中日韩（CJK）歌词分语种字体回退：
//
// 含假名的日文行强制使用 `Locale('ja')` 与日文字体栈，避免「燃 / 忘 / 戻 / 直 / 海」
// 等日文汉字在中文系统下借用简中字形；纯汉字行强制走 `Locale('zh', 'CN')` 统一简中字体，
// 避免英文 Windows 上中文字形混拼。

import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:material_ui/material_ui.dart';

/// 根据歌词文本脚本推断语种（用于字形选择，不改变应用界面语言）。
Locale? detectLyricLocale(String text) {
  var hasCjk = false;
  for (final rune in text.runes) {
    // 平假名 / 片假名 / 半角片假名 → 日语
    if ((rune >= 0x3040 && rune <= 0x30FF) ||
        (rune >= 0x31F0 && rune <= 0x31FF) ||
        (rune >= 0xFF65 && rune <= 0xFF9F)) {
      return const Locale('ja');
    }
    // 谚文 → 韩语
    if ((rune >= 0xAC00 && rune <= 0xD7AF) ||
        (rune >= 0x1100 && rune <= 0x11FF) ||
        (rune >= 0x3130 && rune <= 0x318F)) {
      return const Locale('ko');
    }
    // 中日韩统一表意文字
    if ((rune >= 0x4E00 && rune <= 0x9FFF) ||
        (rune >= 0x3400 && rune <= 0x4DBF)) {
      hasCjk = true;
    }
  }
  return hasCjk ? const Locale('zh', 'CN') : null;
}

List<String> _fallbackFor(Locale locale) {
  final isWin = !kIsWeb && Platform.isWindows;
  final isApple = !kIsWeb && (Platform.isMacOS || Platform.isIOS);
  return switch (locale.languageCode) {
    'ja' =>
      isWin
          ? const ['Yu Gothic UI', 'Meiryo', 'MS PGothic', 'Noto Sans JP']
          : isApple
          ? const ['Hiragino Sans', 'YuGothic', 'Noto Sans JP']
          : const ['Noto Sans CJK JP', 'Noto Sans JP', 'Droid Sans Japanese'],
    'ko' =>
      isWin
          ? const ['Malgun Gothic', 'Noto Sans KR']
          : isApple
          ? const ['Apple SD Gothic Neo', 'Noto Sans KR']
          : const ['Noto Sans CJK KR', 'Noto Sans KR'],
    _ =>
      isWin
          ? const ['Microsoft YaHei UI', 'Microsoft YaHei', 'Noto Sans SC']
          : isApple
          ? const ['PingFang SC', 'Hiragino Sans GB', 'Noto Sans SC']
          : const ['Noto Sans CJK SC', 'Noto Sans SC', 'Source Han Sans CN'],
  };
}

/// 为单行歌词或翻译应用分语种的 `locale` 与 `fontFamilyFallback`。
TextStyle lyricTextStyleFor(String text, TextStyle base) {
  final locale = detectLyricLocale(text);
  if (locale == null) return base;
  final langFonts = _fallbackFor(locale);
  final existing = base.fontFamilyFallback;
  final merged = <String>[
    ...langFonts,
    if (existing != null)
      for (final f in existing)
        if (!langFonts.contains(f)) f,
  ];
  return base.copyWith(
    locale: locale,
    fontFamily: langFonts.first,
    fontFamilyFallback: merged,
  );
}
