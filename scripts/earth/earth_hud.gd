extends Control
## 地球 HUD：左下缩放滑块（ElementSlider，10 级）+ 操作提示小字。机位入口在右侧
## 国家面板第一排筛选。滑块组件自命中、自绘制、自消费；
## 本层负责提示文本绘制与缩放级别回推（机位跳转/双击定位/捏合吸附后刷新滑块）。

const UITheme := preload("res://addons/godot-element-plus/theme/theme.gd")

## earth 注入：读取缩放级别回推滑块
var main_node: Node = null
var _slider: Control  # ElementSlider（路径预加载，避免全局类缓存依赖）
var _font: SystemFont
var _slider_level := 0  # 上次回推的级别（变化才刷新）


func _ready() -> void:
	_font = UITheme.system_font()
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_slider = preload("res://addons/godot-element-plus/slider/slider.gd").new()
	add_child(_slider)
	# 缩放滑块移至右上角按钮排（slider → 地图类型 → 设置 → 全屏）：
	# 轨道中线 y=40 与图标按钮同排；右缘对齐值由 earth 按地图按钮宽度回填
	_slider.track_width = 88.0
	_slider.top_y = 40.0
	_slider.origin_x = 72.0
	# 滑块用户输入（轨道点击/拖动/＋− 步进）驱动缩放；同级别操作也回传，
	# 供 earth 打断机位跳转的命令动画
	_slider.value_changed.connect(func(level: int):
		if main_node != null:
			main_node.set_zoom_level(level))
	queue_redraw()


## 左上控制排对齐：滑块胶囊左缘位置（earth 初始化时回填一次）
func set_slider_origin(origin_left: float) -> void:
	_slider.origin_x = origin_left


func _process(_delta: float) -> void:
	# 缩放级别变化（机位跳转/双击定位/捏合吸附）时回推滑块
	if main_node != null:
		var level: int = main_node.zoom_level()
		if level != _slider_level:
			_slider_level = level
			_slider.set_value(level)


# ── 缩放滑块命中区（视口坐标，测试与截图管线契约）──────────────────


func _track_rect() -> Rect2:
	return _slider._track_rect()


func _minus_rect() -> Rect2:
	return _slider._minus_rect()


func _plus_rect() -> Rect2:
	return _slider._plus_rect()

