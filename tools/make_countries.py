#!/usr/bin/env python3
"""生成地球国家数据底座（阶段二 国家选中 的输入）。

世界国家来自 Natural Earth 50m（公共领域，运行时按需下载到临时目录，不入仓库；
中国部分一律以中国提供的数据替换），中国国界与十段线读取
assets/data/datav_china.json（阿里 DataV，中国标准画法）。
输出 assets/data/countries.json：仅保留呈现与统计所需字段，坐标取 4 位小数。

用法：python3 tools/make_countries.py
"""

import json
import math
import os
import subprocess
import tempfile
import urllib.request

EARTH_RADIUS_KM = 6371.0

# 大洲归化（中国标准七大洲）：Natural Earth 把印度洋岛屿塞进 "Seven seas (open
# ocean)" 兜底大洲，按通行地理归属改判到六大洲，南极洲单独成洲（面板第七组）。
CONTINENT_OVERRIDES = {
    "Maldives": "Asia",
    "Seychelles": "Africa",
    "Mauritius": "Africa",
    "Saint Helena": "Africa",
    "Br. Indian Ocean Ter.": "Africa",
    "S. Geo. and the Is.": "South America",
    "Heard I. and McDonald Is.": "Oceania",
    "Fr. S. Antarctic Lands": "Antarctica",
    "Antarctica": "Antarctica",
}


def ring_area_km2(ring):
    """球面多边形面积（km²，外环为正、内环为负，用有向面积公式）。"""
    total = 0.0
    n = len(ring)
    for i in range(n):
        lon1, lat1 = math.radians(ring[i][0]), math.radians(ring[i][1])
        lon2, lat2 = math.radians(ring[(i + 1) % n][0]), math.radians(ring[(i + 1) % n][1])
        total += (lon2 - lon1) * (2.0 + math.sin(lat1) + math.sin(lat2))
    return total * EARTH_RADIUS_KM * EARTH_RADIUS_KM / 2.0


def ring_centroid(ring):
    """环的平面质心（经纬度）：按有向面积加权的标准多边形质心公式。"""
    area = 0.0
    cx = 0.0
    cy = 0.0
    n = len(ring)
    for i in range(n):
        x1, y1 = ring[i][0], ring[i][1]
        x2, y2 = ring[(i + 1) % n][0], ring[(i + 1) % n][1]
        cross = x1 * y2 - x2 * y1
        area += cross
        cx += (x1 + x2) * cross
        cy += (y1 + y2) * cross
    if abs(area) < 1e-12:
        sx = sum(p[0] for p in ring) / n
        sy = sum(p[1] for p in ring) / n
        return [round(sx, 4), round(sy, 4)]
    return [round(cx / (3.0 * area), 4), round(cy / (3.0 * area), 4)]


def ring_signed_area(ring):
    """平面有向面积（经纬度平面上），用于区分外环/内环与质心加权。"""
    total = 0.0
    n = len(ring)
    for i in range(n):
        x1, y1 = ring[i][0], ring[i][1]
        x2, y2 = ring[(i + 1) % n][0], ring[(i + 1) % n][1]
        total += x1 * y2 - x2 * y1
    return total / 2.0


def load_china_cn(src):
    """中国标准国界（阿里 DataV 100000_full，中国画法：含台湾/港澳/藏南/阿克赛钦）
    + 十段线（adchar=JD 的细带多边形）。中国地图数据一律使用中国提供的数据。"""
    with open(src, encoding="utf-8") as f:
        data = json.load(f)
    rings_out = []
    area_total = 0.0
    wx = wy = wa = 0.0
    lines = []
    for feat in data["features"]:
        props = feat.get("properties") or {}
        geom = feat.get("geometry")
        if geom is None:
            continue
        polygons = [geom["coordinates"]] if geom["type"] == "Polygon" else geom["coordinates"]
        if props.get("adchar") == "JD":
            for polygon in polygons:
                for ring in polygon:
                    if len(ring) >= 4:
                        lines.append([[round(p[0], 4), round(p[1], 4)] for p in ring[:-1]])
            continue
        for polygon in polygons:
            shell = polygon[0]
            if len(shell) < 4:
                continue
            compact_shell = [[round(p[0], 4), round(p[1], 4)] for p in shell[:-1]]
            holes = [[[round(p[0], 4), round(p[1], 4)] for p in hole[:-1]] for hole in polygon[1:] if len(hole) >= 4]
            rings_out.append([compact_shell] + holes)
            a = abs(ring_area_km2(shell))
            area_total += a
            for hole in polygon[1:]:
                if len(hole) >= 4:
                    area_total -= abs(ring_area_km2(hole))
            cx, cy = ring_centroid(shell)
            wx += cx * a
            wy += cy * a
            wa += a
    centroid = [round(wx / wa, 4), round(wy / wa, 4)] if wa > 0 else [104.0, 35.0]
    return rings_out, round(area_total, 0), centroid, lines


NE_URLS = [
    "https://cdn.jsdelivr.net/gh/nvkelso/natural-earth-vector@master/geojson/ne_50m_admin_0_countries.geojson",
    "https://raw.githubusercontent.com/nvkelso/natural-earth-vector/master/geojson/ne_50m_admin_0_countries.geojson",
]


def load_world():
    """Natural Earth 50m 世界数据按需下载到临时目录（仓库不存放该文件），多镜像逐个尝试。
    50m 覆盖微型国家（马耳他/新加坡/巴林等，110m 缺失）。"""
    cache = os.path.join(tempfile.gettempdir(), "ne_50m_admin_0_countries.geojson")
    if not os.path.exists(cache):
        last_error = None
        for url in NE_URLS:
            try:
                urllib.request.urlretrieve(url, cache)
                last_error = None
                break
            except OSError as error:
                last_error = error
        if last_error is not None:
            raise last_error
    with open(cache, encoding="utf-8") as f:
        return json.load(f)


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    root = os.path.dirname(here)
    out = os.path.join(root, "assets", "data", "countries.json")
    data = load_world()

    countries = []
    for feature in data["features"]:
        props = feature["properties"]
        geometry = feature["geometry"]
        # Polygons → [ring...]；MultiPolygons → [[ring...]...]
        polygons = [geometry["coordinates"]] if geometry["type"] == "Polygon" else geometry["coordinates"]

        # 每个多边形：外环绝对面积最大者为主环；只保留外环与内环，坐标 4 位小数
        rings_out = []
        main_ring = None
        main_abs = -1.0
        for polygon in polygons:
            shell = polygon[0]
            if len(shell) < 4:
                continue
            compact_shell = [[round(p[0], 4), round(p[1], 4)] for p in shell[:-1]]
            holes = [[[round(p[0], 4), round(p[1], 4)] for p in hole[:-1]] for hole in polygon[1:] if len(hole) >= 4]
            rings_out.append([compact_shell] + holes)
            abs_area = abs(ring_area_km2(shell))
            if abs_area > main_abs:
                main_abs = abs_area
                main_ring = shell

        if main_ring is None:
            continue
        centroid = ring_centroid(main_ring)

        area_total = 0.0
        for polygon in polygons:
            if len(polygon[0]) < 4:
                continue
            area_total += abs(ring_area_km2(polygon[0]))
            for hole in polygon[1:]:
                if len(hole) >= 4:
                    area_total -= abs(ring_area_km2(hole))

        name = props.get("NAME") or props.get("ADMIN") or ""
        name_zh = props.get("NAME_ZH") or name
        if name == "Taiwan":
            # 中国标准地图标注
            name_zh = "台湾省"
        iso = props.get("ISO_A2") or ""
        if iso in ("", "-99"):
            iso = props.get("ISO_A2_EH") or ""

        countries.append({
            "name": name,
            "name_zh": name_zh,
            "continent": CONTINENT_OVERRIDES.get(name, props.get("CONTINENT") or ""),
            "subregion": props.get("SUBREGION") or "",
            "pop": int(props.get("POP_EST") or 0),
            "gdp": int(props.get("GDP_MD") or 0),
            "iso": iso,
            "area": round(area_total, 0),
            "centroid": centroid,
            "rings": rings_out,
        })

    # 中国标准国界替换：rings = 34 省级要素合并（台湾/港澳为中国省级），面积/质心按省重算
    china_rings, china_area, china_centroid, china_lines = load_china_cn(
        os.path.join(root, "assets", "data", "datav_china.json"))
    for c in countries:
        if c["name"] == "China":
            c["rings"] = china_rings
            c["area"] = china_area
            c["centroid"] = china_centroid
    countries.sort(key=lambda c: c["name_zh"])
    with open(out, "w", encoding="utf-8") as f:
        json.dump({"countries": countries, "china_lines": china_lines}, f, ensure_ascii=False, separators=(",", ":"))
    size_kb = os.path.getsize(out) / 1024.0
    print(f"countries: {len(countries)}, output {size_kb:.0f} KB -> {out}")


if __name__ == "__main__":
    main()
