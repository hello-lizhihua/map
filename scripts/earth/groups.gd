extends RefCounted
## 编组数据底座（阶段三 编组选中）：地缘政治常见联盟/区域的成员解析与统计聚合。
## 数据：assets/data/groups.json（name + ISO 成员清单）+ 由国家数据自动生成的
## 大洲组（排在组织组之前，从大洲与组织两个维度分组）；
## ISO 按国家数据底座（countries.gd）解析为索引，未知代码跳过并告警。

const DATA_PATH := "res://assets/data/groups.json"

# 大洲英文名 → 中文组名（从国家数据自动聚合，跳过南极洲）
const CONTINENT_GROUPS := {
	"Asia": "亚洲",
	"Europe": "欧洲",
	"Africa": "非洲",
	"North America": "北美洲",
	"South America": "南美洲",
	"Oceania": "大洋洲",
}

var count := 0
var names: Array = []  # 编组名
var members: Array = []  # 每组 Array[int] 国家索引（对齐 countries 数据）
var area_sums: Array = []  # 成国面积合计 km²
var pop_sums: Array = []  # 成员人口合计（人）
var centroids: Array = []  # [lon, lat] 成员质心的面积加权球面平均
var spans: Array = []  # 区域角半径（弧度）：成员包围盒并集对角，大跨度编组切全球机位用


static func load_data(countries: RefCounted) -> RefCounted:
	var text := FileAccess.get_file_as_string(DATA_PATH)
	if text.is_empty():
		return null
	var parsed: Variant = JSON.parse_string(text)
	if parsed == null or not parsed.has("groups"):
		return null
	# ISO2 → 国家索引
	var iso_index := {}
	for i in countries.count:
		var iso: String = countries.isos[i] if i < countries.isos.size() else ""
		if iso != "":
			iso_index[iso] = i
	var data: RefCounted = load("res://scripts/earth/groups.gd").new()
	# 大洲组排最前（大洲维度优先），成员由数据聚合
	for continent in CONTINENT_GROUPS:
		var member_indices: Array = []
		for i in countries.count:
			if countries.continents[i] == continent:
				member_indices.append(i)
		if member_indices.is_empty():
			continue
		_append_group(data, CONTINENT_GROUPS[continent], member_indices, countries)
	for group: Dictionary in parsed["groups"]:
		var member_indices: Array = []
		for iso: String in group.get("iso", []):
			if iso_index.has(iso):
				member_indices.append(iso_index[iso])
			else:
				print("编组 %s：未知 ISO 代码 %s，已跳过" % [group.get("name", "?"), iso])
		if member_indices.is_empty():
			continue
		_append_group(data, group.get("name", ""), member_indices, countries)
	data.count = data.names.size()
	return data


static func _append_group(data: RefCounted, group_name: String, member_indices: Array, countries: RefCounted) -> void:
	var area_sum := 0.0
	var pop_sum := 0
	var vec := Vector3.ZERO
	for i in member_indices:
		area_sum += countries.areas[i]
		pop_sum += countries.pops[i]
		var centroid: Array = countries.centroids[i]
		vec += latlon_to_dir(centroid[1], centroid[0]) * countries.areas[i]
	var mean_dir := vec.normalized() if vec.length() > 0.001 else Vector3.BACK
	data.names.append(group_name)
	data.members.append(member_indices)
	data.area_sums.append(area_sum)
	data.pop_sums.append(pop_sum)
	data.centroids.append(dir_to_latlon(mean_dir))
	data.spans.append(_span_of(member_indices, countries))


## 区域角半径：成员包围盒并集（各成员 ±360 就近对齐）的对角半径，
## 与成员自身角半径取大，保证小联盟也有可用下限
static func _span_of(member_indices: Array, countries: RefCounted) -> float:
	var union: Array = []
	var first := true
	for i in member_indices:
		var bbox: Array = countries.bboxes[i]
		var center: float = (bbox[0] + bbox[2]) * 0.5
		if first:
			union = [bbox[0], bbox[1], bbox[2], bbox[3]]
			first = false
			continue
		var shift := 0.0
		var union_center: float = (union[0] + union[2]) * 0.5
		var best := absf(center - union_center)
		for candidate in [360.0, -360.0]:
			if absf(center + candidate - union_center) < best:
				best = absf(center + candidate - union_center)
				shift = candidate
		union[0] = minf(union[0], bbox[0] + shift)
		union[1] = minf(union[1], bbox[1])
		union[2] = maxf(union[2], bbox[2] + shift)
		union[3] = maxf(union[3], bbox[3])
	var dlon: float = union[2] - union[0]
	var dlat: float = union[3] - union[1]
	var mid_lat: float = (union[1] + union[3]) * 0.5
	var diag_deg := sqrt(pow(dlon * cos(deg_to_rad(mid_lat)), 2.0) + dlat * dlat)
	var ang := deg_to_rad(diag_deg * 0.5)
	for i in member_indices:
		ang = maxf(ang, countries.ang_radii[i])
	return ang


static func latlon_to_dir(lat_deg: float, lon_deg: float) -> Vector3:
	var lat := deg_to_rad(lat_deg)
	var lon := deg_to_rad(lon_deg)
	return Vector3(-cos(lat) * sin(lon), sin(lat), -cos(lat) * cos(lon))


static func dir_to_latlon(dir: Vector3) -> Array:
	var lat := rad_to_deg(asin(clampf(dir.y, -1.0, 1.0)))
	var lon := rad_to_deg(atan2(-dir.x, -dir.z))
	return [lon, lat]
