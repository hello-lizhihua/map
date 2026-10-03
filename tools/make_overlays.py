#!/usr/bin/env python3
"""生成地球叠加层资源（阶段四 学习增强）：

1. 政治区划底图 political_map.png：去饱和海洋 + 每国一色（黄金角异色）+ 海岸描线
2. 人口着色底图 population_map.png / 经济着色底图 gdp_map.png：sqrt 归一化分级
   （低值浅黄 → 高值深红），与地球图例同色
3. 选中高亮遮罩 masks/country_<i>.png 与 masks/group_<i>.png：白色 = 国内，
   透明 = 国外；运行时经 shader 作为高亮填充（像素级贴合，弦高问题不存在）

网格填充三角化在球面上有致命弦高问题（内部三角形沉入球面被深度遮挡，只渲染出
边界一圈），故填充一律走预生成遮罩/底图；描边仍用球面窄带网格。

用法：python3 tools/make_overlays.py
"""

import json
import math
import os
import struct
import zlib

import numpy as np

W, H = 4096, 2048
MASK_W, MASK_H = 2048, 1024
EARTH_RADIUS_KM = 6371.0

OCEAN_EQUATOR = np.array([0.27, 0.44, 0.62])
OCEAN_POLE = np.array([0.22, 0.38, 0.55])
OCEAN_SHALLOW = np.array([0.60, 0.72, 0.80])
CHOROPLETH_LOW = np.array([1.00, 0.96, 0.78])
CHOROPLETH_HIGH = np.array([0.62, 0.13, 0.08])


def write_png(path: str, arr: np.ndarray) -> None:
    """最小 PNG 编码；arr 为 (H, W) 灯度或 (H, W, 3/4) 彩色，uint8。"""
    if arr.ndim == 2:
        arr = np.stack([arr, arr, arr], axis=-1)
    h, w, channels = arr.shape
    ctype = 2 if channels == 3 else 6
    raw = b"".join(b"\x00" + arr[y].tobytes() for y in range(h))

    def chunk(tag: bytes, data: bytes) -> bytes:
        body = tag + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)

    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, ctype, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(raw, 6))
    png += chunk(b"IEND", b"")
    with open(path, "wb") as f:
        f.write(png)


def load_data():
    here = os.path.dirname(os.path.abspath(__file__))
    root = os.path.dirname(here)
    with open(os.path.join(root, "assets", "data", "countries.json"), encoding="utf-8") as f:
        countries = json.load(f)["countries"]
    with open(os.path.join(root, "assets", "data", "groups.json"), encoding="utf-8") as f:
        groups = json.load(f)["groups"]
    return countries, groups, root


def rasterize(rings, w: int, h: int) -> np.ndarray:
    """偶奇扫描线栅格化（原始经度，span 跨 ±180 两侧回绕填充）。rings 为环列表。"""
    edges = []
    for ring in rings:
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
        # 扫描线约定：边在 y ∈ [ymin, ymax) 上激活（sample = 行中心）
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
        xs = np.sort(ex1[i] + t * (ex2[i] - ex1[i]))
        row = mask[y]
        for k in range(0, len(xs) - 1, 2):
            a, b = int(math.ceil(xs[k])), int(math.ceil(xs[k + 1]))
            row[a % w : b % w if b % w else w] = True
            if a < 0:
                row[max(0, a + w) :] = True
            if b > w:
                row[: b - w] = True
    return mask


def dilate(mask: np.ndarray, iterations: int) -> np.ndarray:
    for _ in range(iterations):
        mask = mask | np.roll(mask, 1, 0) | np.roll(mask, -1, 0) | np.roll(mask, 1, 1) | np.roll(mask, -1, 1)
    return mask


def political_color(index: int) -> np.ndarray:
    """黄金角均分色相 + 明度两档交错（与旧网格方案同参数）。"""
    import colorsys

    hue = (index * 0.61803398875) % 1.0
    lightness = 0.62 if index % 2 == 0 else 0.48
    r, g, b = colorsys.hls_to_rgb(hue, lightness, 0.42)
    return np.array([r, g, b])


def ocean_base(land: np.ndarray) -> np.ndarray:
    """海洋底色：纬度微暗 + 近岸浅水渐进 + 海岸描线（与风格化地图同语言）。"""
    h, w = land.shape
    lat = np.abs(90.0 - (np.arange(h) + 0.5) * (180.0 / h))[:, None] * np.ones((1, w))
    ocean = OCEAN_EQUATOR + (OCEAN_POLE - OCEAN_EQUATOR) * (lat / 90.0)[..., None]
    image = np.zeros((h, w, 3))
    image[land] = 0.5
    image[~land] = ocean[~land]
    shallow_near = dilate(land.copy(), 4) & ~land
    shallow_far = dilate(land.copy(), 10) & ~land & ~shallow_near
    image[shallow_far] = image[shallow_far] * 0.55 + OCEAN_SHALLOW * 0.45
    image[shallow_near] = image[shallow_near] * 0.30 + OCEAN_SHALLOW * 0.70
    coast = land ^ dilate(land.copy(), 1)
    image[coast & ~land] = image[coast & ~land] * 0.72
    image[coast & land] = image[coast & land] * 0.88
    return image


def build_maps(countries, root: str) -> None:
    rings_per_country = [[ring for poly in c["rings"] for ring in poly] for c in countries]
    all_rings = [ring for rings in rings_per_country for ring in rings]
    print("栅格化陆地…")
    land = rasterize(all_rings, W, H)
    ocean = ocean_base(land)

    # 政治区划：每国一色 + 细颗粒
    print("政治区划底图…")
    political = ocean.copy()
    for i, rings in enumerate(rings_per_country):
        mask = rasterize(rings, W, H) & land
        color = political_color(i)
        mottle = 1.0 + (np.random.default_rng(1000 + i).random((H, W)) - 0.5) * 0.0
        political[mask] = color * np.ones((int(mask.sum()), 1))
    # 政治区划国界线：邻国交界压暗（陆地掩膜的边界）
    land_edge = land ^ dilate(land.copy(), 1)
    political[land_edge & land] = political[land_edge & land] * 0.82
    write_png(os.path.join(root, "assets", "textures", "earth", "political_map.png"), (np.clip(political, 0, 1) * 255).astype(np.uint8))

    # 数据着色：sqrt 归一化分级（人口 / GDP）
    for key, fname in (("pop", "population_map.png"), ("gdp", "gdp_map.png")):
        print(f"{fname} …")
        values = np.array([int(c[key]) for c in countries], dtype=float)
        values = np.maximum(values, 0.0)
        vmax = max(values.max(), 1.0)
        image = ocean.copy()
        for i, rings in enumerate(rings_per_country):
            mask = rasterize(rings, W, H) & land
            t = math.sqrt(values[i] / vmax)
            color = CHOROPLETH_LOW * (1 - t) + CHOROPLETH_HIGH * t
            image[mask] = color * np.ones((int(mask.sum()), 1))
        land_edge = land ^ dilate(land.copy(), 1)
        image[land_edge & land] = image[land_edge & land] * 0.82
        write_png(os.path.join(root, "assets", "textures", "earth", fname), (np.clip(image, 0, 1) * 255).astype(np.uint8))


CONTINENT_GROUPS = {
    "Asia": "亚洲",
    "Europe": "欧洲",
    "Africa": "非洲",
    "North America": "北美洲",
    "South America": "南美洲",
    "Oceania": "大洋洲",
}  # 与 scripts/earth/groups.gd 保持一致：大洲组在前，索引必须对齐


def build_masks(countries, groups, root: str) -> None:
    """逐国/逐组遮罩：白色 = 范围内（alpha 通道）；组索引与 groups.gd 对齐
    （大洲组 6 个在前，其后为 groups.json 手写组）。"""
    out_dir = os.path.join(root, "assets", "data", "masks")
    os.makedirs(out_dir, exist_ok=True)
    print("逐国遮罩…")
    iso_to_index = {c["iso"]: i for i, c in enumerate(countries) if c.get("iso")}
    country_masks = []
    for i, c in enumerate(countries):
        rings = [ring for poly in c["rings"] for ring in poly]
        mask = rasterize(rings, MASK_W, MASK_H)
        country_masks.append(mask)
        rgba = np.zeros((MASK_H, MASK_W, 4), dtype=np.uint8)
        rgba[..., 0] = 255
        rgba[..., 3] = mask * 255
        write_png(os.path.join(out_dir, f"country_{i}.png"), rgba)
    print("逐组遮罩…")
    g = 0

    def write_group(union):
        nonlocal g
        rgba = np.zeros((MASK_H, MASK_W, 4), dtype=np.uint8)
        rgba[..., 0] = 255
        rgba[..., 3] = union * 255
        write_png(os.path.join(out_dir, f"group_{g}.png"), rgba)
        g += 1

    for continent in CONTINENT_GROUPS:
        union = np.zeros((MASK_H, MASK_W), dtype=bool)
        for i, c in enumerate(countries):
            if c.get("continent") == continent:
                union |= country_masks[i]
        write_group(union)
    for group in groups:
        union = np.zeros((MASK_H, MASK_W), dtype=bool)
        for iso in group.get("iso", []):
            if iso in iso_to_index:
                union |= country_masks[iso_to_index[iso]]
        write_group(union)
    print(f"masks: {len(countries)} 国 + {g} 组（6 大洲 + {len(groups)} 组织）")


def main() -> None:
    countries, groups, root = load_data()
    build_maps(countries, root)
    build_masks(countries, groups, root)


if __name__ == "__main__":
    main()
