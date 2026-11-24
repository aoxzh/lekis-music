#!/usr/bin/env python3
"""Generate `core/crates/lekis-enrich/src/ruby_ja_data.rs`.

Readings come from the Unicode Unihan database (`Unihan_Readings.txt`,
field `kJapanese`). Unihan is published by the Unicode Consortium under
the Unicode License v3. Only the Japanese common-use kanji (jōyō, 2136
characters) plus a short list of frequent non-jōyō lyric kanji are kept.

Usage:
    python tools/gen-kanji-readings.py path/to/Unihan_Readings.txt

The output is deterministic; re-run it if the kanji list or Unihan data
changes and commit the regenerated file.
"""

import io
import sys

# jōyō kanji (2136), grouped by the Kanji Kentei levels used by the
# `kanji` crate (MIT). Kept inline so this script only needs Unihan.
JOYO = (
    "一七三上下中九二五人休先入八六円出力十千口右名四土夕大天女子字学小山川左年手文日早月木本村林校森正気水火犬玉王生田男町白"
    "百目石空立竹糸耳花草虫見貝赤足車金雨青音万丸交京今会体何作元兄光公内冬刀分切前北午半南原友古台合同回図国園地場声売夏外多"
    "夜太妹姉室家寺少岩工市帰広店弓引弟弱強当形後心思戸才教数新方明星春昼時晴曜書朝来東楽歌止歩母毎毛池汽活海点父牛理用画番直"
    "矢知社秋科答算米紙細組絵線羽考聞肉自船色茶行西親角言計記話語読谷買走近通週道遠里野長門間雪雲電頭顔風食首馬高魚鳥鳴麦黄黒"
    "丁世両主乗予事仕他代住使係倍全具写列助勉動勝化区医去反取受号向君味命和品員商問坂央始委守安定実客宮宿寒対局屋岸島州帳平幸"
    "度庫庭式役待急息悪悲想意感所打投拾持指放整旅族昔昭暑暗曲有服期板柱根植業様横橋次歯死氷決油波注泳洋流消深温港湖湯漢炭物球"
    "由申界畑病発登皮皿相県真着短研礼神祭福秒究章童笛第筆等箱級終緑練羊美習者育苦荷落葉薬血表詩調談豆負起路身転軽農返追送速進"
    "遊運部都配酒重鉄銀開院陽階集面題飲館駅鼻不争井付令以仲伝位低佐例便信倉候借健側働億兆児共兵典冷初別利刷副功加努労勇包卒協"
    "単博印参司各周唱器固城埼塩変夫失奈好媛季孫完官害富察岐岡崎巣差希席帯底府康建径徒徳必念愛成戦折挙改敗散料旗昨景最望未末札"
    "材束松果栃栄案梅梨械極標機欠残氏民求沖治法泣浅浴清満滋漁潟灯無然焼照熊熱牧特産的省祝票種積競笑管節約結給続縄置群老臣良芸"
    "芽英茨菜街衣要覚観訓試説課議貨賀軍輪辞辺連達選郡量録鏡関阜阪陸隊静順願類飛飯養香験鹿久仏仮件任似余価保修個停備像再刊判制"
    "則効務勢厚句可史告喜営因団囲圧在均型基堂報境墓増士夢妻婦容寄導居属布師常幹序弁張往得復志応快性情態慣技招授採接提損支政故"
    "救断旧易暴条枝査格桜検構武歴殺毒比永河液混減測準演潔災燃版犯状独率現留略益眼破確示祖禁移程税築粉精紀素経統絶綿総編績織罪"
    "義耕職肥能脈興舎航術衛製複規解設許証評講謝識護豊象財貧責貯貸費貿資賛賞質輸述迷逆造過適酸鉱銅防限険際雑非領額飼並乱乳亡仁"
    "供俳俵値傷優党冊処券刻割創劇勤危卵厳収后否吸呼善困垂域奏奮姿存孝宅宇宗宙宝宣密寸専射将尊就尺届展層己巻幕干幼庁座延律従忘"
    "忠恩憲我批承担拝拡捨探推揮操敬敵映晩暖暮朗机枚染株棒模権樹欲段沿泉洗派済源潮激灰熟片班異疑痛皇盛盟看砂磁私秘穀穴窓筋策簡"
    "糖系紅納純絹縦縮署翌聖肺胃背胸脳腸腹臓臨至舌若著蒸蔵蚕衆裁装裏補視覧討訪訳詞誌認誕誠誤論諸警貴賃退遺郵郷針銭鋼閉閣降陛除"
    "障難革頂預骨丈与丘丹乾互介仰伺依侵俗倒偉傍傾僧儀兼冒凡凶刈到刺剣剤劣勧匹占即却及叫召吐含吹咲唐嘆噴圏坊執堅堤塔壁壊壱奇奥"
    "奴妙姓威娘婚寂寝尋尽尾屈峠峰巡巨帽幅幾床弐弾彩影彼征御微徴忙怒怖恋恐恒恥恵悩惑惨慎慢慮憶戒戯扇払扱抗抜抱抵押拍拓拠振捕掘"
    "描握援搬摘撃攻敏敷斜旨旬是普暇暦曇更替朱朽杯枯柄柔桃欄歓歳殖殿汗汚沈沢沼況泊浜浮浸涙淡添渡溶滴漫澄濁濃為烈煙煮燥爆狂狩狭"
    "猛獣獲玄珍環甘畳疲療皆盆盗監盤盾眠瞬矛砲祈秀称稲稿突端箇範粒紋紫紹絡継維網緯縁繁繰罰翼耐肩肪胴脂脚脱腐腕腰膚致舗舞舟般芋"
    "芝茂荒菓蓄薄薪被襲触訴詰詳誇誉謡豪販賦贈越趣距跡跳踊踏躍軒較載輝輩込迎迫逃透途遅違遣避郎釈鈍鉛鋭鎖鑑闘陣陰隠隣隷雄雅雌離"
    "雷需震霧露響項頼飾駆騒驚髪鬼鮮麗黙鼓齢乏乙了企伏伐伴伸佳侍促倣倹偶催債克免冗冠凍凝刑削励勘募匠匿卑卓卸厘又双吉吏哀哲啓喚"
    "喫嘱坑埋塊塗墜墨墳墾壇奉契奪如妨姫娯婆婿嫁嬢孔孤宴審寿封尿岳峡崩巧帆帝幻幽廉廊弧彫徐忌怠怪恨悔悟悦惜愚慈慌慕慨慰憂憎憩房"
    "抑択抽拘掃掌排掛控措掲揚換揺携搾摂撮擁擦敢斗斤斥施既昇晶暫架某桑棄棋楼概欧欺殊殴没泌浪湾湿滅滑滝滞漂漏潜潤濫瀬炉炊炎焦牲"
    "犠猟獄甲畔畜疾痘癖硬碑礎祉稚穂穏穫窒符篤簿籍粋粗粘糧紛紺絞綱緊締緩縛縫繕翻聴肝胆胎胞脅膜膨芳苗菊華葬藩虐虚蛮衝衰袋裂裸覆"
    "訂託詠該誘請諮諾謀譲豚貫賊賢赦赴超軌軸辛辱逮遂遇遭遵邦邪郊郭酔酵鋳錠錬錯鍛鎮鐘閲阻陪陳陵陶隆随隔隻雇零霊顧飽餓駐騎髄魂魅"
    "魔鯨鶏且丙亜享亭仙伯但併侮侯俊俸倫偏偵偽傑傘僕僚儒償充准凸凹刃剖剛剰劾勅勲升厄叔叙吟呈呉唆唇唯喝喪嗣嚇囚坪垣培堀堕堪塀塁"
    "塑塚塾壌壮奔奨妃妄妊妥姻娠媒嫌嫡宜宰宵寛寡寧寮尉尚尼履屯岬崇帥幣庶庸廃廷弊弔弦彰循徹忍恭悠患悼惰愁愉慶憤憾懇懐懲懸戻扉扶"
    "抄把披抹拐拒拙括拷挑挟挿捜据搭摩撤撲擬斉斎旋昆暁曹朕朴杉析枠枢柳栓核栽桟棚棟棺槽款殉殻汁江沸泡泥泰洞津洪浄浦涯涼淑渇渉渋"
    "渓渦溝漆漠漬漸濯煩爵猫献猶猿珠琴璽瓶甚畝疎疫症痢痴癒盲眺睡督矯砕硝硫碁磨礁祥禅禍租秩稼窃窮窯竜筒粛粧糾紡索累紳緒繊繭缶罷"
    "羅翁耗肌肖肢肯臭舶艇艦茎荘菌薦薫藻虜虞蚊蛇蛍融衡衷裕褐褒襟覇訟診詐詔誓諭謁謄謙謹譜貞貢賄賓賜賠購践軟轄迅迭逐逓逝逸遍遮遷"
    "還邸酌酢酪酬酷醜醸釣鈴鉢銃銘閑閥附陥隅雰霜靴韻頑頒頻顕飢駄騰麻串丼乞亀伎侶俺傲僅冥冶凄刹剥勃勾匂叱呂呪咽哺唄唾喉喩嗅嘲堆"
    "塞填妖妬嫉宛尻崖嵐巾弄弥彙怨恣惧慄憧憬戚戴拉拭拳拶挨挫捉捗捻摯斑斬旦旺昧曖曽枕柵柿桁梗椅椎楷毀氾汎汰沃沙淫湧溺潰煎爪爽牙"
    "狙玩瑠璃璧瓦畏畿痕痩瘍眉睦瞭瞳稽窟箋箸籠綻緻罵羞羨肘股脇脊腎腫腺膝膳臆臼舷艶芯苛萎葛蓋蔑蔽藍藤虎虹蜂蜜袖裾訃詣詮誰諦諧謎"
    "貌貪貼賂賭踪蹴辣遜遡那酎醒采釜錦錮鍋鍵鎌闇隙韓頃須頓頬顎餅餌駒骸鬱鶴麓麺"
)

# Frequent non-jōyō kanji that show up in lyrics (names, poetry, scenery).
EXTRA = "咲唄嘘頬瞳雫凪蕾栞繋逢憧吻掠蘇呟囁瞼睫綺麗莉蘭蓮颯爽遥遼玲琉凛楓蛍蝶蜜緋燦煌澪湊隼葵柚杏珀翔辿眩溺歪噛呪妬嫉葛藤鍵硝罠頁"

OUT = r"core/crates/lekis-enrich/src/ruby_ja_data.rs"


def to_hiragana(text):
    return "".join(
        chr(ord(c) - 0x60) if "\u30a1" <= c <= "\u30f6" else c for c in text
    )


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: gen-kanji-readings.py path/to/Unihan_Readings.txt")
    wanted = set(JOYO + EXTRA)
    readings = {}
    with io.open(sys.argv[1], encoding="utf-8") as f:
        for line in f:
            if "\tkJapanese\t" not in line:
                continue
            code, _, value = line.rstrip("\n").split("\t", 2)
            ch = chr(int(code[2:], 16))
            if ch not in wanted:
                continue
            tokens = value.split()
            on = [to_hiragana(t) for t in tokens if "\u30a1" <= t[0] <= "\u30f6"]
            kun = [t for t in tokens if "\u3041" <= t[0] <= "\u3096"]
            if on or kun:
                readings[ch] = (" ".join(on[:3]), " ".join(kun))

    missing = sorted(wanted - set(readings))
    if missing:
        print("warning: no kJapanese readings for " + " ".join(missing), file=sys.stderr)

    lines = [
        "//! 日语汉字读音表（`@generated`，不要手改）。",
        "//!",
        "//! 数据来源：Unicode Unihan 数据库 `Unihan_Readings.txt` 的 `kJapanese`",
        "//! 字段，只保留日本常用汉字（jōyō）和少量歌词常见的非常用汉字。",
        "//! 音读已统一转成平假名，空格分隔多个读音。",
        "//!",
        "//! 版权 © Unicode, Inc.，按 Unicode License v3 发布（见 THIRD_PARTY_NOTICES.md）。",
        "//! 重新生成：`python tools/gen-kanji-readings.py path/to/Unihan_Readings.txt`。",
        "",
        "pub(crate) struct KanjiReadings {",
        "    pub ch: char,",
        "    pub on: &'static str,",
        "    pub kun: &'static str,",
        "}",
        "",
        "pub(crate) static KANJI_READINGS: &[KanjiReadings] = &[",
    ]
    for ch in sorted(readings):
        on, kun = readings[ch]
        lines.append(
            '    KanjiReadings { ch: %r, on: "%s", kun: "%s" },'
            % (ch, on, kun)
        )
    lines.append("];")
    lines.append("")
    io.open(OUT, "w", encoding="utf-8", newline="\n").write("\n".join(lines))
    print("wrote %s: %d entries, %d bytes" % (OUT, len(readings), len("\n".join(lines))))


if __name__ == "__main__":
    main()
