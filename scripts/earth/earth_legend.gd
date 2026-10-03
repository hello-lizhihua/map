extends Control
## 数据着色图例（阶段四 学习增强）：左下渐变条 + 端值标签，仅分级统计模式
## （人口着色 / 经济着色）可见；政区覆色色的低值 → 高值与 earth.gd 保持同色。
## 文本色取 godot-element-plus 设计令牌提示色（浅幕布上深色主体 + 浅色描影）。

const UITheme := preload("res://addons/godot-element-plus/theme/theme.gd")

const BAR_SIZE := Vector2(220.0, 10.0)
const BAR_MARGIN := Vector2(20.0, 70.0)  # 距左下角：端值标签下缘让开操作提示行（y 864 起）

const RAMP_LOW := Color(1.0, 0.96, 0.78)
const RAMP_HIGH := Color(0.62, 0.13, 0.08)

var _mode := "stylized"
var _pop_max := 0
var _gdp_max := 0
var _font: SystemFont


func _ready() -> void:
	_font = UITheme.system_font()
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false
	queue_redraw()


func setup(countries: RefCounted) -> void:
	# 注入国家数据取端值（图例只标最大端，低端恒为 0）
	if countries == null:
		return
	for value in countries.pops:
		_pop_max = maxi(_pop_max, int(value))
	for value in countries.gdps:
		_gdp_max = maxi(_gdp_max, int(value))


func set_mode(mode: String) -> void:
	_mode = mode
	visible = mode == "population" or mode == "gdp"
	queue_redraw()


## 图例矩形（面板几何登记用：标题上缘到端值标签下缘的外接）
func bar_rect() -> Rect2:
	var size := get_viewport_rect().size
	var origin := Vector2(BAR_MARGIN.x, size.y - BAR_MARGIN.y)
	return Rect2(origin + Vector2(0.0, -24.0), Vector2(BAR_SIZE.x, BAR_SIZE.y + 42.0))


func _draw() -> void:
	if not visible:
		return
	var size := get_viewport_rect().size
	var origin := Vector2(BAR_MARGIN.x, size.y - BAR_MARGIN.y)
	# 标题
	var title := "人口" if _mode == "population" else "经济总量（GDP）"
	_draw_text(origin + Vector2(0.0, -8.0), title, 12)
	# 渐变条：24 段近似连续渐变
	var slices := 24
	for i in slices:
		var t := float(i) / float(slices - 1)
		draw_rect(
			Rect2(origin + Vector2(BAR_SIZE.x * t, 0.0), Vector2(BAR_SIZE.x / slices + 1.0, BAR_SIZE.y)),
			RAMP_LOW.lerp(RAMP_HIGH, t)
		)
	# 端值：低恒 0，高按模式格式化
	_draw_text(origin + Vector2(0.0, BAR_SIZE.y + 16.0), "0", 11)
	var max_text := ""
	if _mode == "population":
		max_text = "%.1f亿人" % (float(_pop_max) / 100000000.0)
	else:
		max_text = "%.0f万亿美元" % (float(_gdp_max) / 1000000.0)
	_draw_text(origin + Vector2(BAR_SIZE.x, BAR_SIZE.y + 16.0), max_text, 11)


func _draw_text(pos: Vector2, text: String, font_size: int) -> void:
	# 深色主体 + 浅色描影（丝绸浅背景上可读），色取设计令牌提示色
	draw_string(_font, pos + Vector2(1.0, 1.0), text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, UITheme.HINT_HALO)
	draw_string(_font, pos, text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, UITheme.HINT_COLOR)
