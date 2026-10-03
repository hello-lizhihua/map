extends SceneTree
## headless UI 端到端自检：真实事件路径点击国家面板——行选中、维度下拉多选、
## 手风琴开一收一、排序单选、搜索筛选。与 earth_test 的 emit 驱动契约测试互补，
## 覆盖 GUI 点击全链路。
## 运行：godot --headless --path . -s res://tests/ui_test.gd

var _total := 0
var _fail := 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	root.size = Vector2i(1600, 900)
	preload("res://tools/silent_window.gd").apply(root)
	var earth: Node3D = (load("res://scenes/earth.tscn") as PackedScene).instantiate()
	root.add_child(earth)
	for i in 3:
		await process_frame
	earth._create_ui(true)
	for i in 2:
		await process_frame
	var panel: Control = earth.get_node("EarthPanel")

	# U0 页签结构：「国家(242)」第一默认激活（排序/搜索/列表），「选中」第二（大洲/组织两行）
	_check(panel._tabs.count() == 2 and panel._tabs.active() == 0, "U0a 国家页签默认激活", "n=%d" % panel._tabs.count())
	_check(panel._tabs.tab_content(0).get_child(0) == panel._sort_row, "U0b 国家页签承载排序行", "")
	_check(panel._continent_select.get_parent().get_parent() == panel._tabs.tab_content(1), "U0c 选中页签承载大洲行", "")
	_check(panel._tabs.tab_content(1).get_child(0) == panel._continent_select.get_parent(), "U0d 选中页签大洲行在首", "")

	# U1 真实点击国家行：国家页签默认激活，亚洲组（默认展开）内中国为面积序首行，行带 ISO 前缀
	await process_frame
	var china_pos := -1
	for pos in panel.row_count():
		var di: int = panel.country_row_data(pos)
		if di >= 0 and earth._countries.names[di] == "China":
			china_pos = pos
			break
	_check(china_pos >= 0, "U1a 中国在列表中", "pos=%d" % china_pos)
	if china_pos >= 0:
		var record: Dictionary = panel._list_rows[china_pos]
		var row: Control = record["row"]
		var iso_label: Label = row.get_child(0)
		_check(iso_label.text == "CN", "U1a-2 国家行 ISO 前缀", "iso=%s" % iso_label.text)
		_click_at(row.get_global_rect().get_center())
		await process_frame
		await process_frame
		_check(earth.selected_index() == int(record["index"]), "U1b 点击中国行选中", "sel=%d" % earth.selected_index())
		_check(row.get_meta("details")[0].visible, "U1c 选中行详情展开", "")
		_check(panel._list._accordion.is_open(0), "U1d 亚洲组展开", "")

	# U2 组织维度下拉多选：切到选中页签，点开组织下拉 → 点北约行 → 编组选中；再点取消
	panel._tabs.set_active(1)
	await process_frame
	_check(panel._continent_select.get_values() == ["all"], "U2-0 大洲下拉默认「全部」", "values=%s" % str(panel._continent_select.get_values()))
	var nato: int = earth._groups.names.find("北约")
	_click_at(panel._org_select.get_global_rect().get_center())
	await process_frame
	await process_frame
	_check(panel._org_select.is_open(), "U2a 组织下拉展开", "")
	var nato_row := _option_row(panel._org_select, "北约")
	_check(nato_row >= 0, "U2b 北约在下拉选项中", "row=%d" % nato_row)
	if nato_row >= 0:
		_click_at(panel._org_select.option_rect(nato_row).get_center())
		await process_frame
		_check(earth._active_groups.has(nato), "U2c 点击北约选中编组", "groups=%s" % str(earth._active_groups))
		_check(panel._org_select.get_values().has(str(nato)), "U2d 下拉勾选回推", "values=%s" % str(panel._org_select.get_values()))
		_check(panel._org_select.is_open(), "U2e 多选下拉保持展开", "")
		_click_at(panel._org_select.option_rect(nato_row).get_center())
		await process_frame
		_check(not earth._active_groups.has(nato), "U2f 再点取消编组", "groups=%s" % str(earth._active_groups))
	_click_at(Vector2(400, 450))  # 点面板外收起下拉
	await process_frame
	_check(not panel._org_select.is_open(), "U2g 点面板外收起", "")

	# U3 大洲维度下拉：点欧洲 → 大洲编组选中
	var europe: int = earth._groups.names.find("欧洲")
	_click_at(panel._continent_select.get_global_rect().get_center())
	await process_frame
	await process_frame
	var europe_row := _option_row(panel._continent_select, "欧洲")
	if europe_row >= 0:
		_click_at(panel._continent_select.option_rect(europe_row).get_center())
		await process_frame
		_check(earth._active_groups.has(europe), "U3a 点击欧洲选中大洲编组", "groups=%s" % str(earth._active_groups))
	_click_at(Vector2(400, 450))
	await process_frame

	# U4 手风琴标题：切回国家页签，滚动到欧洲标题后点击——不改变编组选中，开一收一
	panel._tabs.set_active(0)
	await process_frame
	var groups_before: Array = earth._active_groups.duplicate()
	var europe_bar: Control = panel._list._accordion._sections[1]["bar"]
	panel._scroll.scroll_vertical = int(europe_bar.position.y) - 40
	await process_frame
	await process_frame
	_click_at(europe_bar.get_global_rect().get_center())
	await process_frame
	_check(earth._active_groups == groups_before, "U4a 标题点击不改变编组选中", "groups=%s" % str(earth._active_groups))
	_check(panel._list._accordion.is_open(1) and not panel._list._accordion.is_open(0), "U4b 手风琴开一收一", "")

	# U5 排序单选按钮组：切到国家页签，点击「人口」→ 大洲组内人口序（亚洲首行中国）
	panel._tabs.set_active(0)
	await process_frame
	var pop_chip: Control = panel._sort_radio.option_at(1)
	_click_at(pop_chip.get_global_rect().get_center())
	await process_frame
	await process_frame
	_check(panel._sort == "pop", "U5a 点击人口排序生效", "sort=%s" % panel._sort)
	_check(pop_chip.is_active() and not panel._sort_radio.option_at(0).is_active(), "U5b 单选高亮切换", "")
	var asia_first := -1
	for pos in panel.row_count():
		var di: int = panel.country_row_data(pos)
		if di >= 0 and earth._countries.continents[di] == "Asia":
			asia_first = di
			break
	_check(earth._countries.names[asia_first] == "China", "U5c 人口序亚洲首行中国", "first=%s" % earth._countries.names[asia_first])

	# U6 维度下拉状态回推：emit 信号驱动（earth 维护状态后 sync 回来）
	var nato6: int = earth._groups.names.find("北约")
	earth.select_group(nato6)
	await process_frame
	_check(panel._org_select.get_values().has(str(nato6)), "U6 组织下拉勾选回推", "values=%s" % str(panel._org_select.get_values()))

	# U7 搜索筛选：CN 命中中国（及 CN-TW 台湾省），未命中行（如 JP 日本）隐藏；清空还原
	panel._search.text_changed.emit("CN")
	await process_frame
	await process_frame
	var china_row_visible := false
	var japan_visible := false
	for record in panel._list_rows:
		if record["kind"] != "item":
			continue
		var di: int = int(record["index"])
		if earth._countries.names[di] == "China":
			china_row_visible = record["row"].is_visible_in_tree()
		elif earth._countries.names[di] == "Japan":
			japan_visible = record["row"].is_visible_in_tree()
	_check(china_row_visible, "U7a CN 命中中国行可见", "")
	_check(not japan_visible, "U7b 未命中行（JP 日本）隐藏", "")
	panel._search.text_changed.emit("")
	await process_frame
	await process_frame
	var restored_visible := false
	for record in panel._list_rows:
		if record["kind"] == "item" and earth._countries.continents[int(record["index"])] == "Asia":
			restored_visible = restored_visible or record["row"].visible
	_check(restored_visible, "U7c 清空搜索还原列表", "")

	# U8 设置面板：返回行 + 全屏开关行 + 呈现模式单选行（齿轮左上 40 主入口；行 0=返回，1=全屏开关，2-6=地图类型）
	var settings: Control = earth.get_node("EarthSettings")
	settings.open_panel()
	await process_frame
	# 返回行随场景选择页存在性降级（独立仓库无 picker）；行序用组件行模型，不写死
	_check(settings.has_back() == ResourceLoader.exists("res://scenes/scene_picker.tscn") and (not settings.has_back() or settings.back_label.contains("返回")), "U8a 返回行随场景选择页存在性降级", "label=%s" % settings.back_label)
	_check(settings.has_switch() and settings.switch_label == "全屏", "U8b 设置面板含全屏开关行", "")
	_check(settings.count() == 5, "U8c 地图类型 5 行", "n=%d" % settings.count())
	_check(earth.get_node_or_null("WindowButton") == null, "U8d 最大化按钮节点已废", "")
	var switch_before: bool = settings.switch_checked
	settings._handle_press(settings._row_rect(settings._switch_row_index()).position + Vector2(30.0, settings.row_height * 0.5))
	_check(settings.switch_checked != switch_before, "U8e 开关行点击翻转", "checked=%s" % str(settings.switch_checked))
	var mode_before: String = earth.presentation_mode
	settings._handle_press(settings._row_rect(settings._option_row_offset() + 1).get_center())  # 首个选项行 + 1 = 卫星影像
	await process_frame
	_check(earth.presentation_mode == "satellite" and earth.presentation_mode != mode_before, "U8f 设置面板切地图类型", "%s -> %s" % [mode_before, earth.presentation_mode])
	settings.close_panel()

	# U9 港澳台展示：CN-HK 中国-香港 / CN-MO 中国-澳门 / CN-TW 中国-台湾
	panel._tabs.set_active(1)
	await process_frame
	var region_expect := {"Hong Kong": "CN-HK", "Macao": "CN-MO", "Taiwan": "CN-TW"}
	for record in panel._list_rows:
		if record["kind"] != "item":
			continue
		var di: int = int(record["index"])
		var en: String = earth._countries.names[di]
		if region_expect.has(en):
			var row: Control = record["row"]
			var iso_text: String = row.get_child(0).text
			var zh_text: String = row.get_child(1).text
			var expect_iso: String = region_expect[en]
			var expect_zh: String = "中国-" + str(["香港", "澳门", "台湾"][["Hong Kong", "Macao", "Taiwan"].find(en)])
			_check(iso_text == expect_iso and zh_text == expect_zh, "U9 " + en + " 展示 " + expect_iso + " " + expect_zh, "iso=%s zh=%s" % [iso_text, zh_text])

	# U10 名称排序 = 二字码排序：亚洲组内首行应为 AE 阿联酋（AE < AF < ...，东帝汶 TL 靠后）
	panel._set_sort("name")
	await process_frame
	await process_frame
	var asia_first_code := ""
	var asia_last_code := ""
	for pos in panel.row_count():
		var di: int = panel.country_row_data(pos)
		if di >= 0 and earth._countries.continents[di] == "Asia":
			if asia_first_code == "":
				asia_first_code = str(panel._region_display(di)[0])
			asia_last_code = str(panel._region_display(di)[0])
	_check(asia_first_code == "AE", "U10 名称序亚洲首行 AE（二字码排序）", "first=%s" % asia_first_code)
	_check(asia_last_code == "", "U10 名称序亚洲末行无码实体（码列空、排序垫底）", "last=%s" % asia_last_code)

	print("—— UI 自检：%d 项，%d FAIL ——" % [_total, _fail])
	print("RESULT PASS=", _total - _fail, " FAIL=", _fail)
	quit(1 if _fail > 0 else 0)


## 按标签找下拉选项行号
func _option_row(select: Control, label: String) -> int:
	for i in select.options.size():
		if str(select.options[i][0]) == label:
			return i
	return -1


func _check(passed: bool, label: String, detail := "") -> void:
	_total += 1
	if not passed:
		_fail += 1
	print(("PASS " if passed else "FAIL ") + label + ("  " + detail if detail != "" else ""))


func _click_at(pos: Vector2) -> void:
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = pos
	Input.parse_input_event(press)
	var release := InputEventMouseButton.new()
	release.button_index = MOUSE_BUTTON_LEFT
	release.pressed = false
	release.position = pos
	Input.parse_input_event(release)
	Input.flush_buffered_events()
