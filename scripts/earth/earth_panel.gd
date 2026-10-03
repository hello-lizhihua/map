extends "res://addons/godot-element-plus/dock_panel/dock_panel.gd"
## 地球右侧国家面板：停靠面板 chrome（折叠把手 / 头部 / 滚轮就地消费 / 漏消费
## 按压吞掉）由 ElementDockPanel 提供，本脚本组装面板内容并保持既有对外契约：
## 头部之下依次为机位行（chip）→ 筛选行（大洲 / 组织两个多选下拉维度列表）
## → 排序行（单选按钮组：面积/人口/名称）→ 搜索框（ISO 码或中文名筛选国家）
## → 大洲分组列表（手风琴承载：默认展开亚洲，点击标题开一收一，选中成员
## 自动展开所在分组，国家行带 ISO 简称前缀如「CN 中国」）。
## 筛选与排序状态由组件维护后经信号上报，编组选中状态由 earth 维护
## （select_country/select_group 后 sync 回来）。

signal country_selected(index: int)
signal group_selected(index: int)

const ChipRowScript := preload("res://addons/godot-element-plus/chip_row/chip_row.gd")
const ChipScript := preload("res://addons/godot-element-plus/chip/chip.gd")
const SelectScript := preload("res://addons/godot-element-plus/select/select.gd")
const RadioGroupScript := preload("res://addons/godot-element-plus/radio_group/radio_group.gd")
const InputScript := preload("res://addons/godot-element-plus/input/input.gd")
const TabsScript := preload("res://addons/godot-element-plus/tabs/tabs.gd")
const GroupListScript := preload("res://addons/godot-element-plus/group_list/group_list.gd")

const PANEL_WIDTH := 300.0
const ROW_HEIGHT := 38.0
const PAD_X := 14.0
const CONTENT_WIDTH := PANEL_WIDTH - 4.0  # 面板内边距后的内容宽

# 大洲维度顺序（用户约定）：亚洲、欧洲、北美洲、南美洲、大洋洲、非洲
const CONTINENT_DIMENSION := ["亚洲", "欧洲", "北美洲", "南美洲", "大洋洲", "非洲"]
# 组织维度优先序：其他组织排在其后（保持数据序）
const ORG_PRIORITY := ["上海合作组织", "金砖国家", "北约", "欧盟", "二十国集团", "七国集团"]
# 港澳台展示（ISO 3166-1 中国代码 + 名称前缀）
const REGION_DISPLAY := {
	"HK": ["CN-HK", "中国-香港"],
	"MO": ["CN-MO", "中国-澳门"],
	"CN-TW": ["CN-TW", "中国-台湾"],
}

# 七洲英→中映射；列表分组顺序与此一致
const CONTINENT_ORDER := [
	["Asia", "亚洲"],
	["Europe", "欧洲"],
	["Africa", "非洲"],
	["North America", "北美洲"],
	["South America", "南美洲"],
	["Oceania", "大洋洲"],
	["Antarctica", "南极洲"],
]
# 排序项：[标签, 键]
const SORT_ITEMS := [["面积", "area"], ["人口", "pop"], ["名称", "name"]]
# 各字段默认顺序：面积/人口倒序（大→小），名称正序（二字码 A→Z，如东帝汶 TL 在后）
const SORT_DEFAULT_DESC := {"area": true, "pop": true, "name": false}

var _names_zh: Array = []
var _pops: Array = []
var _areas: Array = []
var _centroids: Array = []
var _continents: Array = []
var _countries: RefCounted = null  # 国家数据底座（ISO 码经其 isos 字段读取）
var _selected := -1          # 选中国家（数据索引），-1 = 无
var _active_groups: Array = []  # 当前选中编组（大洲/组织维度多选），空 = 无
var _group_names: Array = []  # 全部编组名（数据序：6 大洲在前）
var _continent_group_index := {}  # 大洲中文名 → 编组数据索引
var _continent_select: Control  # ElementSelect（多选）
var _org_select: Control  # ElementSelect（多选）
var _sort_row: HBoxContainer  # 「排序」标签 + ElementRadioGroup
var _sort_radio: HFlowContainer  # ElementRadioGroup
var _order_radio: HFlowContainer  # 顺序行 ElementRadioGroup（正序/倒序）
var _search: Control  # ElementInput
var _tabs: Control  # ElementTabs（「选中」/「国家」两页签）
var _list: CountryList
var _scroll: ScrollContainer  # 分组列表本体（ScrollContainer，滚动契约与测试用）
var _sort := "area"  # 大洲组内排序：area / pop / name
var _order_desc := true  # 排序顺序：倒序（默认，面积/人口大→小、名称二字码反序）
var _list_rows: Array = []  # 显示顺序记录（rows_changed 同步，测试契约）


func _init() -> void:
	super()
	width = PANEL_WIDTH
	# 头部不再放标题：tab 页签「国家(242)」即标题（设计稿 v6），避免头部与页签重叠


func setup(countries: RefCounted, groups: RefCounted = null) -> void:
	# 注入数据对象（国家：names_zh/pops/areas/centroids/continents；
	# 编组：names，数据序 6 大洲在前、其后为手写组织组）
	_countries = countries
	_names_zh = _as_array(countries.get("names_zh"))
	_pops = _as_array(countries.get("pops"))
	_areas = _as_array(countries.get("areas"))
	_centroids = _as_array(countries.get("centroids"))
	_continents = _as_array(countries.get("continents"))
	if groups != null:
		_group_names = _as_array(groups.get("names"))
		for continent in CONTINENT_ORDER:
			var group_index: int = _group_names.find(continent[1])
			if group_index >= 0:
				_continent_group_index[continent[1]] = group_index
	content().add_theme_constant_override("separation", 4)
	_build_tabs()


func _build_tabs() -> void:
	# 面板两个页签：「国家(242)」第一默认（排序 + 搜索 + 手风琴列表）；「选中」第二（大洲/组织维度下拉）
	_tabs = TabsScript.new()
	_tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content().add_child(_tabs)
	var country_tab: int = _tabs.add_tab("国家(%d)" % _names_zh.size())
	var select_tab: int = _tabs.add_tab("选中")
	var country_content: VBoxContainer = _tabs.tab_content(country_tab)
	var select_content: VBoxContainer = _tabs.tab_content(select_tab)
	country_content.add_theme_constant_override("separation", 4)
	select_content.add_theme_constant_override("separation", 4)
	_build_filter_selects(select_content)
	_build_sort_row(country_content)
	_build_search(country_content)
	_build_list(country_content)


func _as_array(value) -> Array:
	return value if value is Array else []


func row_count() -> int:
	return _list.row_count()


func country_row_data(pos: int) -> int:
	# 显示位置 → 国家数据索引（非国家行返回 -1）
	return _list.item_index_at(pos)


func sync_selection(kind: String, index: int) -> void:
	# kind："country" / ""（仅清除）；国家行展开详情并滚动到可见（所在分组
	# 自动展开），编组多选高亮走 sync_groups
	match kind:
		"country":
			_active_groups.clear()
			_selected = index if index < _names_zh.size() else -1
			_list.set_selected(_selected)
			_list.scroll_to_item(_selected)
		_:
			_selected = -1
			_active_groups.clear()
			_list.set_selected(-1)
			_list.set_active_groups([])
	_sync_filters()


func sync_groups(indices: Array) -> void:
	# 大洲/组织维度多选高亮（earth.select_group 维护状态后回调）
	_active_groups = indices.duplicate()
	_selected = -1
	_list.set_selected(-1)
	_list.set_active_groups(_active_groups)
	_sync_filters()


# ── 面板内容（筛选行 / 排序行 / 搜索框 / 分组列表，装入页签内容容器）──────────


## 编组数据索引 → 维度：0-5 大洲，6+ 组织
func _dimension_of(group_index: int) -> String:
	return "continent" if group_index < 6 else "org"


## 维度下拉选项：[标签, 编组数据索引（字符串）]；组织按优先序排列
func _build_filter_selects(parent: Container) -> void:
	# 筛选两行：大洲（含首项「全部」互斥，代替全球视角）+ 组织（无全部项）
	var cont_row := HBoxContainer.new()
	cont_row.add_theme_constant_override("separation", 6)
	parent.add_child(cont_row)
	_continent_select = SelectScript.new()
	_continent_select.label = "大洲"
	_continent_select.label_width = 32.0
	_continent_select.placeholder = "全部"
	_continent_select.multiple = true
	_continent_select.exclusive_first = true
	_continent_select.show_clear = true
	_continent_select.options = _dimension_options("continent")
	_continent_select.width = CONTENT_WIDTH - 32.0
	_continent_select.option_toggled.connect(_on_filter_toggled)
	_continent_select.selection_cleared.connect(_on_filter_cleared)
	# 弹层贴面板内容顶部（设计决策：下拉列表显示在面板最上面，展开时覆盖筛选行）
	_continent_select.popup_top_y_provider = func(): return _tabs.get_global_rect().position.y + TabsScript.BAR_HEIGHT + 2.0
	cont_row.add_child(_continent_select)
	_continent_select.set_values(["all"])
	var org_row := HBoxContainer.new()
	org_row.add_theme_constant_override("separation", 6)
	parent.add_child(org_row)
	_org_select = SelectScript.new()
	_org_select.label = "组织"
	_org_select.label_width = 32.0
	_org_select.placeholder = "组织"
	_org_select.multiple = true
	_org_select.show_clear = true
	_org_select.options = _dimension_options("org")
	_org_select.width = CONTENT_WIDTH - 32.0
	_org_select.option_toggled.connect(_on_filter_toggled)
	_org_select.selection_cleared.connect(_on_filter_cleared)
	_org_select.popup_top_y_provider = _continent_select.popup_top_y_provider
	org_row.add_child(_org_select)


## 维度下拉选项：[标签, 编组数据索引（字符串）]；大洲首项「全部」（值 all），组织按优先序排列
func _dimension_options(dimension: String) -> Array:
	var options: Array = []
	if dimension == "continent":
		options.append(["全部", "all"])
		for continent_zh in CONTINENT_DIMENSION:
			if _group_names.has(continent_zh):
				options.append([continent_zh, str(_group_names.find(continent_zh))])
	else:
		for org_zh in ORG_PRIORITY:
			if _group_names.has(org_zh):
				options.append([org_zh, str(_group_names.find(org_zh))])
		for i in range(6, _group_names.size()):
			if not ORG_PRIORITY.has(str(_group_names[i])):
				options.append([str(_group_names[i]), str(i)])
	return options


func _on_filter_toggled(value: String) -> void:
	# 直接上报编组数据索引，选中状态由 earth 维护（多选 toggle）后 sync_groups 回来
	if value == "all":
		group_selected.emit(-1)
		return
	group_selected.emit(int(value))


func _on_filter_cleared() -> void:
	# clearable 清空：大洲回退「全部」（即清除编组选中），组织同为清除
	group_selected.emit(-1)


func _build_sort_row(parent: Container) -> void:
	# 排序行：行首「排序」标签 chip（禁用占位）+ 单选按钮组（面积/人口/名称）
	_sort_row = HBoxContainer.new()
	_sort_row.add_theme_constant_override("separation", 8)
	parent.add_child(_sort_row)
	var sort_label := Label.new()
	sort_label.text = "排序"
	_style_dim_label(sort_label)
	_sort_row.add_child(sort_label)
	_sort_radio = RadioGroupScript.new()
	_sort_radio.size_flags_horizontal = Control.SIZE_EXPAND_FILL  # 撑满剩余宽：单选组不换行竖排
	_sort_row.add_child(_sort_radio)
	for item in SORT_ITEMS:
		_sort_radio.add_option(item[0])
	_sort_radio.selected_changed.connect(func(index: int): _set_sort(SORT_ITEMS[index][1]))
	_sort_radio.set_selected(0)
	# 顺序行：「顺序」标签 + 正序/倒序（默认倒序 = 现状面积大→小；切正序看排在后面的国家）
	var order_row := HBoxContainer.new()
	order_row.add_theme_constant_override("separation", 8)
	parent.add_child(order_row)
	var order_label := Label.new()
	order_label.text = "顺序"
	_style_dim_label(order_label)
	order_row.add_child(order_label)
	_order_radio = RadioGroupScript.new()
	_order_radio.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	order_row.add_child(_order_radio)
	_order_radio.add_option("正序")
	_order_radio.add_option("倒序")
	_order_radio.selected_changed.connect(func(index: int): _set_order(index == 1))
	_order_radio.set_selected(1)


func _style_dim_label(label: Label) -> void:
	label.add_theme_font_override("font", UITheme.system_font())
	label.add_theme_font_size_override("font_size", 13)
	label.add_theme_color_override("font_color", UITheme.TEXT_FAINT)


func _build_search(parent: Container) -> void:
	# 搜索框：ISO 码（CN）或中文名（中）筛选国家
	_search = InputScript.new()
	_search.placeholder_text = "搜索国家：CN / 中国"
	_search.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(_search)
	_search.text_changed.connect(func(text: String): _list.set_filter(text))


func _build_list(parent: Container) -> void:
	_list = CountryList.new()
	_list.panel = self
	_list.row_width = PANEL_WIDTH
	_list.sort_keys = SORT_ITEMS
	_list.sort_key = _sort
	_list.sort_comparator = Callable(self, "_sort_compare")
	_list.filter_callable = Callable(self, "_match_country")
	_list.accordion = true
	_list.open_section = 0  # 默认展开亚洲（CONTINENT_ORDER 首组）
	_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	parent.add_child(_list)
	_scroll = _list
	_list.item_clicked.connect(func(_item: Dictionary, index: int): country_selected.emit(index))
	_list.rows_changed.connect(func(rows: Array): _list_rows = rows)
	_list.set_data(_continent_payload())


## 国家展示（港澳台按中国代码与前缀；无 ISO 码实体不显示码列）：返回 [展示 ISO, 展示名]
func _region_display(index: int) -> Array:
	var isos: Array = _countries.get("isos") if _countries != null else []
	var iso := str(isos[index]) if index < isos.size() else ""
	if REGION_DISPLAY.has(iso):
		return REGION_DISPLAY[iso]
	if iso == "-99":
		return ["", str(_names_zh[index])]
	return [iso, str(_names_zh[index])]


## 搜索匹配：ISO 码前缀（大小写不敏感，含 CN-HK 等展示码）或中文名包含
func _match_country(item: Dictionary, text: String) -> bool:
	var index: int = int(item["index"])
	var lower := text.to_lower()
	var display := _region_display(index)
	if str(display[0]).to_lower().begins_with(lower):
		return true
	return str(display[1]).contains(text) or str(_names_zh[index]).contains(text)


func _continent_payload() -> Array:
	# 大洲分组载荷：组内条目带国家索引与排序键
	var payload: Array = []
	for continent in CONTINENT_ORDER:
		var items: Array = []
		for i in _names_zh.size():
			if str(_continents[i]) == continent[0]:
				items.append({"index": i, "area": float(_areas[i]), "pop": int(_pops[i])})
		payload.append({"name": continent[0], "title": continent[1], "items": items})
	return payload


func _sort_compare(key: String, a: Dictionary, b: Dictionary) -> bool:
	# 面积/人口按方向比较；名称按二字码排序（如东帝汶 TL 靠后），方向同样生效
	match key:
		"area":
			return _by_order(float(a["area"]), float(b["area"]))
		"pop":
			return _by_order(float(a["pop"]), float(b["pop"]))
	var code_a := _sort_code(int(a["index"]))
	var code_b := _sort_code(int(b["index"]))
	return (code_a > code_b) if _order_desc else (code_a < code_b)


func _by_order(a: float, b: float) -> bool:
	return (a > b) if _order_desc else (a < b)


func _set_order(desc: bool) -> void:
	# 切换正序/倒序：键不变，重排即可（正序可查看排在后面的国家）
	if _order_desc == desc:
		return
	_order_desc = desc
	_order_radio.set_selected(1 if desc else 0)
	_list.resort()
	if _selected >= 0:
		_list.scroll_to_item(_selected)
	queue_redraw()


func _sort_code(index: int) -> String:
	# 二字码排序键；无码实体（含数据占位 -99）垫底
	var code := str(_region_display(index)[0])
	return code if code != "" else "～～"


func _sync_filters() -> void:
	# 大洲/组织维度下拉按编组数据索引回推勾选（空勾选回退「全部」）
	var continents: Array = []
	var orgs: Array = []
	for group_index in _active_groups:
		if _dimension_of(group_index) == "continent":
			continents.append(str(group_index))
		else:
			orgs.append(str(group_index))
	_continent_select.set_values(continents if not continents.is_empty() else ["all"])
	_org_select.set_values(orgs)


func _set_sort(key: String) -> void:
	if _sort == key:
		return
	_sort = key
	for i in SORT_ITEMS.size():
		if SORT_ITEMS[i][1] == key:
			_sort_radio.set_selected(i)
			break
	# 切字段回该字段默认顺序（面积/人口倒序、名称正序），顺序行同步高亮
	_order_desc = SORT_DEFAULT_DESC[key]
	_order_radio.set_selected(0 if _order_desc else 1)
	_list.set_sort(key)
	if _selected >= 0:
		_list.scroll_to_item(_selected)
	queue_redraw()


## 列表行渲染子类：国家行 = ISO 简称 + 中文名 + 人口短格式；选中行展开
## 「大小/人口」「位置/大洲」两行详情（meta "details" 交列表统一显隐）
class CountryList extends "res://addons/godot-element-plus/group_list/group_list.gd":

	var panel: Control = null  # 外层面板（内层类不捕获外部成员，经此访问数据）
	var row_width := 300.0

	func _format_count(count: int) -> String:
		return "%d 国" % count

	func _fill_item_row(row: Control, item: Dictionary) -> void:
		var index: int = int(item["index"])
		var data: Control = panel
		var font: SystemFont = data._font
		var pad_x := UITheme.PAD_M
		var display: Array = data._region_display(index)

		# ISO 二字码（如 CN / CN-HK），名称前展示
		var iso := Label.new()
		iso.text = str(display[0])
		iso.position = Vector2(pad_x, 10.0)
		iso.size = Vector2(46.0, 18.0)
		iso.add_theme_font_override("font", font)
		iso.add_theme_font_size_override("font_size", 12)
		iso.add_theme_color_override("font_color", UITheme.TEXT_FAINT)
		iso.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(iso)

		var zh := Label.new()
		zh.text = str(display[1])
		zh.position = Vector2(pad_x + 48.0, 8.0)
		zh.size = Vector2(row_width - pad_x - 48.0 - 90.0, 24.0)
		zh.add_theme_font_override("font", font)
		zh.add_theme_font_size_override("font_size", 16)
		zh.add_theme_color_override("font_color", UITheme.TEXT_MAIN)
		zh.clip_text = true
		zh.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(zh)

		var pop := Label.new()
		pop.text = data._fmt_pop(int(item["pop"]))
		pop.position = Vector2(row_width - pad_x - 90.0, 10.0)
		pop.size = Vector2(90.0, 18.0)
		pop.add_theme_font_override("font", font)
		pop.add_theme_font_size_override("font_size", 13)
		pop.add_theme_color_override("font_color", UITheme.TEXT_DIM)
		pop.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		pop.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(pop)

		var detail_size := Label.new()
		detail_size.text = "大小 %s · 人口 %s" % [data._fmt_area(float(item["area"])), data._fmt_pop(int(item["pop"]))]
		detail_size.position = Vector2(pad_x, item_height + 2.0)
		detail_size.size = Vector2(row_width - pad_x * 2.0, 18.0)
		detail_size.add_theme_font_override("font", font)
		detail_size.add_theme_font_size_override("font_size", 13)
		detail_size.add_theme_color_override("font_color", UITheme.TEXT_DIM)
		detail_size.mouse_filter = Control.MOUSE_FILTER_IGNORE
		detail_size.visible = false
		row.add_child(detail_size)

		var centroid: Array = data._centroids[index]
		var detail_pos := Label.new()
		detail_pos.text = "位置 %s · %s" % [data._fmt_pos(centroid), data._continent_zh(str(data._continents[index]))]
		detail_pos.position = Vector2(pad_x, item_height + 24.0)
		detail_pos.size = Vector2(row_width - pad_x * 2.0, 18.0)
		detail_pos.add_theme_font_override("font", font)
		detail_pos.add_theme_font_size_override("font_size", 13)
		detail_pos.add_theme_color_override("font_color", UITheme.TEXT_DIM)
		detail_pos.mouse_filter = Control.MOUSE_FILTER_IGNORE
		detail_pos.visible = false
		row.add_child(detail_pos)

		row.set_meta("details", [detail_size, detail_pos])


# ── 格式化 ──────────────────────────────────────────────────────

func _fmt_pop(value: int) -> String:
	# 人口短格式：≥1e8 →「14.0亿」（一位小数）；≥1e4 →「8899万」（万位取整）；否则原数字
	if value >= 100000000:
		return "%.1f亿" % (float(value) / 100000000.0)
	if value >= 10000:
		return "%d万" % roundi(value / 10000.0)
	return str(value)


func _fmt_area(value: float) -> String:
	# 面积短格式：≥100万 km² →「960万 km²」（万位取整）；否则保留整数原值
	if value >= 1000000.0:
		return "%d万 km²" % roundi(value / 10000.0)
	return "%d km²" % roundi(value)


func _fmt_pos(centroid) -> String:
	# 「35°N / 22°S」纬度 +「105°E / 85°W」经度，各保留整数度，纬度在前
	var lon := float(centroid[0])
	var lat := float(centroid[1])
	return "%d°%s / %d°%s" % [
		absi(roundi(lat)), "N" if lat >= 0.0 else "S",
		absi(roundi(lon)), "E" if lon >= 0.0 else "W",
	]


func _continent_zh(name_en: String) -> String:
	for continent in CONTINENT_ORDER:
		if continent[0] == name_en:
			return continent[1]
	return name_en
