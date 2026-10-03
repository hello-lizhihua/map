extends RefCounted
## 国家数据底座（阶段二 国家选中）：Natural Earth 110m 瘦数据的加载与几何查询。
## 数据：assets/data/countries.json（tools/make_countries.py 由 NE 110m 生成，
## 公共领域）；rings 已做反子午线解缠（跨 ±180 的环存连续经度），查询时以
## 点经度 ±360 三次试探兜底跨线国家（斐济、俄罗斯东端）。

const DATA_PATH := "res://assets/data/countries.json"
const EARTH_RADIUS_KM := 6371.0

var count := 0
var names: Array = []
var names_zh: Array = []
var isos: Array = []  # ISO 3166-1 两字母码（编组成员解析用）
var continents: Array = []
var subregions: Array = []
var pops: Array = []
var gdps: Array = []  # GDP（百万美元，NE 字段 GDP_MD）
var areas: Array = []
var centroids: Array = []  # [lon, lat] 主环质心
var rings: Array = []  # 每国 [[多边形1外环, 多边形1内环...], ...] 环为 [lon, lat] 连续经度
var bboxes: Array = []  # 每国 [lon_min, lat_min, lon_max, lat_max]（解缠后）
var ang_radii: Array = []  # 角半径（弧度）= sqrt(面积/π)/地球半径，缩放定位用
var china_lines: Array = []  # 十段线（环列表，独立于国家描边绘制；中国标准地图数据）


## 读取并解析数据；失败返回 null（调用方降级为无国界模式并告警）
static func load_data() -> RefCounted:
	var text := FileAccess.get_file_as_string(DATA_PATH)
	if text.is_empty():
		return null
	var parsed: Variant = JSON.parse_string(text)
	if parsed == null or not parsed.has("countries"):
		return null
	var data: RefCounted = load("res://scripts/earth/countries.gd").new()
	var countries: Array = parsed["countries"]
	data.count = countries.size()
	for country: Dictionary in countries:
		data.names.append(country.get("name", ""))
		data.names_zh.append(country.get("name_zh", ""))
		data.isos.append(country.get("iso", ""))
		data.continents.append(country.get("continent", ""))
		data.subregions.append(country.get("subregion", ""))
		data.pops.append(int(country.get("pop", 0)))
		data.gdps.append(int(country.get("gdp", 0)))
		data.areas.append(float(country.get("area", 0.0)))
		data.centroids.append(country.get("centroid", [0.0, 0.0]))
		var unwrapped: Array = []
		var polygons: Array = country.get("rings", [])
		for polygon: Array in polygons:
			var poly: Array = []
			for ring: Array in polygon:
				poly.append(_unwrap_ring(ring))
			unwrapped.append(poly)
		data.rings.append(unwrapped)
		data.bboxes.append(_bbox(unwrapped))
		var area := float(country.get("area", 0.0))
		data.ang_radii.append(sqrt(area / PI) / EARTH_RADIUS_KM)
	for ring: Array in parsed.get("china_lines", []):
		data.china_lines.append(ring)
	return data


## 点在多边形判定（经纬度）：跨该国全部环做偶奇计数（内环自动成洞）
func find_country(lat_deg: float, lon_deg: float) -> int:
	for i in count:
		var bbox: Array = bboxes[i]
		# 解缠环经度可能超出 ±180；包围盒跨度 < 360，±360 平移后至多一个落盒
		for shift in [0.0, 360.0, -360.0]:
			var lon: float = lon_deg + shift
			if lon < bbox[0] or lon > bbox[2] or lat_deg < bbox[1] or lat_deg > bbox[3]:
				continue
			var inside := false
			for polygon: Array in rings[i]:
				for ring: Array in polygon:
					if _point_in_ring(ring, lon, lat_deg):
						inside = not inside
			if inside:
				return i
			break
	return -1


static func _point_in_ring(ring: Array, lon: float, lat: float) -> bool:
	# 射线法（偶奇）：环顶点数少（110m），直接遍历
	var inside := false
	var n := ring.size()
	var j := n - 1
	for i in n:
		var yi: float = ring[i][1]
		var yj: float = ring[j][1]
		if (yi > lat) != (yj > lat):
			var xi: float = ring[i][0]
			var xj: float = ring[j][0]
			if lon < (xj - xi) * (lat - yi) / (yj - yi) + xi:
				inside = not inside
		j = i
	return inside


## 反子午线解缠：相邻点经度跳变超过 180 时连续化（如 179 → -179 记为 179 → 181）；
## 偏移钳制在 ±360 内——南极洲等环多次跨线会让偏移无限累积（+720° 起步），
## 产生数百度的伪长边，下游三角化与细分全部爆掉
static func _unwrap_ring(ring: Array) -> Array:
	if ring.is_empty():
		return ring
	var out: Array = [[ring[0][0], ring[0][1]]]
	var offset := 0.0
	for i in range(1, ring.size()):
		var lon: float = ring[i][0]
		var prev: float = ring[i - 1][0]
		if lon - prev > 180.0:
			offset -= 360.0
		elif lon - prev < -180.0:
			offset += 360.0
		offset = clampf(offset, -360.0, 360.0)
		out.append([lon + offset, ring[i][1]])
	return out


static func _bbox(polygons: Array) -> Array:
	var lon_min := INF
	var lat_min := INF
	var lon_max := -INF
	var lat_max := -INF
	for polygon: Array in polygons:
		for ring: Array in polygon:
			for point: Array in ring:
				lon_min = minf(lon_min, point[0])
				lat_min = minf(lat_min, point[1])
				lon_max = maxf(lon_max, point[0])
				lat_max = maxf(lat_max, point[1])
	return [lon_min, lat_min, lon_max, lat_max]
