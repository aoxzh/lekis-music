"""Original demo catalogue for promo recordings and screenshots.

Everything here is fictional: the artists, albums, lyrics and cover art do not
refer to real recordings.  The lyrics are short original poems, not excerpts.
"""

from __future__ import annotations

from dataclasses import dataclass, field


@dataclass(frozen=True)
class Track:
    title: str
    duration: float
    bpm: int
    mood: str
    lyrics: tuple[str, ...] = field(default_factory=tuple)
    instrumental: bool = False


@dataclass(frozen=True)
class Album:
    slug: str
    title: str
    artist: str
    year: int
    genre: str
    accent: str
    mood: str
    tracks: tuple[Track, ...]


ALBUMS: tuple[Album, ...] = (
    Album(
        slug="starlit-reverie",
        title="Starlit Reverie",
        artist="Hoshimiya",
        year=2026,
        genre="Anime / Dream Pop",
        accent="#8f7bff",
        mood="starlit",
        tracks=(
            Track(
                title="Starlit Reverie",
                duration=210,
                bpm=86,
                mood="starlit",
                lyrics=(
                    "夜空にほどけた 銀色のリボン",
                    "星屑の海を すくう指先",
                    "遠い光が 名前を呼ぶ",
                    "まだ知らない 明日の向こう",
                    "まばたきのたび こぼれる願い",
                    "月の裏側で そっと重ねた",
                    "眠らない街 抜け出して",
                    "風のない丘で 君を待つ",
                    "星が降るなら この想いごと",
                    "白い軌跡に 変えてみせよう",
                    "消えそうな聲 繋いだ手のひら",
                    "同じ鼓動を 数えていた",
                    "朝が来るまで 夢をほどかないで",
                    "ガラスの宇宙で 二人きり",
                    "遠回りした 道の先で",
                    "君の名前を もう一度呼ぶ",
                    "星屑の川を 渡る舟は",
                    "小さな勇気で できている",
                    "夜明けの向こう 光が騒ぐ",
                    "この歌だけは 君に届け",
                ),
            ),
            Track(
                title="Paper Comet",
                duration=78,
                bpm=98,
                mood="starlit",
                lyrics=(
                    "紙でできた 彗星を折る",
                    "窓辺にそっと 浮かべた夜",
                    "届かないなら 届くまで走る",
                    "ちっぽけな尾を 引いて",
                    "星のない空も 悪くないね",
                    "君が笑えば 光になる",
                    "書きかけの 手紙をたたんで",
                    "明日の空へ 飛ばした",
                ),
            ),
            Track(
                title="Afterglow Letter",
                duration=72,
                bpm=78,
                mood="starlit",
                lyrics=(
                    "夕焼けの端に 文字を書く",
                    "消えてしまう前に 君へ",
                    "ありふれた言葉 並べても",
                    "足りない気がして 黙った",
                    "オレンジの風が ページをめくる",
                    "最後の一行は まだ白い",
                    "また会えるなら 笑ってほしい",
                    "それだけを 空に預ける",
                ),
            ),
        ),
    ),
    Album(
        slug="neon-tides",
        title="Neon Tides",
        artist="LUMEN",
        year=2026,
        genre="Anime / Synthwave",
        accent="#39e0e8",
        mood="neon",
        tracks=(
            Track(
                title="Neon Tides",
                duration=80,
                bpm=118,
                mood="neon",
                lyrics=(
                    "Neon tides are pulling me under",
                    "青い光の 波を越えて",
                    "Your voice is a signal in the rain",
                    "午前零時の 海へ",
                    "We are running out of gravity",
                    "落ちてく街を 見下ろして",
                    "Hold my hand until the morning comes",
                    "ネオンの潮に 溶けてゆく",
                ),
            ),
            Track(
                title="Midnight Arcade",
                duration=70,
                bpm=124,
                mood="neon",
                lyrics=(
                    "Insert a coin into the night",
                    "点滅する 迷路のなか",
                    "Every pixel feels alive",
                    "君のコイン 残り何枚",
                    "Game over is not the end",
                    "リセットして また笑う",
                    "Midnight arcade, don't close the lights",
                    "あと一回だけ 遊ばせて",
                ),
            ),
            Track(
                title="Signal Lost",
                duration=64,
                bpm=108,
                mood="neon",
                lyrics=(
                    "Signal lost at 3 a.m.",
                    "ノイズの向こう 君の声",
                    "I keep tuning through the static",
                    "届かない周波数",
                    "If the tower falls tonight",
                    "この街ごと 歌うから",
                    "Call me back before the dawn",
                    "消えないで まだ",
                ),
            ),
        ),
    ),
    Album(
        slug="paper-moon-diaries",
        title="Paper Moon Diaries",
        artist="Mizuki & The Paper Moons",
        year=2026,
        genre="Anime / Acoustic",
        accent="#d8b88a",
        mood="paper",
        tracks=(
            Track(
                title="Paper Moon",
                duration=75,
                bpm=76,
                mood="paper",
                lyrics=(
                    "紙で作った 月を灯す",
                    "雨の窓辺で ひとり",
                    "透ける光が 手のひらに",
                    "小さな星を 描いた",
                    "遠くの街で 君も今",
                    "同じ空を 見上げてる？",
                    "濡れたホームに 響く音",
                    "帰り道を 教えて",
                ),
            ),
            Track(
                title="Rainy Station",
                duration=68,
                bpm=72,
                mood="paper",
                lyrics=(
                    "雨の駅で 電車を待つ",
                    "傘の花が 咲いてる",
                    "行き先のない 切符を握り",
                    "君の面影 探した",
                    "ホームの端で 揺れる影",
                    "もう来ないと 知ってる",
                    "それでも今日は ここにいたい",
                    "雨が止むまで いい",
                ),
            ),
            Track(
                title="One More Spring",
                duration=62,
                bpm=80,
                mood="paper",
                lyrics=(
                    "Another spring without you here",
                    "桜の匂い 風に乗せ",
                    "I left the window open again",
                    "君の椅子を 拭いて",
                    "One more spring, one more song",
                    "歌えば また会えるかな",
                    "Petal by petal, I let it go",
                    "春よ ゆっくり 来て",
                ),
            ),
        ),
    ),
    Album(
        slug="ashes-of-summer",
        title="Ashes of Summer",
        artist="Yoru no Kakera",
        year=2026,
        genre="Anime / Alternative",
        accent="#ff8a5c",
        mood="summer",
        tracks=(
            Track(
                title="Ashes of Summer",
                duration=80,
                bpm=102,
                mood="summer",
                lyrics=(
                    "夏の終わりに 火を灯す",
                    "闇に浮かぶ オレンジの輪",
                    "はしゃいだ声が 遠くなる",
                    "汗ばむ背中 風が撫でる",
                    "灰になっても 残る熱",
                    "君の笑顔が 焼き付いてる",
                    "また来年も 会えるかな",
                    "答えのない 花火の音",
                ),
            ),
            Track(
                title="Fireworks, Again",
                duration=66,
                bpm=96,
                mood="summer",
                lyrics=(
                    "打ち上げ花火 二度目はない",
                    "そう言いながら また見上げた",
                    "一瞬だけの 光でも",
                    "永遠に近い 気がした",
                    "隣の君が 手を伸ばす",
                    "届かないね と笑う",
                    "夏が終わる 音がした",
                    "耳を塞いでも 聞こえる",
                ),
            ),
            Track(
                title="Last Train Home",
                duration=72,
                bpm=88,
                mood="summer",
                lyrics=(
                    "終電の窓 流れる街",
                    "眠る君の 肩に寄りかかり",
                    "このままずっと 行けたなら",
                    "終点なんて いらないのに",
                    "ガタゴト揺れる 夜の詩",
                    "君の寝息が リズムになる",
                    "降りる駅名 聞こえたけど",
                    "もう少しだけ 座ってたい",
                ),
            ),
        ),
    ),
    Album(
        slug="lunar-arcade",
        title="Lunar Arcade",
        artist="KAGURA",
        year=2026,
        genre="Anime / Chiptune",
        accent="#ff66c9",
        mood="arcade",
        tracks=(
            Track(
                title="Lunar Arcade",
                duration=74,
                bpm=128,
                mood="arcade",
                lyrics=(
                    "Welcome to the lunar arcade",
                    "重力のない ゲームセンター",
                    "Starlight on the joystick",
                    "月面の ネオンサイン",
                    "Jump, jump, don't look down",
                    "クレーターを 飛び越えて",
                    "One more life, one more dream",
                    "銀河の端で 遊ぼう",
                ),
            ),
            Track(
                title="Zero Gravity Love",
                duration=67,
                bpm=132,
                mood="arcade",
                lyrics=(
                    "Zero gravity love",
                    "宙返りする 心臓",
                    "Can't tell up from down",
                    "君の軌道に 捕まった",
                    "Spin me round and round",
                    "星の海で ダンス",
                    "Don't let me float away",
                    "この引力で 繋いで",
                ),
            ),
            Track(
                title="Pixel Heart",
                duration=60,
                bpm=120,
                mood="arcade",
                lyrics=(
                    "8-bit heart on the screen",
                    "点滅する 赤いハート",
                    "Press start to begin",
                    "君のステージへ",
                    "Even if the game resets",
                    "この気持ちは 残る",
                    "Save my heart, save my heart",
                    "ピクセルの 永遠",
                ),
            ),
        ),
    ),
    Album(
        slug="dawn-signal",
        title="Dawn Signal",
        artist="Aoi Kisaragi",
        year=2026,
        genre="Anime / Indie Pop",
        accent="#ffb48a",
        mood="dawn",
        tracks=(
            Track(
                title="Dawn Signal",
                duration=76,
                bpm=90,
                mood="dawn",
                lyrics=(
                    "夜明けの信号 青に変わる",
                    "眠たい街が 息をしてる",
                    "君のメッセージ 画面に浮かぶ",
                    "おはよう の三文字",
                    "昨日の涙は 海に返す",
                    "今日の空は 少しだけ広い",
                    "自転車を漕いで 坂を上る",
                    "光の向こうへ",
                ),
            ),
            Track(
                title="Blue Hour",
                duration=69,
                bpm=84,
                mood="dawn",
                lyrics=(
                    "青い時間 街を包む",
                    "昼でも夜でもない 隙間",
                    "君と歩いた 帰り道",
                    "今は一人でも 怖くない",
                    "遠くの灯が ひとつずつ",
                    "明日を 灯していく",
                    "急がなくても いいよね",
                    "この青を 覚えていたい",
                ),
            ),
            Track(
                title="Hello, Tomorrow",
                duration=65,
                bpm=92,
                mood="dawn",
                lyrics=(
                    "Hello, tomorrow, nice to meet you",
                    "知らない空に 手を振る",
                    "I don't know what you're bringing",
                    "それでも 歩き出す",
                    "小さな声で 歌いながら",
                    "靴紐を 結び直す",
                    "Hello, tomorrow, I'm ready",
                    "昨日の私に さよなら",
                ),
            ),
        ),
    ),
)


def catalog_stats() -> tuple[int, int, float]:
    tracks = [track for album in ALBUMS for track in album.tracks]
    return len(ALBUMS), len(tracks), sum(t.duration for t in tracks)
