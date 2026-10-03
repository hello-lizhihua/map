extends SceneTree
## headless 地球自检：机位数学、拖动跟手与松手即停、缩放与钳制、机位跳转、
## 触屏捏合。输入经 Input.parse_input_event 真实事件路径注入。
## 运行：godot --headless --path . -s res://tests/earth_test.gd

var errors := 0


var _watchdog_armed := true


func _initialize() -> void:
	# 看门狗：出错路径下 _run 提前返回、quit 不执行，进程挂死占住终端；
	# 90 秒强制退出并打印统计
	var timer := Timer.new()
	timer.wait_time = 90.0
	timer.one_shot = true
	timer.timeout.connect(func():
		if _watchdog_armed:
			print("WATCHDOG TIMEOUT — 测试挂死，强制退出")
			print("RESULT PASS=", _total - _fail, " FAIL=", _fail, " (incomplete)")
			quit(2))
	root.add_child(timer)
	timer.start()
	_run.call_deferred()


func _run() -> void:
	# headless 视口退化为 64×64，拖动灵敏度按视口高度换算，先撑到项目分辨率
	root.size = Vector2i(1600, 900)
	# 非无头运行亦须静默；headless 下为空操作
	preload("res://tools/silent_window.gd").apply(root)
	var earth: Node3D = (load("res://scenes/earth.tscn") as PackedScene).instantiate()
	root.add_child(earth)
	for i in 3:
		await process_frame

	# B1 启动定位亚洲机位：注视点与相机位置一致
	var dir: Vector3 = earth.latlon_to_dir(35.0, 105.0)
	_check(earth.facing_lat == 35.0 and earth.facing_lon == 105.0, "B1 启动注视亚洲", "lat=%s lon=%s" % [earth.facing_lat, earth.facing_lon])
	_check(earth.get_node("Camera3D").global_position.distance_to(dir * earth.zoom_level_distance(earth.START_LEVEL)) < 0.001, "B1 相机在注视方向", "pos=%s" % earth.get_node("Camera3D").global_position)

	# B2 拖动跟手：拖右 450px → 注视经度 -= 450*50/900 = 25 度；拖下 270px → 纬度 += 15 度
	_mouse_press()
	_mouse_motion(Vector2(450, 270))
	_mouse_release()
	var lon_after: float = earth.facing_lon
	var lat_after: float = earth.facing_lat
	_check(absf((105.0 - lon_after) - 25.0) < 0.01, "B2 拖右地图右移", "dlon=%.3f" % (105.0 - lon_after))
	_check(absf((lat_after - 35.0) - 15.0) < 0.01, "B2 拖下地图下移", "dlat=%.3f" % (lat_after - 35.0))

	# B3 松手即停：松手后 40 帧注视点零漂移
	for i in 40:
		await process_frame
	_check(earth.facing_lon == lon_after and earth.facing_lat == lat_after, "B3 松手即停", "lon=%s lat=%s" % [earth.facing_lon, earth.facing_lat])

	# B4 缩放：滑块 10 级（触摸板/滚轮缩放已废）
	earth.set_zoom_level(3)
	_check(absf(earth.distance - earth.zoom_level_distance(3)) < 0.001, "B4 滑块级 3 距离", "dist=%.3f" % earth.distance)
	earth.set_zoom_level(0)
	_check(earth.zoom_level() == 1 and earth.distance == earth.zoom_level_distance(1), "B4 级别下钳制", "lv=%d" % earth.zoom_level())
	earth.set_zoom_level(99)
	_check(earth.zoom_level() == 10, "B4 级别上钳制", "lv=%d" % earth.zoom_level())
	# 滚轮不再缩放：滚轮打在地球中心，距离不变
	var dist_wheel: float = earth.distance
	_wheel(true)
	_check(earth.distance == dist_wheel, "B4 滚轮不缩放（已废）", "dist %.3f -> %.3f" % [dist_wheel, earth.distance])

	# B5 缓动对准（命令动画）：缓动到欧洲注视点，距离保持（对准入口为大洲/组织维度）
	var dist_before_b5: float = earth.distance
	earth._animate_to(48.0, 15.0, dist_before_b5)
	await _wait_jump(earth)
	_check(absf(earth.facing_lat - 48.0) < 0.01 and absf(wrapf(earth.facing_lon - 15.0, -180.0, 180.0)) < 0.01, "B5 缓动注视欧洲", "lat=%.3f lon=%.3f" % [earth.facing_lat, earth.facing_lon])
	_check(absf(earth.distance - dist_before_b5) < 0.01, "B5 对准不改缩放", "dist=%.3f" % earth.distance)
	var europe_cam: Vector3 = earth.latlon_to_dir(48.0, 15.0) * earth.distance
	_check(earth.get_node("Camera3D").global_position.distance_to(europe_cam) < 0.001, "B5 欧洲相机随缓动到位", "cam=%s" % earth.get_node("Camera3D").global_position)

	# B6 手动输入打断缓动：缓动途中拖动，缓动中止、进入自由观察
	earth._animate_to(48.0, 15.0, earth.distance)
	for i in 6:
		await process_frame
	_mouse_press()
	_mouse_motion(Vector2(100, 0))
	_mouse_release()
	_check(not earth.is_jumping(), "B6 拖动打断缓动", "")
	var lon_frozen: float = earth.facing_lon
	for i in 40:
		await process_frame
	_check(earth.facing_lon == lon_frozen, "B6 打断后无残余滑动", "lon=%s" % earth.facing_lon)

	# B7 触屏：单指拖动旋转（捏合缩放已废，缩放只用滑块）
	var lat0: float = earth.facing_lat
	_touch_press(7, Vector2(800, 450))
	_touch_drag(7, Vector2(800, 450), Vector2(806, 462))
	_touch_release(7, Vector2(806, 462))
	_check(absf((earth.facing_lat - lat0) - 12.0 * 50.0 / 900.0) < 0.01, "B7 单指拖动旋转", "dlat=%.3f" % (earth.facing_lat - lat0))

	# B8 面板页签结构（机位 chips 已废：跳转由大洲维度下拉承载，键盘 1-5 已移除）
	earth._create_ui(true)
	var hud: Control = earth.get_node("EarthHud")
	var panel_presets: Control = earth.get_node("EarthPanel")
	_check(panel_presets._tabs.count() == 2 and panel_presets._tabs.active() == 0, "B8 面板页签国家默认激活", "n=%d" % panel_presets._tabs.count())

	# C 组：国家选中（阶段二）
	# C1 数据底座：177 国
	var countries: RefCounted = earth._countries
	_check(countries != null and countries.count == 242, "C1 国家数据 242 国（50m）", "count=%s" % str(countries.count if countries != null else -1))
	if countries != null:
		# C2 点在多边形：首都坐标 → 国家；海洋 → 无
		var beijing: int = countries.find_country(39.9, 116.4)
		_check(beijing >= 0 and countries.names[beijing] == "China", "C2 北京→中国", "idx=%d name=%s" % [beijing, countries.names[beijing] if beijing >= 0 else "?"])
		var tokyo: int = countries.find_country(35.7, 139.7)
		_check(tokyo >= 0 and countries.names[tokyo] == "Japan", "C2 东京→日本", "idx=%d" % tokyo)
		var paris: int = countries.find_country(48.85, 2.35)
		_check(paris >= 0 and countries.names[paris] == "France", "C2 巴黎→法国", "idx=%d" % paris)
		var london: int = countries.find_country(51.5, -0.1)
		_check(london >= 0 and countries.names[london] == "United Kingdom", "C2 伦敦→英国", "idx=%d" % london)
		var kansas: int = countries.find_country(39.0, -98.0)
		_check(kansas >= 0 and countries.names[kansas] == "United States of America", "C2 堪萨斯腹地→美国", "idx=%d" % kansas)
		var brasil: int = countries.find_country(-15.79, -47.88)
		_check(brasil >= 0 and countries.names[brasil] == "Brazil", "C2 巴西利亚→巴西", "idx=%d" % brasil)
		var suva: int = countries.find_country(-17.8, 178.0)
		_check(suva >= 0 and countries.names[suva] == "Fiji", "C2 斐济（跨反子午线）", "idx=%d" % suva)
		var ocean: int = countries.find_country(0.0, -140.0)
		_check(ocean == -1, "C2 太平洋腹地→无国家", "idx=%d" % ocean)

		# C3 选中与高亮：选中中国出现遮罩填充+描边，取消选中清空
		var china: int = countries.names.find("China")
		earth.select_country(china)
		var mask_tex: Texture2D = earth._highlight_material.get_shader_parameter("mask")
		_check(earth.selected_index() == china and earth._stroke_mesh != null and mask_tex != null and mask_tex != earth._empty_mask, "C3 选中中国高亮", "stroke=%s mask_set=%s" % [str(earth._stroke_mesh != null), str(mask_tex != null and mask_tex != earth._empty_mask)])
		var china_stroke_verts: int = (earth._stroke_mesh.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
		var usa_idx: int = countries.names.find("United States of America")
		earth.select_country(usa_idx)
		var usa_stroke_verts: int = (earth._stroke_mesh.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
		earth.select_country(china)
		_check(china_stroke_verts > usa_stroke_verts, "C3 选中国十段线随描边高亮", "china=%d usa=%d" % [china_stroke_verts, usa_stroke_verts])
		await process_frame
		await process_frame
		earth.select_country(-1)
		var mask_cleared: Texture2D = earth._highlight_material.get_shader_parameter("mask")
		_check(earth.selected_index() == -1 and earth._stroke_mesh == null and mask_cleared == earth._empty_mask, "C3 取消选中清空", "sel=%d" % earth.selected_index())

		# C4 对准定位：注视质心，缩放锁定当前级别
		earth.place_camera(35.0, 105.0, 2.1)
		await process_frame
		var dist_before_face: float = earth.distance
		earth.face_country(china)
		await _wait_jump(earth)
		var centroid: Array = countries.centroids[china]
		_check(absf(earth.facing_lat - centroid[1]) < 0.01 and absf(wrapf(earth.facing_lon - centroid[0], -180.0, 180.0)) < 0.01, "C4 对准中国质心", "lat=%.3f lon=%.3f" % [earth.facing_lat, earth.facing_lon])
		_check(absf(earth.distance - dist_before_face) < 0.001, "C4 对准不改缩放", "dist %.3f -> %.3f" % [dist_before_face, earth.distance])

		# C6 真实点击拾取全链路（相机→射线→点在多边形）：中国画面中心点击选中
		earth.select_country(-1)
		earth.place_camera(35.0, 105.0, 2.1)
		await process_frame
		_mouse_press()
		_mouse_release()
		_check(earth.selected_index() == china, "C6 画面中心点击选中中国", "sel=%d" % earth.selected_index())
		# C7 太平洋腹地点击取消选中
		earth.place_camera(0.0, -140.0, 2.5)
		await process_frame
		_mouse_press()
		_mouse_release()
		_check(earth.selected_index() == -1, "C7 海洋点击取消选中", "sel=%d" % earth.selected_index())

		# C9 设置面板就位（UI force 注入后）；最大化按钮已废（全屏走设置面板开关行）
		var settings_node := earth.get_node_or_null("EarthSettings")
		var window_node := earth.get_node_or_null("WindowButton")
		_check(settings_node != null and window_node == null, "C9 设置面板就位、最大化按钮已废", "settings=%s window=%s" % [str(settings_node != null), str(window_node)])

		# C8 呈现模式切换与还原（设置面板入口共用 apply_presentation；默认模拟地图）
		var texture_stylized: Texture2D = (earth.get_node("Globe").material_override as StandardMaterial3D).albedo_texture
		earth.apply_presentation("satellite")
		var texture_satellite: Texture2D = (earth.get_node("Globe").material_override as StandardMaterial3D).albedo_texture
		earth.apply_presentation("stylized")
		var texture_restored: Texture2D = (earth.get_node("Globe").material_override as StandardMaterial3D).albedo_texture
		_check(texture_stylized != texture_satellite and texture_stylized == texture_restored and earth.presentation_mode == "stylized", "C8 贴图模式切换与还原", "%s -> %s -> %s" % [texture_stylized, texture_satellite, texture_restored])

		# E 组：呈现模式（阶段四 学习增强）
		# E1 底图切换：政治区划/人口/经济各自换预生成底图，回模拟地图还原
		var base_texture: Texture2D = (earth.get_node("Globe").material_override as StandardMaterial3D).albedo_texture
		earth.apply_presentation("political")
		var political_texture: Texture2D = (earth.get_node("Globe").material_override as StandardMaterial3D).albedo_texture
		_check(political_texture != base_texture and earth.presentation_mode == "political", "E1 政治区划底图", "mode=%s" % earth.presentation_mode)
		earth.apply_presentation("population")
		var population_texture: Texture2D = (earth.get_node("Globe").material_override as StandardMaterial3D).albedo_texture
		_check(population_texture != political_texture, "E1 人口着色底图", "swapped=%s" % str(population_texture != political_texture))
		earth.apply_presentation("stylized")
		var restored_texture: Texture2D = (earth.get_node("Globe").material_override as StandardMaterial3D).albedo_texture
		_check(restored_texture == base_texture, "E1 回模拟地图还原", "restored=%s" % str(restored_texture == base_texture))
		# E2 图例：着色模式可见、底图模式隐藏
		var legend: Control = earth.get_node_or_null("EarthLegend")
		earth.apply_presentation("gdp")
		_check(legend != null and legend.visible, "E2 经济着色图例可见", "legend=%s" % str(legend != null))
		earth.apply_presentation("stylized")
		_check(legend != null and not legend.visible, "E2 底图模式图例隐藏", "visible=%s" % str(legend.visible))

		# C5 面板联动：面板信号驱动选中与对准，缩放锁定（契约测试）
		if earth._panel != null:
			earth.place_camera(35.0, 105.0, 2.1)
			await process_frame
			var dist_before_panel: float = earth.distance
			earth._panel.country_selected.emit(countries.names.find("Brazil"))
			await _wait_jump(earth)
			var brazil: int = countries.names.find("Brazil")
			_check(earth.selected_index() == brazil, "C5 面板信号选中巴西", "sel=%d" % earth.selected_index())
			var brazil_centroid: Array = countries.centroids[brazil]
			_check(absf(wrapf(earth.facing_lon - brazil_centroid[0], -180.0, 180.0)) < 0.01 and absf(earth.facing_lat - brazil_centroid[1]) < 0.01, "C5 面板信号对准巴西", "lat=%.3f lon=%.3f" % [earth.facing_lat, earth.facing_lon])
			_check(absf(earth.distance - dist_before_panel) < 0.001, "C5 面板信号不改缩放（小国不狂缩放）", "dist %.3f -> %.3f" % [dist_before_panel, earth.distance])
		else:
			print("SKIP C5（面板脚本未就位）")

		# D 组：编组选中（阶段三）
		var groups: RefCounted = earth._groups
		# 17 个手写组织组（含 G20/上合）+ 6 个大洲组大洲维度排最前
		_check(groups != null and groups.count == 23, "D1 编组 23 组（17 组织 + 6 大洲）", "count=%s" % str(groups.count if groups != null else -1))
		if groups != null:
			var nato: int = groups.names.find("北约")
			var eu: int = groups.names.find("欧盟")
			_check(nato >= 0 and groups.members[nato].size() == 32, "D2 北约 32 国", "members=%s" % str(groups.members[nato].size() if nato >= 0 else -1))
			# 50m 数据马耳他回归，欧盟 27 国齐
			_check(eu >= 0 and groups.members[eu].size() == 27, "D2 欧盟 27 国（50m 马耳他回归）", "members=%s" % str(groups.members[eu].size() if eu >= 0 else -1))
			# D3 编组选中：成员遮罩 + 描边；再点切换为多选（上合并入）
			earth.select_group(nato)
			var group_mask: Texture2D = earth._highlight_material.get_shader_parameter("mask")
			var nato_overlays: Dictionary = earth._group_overlays.get(nato, {})
			_check(earth.selected_kind() == "group" and nato_overlays.get("stroke") != null and nato_overlays.get("fill") != null, "D3 选中北约成员描边+填充", "kind=%s stroke=%s fill=%s" % [earth.selected_kind(), str(nato_overlays.get("stroke") != null), str(nato_overlays.get("fill") != null)])
			var sco_d3: int = groups.names.find("上海合作组织")
			earth.select_group(sco_d3)
			_check(earth._active_groups.size() == 2 and earth._group_overlays.size() == 2, "D3 多选编组双 overlay", "groups=%s overlays=%s" % [str(earth._active_groups), str(earth._group_overlays.size())])
			earth.select_group(sco_d3)
			_check(earth._active_groups.size() == 1, "D3 再点移除多选", "groups=%s" % str(earth._active_groups))
			earth.select_country(-1)
			_check(earth.selected_kind() == "" and earth._stroke_mesh == null and earth._active_groups.is_empty(), "D3 取消选中清空", "kind=%s" % earth.selected_kind())
			# D4 对准编组区域：大跨度（北约跨欧美）切全球机位距离，小跨度保持当前
			earth.place_camera(35.0, 105.0, 2.1)
			await process_frame
			earth.face_group(nato)
			await _wait_jump(earth)
			var nato_centroid: Array = groups.centroids[nato]
			_check(absf(earth.facing_lat - nato_centroid[1]) < 0.01 and absf(wrapf(earth.facing_lon - nato_centroid[0], -180.0, 180.0)) < 0.01, "D4 对准北约区域中心", "lat=%.3f lon=%.3f" % [earth.facing_lat, earth.facing_lon])
			_check(groups.spans[nato] > earth.GROUP_GLOBAL_SPAN, "D4 北约为大跨度", "span=%.3f" % groups.spans[nato])
			_check(absf(earth.distance - earth.zoom_level_distance(earth.GLOBAL_LEVEL)) < 0.001, "D4 大跨度编组切全球机位", "dist=%.3f" % earth.distance)
			earth.place_camera(35.0, 105.0, 2.1)
			await process_frame
			var baltic: int = groups.names.find("波罗的海三国")
			var dist_before_eu: float = earth.distance
			earth.face_group(baltic)
			await _wait_jump(earth)
			_check(groups.spans[baltic] <= earth.GROUP_GLOBAL_SPAN, "D4 波罗的海三国为小跨度", "span=%.3f" % groups.spans[baltic])
			_check(absf(earth.distance - dist_before_eu) < 0.001, "D4 小跨度编组不改缩放", "dist %.3f -> %.3f" % [dist_before_eu, earth.distance])
			# D5 面板编组信号联动（对准语义，小跨度不改缩放）
			if earth._panel != null:
				earth.place_camera(35.0, 105.0, 2.1)
				await process_frame
				var baltic_d5: int = groups.names.find("波罗的海三国")
				var dist_before_d5: float = earth.distance
				earth._panel.group_selected.emit(baltic_d5)
				await _wait_jump(earth)
				_check(earth._active_groups.has(baltic_d5), "D5 面板编组信号选中波罗的海三国", "groups=%s" % str(earth._active_groups))
				var baltic_centroid: Array = groups.centroids[baltic_d5]
				_check(absf(wrapf(earth.facing_lon - baltic_centroid[0], -180.0, 180.0)) < 0.01, "D5 面板编组信号对准", "lon=%.3f" % earth.facing_lon)
				_check(absf(earth.distance - dist_before_d5) < 0.001, "D5 面板编组信号不改缩放", "dist %.3f -> %.3f" % [dist_before_d5, earth.distance])
			else:
				print("SKIP D5（面板脚本未就位）")

		# F 组：面板折叠与设置面板避让
		var hud2: Control = earth.get_node("EarthHud")
		var panel2: Control = earth.get_node("EarthPanel")
		var settings2: Control = earth.get_node("EarthSettings")
		# F1 设置面板打开位置在国家面板左侧（不重叠）；开设置同时收起国家面板
		settings2.open_panel()
		earth.on_settings_opened()
		var srect: Rect2 = settings2._panel_rect()
		var prect: Rect2 = panel2.get_global_rect()
		_check(not srect.intersects(prect), "F1 设置面板不与国家面板重叠", "s=%s p=%s" % [srect, prect])
		# F4 面板几何登记（面板布局技术决策：先算面积与位置，摆放互斥）：
		# 设置开 + 面板收起态，四个可见面板矩形两两不相交，且行模型容纳全部行
		var rects_closed: Dictionary = earth.visible_panel_rects()
		_check(rects_closed.has_all(["gear", "slider", "settings_panel", "panel_handle"]), "F4 几何登记齐全（设置开/面板收起）", "keys=%s" % str(rects_closed.keys()))
		_check(earth.first_rect_overlap(rects_closed) == "", "F4 设置开时可见面板互斥", "hit=%s" % earth.first_rect_overlap(rects_closed))
		var last_row: Rect2 = settings2._row_rect(settings2._option_row_offset() + settings2.options.size() - 1)
		_check(settings2._panel_rect().encloses(last_row), "F4 设置面板行模型容纳全部行（含返回/开关行）", "panel=%s last=%s" % [str(settings2._panel_rect()), str(last_row)])
		_check(settings2._switch != null and settings2._switch.visible, "F4 全屏开关控件就位（懒建）", "sw=%s" % str(settings2._switch != null))
		# F2 设置面板打开时点击国家行：设置收起（点面板外透传给 GUI 控件）且行选中生效
		panel2.toggle_collapsed()
		for i in 480:
			if panel2.visible and panel2.position.x <= 1289.0:
				break
			await process_frame
		var vis_pos := -1
		for pos in panel2.row_count():
			var di: int = panel2.country_row_data(pos)
			var rec: Dictionary = panel2._list_rows[pos]
			if di >= 0 and rec["row"].is_visible_in_tree():
				vis_pos = pos
				break
		var vis_row: Control = panel2._list_rows[vis_pos]["row"]
		var vis_index: int = int(panel2._list_rows[vis_pos]["index"])
		_click_at(vis_row.get_global_rect().get_center())
		await process_frame
		_check(not settings2._panel_open and earth.selected_index() == vis_index, "F2 设置开时点可见国家行透传生效", "open=%s sel=%d" % [str(settings2._panel_open), earth.selected_index()])
		# F3 国家面板折叠/展开
		panel2.toggle_collapsed()
		await process_frame
		for i in 240:
			if not panel2._panel_margins.visible:
				break
			await process_frame
		_check(panel2.collapsed and not earth.is_panel_expanded() and not panel2._panel_margins.visible and panel2.visible, "F3 面板收起正文隐藏（把手保留）", "collapsed=%s visible=%s" % [str(panel2.collapsed), str(panel2.visible)])
		_check(settings2._panel_rect().position.x < 200.0, "F3 设置面板左锚定于齿轮下方", "x=%.0f" % settings2._panel_rect().position.x)
		panel2.toggle_collapsed()
		await process_frame
		_check(not panel2.collapsed and earth.is_panel_expanded(), "F3 面板展开还原", "collapsed=%s" % str(panel2.collapsed))
		# F4b 面板展开 + 设置收起态：三个可见面板矩形两两不相交
		var rects_expanded: Dictionary = earth.visible_panel_rects()
		_check(earth.first_rect_overlap(rects_expanded) == "", "F4 面板展开时可见面板互斥", "hit=%s" % earth.first_rect_overlap(rects_expanded))
		# F3b 真实点击头部收起钮 / 圆形把手（回归：停靠面板是 STOP 控件，本体矩形内
		# 点击在 GUI 阶段即被消费，_unhandled_input 收不到——收起必须走 _gui_input）
		var chevron_global: Vector2 = panel2.global_position + panel2._chevron_rect().get_center()
		_click_at(chevron_global)
		await process_frame
		for i in 240:
			if not panel2._panel_margins.visible:
				break
			await process_frame
		_check(panel2.collapsed and panel2.visible and not panel2._panel_margins.visible, "F3b 点头部收起钮收起（把手保留）", "collapsed=%s" % str(panel2.collapsed))
		var handle_center: Vector2 = panel2._handle_rect().get_center()
		_click_at(handle_center)
		await process_frame
		for i in 240:
			if panel2.visible and panel2.position.x <= 1289.0:
				break
			await process_frame
		_check(panel2.is_expanded() and panel2.visible, "F3b 点圆形把手展开", "collapsed=%s" % str(panel2.collapsed))

		# G 组：分组扩充/排序/滚轮穿透/双击/手风琴/标签
		var settings3: Control = earth.get_node("EarthSettings")
		# G1 大洲组：亚洲（数据自动聚合）
		var asia: int = groups.names.find("亚洲")
		_check(asia >= 0 and groups.members[asia].size() >= 40, "G1 大洲组亚洲", "members=%s" % str(groups.members[asia].size() if asia >= 0 else -1))
		# G2 组织组：上合含伊朗、G20 含日本（重要国家经组织组可达）
		var sco: int = groups.names.find("上海合作组织")
		var g20: int = groups.names.find("二十国集团")
		_check(sco >= 0 and groups.members[sco].has(countries.names.find("Iran")), "G2 上合含伊朗", "idx=%d" % sco)
		_check(g20 >= 0 and groups.members[g20].has(countries.names.find("Japan")), "G2 G20 含日本", "idx=%d" % g20)
		# G3 排序：大洲组内排序——面积序亚洲首行中国、人口序亚洲首行中国
		panel2._set_sort("area")
		await process_frame
		var asia_first_area := -1
		for pos in panel2.row_count():
			var di: int = panel2.country_row_data(pos)
			if di >= 0 and countries.continents[di] == "Asia":
				asia_first_area = di
				break
		_check(countries.names[asia_first_area] == "China", "G3 面积序亚洲首行中国", "first=%s" % countries.names[asia_first_area])
		panel2._set_sort("pop")
		await process_frame
		var asia_first_pop := -1
		for pos in panel2.row_count():
			var di2: int = panel2.country_row_data(pos)
			if di2 >= 0 and countries.continents[di2] == "Asia":
				asia_first_pop = di2
				break
		_check(countries.names[asia_first_pop] == "China", "G3 人口序亚洲首行中国", "first=%s" % countries.names[asia_first_pop])
		# G3c 排序顺序：默认倒序（面积大→小），切正序后亚洲组内前两行面积升序、首行改变
		panel2._set_sort("area")
		await process_frame
		var asia_desc_first := -1
		for pos in panel2.row_count():
			var di3: int = panel2.country_row_data(pos)
			if di3 >= 0 and countries.continents[di3] == "Asia":
				asia_desc_first = di3
				break
		panel2._set_order(false)
		await process_frame
		var asia_asc: Array = []
		for pos in panel2.row_count():
			var di4: int = panel2.country_row_data(pos)
			if di4 >= 0 and countries.continents[di4] == "Asia":
				asia_asc.append(di4)
				if asia_asc.size() == 2:
					break
		_check(asia_asc.size() == 2 and float(countries.areas[asia_asc[0]]) <= float(countries.areas[asia_asc[1]]), "G3c 正序亚洲前两行面积升序", "a0=%.0f a1=%.0f" % [float(countries.areas[asia_asc[0]]), float(countries.areas[asia_asc[1]])])
		_check(asia_desc_first >= 0 and int(asia_asc[0]) != asia_desc_first, "G3c 正序倒序首行不同", "desc=%s asc=%s" % [countries.names[asia_desc_first], countries.names[asia_asc[0]]])
		panel2._set_order(true)
		await process_frame
		panel2._set_sort("name")
		await process_frame
		# G4 面板滚轮不穿透：列表到列表尾时滚轮不缩放地球
		var dist_before: float = earth.distance
		panel2._scroll.scroll_vertical = 1000000
		await process_frame
		var wheel := InputEventMouseButton.new()
		wheel.button_index = MOUSE_BUTTON_WHEEL_DOWN
		wheel.pressed = true
		wheel.position = panel2.get_global_rect().get_center()
		wheel.factor = 3.0
		Input.parse_input_event(wheel)
		Input.flush_buffered_events()
		var wheel_up := InputEventMouseButton.new()
		wheel_up.button_index = MOUSE_BUTTON_WHEEL_DOWN
		wheel_up.pressed = false
		wheel_up.position = panel2.get_global_rect().get_center()
		Input.parse_input_event(wheel_up)
		Input.flush_buffered_events()
		_check(earth.distance == dist_before, "G4 面板滚轮不穿透缩放", "dist %s -> %s" % [dist_before, earth.distance])
		# G5 双击国家旋转到正前方，缩放锁定当前级别（单击仅选中）
		earth.place_camera(35.0, 105.0, 2.1)
		await process_frame
		var dist_before_dbl: float = earth.distance
		var dbl := InputEventMouseButton.new()
		dbl.button_index = MOUSE_BUTTON_LEFT
		dbl.pressed = true
		dbl.position = Vector2(800, 450)
		dbl.double_click = true
		Input.parse_input_event(dbl)
		Input.flush_buffered_events()
		var dbl_up := InputEventMouseButton.new()
		dbl_up.button_index = MOUSE_BUTTON_LEFT
		dbl_up.pressed = false
		dbl_up.position = Vector2(800, 450)
		Input.parse_input_event(dbl_up)
		Input.flush_buffered_events()
		await _wait_jump(earth)
		var china_centroid: Array = countries.centroids[china]
		_check(absf(wrapf(earth.facing_lon - china_centroid[0], -180.0, 180.0)) < 0.01 and absf(earth.facing_lat - china_centroid[1]) < 0.01, "G5 双击中国旋转到正前方", "lat=%.2f lon=%.2f" % [earth.facing_lat, earth.facing_lon])
		_check(absf(earth.distance - dist_before_dbl) < 0.001, "G5 双击不改缩放", "dist %.3f -> %.3f" % [dist_before_dbl, earth.distance])
		# 相机 transform 必须真正跟随缓动到位（回归防线：tween 只改注视属性
		# 不自动摆相机，缺逐帧 _apply 时画面静止，属性断言全部漏过）
		var expected_cam: Vector3 = earth.latlon_to_dir(china_centroid[1], china_centroid[0]) * earth.distance
		_check(earth.get_node("Camera3D").global_position.distance_to(expected_cam) < 0.001, "G5 双击后相机随缓动到位", "cam=%s expected=%s" % [earth.get_node("Camera3D").global_position, expected_cam])
		# G6 手风琴：开设置收面板、开面板收设置（齿轮居 40 主入口，96 为最大化按钮）
		_click_at(Vector2(40.0, 40.0))
		await process_frame
		_check(settings3._panel_open and not earth.is_panel_expanded(), "G6a 开设置收国家面板", "open=%s expanded=%s" % [str(settings3._panel_open), str(earth.is_panel_expanded())])
		earth._toggle_country_panel()
		await process_frame
		_check(earth.is_panel_expanded() and not settings3._panel_open, "G6b 开面板收设置", "expanded=%s open=%s" % [str(earth.is_panel_expanded()), str(settings3._panel_open)])
		# G6c 设置收起后国家面板自动恢复展开（收起只为让位，不收走入口）
		var panel_g: Control = earth.get_node("EarthPanel")
		settings3.open_panel()
		earth.on_settings_opened()
		await process_frame
		for i in 240:
			if not panel_g._panel_margins.visible:
				break
			await process_frame
		_check(panel_g.collapsed, "G6c 前置：设置开面板收起", "")
		settings3.close_panel()
		await process_frame
		for i in 240:
			if panel_g.position.x <= 1289.0:
				break
			await process_frame
		_check(not panel_g.collapsed and panel_g._panel_margins.visible, "G6c 设置收起后面板自动恢复", "collapsed=%s" % str(panel_g.collapsed))
		# G7 国家名标签
		_check(earth._labels.size() == 242, "G7 国家名标签 242", "n=%d" % earth._labels.size())

		# H 组：中国地图数据 + 缩放滑块
		# H1 中国标准国界（DataV 替换 NE）：面积 ≈ 952 万 km²，十段线 10 段
		var china_cn: int = countries.names.find("China")
		_check(countries.areas[china_cn] > 9400000.0 and countries.areas[china_cn] < 9700000.0, "H1 中国标准面积", "area=%s" % str(countries.areas[china_cn]))
		_check(countries.china_lines.size() == 10, "H1 十段线 10 段", "n=%d" % countries.china_lines.size())
		# H2 缩放滑块：轨道点击定级、＋/− 步进、机位跳转级别同步
		var hud3: Control = earth.get_node("EarthHud")
		earth.set_zoom_level(1)
		var track: Rect2 = hud3._track_rect()
		_click_at(track.position + Vector2(track.size.x, 0.0))
		_check(earth.zoom_level() == 10, "H2 轨道最右点击=级10", "lv=%d" % earth.zoom_level())
		_click_at(hud3._minus_rect().get_center())
		_check(earth.zoom_level() == 9, "H2 − 步进", "lv=%d" % earth.zoom_level())
		_click_at(hud3._plus_rect().get_center())
		_check(earth.zoom_level() == 10, "H2 ＋ 步进", "lv=%d" % earth.zoom_level())



		# I 组：面板新版式（维度下拉 + 排序 + 大洲强制分组）
		var panel3: Control = earth.get_node("EarthPanel")
		# I1 筛选行：大洲 / 组织两个多选下拉（维度选项列表），组织 17 项、大洲 6 项
		_check(panel3._continent_select.count() == 7, "I1a 大洲维度下拉 7 项（含全部）", "n=%d" % panel3._continent_select.count())
		_check(panel3._org_select.count() == 17, "I1b 组织维度下拉 17 项", "n=%d" % panel3._org_select.count())
		# I1c 组织优先序：上合、金砖、北约、欧盟、G20、G7 在前
		var org_first: String = str(panel3._org_select.options[0][0])
		_check(org_first == "上海合作组织", "I1c 组织下拉优先序上合在首", "first=%s" % org_first)
		# I1d 点维度下拉本体开合（回归：width 必须回写最小尺寸，否则可视框右半段
		# 超出控件实际矩形，点箭头/× 全部落空——「下拉无效」根因）。
		# 先切到「选中」页签（下拉所在页），结束切回「国家」页签；
		# 弹层展开时钉在面板顶部覆盖选择框，收起统一走点面板外
		panel3._tabs.set_active(1)
		await process_frame
		var sel_rect: Rect2 = panel3._continent_select.get_global_rect()
		_click_at(sel_rect.get_center())
		await process_frame
		_check(panel3._continent_select.is_open(), "I1d 点大洲下拉展开", "")
		_click_at(Vector2(1430, 700))
		await process_frame
		_check(not panel3._continent_select.is_open(), "I1d 点面板外收起", "")
		# I1e × 清除全链路：弹层勾选欧洲 → 收层点 × → 回退「全部」并同步编组清空
		_click_at(sel_rect.get_center())
		await process_frame
		_click_at(panel3._continent_select.option_rect(2).get_center())
		await process_frame
		_check(panel3._continent_select.get_values() == ["1"], "I1e 弹层勾选欧洲", "v=%s" % str(panel3._continent_select.get_values()))
		_click_at(Vector2(1430, 700))
		await process_frame
		var clear_pos: Vector2 = panel3._continent_select.get_global_rect().position + panel3._continent_select._clear_rect().get_center()
		_click_at(clear_pos)
		await process_frame
		_check(panel3._continent_select.get_values() == ["all"], "I1e × 清除回退全部", "v=%s" % str(panel3._continent_select.get_values()))
		_check(earth._active_groups.is_empty(), "I1e 清除同步编组清空", "g=%s" % str(earth._active_groups))
		# I1g 取消勾选同样清地图高亮（回归：取消分支曾不发 option_toggled，
		# select 勾没了、地球 _active_groups 还留着）
		_click_at(sel_rect.get_center())
		await process_frame
		_click_at(panel3._continent_select.option_rect(2).get_center())
		await process_frame
		_check(earth._active_groups == [1], "I1g 勾选欧洲地图高亮", "g=%s" % str(earth._active_groups))
		_click_at(panel3._continent_select.option_rect(2).get_center())
		await process_frame
		_check(panel3._continent_select.get_values() == ["all"] and earth._active_groups.is_empty(), "I1g 取消勾选清地图高亮", "v=%s g=%s" % [str(panel3._continent_select.get_values()), str(earth._active_groups)])
		# I1h 弹层贴面板内容顶部（设计决策：下拉列表显示在面板最上面）
		var popup_top: float = panel3._continent_select._panel_rect().position.y
		var tabs_top: float = (panel3._tabs as Control).get_global_rect().position.y
		_check(absf(popup_top - (tabs_top + 34.0)) < 2.0, "I1h 弹层钉在面板内容顶部", "top=%.0f expect=%.0f" % [popup_top, tabs_top + 34.0])
		_click_at(Vector2(1430, 700))
		await process_frame
		_check(not panel3._continent_select.is_open(), "I1h 弹层收起还原", "")
		panel3._tabs.set_active(0)
		await process_frame
		# I1f 下拉框多点命中（标签区/框左/框中/框右 全部可开合，无死区）
		panel3._tabs.set_active(1)
		await process_frame
		var probe_rect: Rect2 = panel3._continent_select.get_global_rect()
		for offset in [0.08, 0.35, 0.62, 0.9]:
			var probe_point := Vector2(probe_rect.position.x + probe_rect.size.x * float(offset), probe_rect.get_center().y)
			_click_at(probe_point)
			await process_frame
			var opened: bool = panel3._continent_select.is_open()
			_click_at(Vector2(1430, 700))
			await process_frame
			_check(opened and not panel3._continent_select.is_open(), "I1f 下拉多点开合 x=%.2f" % float(offset), "opened=%s" % str(opened))
		panel3._tabs.set_active(0)
		await process_frame
		# I2 列表强制按大洲分组：7 个标题行（中国标准七大洲），标题后紧跟该大洲国家
		var titles := 0
		var first_title_pos := -1
		for pos in panel3.row_count():
			var record: Dictionary = panel3._list_rows[pos]
			if record["kind"] == "title":
				titles += 1
				if first_title_pos < 0:
					first_title_pos = pos
		_check(titles == 7, "I2 大洲标题 7 个（含南极洲）", "n=%d" % titles)
		_check(first_title_pos == 0, "I2 列表以大洲标题开头", "pos=%d" % first_title_pos)
		# I3 组织 chip 点选 = 加入多选：上合 + 欧盟同时激活（双 overlay 双色）
		var sco_idx: int = groups.names.find("上海合作组织")
		var eu_idx: int = groups.names.find("欧盟")
		earth._panel.group_selected.emit(sco_idx)
		earth._panel.group_selected.emit(eu_idx)
		_check(earth._active_groups.has(sco_idx) and earth._active_groups.has(eu_idx), "I3 上合与欧盟同时激活", "groups=%s" % str(earth._active_groups))
		_check(earth._group_overlays.size() == 2, "I3 双编组双 overlay", "n=%d" % earth._group_overlays.size())
		var color0: Color = earth.GROUP_COLORS[0]
		var color1: Color = earth.GROUP_COLORS[1]
		_check(color0 != color1, "I3 色彩列表颜色不同", "%s vs %s" % [color0, color1])
		# I4 「全部」chip 清除编组选中
		earth._panel.group_selected.emit(-1)
		_check(earth._active_groups.is_empty(), "I4 全部 chip 清除选中", "groups=%s" % str(earth._active_groups))
		# I5 大洲标题点选 = 选中大洲编组
		var asia_group: int = groups.names.find("亚洲")
		earth._panel.group_selected.emit(asia_group)
		_check(earth._active_groups.has(asia_group), "I5 大洲标题选中亚洲编组", "groups=%s" % str(earth._active_groups))
		earth.select_group(-1)


		# J 组：面板机位行跳转 + 地形位移
		var panel4: Control = earth.get_node("EarthPanel")
		# J1 机位 chips 已废（对准由大洲/组织维度下拉承载，见 D5）

		# J2 地形位移：珠峰方向网格顶点高于球面，海洋顶点齐平
		if earth._terrain_height != null:
			var everest_dir: Vector3 = earth.latlon_to_dir(27.99, 86.93)
			var peak_h: float = earth._terrain_height_at(27.99, 86.93)
			_check(peak_h > 5000.0, "J2 珠峰高程采样（zoom4 区域平滑）", "h=%.0f" % peak_h)
			_check((everest_dir * (1.0 + peak_h / earth.TERRAIN_MAX_ELEV * earth.TERRAIN_MAX_DISPLACE)).length() > 1.00001, "J2 珠峰位移生效（0.2 倍温和夸张）", "disp=%.6f" % (peak_h / earth.TERRAIN_MAX_ELEV * earth.TERRAIN_MAX_DISPLACE))
			var ocean_h: float = earth._terrain_height_at(0.0, -140.0)
			_check(ocean_h == 0.0, "J2 海洋齐平", "h=%.0f" % ocean_h)
		else:
			print("SKIP J2（高程贴图缺失）")

		# K 组：设置面板返回行 + 微型国家（本轮收尾）；返回按钮已并入设置面板
		# 首行「‹ 返回场景选择」（左上角不再有独立返回按钮，避免与齿轮重叠）
		var settings_k: Control = earth.get_node("EarthSettings")
		# 独立仓库无场景选择页：返回行随资源存在性降级
		var picker_exists: bool = ResourceLoader.exists("res://scenes/scene_picker.tscn")
		_check(settings_k.has_back() == picker_exists and (not picker_exists or settings_k.back_label.contains("返回")), "K1 返回行随场景选择页存在性降级", "back=%s picker=%s" % [str(settings_k.has_back()), str(picker_exists)])
		_check(earth.get_node_or_null("BackButton") == null, "K1b 左上角无独立返回按钮（不与齿轮重叠）", "")
		for probe in ["Malta", "Singapore", "Bahrain"]:
			var mi: int = countries.names.find(probe)
			_check(mi >= 0, "K2 微型国家回归 " + probe, "idx=%d" % mi)
		# K3 面板行数与国家数一致（242 国 + 7 大洲标题）
		_check(earth._panel.row_count() == 242 + 7, "K3 面板行数 242+7 标题", "n=%d" % earth._panel.row_count())
		# K4 域外岛屿按中国标准七大洲归化（NE 兜底洲 "Seven seas" 清空）
		var maldives: int = countries.names.find("Maldives")
		var mauritius: int = countries.names.find("Mauritius")
		var sgeorgia: int = countries.names.find("S. Geo. and the Is.")
		_check(maldives >= 0 and countries.continents[maldives] == "Asia", "K4 马尔代夫归亚洲", "c=%s" % str(countries.continents[maldives]))
		_check(mauritius >= 0 and countries.continents[mauritius] == "Africa", "K4 毛里求斯归非洲", "c=%s" % str(countries.continents[mauritius]))
		_check(sgeorgia >= 0 and countries.continents[sgeorgia] == "South America", "K4 南乔治亚归南美", "c=%s" % str(countries.continents[sgeorgia]))
		var seven_seas := 0
		for ci in countries.count:
			if str(countries.continents[ci]).begins_with("Seven seas"):
				seven_seas += 1
		_check(seven_seas == 0, "K4 无域外兜底洲残留", "n=%d" % seven_seas)

		# P 组：面板关系矩阵（面板布局技术决策：任意状态组合下同时可见面板两两互斥）
		var panel_p: Control = earth.get_node("EarthPanel")
		var settings_p: Control = earth.get_node("EarthSettings")
		# P1 默认态：面板展开 + 设置收起 + 底图模式
		earth.apply_presentation("stylized")
		settings_p.close_panel()
		if panel_p.collapsed:
			panel_p.toggle_collapsed()
			for i in 240:
				if panel_p.visible and panel_p.position.x <= 1289.0:
					break
				await process_frame
		var rects_p1: Dictionary = earth.visible_panel_rects()
		_check(rects_p1.has_all(["gear", "slider", "country_panel"]), "P1 默认态登记齐全", "keys=%s" % str(rects_p1.keys()))
		_check(earth.first_rect_overlap(rects_p1) == "", "P1 默认态面板互斥", "hit=%s" % earth.first_rect_overlap(rects_p1))
		# P2 设置开（面板自动收起）：齿轮/滑块/提示/设置面板/圆形把手
		settings_p.open_panel()
		earth.on_settings_opened()
		for i in 240:
			if not panel_p._panel_margins.visible:
				break
			await process_frame
		var rects_p2: Dictionary = earth.visible_panel_rects()
		_check(rects_p2.has("settings_panel") and rects_p2.has("panel_handle"), "P2 设置开登记齐全", "keys=%s" % str(rects_p2.keys()))
		_check(earth.first_rect_overlap(rects_p2) == "", "P2 设置开面板互斥", "hit=%s" % earth.first_rect_overlap(rects_p2))
		# P3 图例模式（经济着色）叠加设置开：图例加入互斥集合
		earth.apply_presentation("gdp")
		await process_frame
		var rects_p3: Dictionary = earth.visible_panel_rects()
		_check(rects_p3.has("legend"), "P3 着色模式图例登记", "keys=%s" % str(rects_p3.keys()))
		_check(earth.first_rect_overlap(rects_p3) == "", "P3 图例+设置开互斥", "hit=%s" % earth.first_rect_overlap(rects_p3))
		# P4 图例 + 面板展开（设置收起后面板自动恢复展开）
		settings_p.close_panel()
		for i in 240:
			if panel_p.position.x <= 1289.0:
				break
			await process_frame
		var rects_p4: Dictionary = earth.visible_panel_rects()
		_check(earth.first_rect_overlap(rects_p4) == "", "P4 图例+面板展开互斥", "hit=%s" % earth.first_rect_overlap(rects_p4))
		# P5 停靠面板内容顶距让开头部带（标题/页签不重叠的几何保证）
		_check(panel_p.content().get_global_rect().position.y >= panel_p.position.y + panel_p.header_height, "P5 内容顶距让开头部带", "content_y=%.0f limit=%.0f" % [panel_p.content().get_global_rect().position.y, panel_p.position.y + panel_p.header_height])
		# 还原默认：底图模式 + 面板展开 + 设置收起 + 选中中国
		earth.apply_presentation("stylized")
		earth.select_country(earth._china_index)

	_watchdog_armed = false

	print("—— 地球自检：%d 项，%d FAIL ——" % [_total, _fail])
	print("RESULT PASS=", _total - _fail, " FAIL=", _fail)
	quit(1 if _fail > 0 else 0)


func _wait_jump(earth: Node) -> void:
	# headless 帧率不封顶，帧数不等于时长：轮询机位缓动结束（上限 900 帧防挂死）
	for i in 900:
		if not earth.is_jumping():
			return
		await process_frame


var _total := 0
var _fail := 0


func _check(passed: bool, label: String, detail := "") -> void:
	_total += 1
	if passed:
		print("PASS ", label)
	else:
		_fail += 1
		errors += 1
		print("FAIL ", label, "  ", detail)


var _mouse_pos := Vector2.ZERO  # 测试内跟踪鼠标位置：release 携带移动后位置（与真实输入一致）


func _mouse_press(pos := Vector2(800, 450)) -> void:
	_mouse_pos = pos
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = true
	event.position = _mouse_pos
	Input.parse_input_event(event)
	Input.flush_buffered_events()


func _mouse_motion(delta: Vector2) -> void:
	_mouse_pos += delta
	var event := InputEventMouseMotion.new()
	event.relative = delta
	event.position = _mouse_pos
	Input.parse_input_event(event)
	Input.flush_buffered_events()


func _mouse_release() -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = false
	event.position = _mouse_pos
	Input.parse_input_event(event)
	Input.flush_buffered_events()


func _click_at(pos: Vector2) -> void:
	# 任意位置点击（UI 命中测试用）：按下+松开同一坐标
	_mouse_press(pos)
	_mouse_release()


func _wheel(zoom_in: bool) -> void:
	var button := MOUSE_BUTTON_WHEEL_UP if zoom_in else MOUSE_BUTTON_WHEEL_DOWN
	var event := InputEventMouseButton.new()
	event.button_index = button
	event.pressed = true
	event.factor = 1.0
	event.position = Vector2(800, 450)
	Input.parse_input_event(event)
	Input.flush_buffered_events()
	var release := InputEventMouseButton.new()
	release.button_index = button
	release.pressed = false
	release.position = Vector2(800, 450)
	Input.parse_input_event(release)
	Input.flush_buffered_events()


func _press_key(keycode: Key) -> void:
	var press := InputEventKey.new()
	press.keycode = keycode
	press.physical_keycode = keycode
	press.pressed = true
	Input.parse_input_event(press)
	Input.flush_buffered_events()


func _touch_press(index: int, position: Vector2) -> void:
	var event := InputEventScreenTouch.new()
	event.index = index
	event.pressed = true
	event.position = position
	Input.parse_input_event(event)
	Input.flush_buffered_events()


func _touch_drag(index: int, from: Vector2, to: Vector2) -> void:
	var event := InputEventScreenDrag.new()
	event.index = index
	event.position = to
	event.relative = to - from
	Input.parse_input_event(event)
	Input.flush_buffered_events()


func _touch_release(index: int, position: Vector2) -> void:
	var event := InputEventScreenTouch.new()
	event.index = index
	event.pressed = false
	event.position = position
	Input.parse_input_event(event)
	Input.flush_buffered_events()
