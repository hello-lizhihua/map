extends Object
## 窗口启动状态：用户面对的场景（场景选择/房间/地球）
## 启动即最大化占满整个屏幕，保留系统标题栏；右上角最大化按钮负责切换无边框全屏。
## 工具场景（截图/对比/预览）不调用，保持 1600×900 出图尺寸与基线一致。
##
## 内容缩放：全部界面按 1600×900 设计分辨率绘制，窗口实际更大时按高度等比放大
## （content_scale CANVAS_ITEMS + EXPAND），否则固定像素字号在大屏上小得不可读；
## 缩放因子随窗口尺寸变化自动重算。1600×900 工具窗口因子恰为 1，出图不变。

const DESIGN_SIZE := Vector2(1600, 900)


## 主场景 _ready（current_scene 门控内）调用：窗口模式时置为最大化并铺内容缩放
static func apply_maximized(window: Window) -> void:
	if window.mode == Window.MODE_WINDOWED:
		window.mode = Window.MODE_MAXIMIZED
	_apply_content_scale(window)
	if not window.size_changed.is_connected(_apply_content_scale):
		window.size_changed.connect(_apply_content_scale.bind(window))


static func _apply_content_scale(window: Window) -> void:
	# 按高度等比：文字/控件与窗口高度同步放大，宽度随宽高比自由扩展
	# （超宽屏下面板垂直空间不缩水）；1600×900 工具窗口因子恰为 1
	var factor: float = window.size.y / DESIGN_SIZE.y
	window.content_scale_mode = Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
	window.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_EXPAND
	window.content_scale_size = Vector2i(DESIGN_SIZE)
	window.content_scale_factor = factor
