# iQOO 15 温控管家（iqoo15-thermal）

适配：iQOO 15 / V2505A / PD2505，Android 16（内核 6.12.58），KernelSU（Magisk 亦可，WebUI 需管理器支持）
通用：其它 vivo / iQOO 机型走通用模式，只要内核开放可写 `emul_temp` 即可伪装，未识别热区归入「其他热区」；厂商级激进操作（停温控服务 / rmmod / 改 PEM / 风扇）只在已验证的 iQOO 15 上执行，「解除温控降频」在通用机型默认关闭

## v1.8.0 动态伪装 / 自定义温度

- 配置页新增「动态伪装 / 自定义温度」面板，15 个分类 + 连接器/主板共 16 项可分别设置
- 每项支持固定值（如 `34`）或随机区间（如 `43-47`），单位 °C，允许 0-47
- 区间写法参考 AaTempSpoof：守护进程默认每 5 秒（1-30 秒可调）用 `/dev/urandom` 重新掷一次，同一分类的所有热区共用同一数值
- 动态守护只在存在区间配置时启动；全部改回固定值后自动退出，不常驻耗电
- 自定义值保存在 `/data/adb/iqoo15_thermal_data/targets.conf`，模块更新/重装不丢失
- 「设置」页目标温度滑块上限从 42°C 放宽到 45°C；拖动滑块会把所有分类统一覆盖为固定值
- 电池、连接器/主板、`cms_class/fixed_temp`、uevent 守护都会跟随对应分类的动态值

## v1.7.23 通用模式进一步放开

- 相机 / 视频 / 壳温 / 屏幕 / 射频 / WiFi / 其他：最高 115°C
- 充电 IC / 电池 / USB / 无线充：最高 110°C
- 仍按各热区 `critical - 5°C` 下压；原值高于上限时保持不动，不会下调
- 继续跳过 `hot` / `critical` / `hw-trip` / `bcl` / `ibat` / `vbat` / `socd` / `pmic` / `xo-therm` 等会触发保护的热区/trip
- iQOO 15 维持原来的 110°C 策略

## v1.7.22 通用模式抬墙细化

- 性能类热区（CPU / GPU / DDR / 基带）最高 110°C，仍按各热区 `critical - 5°C` 下压
- 非性能热区（相机 / 壳温 / 充电 / 电池 / USB / PMIC 等）最高 95°C
- 只跳过会触发保护/关机的热区：`hot` / `critical` / `hw-trip` / `bcl` / `ibat` / `vbat` / `socd` / `pmic` / `charger` / `chg` / `usb` / `wireless` / `battery` / `bq_bms` / `fg_` / `xo-therm`
- 没有 `critical` 的热区：性能类最高 105°C，其它 95°C
- 通用机型抬墙默认开启，激进解限默认关闭
- 已安装 v1.7.21 的用户覆盖安装并重启即可

## v1.7.21 安全修复（其它高通机型死机，已被 v1.7.22 细化）

- 问题：温控墙固定抬到 110°C，在 `critical` 上限较低的高通机型上会超过 critical，
  厂商温控/内核直接触发死机；之前只对 iQOO 15 做了保护
- 现在抬墙前先读取每个热区的 `critical`，永远压在 `critical - 5°C` 以下
- 非 iQOO 15 机型：抬墙上限 95°C，只处理明确标记为 `passive` 的 trip，
  跳过 hot/critical/hw-trip/bcl/ibat/vbat/socd/pmic/charger/usb/battery/xo-therm 等安全关键热区
- 非 iQOO 15 机型首次升级：自动关闭「提高温控墙」与「解除温控降频」，
  需要时可在 WebUI 手动开启（开启后仍受上面的上限保护）
- 温度伪装目标硬上限 45°C，避免上报温度过高被厂商服务判定过热
- 安装时清除 `/dev/.iq15` 旧解密缓存，升级后不会继续跑旧脚本

## 功能
- 温度伪装总开关 + 15 个温度分类独立开关：CPU / GPU / 内存 / 基带 / 相机 / 视频 / 主板壳温 / 屏幕外壳 / 电池 / 充电 IC / USB 无线充 / 射频 / WiFi / PMIC / 其他
- 默认伪装 34.0°C，可按分类自定义固定值或随机区间（如 43-47），热区通过内核 `emul_temp` 生效（内核热控读到的就是设定值）
- 电池上报温度通过 vivo `cms_class/fixed_temp` 锁定（`battery/temp`、`dumpsys battery` 均为 34.0）
- 只读节点伪装：USB 口 / 无线充 / USB 连接器 / 主副板 / 放电曲线 / `bat_therm`，用 bind mount 覆盖
- 电池循环次数伪装（默认 22 次），覆盖所有带 `cycle_count` 的 power_supply 及其 uevent
- uevent 同步守护：自动发现机型上的电量计/充电器节点，每 10 秒重生成假 uevent
- 解除温控降频（iQOO 15）：温度墙抬到 110°C、CPU 频率上限恢复硬件最大值、冷却设备清零，并关闭厂商温控服务与 PEM 限制
- 「提高温控墙」与「解除温控降频」独立于温度伪装，关掉温度伪装后仍单独生效
- 提高温控墙时自动跳过 `critical` 与未启用的 trip，只处理普通降频墙
- 外观设置：跟随系统深浅色、自定义壁纸、玻璃模糊、触感反馈、页面切换动画
- 开关与备份保存在 `/data/adb/iqoo15_thermal_data`，模块更新 / 重装不会重置，卸载时清除
- 安装时检测机型 / Root 方案 / 冲突模块，非 vivo 或内核不支持 `emul_temp` 会拒绝安装

## 安装
管理器安装 `release/iqoo15_thermal_v1.8.0.zip`，安装后脚本立即生效，开机脚本下次启动接管。

## 异常恢复
开机脚本支持安全模式：新建空文件 `/data/adb/iqoo15_thermal_data/safe_mode` 后重启，模块开机阶段不做任何写入；删除该文件即恢复。

## 使用
WebUI 四个页签：
- 状态：总状态、温度伪装 / 提高温控墙 / 解除温控降频开关、实时读数
- 配置：只读节点伪装（连接器/主板、电池循环）、15 个分类开关、动态伪装 / 自定义温度（固定值或随机区间）
- 热区：全部热区与实时温度
- 设置：目标温度（28–45°C）、外观设置、重新应用、全部还原

## 风险提示
- 温度伪装会让系统热控失去真实温度参考，长时间高负载可能过热
- 解除温控会放开温度墙与 CPU 频率限制，请自行评估硬件风险
- 只读节点用 bind mount 实现，仅影响上层读取，不改内核充电算法

## 目录
```
module.prop / customize.sh / service.sh / post-fs-data.sh / action.sh / uninstall.sh
bin/thermal.sh      核心逻辑
bin/ueventd.sh      uevent 同步守护
bin/check_env.sh    安装环境检测
conf/               分类映射与保持真实名单
webroot/index.html  WebUI（AES-256-GCM 加密）
release/            发布包
```
