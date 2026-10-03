extends Object
## 静默窗口共享工具：智能体的截图/预览/对比/探针/测试等
## 一切非用户发起的运行，一律在代码层强制「离屏 + 无边框」，不依赖启动参数；
## dev（主场景正常运行，无标志位）不调用本工具，窗口保持可见。
##
## 用法（工具场景 _ready 首行 / 测试脚本 _run 首行）：
##   preload("res://tools/silent_window.gd").apply(get_window())
##
## 实测要点（macOS/Metal）：完全屏外窗口会被系统判定遮挡、常规 draw 停发，
## 调用方须以 RenderingServer.force_draw(false)（无交换渲染离屏 target）出图，
## 且相机/节点放置后先 await process_frame 让变换提交再出帧。

const OFFSCREEN_MARGIN := 100


## 将窗口移出所有屏幕可用区并去边框；打印一行屏外断言供运行核验
static func apply(window: Window) -> void:
	# 工具运行与用户场景互不干扰：先复位窗口模式（最大化/全屏下 position 不生效），
	# 用户场景启动最大化由 app_window.gd 负责，工具窗口保持 1600×900 出图尺寸
	window.mode = Window.MODE_WINDOWED
	window.borderless = true
	# 取所有屏幕可用区（usable rect）的最小原点，向外再退一个窗口尺寸 + 余量：
	# 窗口矩形与任一屏幕可用区都不相交，任意显示器排布下均成立
	var min_x := 0
	var min_y := 0
	for i in DisplayServer.get_screen_count():
		var usable := DisplayServer.screen_get_usable_rect(i)
		min_x = mini(min_x, usable.position.x)
		min_y = mini(min_y, usable.position.y)
	window.position = Vector2i(
		min_x - window.size.x - OFFSCREEN_MARGIN,
		min_y - window.size.y - OFFSCREEN_MARGIN
	)
	var applied := DisplayServer.window_get_position()
	print("[静默] 窗口 pos=", applied, " size=", window.size, " 屏外=", _is_offscreen(applied, window.size), " 无边框=", window.borderless)


## 断言窗口矩形不与任何屏幕可用区相交
static func _is_offscreen(pos: Vector2i, size: Vector2i) -> bool:
	var window_rect := Rect2i(pos, size)
	for i in DisplayServer.get_screen_count():
		if window_rect.intersects(DisplayServer.screen_get_usable_rect(i)):
			return false
	return true
