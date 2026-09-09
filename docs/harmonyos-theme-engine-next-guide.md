# HarmonyOS 5.0+ 主题引擎开发手册

整理日期：2026-05-19  
资料来源：华为开发者文档「主题引擎」与「HarmonyOS 5.0及以上版本主题引擎规范」  
适用场景：NEXT 主题 XML 脚本开发、锁屏/桌面/百变卡片/充电动效/一镜到底/动效调试

> 这是一份开发速查文档，不是华为官网文档的逐字复制。它把官方 5.0+ 主题引擎规范整理成开发时更容易查的结构，并保留官方链接用于确认细节。

## 0. 先记住这件事

HarmonyOS 5.0+ 主题引擎不是 ArkTS 页面，也不是普通 HTML/CSS。它是一套由系统主题引擎解释执行的 XML 描述语言，用 XML 标签声明界面元素、变量、表达式、命令、动画和数据绑定。

典型脚本结构是：

```xml
<?xml version="1.0" encoding="utf-8"?>
<Lockscreen frameRate="60" screenWidth="1080">
  <Var name="w" expression="#screen_width" const="true" />
  <Image name="bg" src="bg.jpg" w="#screen_width" h="#screen_height" />
  <Button x="0" y="0" w="#screen_width" h="#screen_height">
    <Triggers>
      <Trigger action="up">
        <ExternCommand command="unlock" condition="gt(abs(#touch_begin_y-#touch_y),250)" />
      </Trigger>
    </Triggers>
  </Button>
</Lockscreen>
```

开发时要把它当成「声明式场景脚本」来理解：标签负责显示，变量负责状态，表达式负责计算，命令负责改变状态，动画负责时间变化。

## 1. 官方文档入口

- 主题引擎入口：https://developer.huawei.com/consumer/cn/doc/content/themes-engine-0000001054452463
- HarmonyOS 5.0+ 主题引擎规范：https://developer.huawei.com/consumer/cn/doc/content/themes-engine-next-0000002242508358
- HarmonyOS 4.X 及以下规范：https://developer.huawei.com/consumer/cn/doc/content/themes-engine4-0000002530591413

本手册主要整理 5.0+ 规范。官方 5.0+ 规范下共读取到 87 篇相关子文档、184 个示例/代码块。注意：目录中的 `AI语音互动<VoiceCommand>` 在抓取时返回 `document not found`，可能是官方文档链接暂时失效或下架。

## 2. 引擎心智模型

### 2.1 它解决什么问题

主题引擎用于制作风格多变的主题界面，尤其是锁屏、桌面、卡片和充电动效。通过替换素材、变量和 XML 脚本，可以改变界面样式、动画和交互方式。

引擎支持动态帧率：没有动画或数据更新时可停止或低频渲染，动画触发时再提高到高帧率。合理写脚本能兼顾效果和功耗。

### 2.2 四类核心能力

- 视图：显示文字、图片、视频、时间、日期、几何图形、遮罩、分组等。
- 变量与表达式：保存状态、计算坐标、判断条件、拼接资源路径。
- 命令：控制可见性、动画播放、视频播放、跳转、刷新数据、解锁等。
- 动效：基础 2D 动画、高级 2D 效果、3D 效果、一镜到底转场。

### 2.3 开发顺序建议

1. 先选应用位置：锁屏、桌面、卡片或充电动效。
2. 定 `screenWidth`，通常用 1080 做虚拟宽度。
3. 先放静态背景和核心视觉元素。
4. 再加时间、日期、天气、步数等数据。
5. 再加按钮、跳转、解锁、声音、视频命令。
6. 最后加动画和性能优化。

## 3. 应用位置

### 3.1 `Lockscreen`

用途：动态锁屏。  
特点：支持锁屏视觉、时间日期、解锁交互、按钮、命令、动效等。

常用根节点：

```xml
<Lockscreen frameRate="60" screenWidth="1080">
</Lockscreen>
```

关键参数：

- `frameRate`：锁屏刷新帧率，常见值 30 或 60。
- `screenWidth`：虚拟屏幕宽度，配合设备宽高比计算 `#screen_width` 和 `#screen_height`。

### 3.2 `Wallpaper`

用途：动态桌面。  
特点：继承大部分引擎能力，但桌面交互和解锁相关能力要谨慎区分。

常用根节点：

```xml
<Wallpaper screenWidth="1080">
</Wallpaper>
```

注意：桌面视频使用 `Video`，不要再按旧习惯使用 `VideoWallpaper`。

### 3.3 `Widget`

用途：百变卡片。  
特点：用于主题卡片模块，适合做可变视觉组件、快捷信息和简单交互。

### 3.4 `ChargingSkin`

用途：充电动效换肤。  
特点：围绕充电场景展示图片、视频、动画或状态感知效果。

## 4. 通用属性

大多数视图标签都支持一组通用属性。不同标签的最终支持情况以各自文档为准。

高频属性：

- `name`：元素名，后续可通过命令或表达式引用。
- `x` / `y`：左上角坐标，通常支持表达式。
- `w` / `width`：显示宽度。
- `h` / `height`：显示高度。
- `pivotX` / `pivotY`：旋转或缩放中心。
- `rotation`：Z 轴旋转角度。
- `rotationX` / `rotationY`：3D 方向旋转。
- `alpha`：透明度，常见范围 0 到 255。
- `visibility`：可见性，常用 `1/0` 或 `true/false`。
- `align` / `alignV`：水平/垂直对齐。
- `enableMove` / `moveRect`：可移动相关设置。
- `active`：是否激活。
- `category`：分类用途，具体依场景。

非常重要的写法习惯：

```xml
<!-- 不推荐，负号开头容易出问题 -->
<Image x="-#w" />

<!-- 推荐 -->
<Image x="0-#w" />
<Image x="-1*#w" />
```

## 5. 视图标签速查

### 5.1 文本 `Text`

用途：显示普通文字、格式化数据、表达式结果。

常用能力：

- 固定文本：`text`
- 表达式文本：`textExp`
- 格式化输出：`format` + `paras`
- 字体大小：`size`
- 字体颜色：`color`
- 对齐、旋转、透明度、可见性

开发提示：

- 长文本中如果要写英文逗号，注意按官方要求转义。
- 字符串表达式里嵌套数字表达式时，用 `{}` 包起来，例如 `srcExp="number/hour/{int(#system.time.hour1)}_{int(#aniTime)}.png"`。

### 5.2 图片 `Image`

用途：显示图片，是主题里最常用的视觉标签。

常用属性：

- `src`：图片路径。
- `srcExp`：动态图片路径。
- `x/y/w/h`：坐标和尺寸。
- `actual_w/actual_h`：替代旧脚本里的 `bmp_width/bmp_height`。
- `alpha/visibility/rotation`：透明度、可见性、旋转。
- `IsFullScreenNode="true"`：折叠屏和平板全屏图片常用，要求 `x=0`、`y=0`。

开发提示：

- 旧脚本里如果看到 `bmp_width`、`bmp_height`，NEXT 主题里优先改成 `actual_w`、`actual_h`。
- 如果桌面是视频，建议提取视频首帧作为 `Image` 背景兜底。

### 5.3 动态图片 `Image`

用途：根据表达式或变量动态切换图片资源。

典型用法：

```xml
<Image srcExp="weather/icon_{int(#weather_type)}.png" />
```

### 5.4 视频 `Video`

用途：播放本地视频，支持播放控制、循环、音量、缩放模式、首帧兜底。

常用属性：

- `name`：必填，方便 `VideoCommand` 或 `Setter` 控制。
- `src`：视频路径，常见格式包含 mp4/avi/mov。
- `defaultBitmap`：视频未加载或停止时的默认图。
- `play`：是否加载后自动播放。
- `looping`：是否循环。
- `sound`：音量，通常 0 到 1。
- `scaleType`：`fill`、`fit_width`、`center_crop`。
- `transit`：一镜到底转场视频会用到。
- `isTransparent`：透明视频能力，限制很多，慎用。

推荐写法：

```xml
<Image name="videoFirstFrame" src="bg_first_frame.jpg" w="#screen_width" h="#screen_height" />
<Video
  name="mainVideo"
  src="main.mp4"
  w="#screen_width"
  h="#screen_height"
  play="true"
  looping="true"
  sound="0"
  scaleType="center_crop" />
```

视频注意事项：

- 视频文件尽量控制体积，官方一镜到底素材要求中单个视频不超过 25M。
- `defaultBitmap` 指向不存在的图片可能黑屏，用 `Image` 兜底更稳。
- 透明视频只适合明确需要异形透明效果的场景，并注意格式、换源、首帧和分辨率限制。
- 尽量减少多个 `Video` 标签同时存在，可用 `VideoCommand` 换源。

### 5.5 时间 `Time`

用途：显示系统时间。  
常用于锁屏时间、AOD 时间、桌面时间。

开发提示：

- 时间点击跳转能力要按锁屏规范处理。
- 时间数字也可以用 `ImageNumber` 或一镜到底中的 `AodClock`/`LockClock` 做定制样式。

### 5.6 日期 `DateTime`

用途：显示日期、星期、农历等信息。  
开发提示：锁屏上的日历功能一般需要支持跳转。

### 5.7 倒计时 `CountDownTime`

用途：显示指定目标时间的倒计时。  
适合节日主题、纪念日主题、活动主题。

### 5.8 数字图片 `ImageNumber`

用途：用一组数字图片显示数值，例如时间、电量、步数。

注意：

- 数字资源必须从 0 开始命名。
- 序列不能缺失。
- 资源路径和命名要稳定，否则显示会断。

### 5.9 串联图片 `ImageSeries`

用途：把多个图片按序列或表达式串联显示。  
适合做复杂数字、状态组合或自定义图形序列。

### 5.10 帧解锁视图 `SourceImage`

用途：跟随解锁、滑动等进度显示帧图。  
适合做“滑动越多，图片帧越往后”的效果。

### 5.11 遮罩 `Mask`

用途：使用遮罩控制图像显示区域。  
常用于镂空、裁切、局部显隐。

### 5.12 图片混合 `GroupImage`

用途：对多张图片做组合混合。  
适合复杂合成效果。

### 5.13 几何图形

相关标签包括：

- `Line`
- `Rectangle`
- `Circle`
- `Ellipse`
- `Arc`

用途：不用图片素材直接画基础形状，适合进度条、圆环、装饰线、简单图标。

### 5.14 路径解析 `PathUtil`

用途：解析路径，配合几何图形或动效做路径相关计算。  
适合复杂曲线和路径动画。

### 5.15 视图切换 `Swiper`

用途：多视图/多页切换。  
适合做多屏锁屏、左右滑动组件、分页场景。

### 5.16 视图组 `Group`

用途：把一组视图作为整体管理。  
常用于：

- 统一控制显隐。
- 统一做动画。
- 按场景组织锁屏层、桌面层、AOD 层。

推荐结构：

```xml
<Group name="lockLayer" visibility="1">
  <Image src="lock_bg.jpg" />
  <Text text="Lock" />
</Group>
```

## 6. 控件与交互

### 6.1 按钮 `Button`

用途：定义可点击/触摸区域，并绑定触发器。

典型结构：

```xml
<Button name="unlockArea" x="0" y="0" w="#screen_width" h="#screen_height">
  <Triggers>
    <Trigger action="up">
      <ExternCommand command="unlock" condition="gt(abs(#touch_begin_y-#touch_y),250)" />
    </Trigger>
  </Triggers>
</Button>
```

常见 `Trigger action`：

- `down`：按下。
- `up`：抬起。
- `click`：点击。
- `resume`：亮屏/恢复。
- `pause`：熄屏/暂停。

注意：

- NEXT 主题里，`Button` 响应区域以脚本设置的区域为准。
- 如果手指抬起时不在按钮区域内，按钮可能不会响应。
- 首屏可滑动区域或容易误触的位置，跳转命令优先考虑 `click`，避免 `up` 导致解锁后误跳应用。

## 7. 变量与表达式

### 7.1 自定义变量 `Var`

用途：声明数字、字符串、数组、持久化变量和常量。

常用属性：

- `name`：变量名，通过 `#name` 引用。
- `expression`：变量值或表达式。
- `type`：`number`、`string`、`number[]`、`string[]`。
- `threshold`：阈值，变化达到条件时可触发命令。
- `persist`：是否持久化。
- `index`：数组索引。
- `values`：一次性写入数组值。
- `size`：数组长度。
- `const`：是否只赋值一次。

常用写法：

```xml
<Var name="w" expression="#screen_width" const="true" />
<Var name="h" expression="#screen_height" const="true" />
<Var name="isNight" expression="gt(#hour,18)" />
<Var name="title" type="string" expression="'Hello Theme'" />
```

数组写法：

```xml
<Var name="colors" type="string[]" values="'#ffffff','#000000','#ff0000'" const="true" />
<Var name="nums" type="number[]" values="10,20,30" const="true" />
```

注意：

- 字符串常量通常需要额外单引号，例如 `expression="'my string'"`。
- 不写 `persist` 默认不保存。
- 未用 `Var` 声明、但直接使用过的变量，可能不会自动重置；需要在 `resume` 里手动重置。

### 7.2 全局变量 `GlobalVariable`

用途：读取系统或引擎提供的全局状态。  
常见思路：

- 屏幕尺寸：`#screen_width`、`#screen_height`
- 触摸坐标：`#touch_x`、`#touch_y`、`#touch_begin_y`
- 系统时间：与 `#system.time...` 相关变量
- 数据开放变量：天气、日历、音乐、健康、蓝牙等标签提供的数据

### 7.3 变量数组 `VarArray`

用途：管理数组变量。  
适合做多图序列、批量状态、循环选择。

### 7.4 控件数组 `Array`

用途：对一组控件做数组式管理。  
适合批量生成或批量控制类似元素。

### 7.5 数字表达式 `Expression`

用途：在支持数字表达式的属性里做计算和判断。

支持：

- 四则运算：`+ - * / %`
- 括号
- 数学函数：`sin`、`cos`、`tan`、`sqrt`、`abs`、`min`、`max`、`pow`
- 取整和随机：`int`、`round`、`rand`
- 条件判断：`eq`、`ne`、`gt`、`ge`、`lt`、`le`、`ifelse`
- 空值判断：`isnull`
- 数组索引：`#arr[int(#i)]`

常用例子：

```xml
<Var name="slide" expression="min(#PageMove+1,#screen_width)/#screen_width" />
<Image x="ifelse(gt(#slide,0.5),100,0)" src="card.png" />
<Text textExp="'Battery '+int(#battery_level)+'%'" />
```

注意：

- 数字表达式超过较大位数时可能有精度问题，坐标判断建议留 1px 左右余量。
- `-#w` 这类负号开头写法容易出问题，写成 `0-#w` 或 `-1*#w`。

### 7.6 字符串表达式 `StringExpression`

用途：动态拼接文本或资源路径。

常用场景：

- 动态图片路径：天气图标、小时数字、状态图。
- 多语言文本。
- 数据格式化。

示例：

```xml
<Image srcExp="weather/{int(#weather_type)}.png" />
<Image srcExp="number/hour/{int(#system.time.hour1)}_{int(#aniTime)}.png" />
```

## 8. 命令系统

命令是主题脚本的“动作”。视图负责显示，命令负责改变显示或触发系统能力。

### 8.1 基础命令 `Command`

用途：控制元素属性，例如可见性和动画播放。

常用属性：

- `target`：目标，格式一般是 `元素名.属性名`。
- `value`：目标值。
- `condition`：执行条件。
- `delay`：延迟执行。
- `delayCondition`：延迟是否生效的判断。

示例：

```xml
<Command target="lockLayer.visibility" value="false" />
<Command target="shine.animation" value="play" condition="gt(#battery_level,20)" />
<Command target="shine.animation" value="stop" delay="300" />
```

### 8.2 声音命令 `SoundCommand`

用途：播放或控制声音。  
注意：声音资源要注意体积和触发频率，避免亮屏或解锁时重复播放。

### 8.3 可见性命令 `VisibilityCommand`

用途：专门控制可见性。  
适合比 `Command target="xxx.visibility"` 更清晰的场景。

### 8.4 意图命令 `IntentCommand`

用途：跳转应用或系统能力。

注意：

- 包名和类名必须替换成真实目标。
- NEXT 主题中不能可靠跳转二级页面，例如某些付款码页。
- 文件夹包名旧写法 `com.huawei.hmos.filemanager` 需要替换为 `com.huawei.hmos.files`。

### 8.5 视频命令 `VideoCommand`

用途：控制 `Video`，例如播放、暂停、换源、音量。

适合：

- 多个视频复用一个 `Video` 标签。
- 根据状态切换视频源。
- 避免页面里堆很多 `Video` 标签。

### 8.6 变量命令 `VariableCommand`

用途：修改变量值。  
常用于按钮点击后切换状态、翻页、计数、选择皮肤。

### 8.7 通用命令 `ExternCommand`

用途：触发系统或引擎外部能力。

常见场景：

- 解锁：`command="unlock"`
- 刷新或系统交互
- 与特定应用位置相关的外部能力

### 8.8 命令组 `GroupCommands`

用途：把多个命令组合执行。  
适合复杂交互：比如点击按钮后同时暂停动画、隐藏图层、播放视频、修改变量。

### 8.9 周期命令 `CycleCommand`

用途：按周期执行命令。  
适合轮播、循环切换、定时刷新。

### 8.10 数据刷新命令

包括：

- `RefreshWeatherCommand`
- `RefreshHealthyCommand`

用途：刷新天气或运动健康数据。  
注意：数据开放标签的刷新变量要放对位置，尤其系统开放数据刷新标签通常要放在数据标签后面。

### 8.11 全景换肤 `StyleCommand`

用途：切换皮肤或全景风格。  
适合主题内多套视觉方案。

### 8.12 自定义亮屏时间 `KeepScreenOnCommand`

用途：控制亮屏保持时间。  
谨慎使用，避免耗电或影响系统体验。

### 8.13 碰一碰 `CollaborationCommands`

用途：碰一碰相关交互。  
具体能力依设备和主题场景支持情况。

### 8.14 线性振动 `VibrateCommand`

用途：触发振动反馈。  
适合关键点击、解锁、特殊动效节点。

### 8.15 情绪感知 `EmotionCommand`

用途：情绪感知相关能力。  
需要结合官方设备能力与主题审核要求使用。

### 8.16 场景感知跳转 `ScenarioIntentCommand`

用途：根据场景感知做跳转。  
适合出行、日程、运动等场景联动。

### 8.17 隔空手势互动 `SwingCommand`

用途：隔空手势相关互动。  
需要确认目标设备支持。

## 9. 数据开放能力

### 9.1 天气 `Weather`

用途：读取天气数据，例如天气类型、温度、城市、空气、预报等。  
常见搭配：

- `Image srcExp` 动态切天气图标。
- `Text` 显示温度和城市。
- `RefreshWeatherCommand` 刷新数据。

### 9.2 日历 `Calendar`

用途：读取日历相关信息。  
适合锁屏日程、日期卡片、提醒主题。

### 9.3 音乐 `MediaController`

用途：读取和控制音乐播放信息。  
注意：旧标签 `MediaControl` 在 NEXT 主题中应改为 `MediaController`。

### 9.4 运动健康 `Healthy`

用途：读取运动健康数据，例如步数。  
如果要用锁屏步数变量，通常需要先添加 `Healthy` 数据标签。

示例：

```xml
<Healthy polling="true" time="5">
  <Var name="steps_value" />
</Healthy>
```

### 9.5 系统数据开放

用途：读取系统级数据。  
注意：系统数据刷新标签的位置可能影响生效，刷新变量通常放在所有数据标签后面。

### 9.6 步数 `StepCount`

用途：读取步数。  
与 `Healthy` 能力有关，实际写法要根据当前主题位置和数据来源处理。

### 9.7 蓝牙耳机数据 `BluetoothBattery`

用途：读取蓝牙耳机电量等信息。  
适合耳机弹窗、锁屏状态主题。

### 9.8 场景感知数据 `Scenarios`

用途：读取场景感知状态。  
可以与 `ScenarioIntentCommand` 搭配做跳转。

## 10. 适配能力

### 10.1 传感器 `SensorBinder`

用途：绑定传感器数据，驱动视觉变化。  
适合重力、姿态、视差等效果。

### 10.2 摇一摇 `Shake`

用途：响应摇动设备。  
适合彩蛋、切换壁纸、粒子触发。

### 10.3 充电状态 `BatteryCharging`

用途：判断充电状态，驱动充电动效或图层变化。

### 10.4 恒定帧率 `FrameRate`

用途：指定或控制固定帧率。  
适合持续动画，但要注意功耗。

### 10.5 可变帧率 `VariableFramerate`

用途：根据动效需要调整帧率。  
适合低功耗设计：静止低帧率，动起来高帧率。

### 10.6 麦克风音量感知 `Microphone`

用途：根据麦克风音量驱动动画。  
注意权限、设备能力和审核要求。

### 10.7 可交互桌面

用途：桌面上的交互能力。  
注意桌面交互和锁屏交互不是完全一样的，尤其不要把解锁相关逻辑误放到桌面。

## 11. 2D 基础动效

基础动效通常挂在视图标签内部，使用关键帧描述属性随时间变化。

### 11.1 透明度动画 `AlphaAnimation`

用途：让元素淡入、淡出、呼吸闪烁。

关键点：

- `repeat="0"` 常表示无限循环。
- 关键帧用 `Alpha`。
- `a` 通常为 0 到 255。
- `time` 是相对动画起点的毫秒。

示例：

```xml
<Image name="glow" src="glow.png">
  <AlphaAnimation repeat="0">
    <Alpha a="0" time="0" />
    <Alpha a="180" time="800" />
    <Alpha a="0" time="1600" />
  </AlphaAnimation>
</Image>
```

### 11.2 位移动画 `PositionAnimation`

用途：平移元素。

关键帧：

```xml
<Position x="0" y="0" time="0" />
<Position x="100" y="0" time="500" />
```

注意：`x/y` 是相对初始位置的偏移，不一定是绝对坐标。

### 11.3 旋转动画 `RotationAnimation`

用途：旋转元素。  
通常要配合 `pivotX/pivotY` 设置旋转中心。

### 11.4 缩放动画 `SizeAnimation`

用途：改变尺寸或缩放感。  
适合呼吸、放大、收缩。

### 11.5 帧动画 `SourceAnimation`

用途：播放图片帧序列。  
注意帧资源命名和缺失问题。

### 11.6 变量动画 `VariableAnimation`

用途：让变量随时间变化，再由表达式驱动多个元素。  
适合复杂联动，因为一个变量可以同时影响位置、透明度、路径、图片选择等。

示例：

```xml
<Var name="progress">
  <VariableAnimation repeat="1">
    <AniFrame value="0" time="0" />
    <AniFrame value="1" time="1000" />
  </VariableAnimation>
</Var>

<Image x="#progress*200" alpha="int(#progress*255)" src="dot.png" />
```

## 12. 2D 高级动效

### 12.1 网格化位移 `MeshImage-Translation`

用途：把图片网格化后做局部位移。  
适合水面、布料、扭曲、局部形变。

### 12.2 网格化水波纹 `MeshImage-SinMotion`

用途：基于正弦运动做水波纹。  
适合液体、光影、能量波纹。

### 12.3 跟手粒子 `ParticleView`

用途：手指触摸或移动时产生粒子。  
适合星光、雪花、火花、涟漪。

### 12.4 下落动效 `DropPhysicalView`

用途：模拟物体下落。  
适合重力、雨滴、落叶、雪花。

### 12.5 延时解锁

用途：将解锁时机延后，让动画先播放一段。  
注意不要影响用户可用性，延迟太久可能体验差。

### 12.6 2D 物理碰撞 `CollisionWorld`

用途：做 2D 物理碰撞。  
适合小球、碎片、弹跳、碰撞交互。

### 12.7 2D 流体动效 `FluidsComponent`

用途：流体模拟。  
适合液态、烟雾、墨水、能量流效果。  
注意性能，尽量减少覆盖面积和持续时间。

## 13. 3D 高级动效

### 13.1 空间翻转 `StereoView`

用途：3D 翻转或空间层叠。  
适合卡片翻面、空间转场。

### 13.2 穿越动效 `MultiLayer`

用途：多层穿越、景深推进。  
适合一镜到底外的层级空间效果。

## 14. 一镜到底 `LongTake`

一镜到底是 5.0+ 主题里很关键的高级能力。它通过 6 段视频完成锁屏、熄屏显示和桌面之间的连续转场。

### 14.1 六段转场

- `aod2lock.mp4`：熄屏显示到锁屏。
- `lock2home.mp4`：锁屏到桌面。
- `aod2home.mp4`：熄屏显示到桌面。
- `lock2aod.mp4`：锁屏到熄屏显示。
- `home2aod.mp4`：桌面到熄屏显示。
- `home2lock.mp4`：桌面到锁屏。

### 14.2 根节点

```xml
<LongTake frameRate="60" screenWidth="1080">
</LongTake>
```

### 14.3 常见骨架

```xml
<LongTake frameRate="60" screenWidth="1080">
  <Var name="w" expression="#screen_width" const="true" persist="true" />
  <Var name="h" expression="#screen_height" const="true" persist="true" />

  <ExternalCommands>
    <Trigger action="resume">
      <!-- 亮屏时停止不该自动跑的动画 -->
    </Trigger>
    <Trigger action="pause">
      <!-- 熄屏时停止动画或重置状态 -->
    </Trigger>
  </ExternalCommands>

  <Video
    name="transitVideo"
    w="#w"
    h="#h"
    play="false"
    looping="false"
    scaleType="center_crop"
    transit="true" />

  <Group name="homeGroup" visibility="0">
    <!-- 桌面自定义元素 -->
  </Group>

  <GroupClock>
    <AodClock numSrcPath="time" baseRect="..." hourHighRect="..." hourLowRect="..." minHighRect="..." minLowRect="...">
      <Group>
        <!-- AOD 日期、星期、农历等 -->
      </Group>
      <GroupBattery>
        <!-- AOD 必须显示电量信息 -->
      </GroupBattery>
    </AodClock>

    <LockClock numSrcPath="time" baseRect="..." hourHighRect="..." hourLowRect="..." minHighRect="..." minLowRect="...">
      <Group>
        <!-- 锁屏自定义元素与解锁按钮 -->
      </Group>
    </LockClock>
  </GroupClock>

  <StoryBoard name="OneShotAodLock">
    <Setter targetName="transitVideo" targetProperty="play" value="aod2lock.mp4" />
  </StoryBoard>
</LongTake>
```

### 14.4 固定命名，不能随便改

`StoryBoard` 名称：

- `OneShotAodLock`
- `OneShotLockHome`
- `OneShotAodHome`
- `OneShotLockAod`
- `OneShotHomeAod`
- `OneShotHomeLock`

视频文件语义名：

- `aod2lock`
- `lock2home`
- `aod2home`
- `lock2aod`
- `home2aod`
- `home2lock`

### 14.5 `GroupClock`

用途：包住 AOD 和锁屏时间相关内容。  
只用于全屏 AOD 一镜到底场景。

### 14.6 `AodClock`

用途：定义 AOD 的时间样式和位置。  
关键点：

- 可包含日期、星期、农历等附加信息。
- AOD 必须显示电量信息，电量内容放在 `GroupBattery` 内。
- 可通过设置里的熄屏显示全屏开关控制相关组件显示/隐藏。

### 14.7 `LockClock`

用途：定义锁屏时间样式和位置。  
关键参数通常包含：

- `numSrcPath`
- `baseRect`
- `dotRect`
- `hourHighRect`
- `hourLowRect`
- `minHighRect`
- `minLowRect`

### 14.8 `ClockRect`

用途：描述时钟数字或冒号的矩形位置。  
通常包含：

- `left`
- `right`
- `top`
- `bottom`

理解方式：它不是 CSS 盒模型，而是用矩形边界描述数字图在整张时间图里的占位。

### 14.9 一镜到底素材要求

官方文档列出了不同设备的视频分辨率建议。开发时重点记住：

- 直板机示例分辨率：1080 × 2340。
- Pura X 内屏示例分辨率：1440 × 2208。
- 折叠屏需要区分折叠态、展开态竖屏、展开态横屏。
- 平板需要区分竖屏和横屏。
- 平板不支持全屏熄屏显示一镜到底主题。
- 视频格式：MP4。
- 编码：H.265/H.264。
- 音频：AAC/MP3。
- 单个视频文件大小不超过 25M。

转场时长建议：

- 锁屏到 AOD：不超过 900ms。
- 锁屏到桌面：不超过 1200ms。
- AOD 到桌面：不超过 1200ms。
- AOD 到锁屏：不超过 900ms。
- 桌面到锁屏：不超过 1200ms。
- 桌面到 AOD：不超过 900ms。

## 15. 多语言与数学曲线

### 15.1 图片多语言 `PicMultiLanguage`

用途：根据语言切换图片资源。  
适合含文字的图片素材。

建议：

- 尽量把可翻译文字做成 `Text`，减少图片多语言维护成本。
- 如果必须用图片文字，保持各语言文件名和尺寸一致。

### 15.2 变速函数 `VarSpeedFun`

用途：定义非线性速度曲线。  
适合缓入缓出、弹性、物理感运动。

## 16. 高危坑位清单

### 16.1 通用坑

- 表达式不要用负号直接开头，例如 `x="-#w"`，改为 `x="0-#w"`。
- 坐标和判断可能有精度误差，临界判断建议加一点余量。
- 底部相机坐标不能被锁屏通知遮挡。
- 锁屏时间和日历通常需要支持跳转。
- 底部天气、相机等图标如需跳转，优先考虑双击或防误触设计。
- 亮屏时不该启动的动画，在 `ExternalCommands` 的 `resume` 中停止。
- 熄屏时需要停止的动画，在 `pause` 中调用 `stop`。

### 16.2 视图坑

- `Image` 旧属性 `bmp_width/bmp_height` 改成 `actual_w/actual_h`。
- `Video defaultBitmap` 文件不存在可能黑屏。
- 桌面视频用 `Video`，不要用旧的 `VideoWallpaper`。
- 桌面视频建议用首帧 `Image` 做背景兜底。
- `ImageNumber` 数字资源从 0 开始，序列不能缺失。
- 折叠屏和平板全屏 `Image` 或 `Video` 加 `IsFullScreenNode="true"` 时，`x/y` 必须为 0。

### 16.3 变量坑

- 负数变量计算前面补 0，例如 `0-#w`。
- 坐标计算有精度误差，边界判断加偏移量。
- 字符串表达式嵌套数字表达式时用 `{}`。
- 直接使用但未声明的变量可能不会重置，`resume` 里手动重置。
- `persist` 不写默认不保存。

### 16.4 控件坑

- `Button` 响应区域只看脚本中设置的区域。
- 手指抬起时不在按钮区域内，`Button` 可能不响应。
- 滑动区域里的跳转优先用 `click` 代替 `up`，减少误触。

### 16.5 命令坑

- `IntentCommand` 的包名和类名要换成实际目标。
- NEXT 主题里不要依赖 `IntentCommand` 跳二级页面。
- 文件夹包名用 `com.huawei.hmos.files`。

### 16.6 数据坑

- 系统数据刷新标签位置很重要，通常放在所有数据标签之后。
- 锁屏步数使用前要补 `Healthy` 数据标签。
- 音乐控制旧标签 `MediaControl` 改成 `MediaController`。

## 17. 开发模板

### 17.1 锁屏基础模板

```xml
<?xml version="1.0" encoding="utf-8"?>
<Lockscreen frameRate="60" screenWidth="1080">
  <Var name="w" expression="#screen_width" const="true" />
  <Var name="h" expression="#screen_height" const="true" />

  <ExternalCommands>
    <Trigger action="resume">
      <!-- 重置变量、停止不该自动播放的动画 -->
    </Trigger>
    <Trigger action="pause">
      <!-- 停止动画、暂停视频 -->
    </Trigger>
  </ExternalCommands>

  <Group name="backgroundLayer">
    <Image src="bg.jpg" x="0" y="0" w="#w" h="#h" />
  </Group>

  <Group name="timeLayer">
    <Time x="80" y="160" />
    <DateTime x="80" y="300" />
  </Group>

  <Group name="interactionLayer">
    <Button x="0" y="0" w="#w" h="#h">
      <Triggers>
        <Trigger action="up">
          <ExternCommand command="unlock" condition="gt(abs(#touch_begin_y-#touch_y),250)" />
        </Trigger>
      </Triggers>
    </Button>
  </Group>
</Lockscreen>
```

### 17.2 桌面视频模板

```xml
<?xml version="1.0" encoding="utf-8"?>
<Wallpaper screenWidth="1080">
  <Var name="w" expression="#screen_width" const="true" />
  <Var name="h" expression="#screen_height" const="true" />

  <Image name="firstFrame" src="video_first_frame.jpg" x="0" y="0" w="#w" h="#h" />

  <Video
    name="wallpaperVideo"
    src="wallpaper.mp4"
    x="0"
    y="0"
    w="#w"
    h="#h"
    play="true"
    looping="true"
    sound="0"
    scaleType="center_crop" />
</Wallpaper>
```

### 17.3 动效联动模板

```xml
<Var name="introProgress">
  <VariableAnimation repeat="1">
    <AniFrame value="0" time="0" />
    <AniFrame value="1" time="900" />
  </VariableAnimation>
</Var>

<Image
  name="logo"
  src="logo.png"
  x="80"
  y="200"
  alpha="int(#introProgress*255)"
  rotation="ifelse(gt(#introProgress,0),#introProgress*12,0)" />
```

### 17.4 数据驱动天气模板

```xml
<Weather polling="true" time="30">
  <Var name="weather_type" />
  <Var name="temperature" />
</Weather>

<Image srcExp="weather/{int(#weather_type)}.png" />
<Text textExp="int(#temperature)+'°'" size="42" color="#ffffff" />
```

### 17.5 一镜到底转场模板

```xml
<LongTake frameRate="60" screenWidth="1080">
  <Var name="w" expression="#screen_width" const="true" persist="true" />
  <Var name="h" expression="#screen_height" const="true" persist="true" />

  <Video name="transition" w="#w" h="#h" play="false" looping="false" scaleType="center_crop" transit="true" />

  <StoryBoard name="OneShotAodLock">
    <Setter targetName="transition" targetProperty="play" value="aod2lock.mp4" />
  </StoryBoard>

  <StoryBoard name="OneShotLockHome">
    <Setter targetName="transition" targetProperty="play" value="lock2home.mp4" />
  </StoryBoard>

  <StoryBoard name="OneShotAodHome">
    <Setter targetName="transition" targetProperty="play" value="aod2home.mp4" />
  </StoryBoard>

  <StoryBoard name="OneShotLockAod">
    <Setter targetName="transition" targetProperty="play" value="lock2aod.mp4" />
  </StoryBoard>

  <StoryBoard name="OneShotHomeAod">
    <Setter targetName="transition" targetProperty="play" value="home2aod.mp4" />
  </StoryBoard>

  <StoryBoard name="OneShotHomeLock">
    <Setter targetName="transition" targetProperty="play" value="home2lock.mp4" />
  </StoryBoard>
</LongTake>
```

## 18. 代码审查 Checklist

开发或改主题 XML 时，按这个顺序检查：

- 根节点是否符合应用位置：`Lockscreen`、`Wallpaper`、`Widget`、`ChargingSkin`、`LongTake`。
- 是否设置了合理的 `screenWidth`。
- 负数表达式是否避免了 `-#var` 这种形式。
- 全屏图片/视频在折叠屏和平板是否处理了 `IsFullScreenNode`。
- 视频是否有首帧兜底，且资源存在。
- 是否堆了太多 `Video` 标签，能否用 `VideoCommand` 换源。
- 变量是否需要 `persist`，不需要持久化的不要乱开。
- 临界判断是否考虑了精度误差。
- `Button` 区域是否覆盖正确，是否存在误触风险。
- `IntentCommand` 包名/类名是否替换。
- 锁屏步数是否补了 `Healthy`。
- `MediaControl` 是否改为 `MediaController`。
- `ExternalCommands resume/pause` 是否停止不必要动画。
- 一镜到底 `StoryBoard` 固定命名是否正确。
- 一镜到底 6 段视频文件名和方向是否对应。
- 平板是否误用了全屏 AOD 一镜到底。

## 19. 本地索引：官方 5.0+ 子文档

### 19.1 主目录

- [HarmonyOS 5.0及以上版本主题引擎规范](https://developer.huawei.com/consumer/cn/doc/content/themes-engine-next-0000002242508358)
- [引擎介绍](https://developer.huawei.com/consumer/cn/doc/content/themes-engine-next-introduction-0000002279818389)
- [应用位置](https://developer.huawei.com/consumer/cn/doc/content/themes-engine-next-scope-0000002279698481)
- [基础功能](https://developer.huawei.com/consumer/cn/doc/content/themes-engine-next-base-0000002279818413)
- [2D基础动效](https://developer.huawei.com/consumer/cn/doc/content/themes-engine-next-2d-0000002471235130)
- [2D高级动效](https://developer.huawei.com/consumer/cn/doc/content/themes-engine-next-2da-0000002504275081)
- [3D高级动效](https://developer.huawei.com/consumer/cn/doc/content/themes-engine-next-3d-0000002504355019)
- [一镜到底](https://developer.huawei.com/consumer/cn/doc/content/themes-engine-next-longtake-0000002499571316)
- [注意事项](https://developer.huawei.com/consumer/cn/doc/content/themes-engine-next-precautions-0000002504275099)

### 19.2 应用位置

- [锁屏<Lockscreen>](https://developer.huawei.com/consumer/cn/doc/content/themes-engine-next-lock-0000002244659534)
- [桌面<Wallpaper>](https://developer.huawei.com/consumer/cn/doc/content/themes-engine-next-home-0000002244819386)
- [百变卡片<Widget>](https://developer.huawei.com/consumer/cn/doc/content/themes-engine-next-fa-0000002471234980)
- [充电动效换肤<ChargingSkin>](https://developer.huawei.com/consumer/cn/doc/content/themes-engine-next-charging-0000002490002440)

### 19.3 基础功能索引

- [视图：通用属性](https://developer.huawei.com/consumer/cn/doc/content/themes-engine-next-base-general-0000002504354839)
- [视图：文本<Text>](https://developer.huawei.com/consumer/cn/doc/content/themes-engine-next-base-text-0000002471394976)
- [视图：图片<Image>](https://developer.huawei.com/consumer/cn/doc/content/themes-engine-next-base-image-0000002504274921)
- [视图：动态图片<Image>](https://developer.huawei.com/consumer/cn/doc/content/themes-engine-next-base-image2-0000002471234986)
- [视图：视频<Video>](https://developer.huawei.com/consumer/cn/doc/content/themes-engine-next-base-video-0000002504354849)
- [视图：时间<Time>](https://developer.huawei.com/consumer/cn/doc/content/themes-engine-next-base-time-0000002471394986)
- [视图：日期<DateTime>](https://developer.huawei.com/consumer/cn/doc/content/themes-engine-next-base-datetime-0000002504274931)
- [视图：倒计时<CountDownTime>](https://developer.huawei.com/consumer/cn/doc/content/themes-engine-next-base-countdowntime-0000002471234998)
- [视图：数字图片<ImageNumber>](https://developer.huawei.com/consumer/cn/doc/content/themes-engine-next-base-imagenumber-0000002504354859)
- [视图：串联图片<ImageSeries>](https://developer.huawei.com/consumer/cn/doc/content/themes-engine-next-base-imageseries-0000002471394996)
- [视图：帧解锁视图<SourceImage>](https://developer.huawei.com/consumer/cn/doc/content/themes-engine-next-base-sourceimage-0000002504274941)
- [视图：遮罩<Mask>](https://developer.huawei.com/consumer/cn/doc/content/themes-engine-next-base-mask-0000002471235010)
- [视图：图片混合<GroupImage>](https://developer.huawei.com/consumer/cn/doc/content/themes-engine-next-base-groupimage-0000002504354869)
- [视图：几何图形<Geometrical figue>](https://developer.huawei.com/consumer/cn/doc/content/themes-engine-next-base-figure-0000002471395006)
- [视图：路径解析<PathUtil>](https://developer.huawei.com/consumer/cn/doc/content/themes-engine-next-base-pathutil-0000002504274953)
- [视图：视图切换<Swiper>](https://developer.huawei.com/consumer/cn/doc/content/themes-engine-next-base-swiper-0000002471235020)
- [组：视图组<Group>](https://developer.huawei.com/consumer/cn/doc/content/themes-engine-next-base-group-0000002504354879)
- [控件：按钮<Button>](https://developer.huawei.com/consumer/cn/doc/content/themes-engine-next-base-button-0000002471395018)
- [变量：自定义变量<Var>](https://developer.huawei.com/consumer/cn/doc/content/themes-engine-next-base-var-0000002504274963)
- [变量：全局变量<GlobalVariable>](https://developer.huawei.com/consumer/cn/doc/content/themes-engine-next-base-globalvar-0000002471235030)
- [变量：变量数组<VarArray>](https://developer.huawei.com/consumer/cn/doc/content/themes-engine-next-base-vararray-0000002504354889)
- [变量：控件数组<Array>](https://developer.huawei.com/consumer/cn/doc/content/themes-engine-next-base-array-0000002471395028)
- [表达式：数字表达式<Expression>](https://developer.huawei.com/consumer/cn/doc/content/themes-engine-next-base-exp-0000002504274983)
- [表达式：字符串表达式<StringExpression>](https://developer.huawei.com/consumer/cn/doc/content/themes-engine-next-base-stringexp-0000002471235050)
- [命令：基础命令<Command>](https://developer.huawei.com/consumer/cn/doc/content/themes-engine-next-base-command-0000002504354913)
- [命令：声音命令<SoundCommand>](https://developer.huawei.com/consumer/cn/doc/content/themes-engine-next-base-soundcommand-0000002471395052)
- [命令：可见性命令<VisibilityCommand>](https://developer.huawei.com/consumer/cn/doc/content/themes-engine-next-base-visibilitycommand-0000002504274995)
- [命令：意图命令<IntentCommand>](https://developer.huawei.com/consumer/cn/doc/content/themes-engine-next-base-intentcommand-0000002471235064)
- [命令：视频命令<VideoCommand>](https://developer.huawei.com/consumer/cn/doc/content/themes-engine-next-base-videocommand-0000002504354923)
- [命令：变量命令<VariableCommand>](https://developer.huawei.com/consumer/cn/doc/content/themes-engine-next-base-variablecommand-0000002471395064)
- [命令：通用命令<ExternCommand>](https://developer.huawei.com/consumer/cn/doc/content/themes-engine-next-base-externcommand-0000002504275007)
- [命令：命令组<GroupCommands>](https://developer.huawei.com/consumer/cn/doc/content/themes-engine-next-base-groupcommand-0000002471235074)
- [命令：周期命令<CycleCommand>](https://developer.huawei.com/consumer/cn/doc/content/themes-engine-next-base-cyclecommand-0000002504354935)
- [命令：天气数据刷新命令<RefreshWeatherCommand>](https://developer.huawei.com/consumer/cn/doc/content/themes-engine-next-base-refreshweather-0000002471395074)
- [命令：运动健康数据刷新命令<RefreshHealthyCommand>](https://developer.huawei.com/consumer/cn/doc/content/themes-engine-next-base-refreshhealthy-0000002504275017)
- [命令：全景换肤<StyleCommand>](https://developer.huawei.com/consumer/cn/doc/content/themes-engine-next-base-stylecommand-0000002471235086)
- [命令：自定义亮屏时间<KeepScreenOnCommand>](https://developer.huawei.com/consumer/cn/doc/content/themes-engine-next-base-keepscreenon-0000002522202229)
- [命令：碰一碰<CollaborationCommands>](https://developer.huawei.com/consumer/cn/doc/content/themes-engine-next-base-collaboration-0000002489842474)
- [命令：线性振动<VibrateCommand>](https://developer.huawei.com/consumer/cn/doc/content/themes-engine-next-vibratecommand-0000002499411342)
- [命令：情绪感知<EmotionCommand>](https://developer.huawei.com/consumer/cn/doc/content/emotioncommand-0000002551079172)
- [命令：场景感知跳转命令<ScenarioIntentCommand>](https://developer.huawei.com/consumer/cn/doc/content/scenario_intentcommand-0000002550844196)
- [命令：隔空手势互动<SwingCommand>](https://developer.huawei.com/consumer/cn/doc/content/swingcommand-0000002593875461)
- [多语言：图片多语言<PicMultiLanguage>](https://developer.huawei.com/consumer/cn/doc/content/themes-engine-next-base-picmulti-0000002504354947)
- [数学曲线：变速函数<VarSpeedFun>](https://developer.huawei.com/consumer/cn/doc/content/themes-engine-next-base-varspeedfun-0000002471395086)
- [数据开放：天气数据开放<Weather>](https://developer.huawei.com/consumer/cn/doc/content/themes-engine-next-base-weather-0000002504275029)
- [数据开放：日历数据开放<Calendar>](https://developer.huawei.com/consumer/cn/doc/content/themes-engine-next-calendar-0000002531331269)
- [数据开放：音乐数据开放<MediaController>](https://developer.huawei.com/consumer/cn/doc/content/themes-engine-next-base-mediacontroller-0000002471235098)
- [数据开放：运动健康数据开放<Healthy>](https://developer.huawei.com/consumer/cn/doc/content/themes-engine-next-base-healthy-0000002504354957)
- [数据开放：系统数据开放](https://developer.huawei.com/consumer/cn/doc/content/themes-engine-next-base-sysdata-0000002471395102)
- [数据开放：步数<StepCount>](https://developer.huawei.com/consumer/cn/doc/content/themes-engine-next-base-stepcount-0000002504275041)
- [数据开放：蓝牙耳机数据开放<BluetoothBattery>](https://developer.huawei.com/consumer/cn/doc/content/themes-engine-next-base-bluetoothbattery-0000002471235108)
- [数据开放：场景感知数据开放<Scenarios>](https://developer.huawei.com/consumer/cn/doc/content/scenarios-0000002581443929)
- [适配功能：传感器<SensorBinder>](https://developer.huawei.com/consumer/cn/doc/content/themes-engine-next-base-sensorbinder-0000002504354969)
- [适配功能：摇一摇<Shake>](https://developer.huawei.com/consumer/cn/doc/content/themes-engine-next-base-shake-0000002471395112)
- [适配功能：充电状态<BatteryCharging>](https://developer.huawei.com/consumer/cn/doc/content/themes-engine-next-base-batterycharging-0000002504275053)
- [适配功能：恒定帧率<FrameRate>](https://developer.huawei.com/consumer/cn/doc/content/themes-engine-next-base-framerate-0000002471235118)
- [适配功能：可变帧率<VariableFramerate>](https://developer.huawei.com/consumer/cn/doc/content/themes-engine-next-base-variableframerate-0000002504354979)
- [适配功能：麦克风音量感知<Microphone>](https://developer.huawei.com/consumer/cn/doc/content/themes-engine-next-base-microphone-0000002471395124)
- [适配功能：可交互桌面](https://developer.huawei.com/consumer/cn/doc/content/themes-engine-next-base-interactivehome-0000002504275063)

### 19.4 动效索引

- [透明度动画<AlphaAnimation>](https://developer.huawei.com/consumer/cn/doc/content/themes-engine-next-2d-alphaanimation-0000002504354989)
- [位移动画<PositionAnimation>](https://developer.huawei.com/consumer/cn/doc/content/themes-engine-next-2d-positionanimation-0000002471395132)
- [旋转动画<RotationAnimation>](https://developer.huawei.com/consumer/cn/doc/content/themes-engine-next-2d-rotationanimation-0000002504275071)
- [缩放动画<SizeAnimation>](https://developer.huawei.com/consumer/cn/doc/content/themes-engine-next-2d-sizeanimation-0000002471235140)
- [帧动画<SourceAnimation>](https://developer.huawei.com/consumer/cn/doc/content/themes-engine-next-2d-sourceanimation-0000002504354999)
- [变量动画<VariableAnimation>](https://developer.huawei.com/consumer/cn/doc/content/themes-engine-next-2d-variableanimation-0000002471395144)
- [网格化-位移<MeshImage-Translation>](https://developer.huawei.com/consumer/cn/doc/content/themes-engine-next-2da-meshimagetrans-0000002471235150)
- [网格化-水波纹<MeshImage-SinMotion>](https://developer.huawei.com/consumer/cn/doc/content/themes-engine-next-2da-meshimagesinmotion-0000002504355009)
- [跟手粒子<ParticleView>](https://developer.huawei.com/consumer/cn/doc/content/themes-engine-next-2da-particleview-0000002471395152)
- [下落动效<DropPhysicalView>](https://developer.huawei.com/consumer/cn/doc/content/themes-engine-next-2da-dropphysicalview-0000002504275089)
- [延时解锁](https://developer.huawei.com/consumer/cn/doc/content/themes-engine-next-2da-dealyunlock-0000002471235160)
- [2D物理碰撞<CollisionWorld>](https://developer.huawei.com/consumer/cn/doc/content/themes-engine-next-2da-collisionworld-0000002522082247)
- [2D流体动效<FluidsComponent>](https://developer.huawei.com/consumer/cn/doc/content/themes-engine-next-fluids-0000002531251233)
- [空间翻转<StereoView>](https://developer.huawei.com/consumer/cn/doc/content/themes-engine-next-3d-stereoview-0000002471395160)
- [穿越动效<MultiLayer>](https://developer.huawei.com/consumer/cn/doc/content/themes-engine-next-3d-multilayer-0000002490002442)

