extends Node3D
## 地球场景（真实地球，策略战棋原型的实例）：呈现模式+ 拖动地球/缩放+ 机位表
## + 国家/编组选中（阶段二/三）。
## 模块隔离：房间代码在 scripts/room/，本模块不引用任何房间脚本；场景级按需加载，
## 进入本场景时不加载房间代码，反之亦然。
##
## 相机模型：机位与拖动都以「注视点经纬度 + 距离」表达——相机始终位于
## dir(facing_lat, facing_lon) * distance 处看向球心；拖动即改注视点，视觉上
## 地球表面跟着指针走（像拨动桌面地球仪），画面与指针同向移动。
## 经纬方向约定：北纬为正、东经为正；北极限在 +Y。

signal selection_changed(index: int)

const GLOBE_RADIUS := 1.0
const TERRAIN_EXAGGERATION := 0.2  # 高程夸张系数
const TERRAIN_MAX_ELEV := 8849.0  # 珠穆朗玛（米），高程贴图归一化基准
const TERRAIN_MAX_DISPLACE := TERRAIN_MAX_ELEV / 1000.0 * TERRAIN_EXAGGERATION / 6371.0  # ≈ 0.0278（米→公里换算）
const TERRAIN_HEIGHT_PATH := "res://assets/textures/earth/terrain_height.png"
const GLOBE_SEGMENTS := 512  # 位移球体网格细分（性能暂不考虑，效果优先）
const STYLIZED_TEXTURE_PATH := "res://assets/textures/earth/stylized_map.png"
const SATELLITE_TEXTURE_PATH := "res://assets/textures/earth/blue_marble.jpg"
const POLITICAL_TEXTURE_PATH := "res://assets/textures/earth/political_map.png"
const POPULATION_TEXTURE_PATH := "res://assets/textures/earth/population_map.png"
const GDP_TEXTURE_PATH := "res://assets/textures/earth/gdp_map.png"
const BACKDROP_PATH := "res://assets/textures/earth/silk_backdrop.png"
const BACKDROP_COLOR := Color(0.952, 0.937, 0.912)  # 与丝绸幕布同底的暖白

# 纹理对准修正：SphereMesh 的 UV 起点与经纬网存在待校准偏差，机位截图核对后
# 调整 YAW（绕 Y 转球）；若南北极颠倒则改 FLIP_V（uv 翻转）
const TEXTURE_YAW_DEG := 0.0
const TEXTURE_FLIP_V := false

# 机位表：[名称, 纬度, 经度, 缩放级别]；启动定位亚洲机位（默认 8 级）
const PRESETS := [
	["亚洲", 35.0, 105.0, 8],
	["欧洲", 48.0, 15.0, 9],
	["北美", 45.0, -100.0, 6],
	["南美", -15.0, -60.0, 6],
	["全球", 22.0, 105.0, 5],
]

const ZOOM_MIN_DISTANCE := 1.12  # 级 10：贴地看国家（最近）
const ZOOM_MAX_DISTANCE := 5.0  # 级 1：全球全景之外留空（最远）
const ZOOM_LEVELS := 10  # 缩放级数滑块 10 级，废除触摸板/滚轮缩放
const FOV_DEG := 50.0
const MAX_LAT := 88.0  # 注视纬度上限：避免 look_at 上向量退化
const JUMP_DURATION := 0.6  # 机位跳转缓动时长（命令动画，非惯性）

# 国界与选中（阶段二/三）：球面描边窄带 + 遮罩贴图填充。填充一律走预生成遮罩
# ——球面网格填充三角有致命弦高（内部三角形沉入球面被深度遮挡，只渲染出边界
# 一圈），已废；遮罩经 shader 上屏，像素级贴合
const BORDER_RADIUS := 1.0015
const BORDER_WIDTH := 0.0035
const BORDER_COLOR := Color(0.24, 0.27, 0.30, 0.55)
const HIGHLIGHT_OVERLAY_RADIUS := 1.0008
const SELECT_FILL_COLOR := Color(1.0, 0.8, 0.2, 0.42)
const SELECT_STROKE_RADIUS := 1.0022
const SELECT_STROKE_WIDTH := 0.007
const SELECT_STROKE_COLOR := Color(1.0, 0.843, 0.369, 0.95)
const TAP_MAX_MOVEMENT := 6.0  # 点击判定：按下到松开位移上限（点）
const TAP_MAX_MSEC := 500  # 点击判定：按下到松开时长上限
const RIBBON_STEP_RAD := 0.035  # 描边窄带单段圆心角上限（弧度，约 2°）
const MASK_PATH_COUNTRY := "res://assets/data/masks/country_%d.png"
const MASK_PATH_GROUP := "res://assets/data/masks/group_%d.png"
# 国家名标签地图上白色文本：世界尺寸随缩放，屏幕上
# 角半径不足阈值时隐藏（拉近渐次显现小国）
const LABEL_RADIUS := 1.012
const LABEL_MIN_PX := 26.0
# 长国名地图简称（面板仍用全名）
const LABEL_SHORT_NAMES := {
	"中华人民共和国": "中国",
	"朝鲜民主主义人民共和国": "朝鲜",
	"大韩民国": "韩国",
	"老挝人民民主共和国": "老挝",
}
const DOUBLE_TAP_MSEC := 350  # 触屏双击判定时长
const DOUBLE_TAP_MOVEMENT := 32.0  # 触屏双击判定位移

const HIGHLIGHT_SHADER := "
shader_type spatial;
render_mode unshaded, blend_mix, cull_disabled, depth_draw_opaque;
uniform sampler2D mask : source_color, filter_linear, repeat_enable;
uniform sampler2D height : source_color, filter_linear, repeat_enable;
uniform vec4 tint : source_color;
uniform float max_displace;
void vertex() {
	vec3 h = texture(height, UV).rgb;
	float elevation = (h.r * 256.0 * 255.0 + h.g * 255.0) / 65535.0;
	VERTEX = VERTEX * (1.0 + elevation * max_displace + 0.0008);
}
void fragment() {
	float m = texture(mask, UV).a;
	ALBEDO = tint.rgb;
	ALPHA = m * tint.a;
}
"

var facing_lat := 35.0  # 注视点纬度（度）
var facing_lon := 105.0  # 注视点经度（度）
var distance := 2.1  # 相机距球心

var _camera: Camera3D
var _globe: MeshInstance3D
var _hud: Control
var _panel: Control
var _settings: Control
var _countries: RefCounted
var _groups: RefCounted
var map_style := "stylized"  # 当前贴图模式：stylized 模拟地图 / satellite 卫星影像
var presentation_mode := "stylized"  # 呈现模式：stylized/satellite/political/population/gdp
var _legend: Control
# 编组高亮色彩列表：多选编组按选中顺序取色（描边高饱和、填充同色低透明）
const GROUP_COLORS := [
	Color(1.0, 0.8, 0.2),    # 琥珀
	Color(1.0, 0.4, 0.27),   # 红橙
	Color(0.27, 0.8, 0.53),  # 翠绿
	Color(0.27, 0.53, 1.0),  # 宝蓝
	Color(0.8, 0.4, 1.0),    # 紫
	Color(1.0, 0.53, 0.73),  # 粉
	Color(0.53, 0.87, 1.0),  # 天青
	Color(0.67, 0.87, 0.27), # 黄绿
]
var _selected := -1  # 当前选中国家索引，-1 = 无
var _selected_kind := ""  # 选中类别："country" / "group" / "" 无
var _active_groups: Array = []  # 多选编组（面板组织 chip），每编组按序取色
var _china_index := -1  # 中国数据索引：选中中国时十段线随高亮
var _borders_mesh: MeshInstance3D
var _stroke_mesh: MeshInstance3D
var _highlight_overlay: MeshInstance3D
var _highlight_material: ShaderMaterial
var _group_overlays := {}  # 多选编组 overlay：编组索引 → {fill, stroke}
var _empty_mask: ImageTexture  # 未选中时的高亮遮罩（全透明 1×1）
var _labels: Array = []  # 国家名 Label3D，索引对齐国家数据
var _terrain_height: Image  # 高程贴图（R=高字节 G=低字节），叠加层与标签采样抬升
# 触屏双击判定：上一次 tap 的位置与时刻
var _last_tap_pos := Vector2.ZERO
var _last_tap_time := 0
# 点击判定状态（鼠标 / 触屏各一份）：按下位置与时刻，松开时判 tap
var _press_screen := Vector2.ZERO
var _press_time := 0
var _touch_tap_index := -1
var _touch_tap_pos := Vector2.ZERO
var _touch_tap_time := 0
var _active_preset := -1  # -1 = 自由观察
var _dragging := false
var _tween: Tween
# 触屏多点状态：index → 最近位置；捏合基线距离；捏合后未抬指前抑制单指旋转
var _touch_points := {}
var _pinch_prev_dist := 0.0
var _suppress_single := false


func _ready() -> void:
	# 触屏拖动/捏合由本模块原生处理，关闭系统触摸→鼠标仿真，防止拖动被
	# 仿真鼠标事件重复驱动而翻倍（同房间触屏层先例 Input.emulate_mouse_from_touch=false）
	Input.emulate_mouse_from_touch = false
	_camera = get_node("Camera3D")
	_build_environment()
	_build_backdrop()
	_load_terrain()
	_build_globe()
	_load_countries()
	_build_borders()
	_build_highlight_overlay()
	_build_labels()
	_load_groups()
	if get_tree().current_scene == self:
		# 用户面对的场景：启动即最大化；工具场景不调用，
		# 保持 1600×900 出图尺寸
		preload("res://scripts/app_window.gd").apply_maximized(get_window())
	_create_ui()
	# 启动定位亚洲机位
	place_camera(PRESETS[0][1], PRESETS[0][2], zoom_level_distance(PRESETS[0][3]))
	# 默认选中国家（设计稿 v6：默认激活中国——高亮 + 面板行选中 + 详情展开）
	if _countries != null and _china_index >= 0:
		select_country(_china_index)


func _create_ui(force := false) -> void:
	# HUD 与右上角最大化按钮：仅主场景交互运行创建——工具场景（截图，current_scene
	# 非本节点）不渲染，headless 测试经 force 注入（同房间 _create_settings_ui 先例）
	if _hud != null:
		return
	if not force and get_tree().current_scene != self:
		return
	_hud = preload("res://scripts/earth/earth_hud.gd").new()
	_hud.name = "EarthHud"
	add_child(_hud)
	_hud.main_node = self
	# 设置面板：齿轮几何与交互语义与房间一致；
	# early_input 在 _input 阶段处理（点面板外收起放行给 GUI 控件）、
	# pass_through_outside 透传该次点击（地球 HUD 是明确目标）；面板左锚定于齿轮下方
	_settings = preload("res://addons/godot-element-plus/settings_panel/settings_panel.gd").new()
	_settings.name = "EarthSettings"
	_settings.options = PRESENTATION_OPTIONS
	_settings.early_input = true
	_settings.pass_through_outside = true
	_settings.opened.connect(on_settings_opened)
	_settings.closed.connect(_on_settings_closed)
	add_child(_settings)
	_settings.value = presentation_mode
	# 设置齿轮为设置唯一入口：
	# 弹层首行「返回场景选择」+ 全屏开关行 + 呈现模式单选行；最大化按钮已废——
	# 全屏只走开关行
	_settings.left_anchor = true
	_settings.margin = 40.0
	_settings.top = 40.0
	_settings.back_label = "‹ 返回场景选择" if ResourceLoader.exists("res://scenes/scene_picker.tscn") else ""
	_settings.switch_label = "全屏"
	_settings.switch_checked = false
	_settings.option_selected.connect(apply_presentation)
	_settings.back_selected.connect(_go_scene_picker)
	_settings.switch_toggled.connect(_set_fullscreen)
	# 数据着色图例（阶段四）：分级统计模式显示端值渐变条
	if _countries != null and ResourceLoader.exists("res://scripts/earth/earth_legend.gd"):
		_legend = preload("res://scripts/earth/earth_legend.gd").new()
		_legend.name = "EarthLegend"
		add_child(_legend)
		_legend.setup(_countries)
	# 右侧国家面板（阶段二）：脚本就位即创建并接线（setup 数据 + 点击选中回环）
	if ResourceLoader.exists("res://scripts/earth/earth_panel.gd"):
		_panel = preload("res://scripts/earth/earth_panel.gd").new()
		_panel.name = "EarthPanel"
		add_child(_panel)
		_panel.setup(_countries, _groups)
		_panel.country_selected.connect(_on_panel_country)
		_panel.group_selected.connect(_on_panel_group)
		if _selected >= 0:
			_panel.sync_selection(_selected_kind, _selected)
	_position_top_controls()


## 呈现模式行：[标签, 模式值]，与 apply_presentation 对应
const PRESENTATION_OPTIONS := [
	["模拟地图", "stylized"],
	["卫星影像", "satellite"],
	["政治区划", "political"],
	["人口着色", "population"],
	["经济着色", "gdp"],
]



func place_camera(lat: float, lon: float, dist: float) -> void:
	# 直接摆位（截图管线与测试用）：不缓动、不算自由观察
	facing_lat = lat
	facing_lon = lon
	distance = dist
	_apply()


func jump_preset(index: int, animated := true) -> void:
	# 机位跳转：注视点与距离缓动到位（命令动画；手动输入随时打断）
	_active_preset = index
	var target_lat := float(PRESETS[index][1])
	var target_lon := float(PRESETS[index][2])
	var target_dist := zoom_level_distance(int(PRESETS[index][3]))
	if not animated:
		place_camera(target_lat, target_lon, target_dist)
		return
	_animate_to(target_lat, target_lon, target_dist)


func _animate_to(lat: float, lon: float, dist: float) -> void:
	# 注视点与距离缓动（机位跳转与国家定位共用）；经度走最短路径
	if _tween != null and _tween.is_valid():
		_tween.kill()
	lon = facing_lon + wrapf(lon - facing_lon, -180.0, 180.0)
	_tween = create_tween().set_parallel(true).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_tween.tween_property(self, "facing_lat", lat, JUMP_DURATION)
	_tween.tween_property(self, "facing_lon", lon, JUMP_DURATION)
	_tween.tween_property(self, "distance", dist, JUMP_DURATION)
	# 相机变换随缓动逐帧应用（tween 只改注视属性，不自动摆相机）；
	# 缺此步画面静止不动，直到用户拖动触发 _apply 才瞬移到目标位
	_tween.chain().tween_callback(_apply)


func active_preset() -> int:
	return _active_preset


func selected_index() -> int:
	return _selected


func is_jumping() -> bool:
	# 机位缓动进行中（测试轮询用；手动输入随时打断）
	return _tween != null and _tween.is_valid() and _tween.is_running()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mouse := event as InputEventMouseButton
		match mouse.button_index:
			MOUSE_BUTTON_LEFT:
				# 松手即停：拖动是逐事件直接映射，无速度状态
				_dragging = mouse.pressed
				if mouse.pressed:
					_begin_manual()
					_press_screen = mouse.position
					_press_time = Time.get_ticks_msec()
					if mouse.double_click:
						# 双击国家：旋转到正前方，缩放保持当前级别；单击仅选中
						if _countries != null:
							var idx := _pick_country(mouse.position)
							if idx >= 0:
								select_country(idx)
								face_country(idx)
				elif _is_tap(mouse.position, _press_screen, _press_time):
					_pick_at(mouse.position)
	elif event is InputEventMouseMotion:
		if _dragging:
			_rotate_by((event as InputEventMouseMotion).relative)
	elif event is InputEventScreenTouch:
		_handle_screen_touch(event as InputEventScreenTouch)
	elif event is InputEventScreenDrag:
		_handle_screen_drag(event as InputEventScreenDrag)


func _handle_screen_touch(touch: InputEventScreenTouch) -> void:
	if touch.pressed:
		_touch_points[touch.index] = touch.position
		_begin_manual()
		if _touch_points.size() == 2:
			_pinch_prev_dist = _pinch_distance()
			_touch_tap_index = -1  # 第二指落下：单指 tap 作废
		elif not _suppress_single:
			# 单指按下记 tap 候选（位置/时刻），松开时按位移与时长判定
			_touch_tap_index = touch.index
			_touch_tap_pos = touch.position
			_touch_tap_time = Time.get_ticks_msec()
	elif not touch.canceled and _touch_points.has(touch.index):
		_touch_points.erase(touch.index)
		if _touch_points.size() < 2:
			_pinch_prev_dist = 0.0
			# 捏合结束：吸附到最近的缩放级别
			distance = zoom_level_distance(level_of_distance(distance))
			_apply()
		# 双指捏合结束后，剩余手指需抬起再按下才恢复单指旋转，防跳变
		_suppress_single = _touch_points.size() >= 1
		if touch.index == _touch_tap_index:
			_touch_tap_index = -1
			if not _suppress_single and _is_tap(touch.position, _touch_tap_pos, _touch_tap_time):
				_pick_at(touch.position)
				# 触屏双击国家：旋转到正前方，缩放保持当前级别（与鼠标双击同语义）
				if _selected >= 0 and touch.position.distance_to(_last_tap_pos) <= DOUBLE_TAP_MOVEMENT \
						and Time.get_ticks_msec() - _last_tap_time <= DOUBLE_TAP_MSEC:
					face_country(_selected)
				_last_tap_pos = touch.position
				_last_tap_time = Time.get_ticks_msec()


func _handle_screen_drag(drag: InputEventScreenDrag) -> void:
	if not _touch_points.has(drag.index):
		return
	_touch_points[drag.index] = drag.position
	if _touch_points.size() == 2:
		var dist := _pinch_distance()
		if _pinch_prev_dist > 0.0 and dist > 0.0:
			# 触屏捏合：手势内连续，松手吸附级别
			_begin_manual()
			distance = clampf(distance * _pinch_prev_dist / dist, ZOOM_MIN_DISTANCE, ZOOM_MAX_DISTANCE)
			_apply()
		_pinch_prev_dist = dist
	elif _touch_points.size() == 1 and not _suppress_single:
		_rotate_by(drag.relative)  # 触屏单指拖动旋转


func _pinch_distance() -> float:
	var points: Array = _touch_points.values()
	if points.size() < 2:
		return 0.0
	return (points[0] as Vector2).distance_to(points[1] as Vector2)


func _is_tap(pos: Vector2, press_pos: Vector2, press_time: int) -> bool:
	# 点击判定：位移与时长都在阈值内（与拖动区分）
	if Time.get_ticks_msec() - press_time > TAP_MAX_MSEC:
		return false
	return pos.distance_to(press_pos) <= TAP_MAX_MOVEMENT


# ── 国家数据与选中（阶段二 国家选中）─────────────────────────────────

func _load_countries() -> void:
	_countries = preload("res://scripts/earth/countries.gd").load_data()
	if _countries == null:
		push_warning("国家数据加载失败：res://assets/data/countries.json")
	else:
		print("国家数据：%d 国" % _countries.count)
		_china_index = _countries.names.find("China")


func _load_groups() -> void:
	# 编组数据依赖国家索引解析，countries 加载失败则无编组
	if _countries == null:
		return
	_groups = preload("res://scripts/earth/groups.gd").load_data(_countries)
	if _groups == null:
		push_warning("编组数据加载失败：res://assets/data/groups.json")
	else:
		print("编组数据：%d 组" % _groups.count)


func _build_borders() -> void:
	# 国界描边：全部国家全部环按球面窄带（ribbon）成网格，白色半透细线
	if _countries == null:
		return
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in _countries.count:
		for polygon: Array in _countries.rings[i]:
			for ring: Array in polygon:
				_ribbon_ring(st, ring, BORDER_WIDTH, BORDER_RADIUS)
	# 十段线：DataV 的段线为细带状面，
	# 直接三角化填充（每段 <1.1°，弦高可忽略）；沿周长画窄带会成一串小方块
	for ring: Array in _countries.china_lines:
		_flat_fill_ring(st, ring, BORDER_RADIUS)
	_borders_mesh = _make_overlay_mesh(st, BORDER_COLOR, 0)
	add_child(_borders_mesh)


func select_country(index: int) -> void:
	# 选中国家：高亮重建 + 面板同步；-1 取消选中；不改缩放（对准由调用方驱动）；
	# 国家选中与编组多选互斥（清空编组）
	_selected = index
	_selected_kind = "country" if index >= 0 else ""
	_clear_groups()
	_rebuild_highlight()
	if _panel != null:
		_panel.sync_selection(_selected_kind, index)
	selection_changed.emit(index)


func select_group(index: int) -> void:
	# 选中编组（多选 toggle）：已在列表则移除，否则追加（按序取色彩列表颜色）；
	# -1 清除全部编组选中；与国家选中互斥
	_selected = -1
	if index < 0:
		_clear_groups()
		selection_changed.emit(-1)
		return
	if _groups != null and index >= _groups.count:
		return
	_selected_kind = "group"
	if _active_groups.has(index):
		_active_groups.erase(index)
	else:
		_active_groups.append(index)
	_rebuild_highlight()
	_sync_group_ui()
	selection_changed.emit(index)


func _clear_groups() -> void:
	_active_groups.clear()
	_sync_group_ui()


func _sync_group_ui() -> void:
	if _panel != null:
		_panel.sync_groups(_active_groups)


func selected_kind() -> String:
	return _selected_kind


func _on_panel_country(index: int) -> void:
	# 面板选国家：选中高亮 + 旋转对准，缩放保持当前级别（看小国用户自己放大）
	select_country(index)
	face_country(index)


func _on_panel_group(index: int) -> void:
	# 面板选编组：成员高亮 + 旋转对准区域，缩放保持当前级别
	select_group(index)
	face_group(index)


func is_panel_expanded() -> bool:
	# 设置面板打开位置的避让依据（国家面板展开时左移，不重叠）
	return _panel != null and _panel.is_expanded()


## 可见面板几何登记（面板布局技术决策：每个面板先算面积与位置，摆放保持互斥）。
## 收集当前所有可见 UI 面板的矩形，测试据此断言两两不相交；
## 新增常驻面板时必须在此登记，未登记的面板不允许上屏
func visible_panel_rects() -> Dictionary:
	var rects := {}
	if _hud != null:
		rects["slider"] = _hud._track_rect().merge(_hud._minus_rect()).merge(_hud._plus_rect())
		rects["hint"] = _hud.hint_rect()
	if _settings != null:
		rects["gear"] = _settings.icon_rect()
		if _settings.is_open():
			rects["settings_panel"] = _settings._panel_rect()
	if _panel != null:
		if _panel.is_expanded():
			rects["country_panel"] = Rect2(_panel.position, _panel.size)
		else:
			rects["panel_handle"] = _panel._handle_rect()
	if _legend != null and _legend.visible:
		rects["legend"] = _legend.bar_rect()
	return rects


## 两两不相交断言：返回第一个相交对（空串 = 全部互斥）
func first_rect_overlap(rects: Dictionary) -> String:
	var keys := rects.keys()
	for i in keys.size():
		for j in range(i + 1, keys.size()):
			var a: Rect2 = rects[keys[i]]
			var b: Rect2 = rects[keys[j]]
			if a.intersects(b):
				return "%s × %s" % [keys[i], keys[j]]
	return ""


func _toggle_country_panel() -> void:
	# 手风琴：先展开国家面板，再收设置（closed 信号触发的恢复发现面板已展开则不动作）
	if _panel == null:
		return
	if not _panel.is_expanded():
		_panel.toggle_collapsed()
	if _settings != null and _settings.has_method("close_panel"):
		_settings.close_panel()


func on_settings_opened() -> void:
	# 手风琴：设置面板打开时收起国家面板（互不遮挡）
	if _panel != null and _panel.is_expanded():
		_panel.toggle_collapsed()


func _on_settings_closed() -> void:
	# 设置面板收起后恢复国家面板：收起只为让位，不收走入口
	# （此前收起后仅剩右缘把手，用户面对空右缘即「面板消失」）
	if _panel != null and _panel.collapsed:
		_panel.toggle_collapsed()


const GROUP_GLOBAL_SPAN := 0.5  # 编组区域角半径阈值（弧度，约 28.6°）：超过切全球机位

func face_group(index: int) -> void:
	# 旋转对准编组区域：注视点缓动到成员质心；跨度超过阈值（五眼联盟、G20 这类
	# 跨好几个洲的编组）时切全球机位的距离才能看全，其余保持当前缩放级别
	if _groups == null or index < 0 or index >= _groups.count:
		return
	_active_preset = -1
	var centroid: Array = _groups.centroids[index]
	var dist := distance
	if _groups.spans[index] > GROUP_GLOBAL_SPAN:
		dist = zoom_level_distance(int(PRESETS[4][3]))
	_animate_to(centroid[1], centroid[0], dist)


func face_country(index: int) -> void:
	# 旋转对准国家：注视点缓动到质心，距离保持当前缩放级别不变
	# （切到小国由用户自己放大，双击不擅动缩放）
	if _countries == null or index < 0 or index >= _countries.count:
		return
	_active_preset = -1
	var centroid: Array = _countries.centroids[index]
	_animate_to(centroid[1], centroid[0], distance)


func _pick_at(screen_pos: Vector2) -> void:
	# 点击拾取：命中国家则选中，未命中（海洋/太空）则取消选中
	if _countries == null:
		return
	select_country(_pick_country(screen_pos))


func _pick_country(screen_pos: Vector2) -> int:
	# 射线与单位球求交 → 交点经纬度 → 点在多边形判定
	var origin := _camera.project_ray_origin(screen_pos)
	var dir := _camera.project_ray_normal(screen_pos)
	var b := origin.dot(dir)
	var c := origin.length_squared() - 1.0
	var disc := b * b - c
	if disc < 0.0:
		return -1
	var t := -b - sqrt(disc)
	if t < 0.0:
		return -1
	var hit := origin + dir * t
	var lat := rad_to_deg(asin(clampf(hit.y, -1.0, 1.0)))
	var lon := rad_to_deg(atan2(-hit.x, -hit.z))
	return _countries.find_country(lat, lon)


func _build_highlight_overlay() -> void:
	# 选中填充载体：整球遮罩 shader（mask.a × tint），未选中时 1×1 全透明遮罩
	var img := Image.create(1, 1, false, Image.FORMAT_RGBA8)
	img.set_pixel(0, 0, Color(0, 0, 0, 0))
	_empty_mask = ImageTexture.create_from_image(img)
	_highlight_overlay = MeshInstance3D.new()
	_highlight_overlay.name = "HighlightOverlay"
	var sphere := SphereMesh.new()
	sphere.radius = HIGHLIGHT_OVERLAY_RADIUS
	sphere.height = HIGHLIGHT_OVERLAY_RADIUS * 2.0
	sphere.radial_segments = 128
	sphere.rings = 64
	_highlight_overlay.mesh = sphere
	_highlight_material = ShaderMaterial.new()
	_highlight_material.shader = Shader.new()
	_highlight_material.shader.code = HIGHLIGHT_SHADER
	_highlight_material.set_shader_parameter("mask", _empty_mask)
	_highlight_material.set_shader_parameter("tint", SELECT_FILL_COLOR)
	if ResourceLoader.exists(TERRAIN_HEIGHT_PATH):
		_highlight_material.set_shader_parameter("height", load(TERRAIN_HEIGHT_PATH))
	_highlight_material.set_shader_parameter("max_displace", TERRAIN_MAX_DISPLACE)
	_highlight_overlay.material_override = _highlight_material
	_highlight_overlay.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_highlight_overlay)


func _rebuild_highlight() -> void:
	# 选中高亮重建：国家 = 单遮罩填充 + 成员描边（选中国时十段线随描边高亮，
	# 中国标准地图要素）；编组多选 = 每编组独立 overlay（遮罩 + 描边，按序取色）
	var mask: Texture2D = _empty_mask
	var path := ""
	if _selected_kind == "country" and _selected >= 0:
		path = MASK_PATH_COUNTRY % _selected
	if path != "" and ResourceLoader.exists(path):
		mask = load(path)
	_highlight_material.set_shader_parameter("mask", mask)
	for child in _group_overlays.values():
		for mesh in child.values():
			mesh.queue_free()
	_group_overlays.clear()
	if _stroke_mesh != null:
		_stroke_mesh.queue_free()
	_stroke_mesh = null
	if _countries == null:
		return
	# 国家描边（选中国时附加十段线）
	if _selected >= 0:
		var stroke_st := SurfaceTool.new()
		stroke_st.begin(Mesh.PRIMITIVE_TRIANGLES)
		for polygon: Array in _countries.rings[_selected]:
			for ring: Array in polygon:
				_ribbon_ring(stroke_st, ring, SELECT_STROKE_WIDTH, SELECT_STROKE_RADIUS)
		if _selected == _china_index:
			for ring: Array in _countries.china_lines:
				_ribbon_ring(stroke_st, ring, SELECT_STROKE_WIDTH, SELECT_STROKE_RADIUS)
		_stroke_mesh = _make_overlay_mesh(stroke_st, SELECT_STROKE_COLOR, 2)
		add_child(_stroke_mesh)
	# 编组多选：每编组独立填充 overlay（遮罩 shader 逐实例 tint）+ 描边
	for order in _active_groups.size():
		var group_index: int = _active_groups[order]
		var color: Color = GROUP_COLORS[order % GROUP_COLORS.size()]
		var overlays := {}
		var mask_path := MASK_PATH_GROUP % group_index
		if ResourceLoader.exists(mask_path):
			var fill_mesh := MeshInstance3D.new()
			fill_mesh.name = "GroupFill%d" % group_index
			var sphere := SphereMesh.new()
			sphere.radius = HIGHLIGHT_OVERLAY_RADIUS
			sphere.height = HIGHLIGHT_OVERLAY_RADIUS * 2.0
			sphere.radial_segments = 128
			sphere.rings = 64
			fill_mesh.mesh = sphere
			var material := _highlight_material.duplicate()
			material.set_shader_parameter("mask", load(mask_path))
			material.set_shader_parameter("tint", Color(color.r, color.g, color.b, SELECT_FILL_COLOR.a))
			fill_mesh.material_override = material
			fill_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			add_child(fill_mesh)
			overlays["fill"] = fill_mesh
		var stroke_st := SurfaceTool.new()
		stroke_st.begin(Mesh.PRIMITIVE_TRIANGLES)
		for index in _groups.members[group_index]:
			if index < 0 or index >= _countries.count:
				continue
			for polygon: Array in _countries.rings[index]:
				for ring: Array in polygon:
					_ribbon_ring(stroke_st, ring, SELECT_STROKE_WIDTH, SELECT_STROKE_RADIUS)
		var stroke := _make_overlay_mesh(stroke_st, Color(color.r, color.g, color.b, SELECT_STROKE_COLOR.a), 2)
		overlays["stroke"] = stroke
		add_child(stroke)
		_group_overlays[group_index] = overlays


func _make_overlay_mesh(st: SurfaceTool, color: Color, priority: int) -> MeshInstance3D:
	# 叠加网格通用收尾：自绘无光照、双面、半透、无阴影，render_priority 控层序
	var mesh_instance := MeshInstance3D.new()
	mesh_instance.name = "CountryOverlay%d" % priority
	mesh_instance.mesh = st.commit()
	mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = color
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.render_priority = priority
	mesh_instance.material_override = material
	return mesh_instance


func _ribbon_ring(st: SurfaceTool, ring: Array, width: float, radius: float) -> void:
	# 环 → 球面窄带网格：长边按 2° 细分（弦高远小于抬升量，不陷入球面）
	var n := ring.size()
	if n < 3:
		return
	var half := width * 0.5
	for i in n:
		var p0: Vector3 = latlon_to_dir(ring[i][1], ring[i][0])
		var p1: Vector3 = latlon_to_dir(ring[(i + 1) % n][1], ring[(i + 1) % n][0])
		var steps := maxi(1, ceili(p0.angle_to(p1) / RIBBON_STEP_RAD))
		var prev := p0
		for s in steps:
			var nxt := p0.lerp(p1, float(s + 1) / steps).normalized()
			_ribbon_segment(st, prev, nxt, half, radius)
			prev = nxt


func _flat_fill_ring(st: SurfaceTool, ring: Array, radius: float) -> void:
	# 小环平面三角化填充（顶点直接投影球面）：仅用于十段线细带这类小环
	if ring.size() < 3:
		return
	var points := PackedVector2Array()
	for p in ring:
		points.append(Vector2(p[0], p[1]))
	var triangles: PackedInt32Array = Geometry2D.triangulate_polygon(points)
	for t in range(0, triangles.size(), 3):
		for k in 3:
			var vertex: Vector2 = points[triangles[t + k]]
			st.add_vertex(latlon_to_dir(vertex.y, vertex.x) * radius)


func _ribbon_segment(st: SurfaceTool, a: Vector3, b: Vector3, half: float, radius: float) -> void:
	# 单段窄带：中线切向侧移 ±half 抬升到 radius，双三角形（双面材质不关心绕序）
	var mid := ((a + b) * 0.5).normalized()
	var side := (b - a).cross(mid)
	if side.length() < 1e-9:
		return
	side = side.normalized()
	var a_minus := (a - side * half).normalized() * radius
	var a_plus := (a + side * half).normalized() * radius
	var b_minus := (b - side * half).normalized() * radius
	var b_plus := (b + side * half).normalized() * radius
	st.add_vertex(a_minus)
	st.add_vertex(b_plus)
	st.add_vertex(a_plus)
	st.add_vertex(a_minus)
	st.add_vertex(b_minus)
	st.add_vertex(b_plus)


func _begin_manual() -> void:
	# 手动输入打断机位跳转，进入自由观察
	if _tween != null and _tween.is_valid():
		_tween.kill()
	if _active_preset != -1:
		_active_preset = -1


func _rotate_by(relative: Vector2) -> void:
	# 跟手旋转：每像素转角 = 视场角 / 视口高，
	# 注视点在屏幕中心处表面严格跟随指针；拖右地图右移、拖下地图下移
	var deg_per_px := FOV_DEG / get_viewport().get_visible_rect().size.y
	facing_lon -= relative.x * deg_per_px
	facing_lat = clampf(facing_lat + relative.y * deg_per_px, -MAX_LAT, MAX_LAT)
	_apply()


func zoom_level_distance(level: float) -> float:
	# 级 1 = 最远（全球），级 10 = 最近（贴地）；线性等距
	var t := clampf((level - 1.0) / float(ZOOM_LEVELS - 1), 0.0, 1.0)
	return lerpf(ZOOM_MAX_DISTANCE, ZOOM_MIN_DISTANCE, t)


func level_of_distance(d: float) -> int:
	# 距离 → 最近级别（1..10）
	var best := 1
	var best_err := INF
	for lv in range(1, ZOOM_LEVELS + 1):
		var err := absf(zoom_level_distance(lv) - d)
		if err < best_err:
			best_err = err
			best = lv
	return best


func set_zoom_level(level: int) -> void:
	# 缩放滑块输入（10 级）
	_begin_manual()
	distance = zoom_level_distance(clampi(level, 1, ZOOM_LEVELS))
	_apply()


func zoom_level() -> int:
	return level_of_distance(distance)


func _apply() -> void:
	_camera.position = latlon_to_dir(facing_lat, facing_lon) * distance
	_camera.look_at(Vector3.ZERO, Vector3.UP)


## 经纬度（度）→ 单位方向：北纬为正、东经为正，北极限 +Y。
## 在本初子午线上本地正东 = -X，与场景坐标技术决策的罗盘方位一致
static func latlon_to_dir(lat_deg: float, lon_deg: float) -> Vector3:
	var lat := deg_to_rad(lat_deg)
	var lon := deg_to_rad(lon_deg)
	return Vector3(-cos(lat) * sin(lon), sin(lat), -cos(lat) * cos(lon))


func apply_map_style(style: String) -> void:
	# 兼容旧入口：贴图切换并入呈现模式体系
	apply_presentation(style)


func apply_presentation(mode: String) -> void:
	# 呈现模式就地切换：
	# stylized 模拟地图 / satellite 卫星影像 / political 政治区划 /
	# population 人口着色 / gdp 经济着色；政区与数据着色为预生成整张底图
	# （tools/make_overlays.py），切换即换贴图，场景不重载
	presentation_mode = mode
	map_style = "satellite" if mode == "satellite" else "stylized"
	if _settings != null:
		_settings.value = mode  # 设置面板高亮随就地切换同步
	if _globe == null:
		return
	var material: StandardMaterial3D = _globe.material_override
	var path := STYLIZED_TEXTURE_PATH
	if mode == "satellite":
		path = SATELLITE_TEXTURE_PATH
	elif mode == "political":
		path = POLITICAL_TEXTURE_PATH
	elif mode == "population":
		path = POPULATION_TEXTURE_PATH
	elif mode == "gdp":
		path = GDP_TEXTURE_PATH
	material.albedo_texture = load(path)
	if _legend != null:
		_legend.set_mode(mode)


func _build_labels() -> void:
	# 国家名标签地图上显示国家名称，白色文本：
	# Label3D 广告牌置于质心上方，白字暗描边；远侧被球体深度遮挡；
	# 显隐 LOD 见 _process
	if _countries == null:
		return
	var font := SystemFont.new()
	font.font_names = PackedStringArray(["PingFang SC", "Hiragino Sans GB", "STHeiti", "Arial Unicode MS"])
	for i in _countries.count:
		var label := Label3D.new()
		label.text = _label_name(str(_countries.names_zh[i]))
		label.font = font
		label.font_size = 36
		label.pixel_size = 0.0007
		label.modulate = Color.WHITE
		label.outline_size = 10
		label.outline_modulate = Color(0.05, 0.06, 0.08, 0.7)
		label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		label.no_depth_test = false
		label.render_priority = 3
		var centroid: Array = _countries.centroids[i]
		# 标签随地形抬升：质心高程 + 基础抬升，避免标签沉入高海拔山体
		label.position = latlon_to_dir(centroid[1], centroid[0]) * (LABEL_RADIUS + _terrain_height_at(centroid[1], centroid[0]) / TERRAIN_MAX_ELEV * TERRAIN_MAX_DISPLACE)
		add_child(label)
		_labels.append(label)


func _label_name(full_name: String) -> String:
	# 地图标签用简称（全名过长会在图上相互压盖），面板保持全名
	if LABEL_SHORT_NAMES.has(full_name):
		return LABEL_SHORT_NAMES[full_name]
	for suffix in ["民主主义人民共和国", "人民共和国", "联邦共和国", "伊斯兰共和国", "共和国"]:
		if full_name.ends_with(suffix) and full_name.length() > suffix.length() + 1:
			return full_name.trim_suffix(suffix)
	return full_name


func _go_scene_picker() -> void:
	if not ResourceLoader.exists("res://scenes/scene_picker.tscn"):
		return
	# 设置面板「返回场景选择」行
	get_tree().change_scene_to_file("res://scenes/scene_picker.tscn")


func _set_fullscreen(on: bool) -> void:
	# 设置面板全屏开关：开 = 无边框全屏，关 = 最大化窗口
	get_window().mode = Window.MODE_FULLSCREEN if on else Window.MODE_MAXIMIZED


func _position_top_controls() -> void:
	# 左上控制排：滑块胶囊左缘 72
	if _hud != null:
		_hud.set_slider_origin(82.0)


func _process(_delta: float) -> void:
	# 相机变换随缓动逐帧应用（兜底层：与 _animate_to 的结束回调双保险）
	if _tween != null and _tween.is_valid() and _tween.is_running():
		_apply()
	# 国家名标签 LOD：屏幕上角半径不足阈值时隐藏（拉近渐次显现小国）；
	# 注视点边缘（点积 0.42→0.62）标签透视压缩渐隐，避免边缘文字堆叠
	if _labels.is_empty() or _camera == null:
		return
	var viewport_h := get_viewport().get_visible_rect().size.y
	var px_per_rad := viewport_h / deg_to_rad(FOV_DEG)
	var surface_dist := maxf(distance - 1.0, 0.12)
	var camera_dir := _camera.global_position.normalized()
	for i in _labels.size():
		var label := _labels[i] as Label3D
		var dot: float = camera_dir.dot(label.position.normalized())
		var fade := clampf((dot - 0.42) / 0.20, 0.0, 1.0)
		var size_ok: bool = _countries.ang_radii[i] * px_per_rad / surface_dist >= LABEL_MIN_PX
		label.visible = size_ok and fade > 0.0
		label.modulate = Color(1.0, 1.0, 1.0, fade)


func _build_environment() -> void:
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = BACKDROP_COLOR
	# 环境光满照：地图模式整球均匀可见（学习用途，不做昼夜明暗面）
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color.WHITE
	environment.ambient_light_energy = 1.0
	var world_environment := WorldEnvironment.new()
	world_environment.environment = environment
	add_child(world_environment)


func _build_backdrop() -> void:
	# 白色丝绸幕布星空背景致晕，改丝绸幕布：
	# 程序化丝绸贴图置天球内侧，任意机位角度背后都是幕布；无外部素材
	var mesh_instance := MeshInstance3D.new()
	mesh_instance.name = "SilkBackdrop"
	var sphere := SphereMesh.new()
	sphere.radius = 60.0
	sphere.height = 120.0
	mesh_instance.mesh = sphere
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_texture = load(BACKDROP_PATH)
	material.cull_mode = BaseMaterial3D.CULL_FRONT  # 站在天球内侧看内壁
	material.roughness = 1.0
	mesh_instance.material_override = material
	mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mesh_instance)


func _load_terrain() -> void:
	# 直读原 PNG（绕过导入系统）：高程是数值数据，detect_3d 自动转 VRAM 压缩后
	# get_pixel 会读到垃圾值，表现为顶点飞出数个身位的放射撕裂
	var path := ProjectSettings.globalize_path(TERRAIN_HEIGHT_PATH)
	if FileAccess.file_exists(path):
		_terrain_height = Image.load_from_file(path)
		print("高程贴图：%d×%d 格式 %d" % [_terrain_height.get_width(), _terrain_height.get_height(), _terrain_height.get_format()])


func _terrain_height_at(lat_deg: float, lon_deg: float) -> float:
	# 双线性采样高程（米）；贴图缺失或海洋返回 0
	if _terrain_height == null:
		return 0.0
	var w := float(_terrain_height.get_width())
	var h := float(_terrain_height.get_height())
	var x := fposmod(lon_deg + 180.0, 360.0) / 360.0 * w - 0.5
	var y := (90.0 - lat_deg) / 180.0 * h - 0.5
	var x0 := int(floor(x))
	var y0 := int(floor(y))
	var fx := x - float(x0)
	var fy := y - float(y0)
	var h00 := _terrain_raw(x0, y0)
	var h10 := _terrain_raw(x0 + 1, y0)
	var h01 := _terrain_raw(x0, y0 + 1)
	var h11 := _terrain_raw(x0 + 1, y0 + 1)
	return lerp(lerp(h00, h10, fx), lerp(h01, h11, fx), fy)


func _terrain_raw(x: int, y: int) -> float:
	var w := _terrain_height.get_width()
	var h := _terrain_height.get_height()
	var c := _terrain_height.get_pixel((x + w) % w, clampi(y, 0, h - 1))
	return (c.r8 * 256.0 + c.g8) / 65535.0 * TERRAIN_MAX_ELEV


func _displaced(pos: Vector3) -> Vector3:
	# 单位方向 → 随地形抬升的位置（20 倍夸张，海洋齐平球面）
	var lat := rad_to_deg(asin(clampf(pos.y, -1.0, 1.0)))
	var lon := rad_to_deg(atan2(-pos.x, -pos.z))
	return pos * (1.0 + _terrain_height_at(lat, lon) / TERRAIN_MAX_ELEV * TERRAIN_MAX_DISPLACE)


func _build_globe() -> void:
	# 位移球体：自建经纬参数网格（经纬由构造已知，UV 手动对齐底图，无接缝歧义），
	# 每顶点沿方向按高程贴图抬升（CPU 一次构建，性能暂不考虑）
	_globe = MeshInstance3D.new()
	_globe.name = "Globe"
	var material := StandardMaterial3D.new()
	material.albedo_texture = load(STYLIZED_TEXTURE_PATH if map_style == "stylized" else SATELLITE_TEXTURE_PATH)
	material.roughness = 1.0
	material.metallic = 0.0
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	if TEXTURE_FLIP_V:
		material.uv1_scale = Vector3(1.0, -1.0, 1.0)
		material.uv1_offset = Vector3(0.0, 1.0, 0.0)
	_globe.material_override = material
	_globe.rotation.y = deg_to_rad(TEXTURE_YAW_DEG)
	_globe.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var cols := GLOBE_SEGMENTS + 1
	var rows := GLOBE_SEGMENTS / 2 + 1
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	verts.resize(cols * rows)
	normals.resize(cols * rows)
	uvs.resize(cols * rows)
	# 高度查表走字节缓冲（get_data 直读 RGB 三元组，get_pixel 每次调用的
	# 绑定开销会让 13 万顶点构建拖到分钟级）
	var height_bytes := _terrain_height.get_data() if _terrain_height != null else PackedByteArray()
	var height_w := float(_terrain_height.get_width()) if _terrain_height != null else 1.0
	var height_h := float(_terrain_height.get_height()) if _terrain_height != null else 1.0
	var has_terrain := _terrain_height != null
	for r in rows:
		var lat := 90.0 - float(r) / float(rows - 1) * 180.0
		var y_raw := (90.0 - lat) / 180.0 * height_h - 0.5
		var y0 := clampi(int(floor(y_raw)), 0, int(height_h) - 1)
		var y1 := clampi(y0 + 1, 0, int(height_h) - 1)
		var fy := clampf(y_raw - float(y0), 0.0, 1.0)
		for c in cols:
			var lon := -180.0 + float(c) / float(cols - 1) * 360.0
			var dir := latlon_to_dir(lat, lon)
			var h := 0.0
			if has_terrain:
				var x_raw := fposmod(lon + 180.0, 360.0) / 360.0 * height_w - 0.5
				var x0 := int(floor(x_raw))
				var fx := clampf(x_raw - float(x0), 0.0, 1.0)
				var xa := posmod(x0, int(height_w))
				var xb := posmod(x0 + 1, int(height_w))
				var h00 := float(height_bytes[(y0 * int(height_w) + xa) * 3]) * 256.0 + float(height_bytes[(y0 * int(height_w) + xa) * 3 + 1])
				var h10 := float(height_bytes[(y0 * int(height_w) + xb) * 3]) * 256.0 + float(height_bytes[(y0 * int(height_w) + xb) * 3 + 1])
				var h01 := float(height_bytes[(y1 * int(height_w) + xa) * 3]) * 256.0 + float(height_bytes[(y1 * int(height_w) + xa) * 3 + 1])
				var h11 := float(height_bytes[(y1 * int(height_w) + xb) * 3]) * 256.0 + float(height_bytes[(y1 * int(height_w) + xb) * 3 + 1])
				h = (lerp(lerp(h00, h10, fx), lerp(h01, h11, fx), fy) / 65535.0) * TERRAIN_MAX_ELEV
			var raised := dir * (1.0 + h / TERRAIN_MAX_ELEV * TERRAIN_MAX_DISPLACE)
			var i := r * cols + c
			verts[i] = raised
			normals[i] = dir
			uvs[i] = Vector2(float(c) / float(cols - 1), float(r) / float(rows - 1))
	var indices := PackedInt32Array()
	indices.resize((rows - 1) * (cols - 1) * 6)
	var idx := 0
	for r in rows - 1:
		for c in cols - 1:
			var a := r * cols + c
			var b := a + 1
			var d := a + cols
			var e := d + 1
			indices[idx] = a
			indices[idx + 1] = d
			indices[idx + 2] = e
			indices[idx + 3] = a
			indices[idx + 4] = e
			indices[idx + 5] = b
			idx += 6
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	var displaced := ArrayMesh.new()
	displaced.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	_globe.mesh = displaced
	add_child(_globe)
