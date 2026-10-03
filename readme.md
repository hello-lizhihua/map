# map

三维地球地图（Godot 4.x）。Natural Earth 110m 数据驱动的 242 国交互地图：拖动旋转、10 级缩放、点击/双击选中国家、大洲与组织维度多选高亮、地形高程位移、中国国界与十段线（中国标准地图数据）。

基于 [godot-element-plus](https://github.com/hello-lizhihua/godot-element-plus) 组件库构建右侧面板（页签、维度下拉、排序、搜索、手风琴国家列表）。

## 功能

- **地球渲染**：位移球体（512 段网格 + 高程贴图，珠峰 0.2 倍温和夸张）、程序化丝绸幕布天球、五种呈现模式（模拟地图 / 卫星影像 / 政治区划 / 人口着色 / 经济着色）
- **国家交互**：点击拾取（射线求交 + 点在多边形）、双击对准、242 国遮罩高亮、国界描边窄带
- **维度筛选**：大洲（含「全部」互斥项）与组织（上合、金砖、北约、欧盟、G20、G7 等）多选，多编组按序取色叠加
- **国家面板**：国家(242) / 选中 双页签、面积/人口/名称 × 正序/倒序排序、ISO 码或中文名搜索、港澳台「CN-HK 中国-香港」展示
- **左上控制排**：齿轮设置面板（呈现模式、全屏、返回）、10 级缩放滑块（经过刻度琥珀点亮）
- **面板几何互斥**：同时可见面板两两不相交，测试断言锁定

## 目录结构

```
addons/godot-element-plus -> ../../godot-element-plus/packages/components
assets/data/              # Natural Earth 瘦数据 + 530 张国家/编组高亮遮罩
assets/textures/earth/    # 底图与高程贴图
scenes/earth.tscn         # 入口场景（逻辑全部代码构建）
scripts/earth/            # 地球、面板、HUD、图例、国家数据底座
layout/panel.html         # 面板布局设计稿（1600×900）
tools/                    # 数据生成（Natural Earth → JSON/遮罩/贴图）与截图管线
tests/earth_test.gd       # 138 项 headless 自检
```

## 接入组件库

本仓库经符号链接引用 [godot-element-plus](https://github.com/hello-lizhihua/godot-element-plus) 组件库，克隆组件库到任意位置后创建软链（示例为两仓库并排放置）：

```bash
# macOS / Linux
ln -s ../../godot-element-plus/packages/components addons/godot-element-plus
# Windows（开发者模式或管理员 PowerShell）
New-Item -ItemType SymbolicLink -Path addons\godot-element-plus -Target ..\godot-element-plus\packages\components
```

软链路径不提交，按你的目录结构调整命令即可。

## 开发

```bash
pnpm dev        # 运行（需 godot 在 PATH）
pnpm test       # headless 自检：138 项，0 FAIL
pnpm shots      # 截图管线（输出 screenshots/）
```

数据再生成（需 Python：geopandas / numpy / pillow）：

```bash
python3 tools/make_countries.py   # Natural Earth → countries.json + 遮罩
python3 tools/make_terrain.py     # 高程贴图
python3 tools/make_overlays.py    # 政区/人口/经济底图
```

## 数据来源

- [Natural Earth](https://www.naturalearthdata.com/) 110m（公有领域），国家属性与几何
- 中国国界与十段线采用中国标准地图数据

## License

MIT
