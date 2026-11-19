"""从 icon.webp 生成各平台的应用图标。

icon.webp 是 1024×1024、白底上的深蓝渐变圆角方块，中间是月兔。直接裁方块
做图标时月兔只占画面一半左右，Android 8+ 还会把旧式方形图标缩进一块白底
里，看起来就很小。所以这里不再整块裁切，而是拆成两层再按需要重新合成：

1. 背景：方块的底色是上下方向的平滑渐变，用每个通道对 y 的线性拟合还原，
   可以无缝外延到原图方块以外。
2. 主体：和背景拟合色差足够大的像素就是月兔，做成带羽化边的 alpha 抠图。

然后按「主体外接框边长 / 画布边长」这个占比（FILL）把主体放大摆正，再铺上
同一套渐变背景。各平台只是 FILL 和蒙版不同：

- Android 自适应图标（minSdk 26，启动器实际只用这个）：
  前景层 = 透明底的月兔，108dp 画布里占 FG_FILL；
  背景层 = drawable/ic_launcher_background.xml 的竖向渐变；
  单色层 = 月兔剪影（Android 13 主题图标）。
- Android 旧式 ic_launcher.png：圆角方块，LEGACY_FILL。
- Windows .ico：48px 及以上是圆角方块 + ICO_FILL；16/24/32 用更紧的
  ICO_SMALL_FILL 和更小的圆角，任务栏上才认得出是兔子。
- app/app_icon.png：1024 主图，和旧式图标同一套参数。

用法：python tools/make-icons.py
"""

from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "icon.webp"
APP = ROOT / "app"
RES = APP / "android/app/src/main/res"

# 源图里圆角方块的范围（白边之内）。
SQUARE = (128, 128, 896, 896)
# 拟合背景时取样的区域：方块左右两侧、避开圆角的竖条。
BG_SAMPLE_ROWS = range(300, 720)
BG_SAMPLE_COLS = list(range(150, 190, 4)) + list(range(840, 880, 4))
# 与背景的 RGB 距离超过它就算主体。
SUBJECT_THRESHOLD = 14

# 主体外接框（取宽高里较大的一边）占画布边长的比例。
FG_FILL = 0.64  # 自适应前景，108dp 画布；66dp 安全区直径 ≈ 0.61
LEGACY_FILL = 0.82  # 圆角方块：旧式 Android 图标、app_icon.png、大号 ico
ICO_SMALL_FILL = 0.94  # 16/24/32 px 的 ico
CORNER_RATIO = 0.22
SMALL_CORNER_RATIO = 0.16

ADAPTIVE_DP = 108
DENSITIES = {
    "mipmap-mdpi": 1.0,
    "mipmap-hdpi": 1.5,
    "mipmap-xhdpi": 2.0,
    "mipmap-xxhdpi": 3.0,
    "mipmap-xxxhdpi": 4.0,
}
LEGACY_DP = 48
WINDOWS_ICO_SIZES = [16, 24, 32, 48, 64, 128, 256]
WINDOWS_SMALL = {16, 24, 32}


class Source:
    """把源图拆成「渐变背景模型 + 月兔抠图」。"""

    def __init__(self, path: Path) -> None:
        rgb = Image.open(path).convert("RGB")
        im = np.asarray(rgb).astype(np.float64)

        ys, cols = [], []
        for y in BG_SAMPLE_ROWS:
            for x in BG_SAMPLE_COLS:
                ys.append(y)
                cols.append(im[y, x])
        ys = np.array(ys)
        cols = np.array(cols)
        # 线性拟合：残差 < 1 级灰度，外延到方块之外也不会跑偏。
        self.coef = [np.polyfit(ys, cols[:, c], 1) for c in range(3)]

        rows = self.bg_at(np.arange(im.shape[0]))
        dist = np.sqrt(((im - rows[:, None, :]) ** 2).sum(axis=2))
        inset = 20  # 方块自身的抗锯齿边不能算进主体
        x0, y0, x1, y1 = SQUARE
        keep_img = Image.new("L", rgb.size, 0)
        ImageDraw.Draw(keep_img).rounded_rectangle(
            (x0 + inset, y0 + inset, x1 - inset, y1 - inset),
            radius=int((x1 - x0) * CORNER_RATIO) - inset,
            fill=255,
        )
        keep = np.asarray(keep_img) > 0
        hard = Image.fromarray(((dist > SUBJECT_THRESHOLD) & keep).astype(np.uint8) * 255)
        # 开运算去噪点，再把封闭的洞（眼睛高光等不会，但以防万一）填上。
        hard = hard.filter(ImageFilter.MinFilter(3)).filter(ImageFilter.MaxFilter(3))
        hard = _fill_holes(hard)
        bbox = hard.getbbox()
        assert bbox, "在 icon.webp 里没找到主体"
        self.bbox = bbox
        # 外扩 1px 再羽化：边缘的抗锯齿像素本来就混着背景色，换上同色渐变后看不出接缝。
        soft = hard.filter(ImageFilter.MaxFilter(3)).filter(ImageFilter.GaussianBlur(1.2))
        self.subject = rgb.convert("RGBA")
        self.subject.putalpha(soft)
        self.silhouette = soft

    def bg_at(self, y: np.ndarray) -> np.ndarray:
        """源图坐标 y 处的背景色（可以超出原方块范围）。"""
        y = np.asarray(y, dtype=np.float64)
        return np.stack([np.polyval(self.coef[c], y) for c in range(3)], axis=-1)

    # ---- 合成 ----

    def _placement(self, size: int, fill: float) -> tuple[float, float, float]:
        """返回 (缩放, 主体中心 x, 主体中心 y)，都在源图坐标系。"""
        x0, y0, x1, y1 = self.bbox
        scale = fill * size / max(x1 - x0, y1 - y0)
        return scale, (x0 + x1) / 2, (y0 + y1) / 2

    def background(self, size: int, fill: float) -> Image.Image:
        scale, _, cy = self._placement(size, fill)
        ys = cy + (np.arange(size) + 0.5 - size / 2) / scale
        rows = np.clip(self.bg_at(ys), 0, 255).astype(np.uint8)
        arr = np.repeat(rows[:, None, :], size, axis=1)
        return Image.fromarray(arr, "RGB").convert("RGBA")

    def foreground(self, size: int, fill: float, layer: Image.Image | None = None) -> Image.Image:
        """把主体（或它的剪影）按占比缩放后放到透明画布正中。"""
        layer = layer or self.subject
        scale, cx, cy = self._placement(size, fill)
        # 先在 4 倍画布上摆好再缩，避免小尺寸发虚。
        big = size * 4
        s = scale * 4
        w, h = layer.size
        scaled = layer.resize((round(w * s), round(h * s)), Image.LANCZOS)
        out = Image.new(layer.mode, (big, big), 0)
        out.paste(scaled, (round(big / 2 - cx * s), round(big / 2 - cy * s)))
        return out.resize((size, size), Image.LANCZOS)

    def composite(self, size: int, fill: float) -> Image.Image:
        return Image.alpha_composite(self.background(size, fill), self.foreground(size, fill))

    def gradient_ends(self, fill: float) -> tuple[str, str]:
        """自适应背景层（108dp 画布）上下两端的颜色。"""
        size = 1000
        scale, _, cy = self._placement(size, fill)
        top, bottom = self.bg_at([cy - size / 2 / scale, cy + size / 2 / scale])
        return _hex(top), _hex(bottom)


def _fill_holes(mask: Image.Image) -> Image.Image:
    """从边角泛洪出外部背景，剩下的都算主体。"""
    w, h = mask.size
    padded = Image.new("L", (w + 2, h + 2), 0)
    padded.paste(mask, (1, 1))
    ImageDraw.floodfill(padded, (0, 0), 128)
    arr = np.asarray(padded)[1:-1, 1:-1]
    return Image.fromarray(np.where(arr == 128, 0, 255).astype(np.uint8))


def _hex(rgb) -> str:
    r, g, b = (int(round(min(255, max(0, v)))) for v in rgb)
    return f"#FF{r:02X}{g:02X}{b:02X}"


def rounded(image: Image.Image, radius_ratio: float) -> Image.Image:
    """给图片套圆角蒙版，超采样之后再缩，边缘才不毛。"""
    size = image.size[0]
    scale = 4
    mask = Image.new("L", (size * scale, size * scale), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        (0, 0, size * scale - 1, size * scale - 1),
        radius=int(size * radius_ratio * scale),
        fill=255,
    )
    mask = mask.resize((size, size), Image.LANCZOS)
    out = image.convert("RGBA")
    alpha = np.minimum(np.asarray(out.getchannel("A")), np.asarray(mask))
    out.putalpha(Image.fromarray(alpha))
    return out


def monochrome_layer(src: Source) -> Image.Image:
    """Android 13 主题图标：月兔剪影，系统会按壁纸配色给它上色。

    纯剪影是一团看不出是兔子，所以把剪影内部最暗的描线（眼睛、耳机、四肢
    分界）挖空，留出线稿细节；最外圈轮廓线不挖，免得剪影边缘镂成一圈细线。
    只看 alpha，颜色无所谓。
    """
    rgb = np.asarray(src.subject.convert("RGB")).astype(np.float64)
    lum = rgb @ np.array([0.299, 0.587, 0.114])
    sil = np.asarray(src.silhouette).astype(np.float64)
    # 亮度 < 30 的描线完全挖空，30..50 之间过渡。
    carve = 1 - np.clip((lum - 30) / 20, 0, 1)
    inner = np.asarray(src.silhouette.filter(ImageFilter.MinFilter(13))).astype(np.float64) / 255
    keep = 1 - carve * inner
    keep_img = Image.fromarray((keep * 255).astype(np.uint8)).filter(ImageFilter.GaussianBlur(0.8))
    alpha = sil * np.asarray(keep_img) / 255
    layer = Image.new("RGBA", src.subject.size, (255, 255, 255, 0))
    layer.putalpha(Image.fromarray(alpha.astype(np.uint8)))
    return layer


ADAPTIVE_XML = """<?xml version="1.0" encoding="utf-8"?>
<!-- 由 tools/make-icons.py 生成，别手改。 -->
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@drawable/ic_launcher_background"/>
    <foreground android:drawable="@mipmap/ic_launcher_foreground"/>
    <monochrome android:drawable="@mipmap/ic_launcher_monochrome"/>
</adaptive-icon>
"""

BACKGROUND_XML = """<?xml version="1.0" encoding="utf-8"?>
<!-- 由 tools/make-icons.py 生成，别手改：icon.webp 底色的竖向渐变（108dp 画布两端）。 -->
<shape xmlns:android="http://schemas.android.com/apk/res/android" android:shape="rectangle">
    <gradient
        android:angle="270"
        android:startColor="{top}"
        android:endColor="{bottom}"/>
</shape>
"""


def _write(path: Path, data) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if isinstance(data, Image.Image):
        data.save(path)
        print(f"{path.relative_to(ROOT)} {data.size[0]}x{data.size[1]}")
    else:
        path.write_text(data, encoding="utf-8", newline="\n")
        print(path.relative_to(ROOT))


def main() -> None:
    src = Source(SRC)
    x0, y0, x1, y1 = src.bbox
    print(f"subject bbox {src.bbox} ({x1 - x0}x{y1 - y0})")

    # ---- Android 自适应图标 ----
    mono = monochrome_layer(src)
    for folder, density in DENSITIES.items():
        size = round(ADAPTIVE_DP * density)
        _write(RES / folder / "ic_launcher_foreground.png", src.foreground(size, FG_FILL))
        _write(RES / folder / "ic_launcher_monochrome.png", src.foreground(size, FG_FILL, mono))
        legacy = round(LEGACY_DP * density)
        _write(RES / folder / "ic_launcher.png", rounded(src.composite(legacy, LEGACY_FILL), CORNER_RATIO))
    top, bottom = src.gradient_ends(FG_FILL)
    _write(RES / "drawable/ic_launcher_background.xml", BACKGROUND_XML.format(top=top, bottom=bottom))
    for name in ("ic_launcher", "ic_launcher_round"):
        _write(RES / "mipmap-anydpi-v26" / f"{name}.xml", ADAPTIVE_XML)

    # ---- 主图 ----
    _write(APP / "app_icon.png", rounded(src.composite(1024, LEGACY_FILL), CORNER_RATIO))

    # ---- Windows .ico：每个尺寸单独合成 ----
    frames = []
    for size in WINDOWS_ICO_SIZES:
        if size in WINDOWS_SMALL:
            frame = rounded(src.composite(size, ICO_SMALL_FILL), SMALL_CORNER_RATIO)
        else:
            frame = rounded(src.composite(size, LEGACY_FILL), CORNER_RATIO)
        frames.append(frame)
    ico = APP / "windows/runner/resources/app_icon.ico"
    ico.parent.mkdir(parents=True, exist_ok=True)
    frames[-1].save(
        ico,
        format="ICO",
        sizes=[(s, s) for s in WINDOWS_ICO_SIZES],
        append_images=frames[:-1],
    )
    print(f"{ico.relative_to(ROOT)} {WINDOWS_ICO_SIZES}")


if __name__ == "__main__":
    main()
