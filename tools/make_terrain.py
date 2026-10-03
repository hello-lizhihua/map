#!/usr/bin/env python3
"""烘焙地球高程贴图（高程地形 adr 0006：数据源最低档）。

数据：AWS Open Data 的 Terrarium 地形瓦片（elevation-tiles-prod，全球 DEM），
zoom 4 共 256 瓦（16384×16384 格，约 2.4 km/格，与 ETOPO 2022 60 角秒同量级），
每像素高程 = R*256 + G + B/256 - 32768（米）。
Web Mercator 投影逐纬度反解（邻行线性插值）采样到等距圆柱 5400×2700
（与底图同尺寸），高程钳制非负（海洋不位移，海面齐平球面），线性归一到
0..65535 编码进 R（高字节）G（低字节）双通道，输出
assets/textures/earth/terrain_height.png。

用法：python3 tools/make_terrain.py
"""

import os
import struct
import subprocess
import tempfile
import zlib

import numpy as np

TILE_ZOOM = 4
TILE_COUNT = 16  # 每边瓦数
TILE_PX = 256
MERC_SIZE = TILE_COUNT * TILE_PX  # mercator 大图边长（16384）
W, H = 5400, 2700
MAX_ELEV = 8849.0  # 珠穆朗玛（米），归一化基准


def write_png(path: str, arr: np.ndarray) -> None:
    """最小 PNG 编码：8 位 RGB。"""
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


def paeth(a: int, b: int, c: int) -> int:
    p = a + b - c
    pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
    if pa <= pb and pa <= pc:
        return a
    if pb <= pc:
        return b
    return c


def decode_png_rgb(data: bytes) -> np.ndarray:
    """最小 PNG 解码：8 位 RGB、无隔行，支持 filter 0-4（terrarium 瓦片为此格式）。"""
    assert data[:8] == b"\x89PNG\r\n\x1a\n"
    pos = 8
    width = height = 0
    idat = b""
    while pos < len(data):
        length = struct.unpack(">I", data[pos:pos + 4])[0]
        tag = data[pos + 4:pos + 8]
        body = data[pos + 8:pos + 8 + length]
        if tag == b"IHDR":
            width = struct.unpack(">I", body[0:4])[0]
            height = struct.unpack(">I", body[4:8])[0]
            assert body[8] == 8 and body[9] == 2, "仅支持 8 位 RGB"
        elif tag == b"IDAT":
            idat += body
        elif tag == b"IEND":
            break
        pos += 12 + length
    raw = zlib.decompress(idat)
    stride = width * 3
    out = np.zeros((height, width, 3), dtype=np.uint8)
    prev = np.zeros(stride, dtype=np.int32)
    offset = 0
    for y in range(height):
        filter_type = raw[offset]
        line = np.frombuffer(raw[offset + 1:offset + 1 + stride], dtype=np.uint8).astype(np.int32).copy()
        offset += 1 + stride
        if filter_type == 1:  # Sub
            for i in range(3, stride):
                line[i] = (line[i] + line[i - 3]) & 0xFF
        elif filter_type == 2:  # Up
            line = (line + prev) & 0xFF
        elif filter_type == 3:  # Average
            for i in range(stride):
                left = int(line[i - 3]) if i >= 3 else 0
                line[i] = (line[i] + ((left + int(prev[i])) >> 1)) & 0xFF
        elif filter_type == 4:  # Paeth
            for i in range(stride):
                left = int(line[i - 3]) if i >= 3 else 0
                up_left = int(prev[i - 3]) if i >= 3 else 0
                line[i] = (line[i] + paeth(left, int(prev[i]), up_left)) & 0xFF
        out[y] = line.reshape(width, 3).astype(np.uint8)
        prev = line
    return out


def download_tiles(cache_dir: str) -> None:
    os.makedirs(cache_dir, exist_ok=True)
    jobs = []
    for ty in range(TILE_COUNT):
        for tx in range(TILE_COUNT):
            path = os.path.join(cache_dir, f"t{tx}_{ty}.png")
            if os.path.exists(path) and os.path.getsize(path) > 1000:
                continue
            url = f"https://s3.amazonaws.com/elevation-tiles-prod/terrarium/{TILE_ZOOM}/{tx}/{ty}.png"
            jobs.append((url, path))
    if jobs:
        procs = []
        for url, path in jobs:
            # 并发 8 路下载，超出排队
            while sum(p.poll() is None for p in procs) >= 8:
                procs = [p for p in procs if p.poll() is None]
            procs.append(subprocess.Popen(["curl", "-sL", "--max-time", "180", "-o", path, url]))
        for p in procs:
            p.wait()
    missing = [f"t{tx}_{ty}.png" for ty in range(TILE_COUNT) for tx in range(TILE_COUNT)
               if not os.path.exists(os.path.join(cache_dir, f"t{tx}_{ty}.png")) or os.path.getsize(os.path.join(cache_dir, f"t{tx}_{ty}.png")) < 1000]
    assert not missing, f"瓦片缺失: {missing}"
    print(f"瓦片下载完成：{TILE_COUNT * TILE_COUNT} 个")


class TileRowCache:
    """瓦片行缓存：整行 16 瓦解码拼合（256 行 × 16384 列），逐目标行扫描时命中率高。"""

    def __init__(self, cache_dir: str, keep: int = 3):
        self.cache_dir = cache_dir
        self.keep = keep
        self.rows = {}

    def row(self, tile_row: int) -> np.ndarray:
        if tile_row not in self.rows:
            tiles = [
                decode_png_rgb(open(os.path.join(self.cache_dir, f"t{tx}_{tile_row}.png"), "rb").read())
                for tx in range(TILE_COUNT)
            ]
            self.rows[tile_row] = np.concatenate(tiles, axis=1)  # (256, 16384, 3)
            while len(self.rows) > self.keep:
                self.rows.pop(next(iter(self.rows)))
        return self.rows[tile_row]


def merc_y(lat_deg: float) -> float:
    """纬度 → mercator 归一化行（0=北 85.05°，1=南 85.05°）。"""
    lat = max(-85.0511, min(85.0511, lat_deg))
    rad = lat * np.pi / 180.0
    return (1.0 - np.log(np.tan(np.pi / 4.0 + rad / 2.0)) / np.pi) / 2.0


def decode_row(cache: TileRowCache, merc_pos: float) -> np.ndarray:
    """mercator 大图浮点行 → 高程行（米），邻行线性插值。"""
    clamped = min(MERC_SIZE - 1.0, max(0.0, merc_pos))
    row_f = clamped / TILE_PX
    tile_row = min(TILE_COUNT - 1, int(row_f))
    in_row = clamped - tile_row * TILE_PX
    pixels = cache.row(tile_row)
    y0 = min(TILE_PX - 1, int(in_row))
    y1 = min(TILE_PX - 1, y0 + 1)
    t = in_row - y0

    def heights(line):
        return line[:, 0].astype(np.float64) * 256.0 + line[:, 1].astype(np.float64) + line[:, 2].astype(np.float64) / 256.0 - 32768.0

    h0 = heights(pixels[y0])
    h1 = heights(pixels[y1])
    return h0 * (1.0 - t) + h1 * t


def main() -> None:
    here = os.path.dirname(os.path.abspath(__file__))
    root = os.path.dirname(here)
    cache_dir = os.path.join(tempfile.gettempdir(), "terrarium_z4")
    download_tiles(cache_dir)
    cache = TileRowCache(cache_dir)

    print("烘焙高程贴图…")
    cols = (np.arange(W) + 0.5) / W * MERC_SIZE
    cols = np.clip(cols.astype(np.int64), 0, MERC_SIZE - 1)
    elev = np.zeros((H, W), dtype=np.float64)
    for y in range(H):
        lat = 90.0 - (y + 0.5) * 180.0 / H
        if abs(lat) > 85.0511:
            # mercator 覆盖外（极地边缘）：用最近有效行外推
            elev[y] = elev[y - 1] if y > 0 else 0.0
            continue
        row = decode_row(cache, merc_y(lat) * MERC_SIZE)
        elev[y] = np.maximum(row[cols], 0.0)

    # 归一化 0..MAX_ELEV → 0..65535，R=高字节 G=低字节（运行时 16 位采样）
    norm = np.clip(elev / MAX_ELEV, 0.0, 1.0) * 65535.0
    image = np.zeros((H, W, 3), dtype=np.uint8)
    image[..., 0] = (norm / 256.0).astype(np.uint8)
    image[..., 1] = (norm % 256.0).astype(np.uint8)
    out = os.path.join(root, "assets", "textures", "earth", "terrain_height.png")
    write_png(out, image)

    # 校验：珠峰（27.99N, 86.93E）附近区域最大高程应接近 8849
    peak_lat = int((90.0 - 27.99) / 180.0 * H)
    peak_lon = int((86.93 + 180.0) / 360.0 * W)
    nearby = elev[max(0, peak_lat - 8):peak_lat + 8, max(0, peak_lon - 8):peak_lon + 8]
    print(f"珠峰校验: {nearby.max():.0f} m（应接近 8849）")
    print(f"马里亚纳校验（海面钳制）: {elev[H // 2 + 180, W // 2 + 1000]:.0f} m（应为 0）")


if __name__ == "__main__":
    main()
