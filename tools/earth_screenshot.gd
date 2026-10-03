extends Node
## 开发工具：按地球机位表截图，输出到 project-godot/screenshots/（git 忽略）。
## 运行：pnpm shots-earth（等价 godot --path . --position -3200,-3200 res://tools/earth_screenshot.tscn）
## asia-close 为诊断机位
## （国家级近距离核对纹理对准与清晰度，不属于机位表）；china-select 评审选中
## 高亮与右侧面板（选中中国，不缩放）。

# 距离为缩放级别值（10 级制）：1.12/1.56/1.99/2.42/2.85/3.28/3.71/4.14/4.57/5.0
const SHOTS := [
	["asia", 35.0, 105.0, 1.99, "", "stylized"],
	["asia-close", 30.0, 110.0, 1.56, "", "stylized"],
	["europe", 48.0, 15.0, 1.99, "", "stylized"],
	["americas", 12.0, -85.0, 2.85, "", "stylized"],
	["global", 22.0, 105.0, 3.28, "", "stylized"],
	["china-select", 30.0, 105.0, 2.42, "China", "stylized"],
	["global-satellite", 22.0, 105.0, 3.28, "", "satellite"],
	["nato-select", 50.0, 10.0, 4.57, "", "stylized", "北约"],
	["political", 22.0, 105.0, 3.28, "", "political"],
	["population", 22.0, 105.0, 3.28, "", "population"],
]


func _ready() -> void:
	# 静默截图：窗口移出所有屏幕并无边框，全程不出现可见窗口
	preload("res://tools/silent_window.gd").apply(get_window())
	var earth: Node3D = load("res://scenes/earth.tscn").instantiate()
	add_child(earth)
	# 机位截图含 HUD 与最大化按钮（force 注入，同 headless 测试先例），
	# 与用户实际画面一致便于评审
	earth._create_ui(true)
	# 等待卫星影像加载与首帧渲染
	await get_tree().create_timer(1.0).timeout
	await get_tree().process_frame
	await get_tree().process_frame
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://screenshots"))
	for shot in SHOTS:
		earth.apply_presentation(shot[5])
		earth.place_camera(shot[1], shot[2], shot[3])
		earth.select_country(-1)
		if shot[4] != "" and earth._countries != null:
			var index: int = earth._countries.names.find(shot[4])
			earth.select_country(index)
		elif shot.size() > 6 and shot[6] != "" and earth._groups != null:
			earth.select_group(earth._groups.names.find(shot[6]))
		# 屏外窗口常规 draw 停发（见 tools/silent_window.gd 头注）：相机放置后先过
		# process 帧让变换提交到渲染侧，再无交换强制渲染到离屏 target 后读图
		await get_tree().process_frame
		RenderingServer.force_draw(false)
		var image := get_viewport().get_texture().get_image()
		var output := ProjectSettings.globalize_path("res://screenshots/earth-%s.png" % shot[0])
		image.save_png(output)
		print("saved earth-", shot[0])
	# UI 状态诊断截图（面板布局评审）：设置面板展开行序 + 选中页签维度下拉勾选态
	earth.apply_presentation("stylized")
	earth.select_country(-1)
	var settings: Control = earth.get_node("EarthSettings")
	var panel: Control = earth.get_node("EarthPanel")
	settings.open_panel()
	earth.on_settings_opened()  # 手风琴：设置展开同时收起国家面板（右缘剩圆形把手）
	for i in 240:
		if not panel._panel_margins.visible:
			break
		await get_tree().process_frame
	earth.place_camera(35.0, 105.0, 1.99)
	await get_tree().process_frame
	await get_tree().process_frame
	RenderingServer.force_draw(false)
	get_viewport().get_texture().get_image().save_png(ProjectSettings.globalize_path("res://screenshots/earth-ui-settings.png"))
	print("saved earth-ui-settings")
	settings.close_panel()  # 收设置后面板自动恢复展开
	for i in 240:
		if panel.position.x <= 1289.0:
			break
		await get_tree().process_frame
	panel._tabs.set_active(1)
	if earth._groups != null:
		earth.select_group(earth._groups.names.find("欧洲"))
	earth._begin_manual()
	earth.place_camera(35.0, 105.0, 1.99)
	await get_tree().process_frame
	await get_tree().process_frame
	RenderingServer.force_draw(false)
	get_viewport().get_texture().get_image().save_png(ProjectSettings.globalize_path("res://screenshots/earth-ui-select-tab.png"))
	print("saved earth-ui-select-tab")
	# 弹层打开态：大洲下拉展开，弹层列表可见（回归弹层绘制坐标）
	panel._continent_select.open_panel()
	await get_tree().process_frame
	await get_tree().process_frame
	RenderingServer.force_draw(false)
	var popup_img := get_viewport().get_texture().get_image()
	print("popup_rect=", panel._continent_select._panel_rect(), " px_in=", popup_img.get_pixel(1445, 95), " px_below=", popup_img.get_pixel(1445, 130))
	popup_img.save_png(ProjectSettings.globalize_path("res://screenshots/earth-ui-select-popup.png"))
	print("saved earth-ui-select-popup")
	get_tree().quit()
