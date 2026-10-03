#!/usr/bin/env python3
"""生成地球场景程序化贴图（阶段外默认贴图改文明式模拟贴图、背景改白色丝绸幕布）。

产物（numpy 生成 + 手写 PNG 编码，无外部素材、确定性种子）：
- assets/textures/earth/stylized_map.png  5400×2700 风格化地图：
  海洋去饱和蓝 + 近岸浅水渐进 + 海岸描线；陆地按纬度生物群系着色（热带雨林深绿 →
  稀树草原 → 荒漠土黄 → 温带绿 → 针叶灰绿 → 苔原灰绿 → 极地淡冰），噪声扰动带界，
  手工圈定大沙漠/雨林区覆色；俄罗斯呈灰绿而非雪白（用户核心诉求）。
- assets/textures/earth/silk_backdrop.png  1024×512 白色丝绸幕布：暖白底 + 竖向
  垂褶明暗 + 斜向光泽 + 细颗粒，低对比不与球体争抢。

用法：python3 tools/make_earth_assets.py
"""

import json
import math
import os
import struct
import zlib

import numpy as np

MAP_W, MAP_H = 5400, 2700
SILK_W, SILK_H = 1024, 512
EARTH_RADIUS_KM = 6371.0


def write_png(path: str, arr: np.ndarray) -> None:
    """最小 PNG 编码：8 位 RGB、无隔行、filter 0。"""
    h, w, _ = arr.shape
    raw = b"".join(b"\x00" + arr[y].tobytes() for y in range(h))

    def chunk(tag: bytes, data: bytes) -> bytes:
        body = tag + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)

    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(raw, 6))
    png += chunk(b"IEND", b"")
    with open(path, "wb") as f:
        f.write(png)
    print(f"{path}: {os.path.getsize(path) / 1024:.0f} KB ({w}x{h})")


def value_noise(w: int, h: int, cell: int, seed: int) -> np.ndarray:
    """双线性值噪声（单倍频），返回 (h, w) 浮点 0~1。"""
    rng = np.random.default_rng(seed)
    gw, gh = int(w / cell) + 2, int(h / cell) + 2
    grid = rng.random((gh, gw))
    ys = np.linspace(0.0, gh - 1.0001, h)
    xs = np.linspace(0.0, gw - 1.0001, w)
    y0 = ys.astype(np.int64)
    x0 = xs.astype(np.int64)
    fy = (ys - y0)[:, None]
    fx = (xs - x0)[None, :]
    g00 = grid[np.ix_(y0, x0)]
    g01 = grid[np.ix_(y0, x0 + 1)]
    g10 = grid[np.ix_(y0 + 1, x0)]
    g11 = grid[np.ix_(y0 + 1, x0 + 1)]
    return g00 * (1 - fy) * (1 - fx) + g01 * (1 - fy) * fx + g10 * fy * (1 - fx) + g11 * fy * fx


def fractal_noise(w: int, h: int, seed: int) -> np.ndarray:
    """三倍频分形噪声，0~1。"""
    n = (
        value_noise(w, h, 512, seed) * 0.5
        + value_noise(w, h, 128, seed + 1) * 0.3
        + value_noise(w, h, 32, seed + 2) * 0.2
    )
    return n / n.max()


def dilate(mask: np.ndarray, iterations: int) -> np.ndarray:
    """4 邻域二值膨胀（水平方向回绕，贴图经向无缝）。"""
    for _ in range(iterations):
        mask = mask | np.roll(mask, 1, 0) | np.roll(mask, -1, 0) | np.roll(mask, 1, 1) | np.roll(mask, -1, 1)
    return mask


def load_rings():
    here = os.path.dirname(os.path.abspath(__file__))
    root = os.path.dirname(here)
    src = os.path.join(root, "assets", "data", "countries.json")
    with open(src, encoding="utf-8") as f:
        data = json.load(f)
    polygons = []
    for country in data["countries"]:
        for poly in country["rings"]:
            polygons.append(poly[0])  # 只取外环（国界即海岸，内环暂无大湖数据）
    return polygons, root


def rasterize(polygons, w: int, h: int) -> np.ndarray:
    """经纬多边形 → 偶奇扫描线栅格化（经度回绕：跨 ±180 的环自动在两侧填充）。"""
    edges = []
    for ring in polygons:
        n = len(ring)
        for i in range(n):
            lon1, lat1 = ring[i]
            lon2, lat2 = ring[(i + 1) % n]
            x1 = (lon1 + 180.0) / 360.0 * w
            x2 = (lon2 + 180.0) / 360.0 * w
            y1 = (90.0 - lat1) / 180.0 * h
            y2 = (90.0 - lat2) / 180.0 * h
            if y1 == y2:
                continue
            edges.append((x1, y1, x2, y2))
    buckets = [[] for _ in range(h)]
    for idx, (x1, y1, x2, y2) in enumerate(edges):
        # 扫描线约定：边在 y ∈ [ymin, ymax) 上激活（sample = 行中心）。
        # 多包一行会对边端点外插出假交点，表现为整图横向条纹伪影
        ymin, ymax = int(math.ceil(min(y1, y2) - 0.5)), int(math.ceil(max(y1, y2) - 0.5))
        for yy in range(max(0, ymin), min(h, ymax)):
            buckets[yy].append(idx)
    mask = np.zeros((h, w), dtype=bool)
    ex1 = np.array([e[0] for e in edges])
    ey1 = np.array([e[1] for e in edges])
    ex2 = np.array([e[2] for e in edges])
    ey2 = np.array([e[3] for e in edges])
    for y in range(h):
        sample = y + 0.5
        idxs = buckets[y]
        if not idxs:
            continue
        i = np.array(idxs)
        t = (sample - ey1[i]) / (ey2[i] - ey1[i])
        xs = ex1[i] + t * (ex2[i] - ex1[i])
        xs.sort()
        row = mask[y]
        for k in range(0, len(xs) - 1, 2):
            a, b = int(math.ceil(xs[k])), int(math.ceil(xs[k + 1]))
            # 经度回绕：跨边界的 span 两侧都填
            row[a % w : b % w if b % w else w] = True
            if a < 0:
                row[max(0, a + w) :] = True
            if b > w:
                row[: b - w] = True
    return mask


def box_blur(mask: np.ndarray, radius: int) -> np.ndarray:
    """可分离盒式模糊（cumsum 实现，边缘按实际窗口归一化），用于把覆色区羽化成软过渡。"""
    m = mask.astype(np.float32)
    for axis in (0, 1):
        d = m.shape[axis]
        cs = np.cumsum(m, axis=axis)
        zeros_shape = list(cs.shape)
        zeros_shape[axis] = 1
        cs = np.concatenate([np.zeros(zeros_shape, dtype=np.float32), cs], axis=axis)
        idx = np.arange(d)
        hi = np.minimum(idx + radius + 1, d)
        lo = np.maximum(idx - radius, 0)
        window = (hi - lo).astype(np.float32)
        shape = [1, 1]
        shape[axis] = d
        m = (np.take(cs, hi, axis=axis) - np.take(cs, lo, axis=axis)) / window.reshape(shape)
    return m


# 手工圈定的荒漠/雨林/冰盖覆色区（rough 多边形，模糊羽化后自然过渡）
DESERTS = [
    [(-17, 21), (-10, 29), (10, 32), (30, 31), (35, 24), (33, 16), (20, 14), (0, 13), (-12, 15)],  # 撒哈拉
    [(35, 13), (43, 13), (50, 17), (56, 22), (55, 28), (47, 30), (40, 28), (35, 22)],  # 阿拉伯
    [(12, -22), (19, -28), (24, -26), (26, -18), (20, -16)],  # 卡拉哈里/纳米布
    [(114, -24), (122, -18), (135, -12), (142, -14), (146, -20), (141, -30), (132, -32), (120, -33)],  # 澳洲内陆
    [(76, 41), (84, 43), (92, 45), (101, 45), (108, 43), (114, 44), (117, 41), (111, 39), (103, 38), (95, 37), (87, 38), (80, 38)],  # 戈壁/塔克拉玛干
    [(53, 39), (58, 42), (63, 45), (68, 47), (72, 45), (74, 42), (70, 39), (63, 37), (57, 36)],  # 中亚（卡拉库姆/克孜勒库姆）
    [(-118, 32), (-108, 30), (-102, 26), (-105, 20), (-112, 24), (-117, 28)],  # 美国西南/墨西哥北部
    [(69, 25), (72, 28), (75, 27), (74, 24), (71, 22)],  # 塔尔
    [(-70, -18), (-68, -24), (-70, -28), (-72, -22)],  # 阿塔卡马
]
RAINFORESTS = [
    [(-75, 4), (-60, 3), (-50, -3), (-52, -12), (-65, -12), (-74, -6)],  # 亚马孙
    [(9, 2), (24, 3), (29, -2), (26, -8), (16, -10), (10, -4)],  # 刚果
    [(95, 2), (105, 4), (118, 2), (130, -2), (140, -4), (150, -8), (140, -10), (125, -9), (110, -8), (98, -2)],  # 马来群岛
    [(-92, 16), (-84, 14), (-78, 8), (-80, 6), (-88, 12)],  # 中美
]
GREENLAND_ICE = [(-60, 76), (-45, 83), (-25, 82), (-20, 75), (-30, 68), (-45, 66), (-55, 70)]

# 纬度生物群系色阶锚点：|纬度| → (r, g, b)，0~1
BIOME_ANCHORS = [
    (0, (0.29, 0.47, 0.24)),
    (10, (0.36, 0.52, 0.27)),
    (20, (0.55, 0.58, 0.34)),
    (30, (0.63, 0.58, 0.42)),
    (40, (0.47, 0.55, 0.34)),
    (50, (0.42, 0.50, 0.33)),
    (60, (0.36, 0.44, 0.34)),
    (70, (0.55, 0.56, 0.50)),
    (78, (0.80, 0.81, 0.80)),
    (90, (0.88, 0.90, 0.90)),
]
OCEAN_EQUATOR = np.array([0.27, 0.44, 0.62])
OCEAN_POLE = np.array([0.22, 0.38, 0.55])
OCEAN_SHALLOW = np.array([0.60, 0.72, 0.80])
DESERT_COLOR = np.array([0.84, 0.76, 0.54])
RAINFOREST_COLOR = np.array([0.24, 0.44, 0.22])
ICE_COLOR = np.array([0.88, 0.90, 0.89])


def biome_color(abs_lat: np.ndarray) -> np.ndarray:
    """纬度 → 生物群系色（线性插值锚点）。abs_lat (H,W)。"""
    lats = np.array([a[0] for a in BIOME_ANCHORS])
    cols = np.array([a[1] for a in BIOME_ANCHORS])
    out = np.empty((abs_lat.shape[0], abs_lat.shape[1], 3))
    for c in range(3):
        out[..., c] = np.interp(abs_lat, lats, cols[:, c])
    return out


def ring_area_deg2(ring) -> float:
    """环的平面面积（度²），微小岛礁识别用。"""
    total = 0.0
    n = len(ring)
    for i in range(n):
        x1, y1 = ring[i]
        x2, y2 = ring[(i + 1) % n]
        total += x1 * y2 - x2 * y1
    return abs(total) / 2.0


def build_map(root: str) -> None:
    polygons, _ = load_rings()
    w, h = MAP_W, MAP_H
    print("栅格化陆地…")
    # 微小岛礁（南海诸岛等，环面积 < 0.05 度²）点化处理：不参与浅水环与海岸
    # 描线（会被放大成方块群），最后画成自然小圆点
    land = np.zeros((h, w), dtype=bool)
    islets = np.zeros((h, w), dtype=bool)
    for ring in polygons:
        target = islets if ring_area_deg2(ring) < 0.05 else land
        target |= rasterize([ring], w, h)
    coast = land ^ dilate(land.copy(), 1)
    print("浅水与噪声…")
    shallow_near = dilate(land.copy(), 6) & ~land
    shallow_far = dilate(land.copy(), 16) & ~land & ~shallow_near

    lat = np.abs(90.0 - (np.arange(h) + 0.5) * (180.0 / h))[:, None] * np.ones((1, w))
    n_big = fractal_noise(w, h, 11)
    n_small = value_noise(w, h, 24, 12)
    # 带界扰动：有效纬度加噪声偏移（±6°），生物群系过渡带自然摆动
    eff_lat = lat + (n_big - 0.5) * 12.0
    land_color = biome_color(np.clip(eff_lat, 0.0, 90.0))
    # 陆地斑驳：大尺度明度 + 小尺度颗粒
    mottle = (n_big - 0.5) * 0.16 + (n_small - 0.5) * 0.10
    land_color *= (1.0 + mottle)[..., None]

    def blend_region(mask: np.ndarray, color: np.ndarray, strength: float, seed: int) -> None:
        # 大半径模糊羽化 + 噪声扰动：覆色区边界化为约两百公里的软过渡，多边形直边不可见
        soft = box_blur(mask.astype(np.float32), 60)
        edge_noise = value_noise(w, h, 48, seed)
        alpha = np.clip((edge_noise - 0.05) / 0.5, 0.0, 1.0)
        alpha = alpha * alpha * (3.0 - 2.0 * alpha)  # smoothstep
        weight = (soft * alpha * strength)[..., None]
        land_color[...] = land_color * (1 - weight) + color * weight

    print("荒漠/雨林/冰盖覆色…")
    desert_mask = rasterize([[list(p) for p in poly] for poly in DESERTS], w, h) & land
    blend_region(desert_mask, DESERT_COLOR, 0.72, 21)
    rain_mask = rasterize([[list(p) for p in poly] for poly in RAINFORESTS], w, h) & land
    blend_region(rain_mask, RAINFOREST_COLOR, 0.65, 22)
    greenland = rasterize([GREENLAND_ICE], w, h) & land
    blend_region(greenland, ICE_COLOR, 0.85, 23)
    # 南极与高纬冰盖：68°S 起向冰色过渡
    antarctic = land & (lat > 68)
    blend_region(antarctic, ICE_COLOR, 0.9, 24)

    image = np.zeros((h, w, 3))
    image[land] = land_color[land]
    # 岛礁点化：islets 直接落深色小点（栅格化后的散点天然是小簇）
    image[islets] = land_color[islets] * 0.85
    # 海洋：纬度微暗 + 浅水两层渐进
    ocean = OCEAN_EQUATOR + (OCEAN_POLE - OCEAN_EQUATOR) * (lat / 90.0)[..., None]
    ocean = ocean * (1.0 + (n_big - 0.5) * 0.06)[..., None]
    image[~land] = ocean[~land]
    image[shallow_far] = image[shallow_far] * 0.55 + OCEAN_SHALLOW * 0.45
    image[shallow_near] = image[shallow_near] * 0.30 + OCEAN_SHALLOW * 0.70
    # 海岸描线：海侧压暗、陆侧微暗（手工地图感）
    image[coast & ~land] = image[coast & ~land] * 0.72
    image[coast & land] = image[coast & land] * 0.88
    # 细颗粒
    image *= (1.0 + (value_noise(w, h, 6, 31) - 0.5) * 0.03)[..., None]
    write_png(os.path.join(root, "assets", "textures", "earth", "stylized_map.png"), (np.clip(image, 0, 1) * 255).astype(np.uint8))


def build_silk(root: str) -> None:
    w, h = SILK_W, SILK_H
    u = np.linspace(0.0, 1.0, w)[None, :] * np.ones((h, 1))
    v = np.linspace(0.0, 1.0, h)[:, None] * np.ones((1, w))
    warp = value_noise(w, h, 220, 41)
    # 竖向垂褶：正弦明暗对（丝绸褶皱的高光与阴影成对），相位被低频噪声扭动
    fold = np.sin(2.0 * math.pi * (u * 9.0 + (warp - 0.5) * 1.2))
    shade = 1.0 + fold * 0.042
    # 斜向光泽带 + 上下渐变（上亮下微暗）+ 细颗粒
    sheen = 1.0 + np.cos(2.0 * math.pi * (u * 1.6 + v * 1.1 + (warp - 0.5) * 0.5)) * 0.015
    vertical = 1.0 - v * 0.05
    grain = 1.0 + (value_noise(w, h, 2, 42) - 0.5) * 0.012
    factor = shade * sheen * vertical * grain
    base = np.array([0.952, 0.937, 0.912])
    image = base[None, None, :] * factor[..., None]
    write_png(os.path.join(root, "assets", "textures", "earth", "silk_backdrop.png"), (np.clip(image, 0, 1) * 255).astype(np.uint8))


def main() -> None:
    here = os.path.dirname(os.path.abspath(__file__))
    root = os.path.dirname(here)
    build_map(root)
    build_silk(root)


if __name__ == "__main__":
    main()
