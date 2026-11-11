# iQOO 15 温控管家（iqoo15-thermal）

适配：iQOO 15 / V2505A / PD2505，Android 16（内核 6.12.58），KernelSU（Magisk 亦可，WebUI 需管理器支持）
通用：其它 vivo / iQOO 机型走通用模式，只要内核开放可写 `emul_temp` 即可伪装，未识别热区归入「其他热区」；厂商级激进操作（停温控服务 / rmmod / 改 PEM / 风扇）只在已验证的 iQOO 15 上执行，「解除温控降频」在通用机型默认关闭

## 功能
- 温度伪装总开关 + 15 个温度分类独立开关：CPU / GPU / 内存 / 基带 / 相机 / 视频 / 主板壳温 / 屏幕外壳 / 电池 / 充电 IC / USB 无线充 / 射频 / WiFi / PMIC / 其他
- 统一伪装 34.0°C，热区通过内核 `emul_temp` 生效（内核热控读到的就是 34°C）
- 电池上报温度通过 vivo `cms_class/fixed_temp` 锁定（`battery/temp`、`dumpsys battery` 均为 34.0）
- 只读节点伪装：USB 口 / 无线充 / USB 连接器 / 主副板 / 放电曲线 / `bat_therm`，用 bind mount 覆盖
- 电池循环次数伪装（默认 22 次），覆盖所有带 `cycle_count` 的 power_supply 及其 uevent
- uevent 同步守护：自动发现机型上的电量计/充电器节点，每 10 秒重生成假 uevent
- 解除温控降频（iQOO 15）：温度墙抬到 110°C、CPU 频率上限恢复硬件最大值、冷却设备清零，并关闭厂商温控服务与 PEM 限制
- 提高温控墙时自动跳过 `critical` 与未启用的 trip，只处理普通降频墙
- 外观设置：跟随系统深浅色、自定义壁纸、玻璃模糊、触感反馈、页面切换动画
- 开关与备份保存在 `/data/adb/iqoo15_thermal_data`，模块更新 / 重装不会重置，卸载时清除
- 安装时检测机型 / Root 方案 / 冲突模块，非 vivo 或内核不支持 `emul_temp` 会拒绝安装

## 安装
管理器安装 `release/iqoo15_thermal_v1.7.19.zip`，安装后脚本立即生效，开机脚本下次启动接管。

## 异常恢复
开机脚本支持安全模式：新建空文件 `/data/adb/iqoo15_thermal_data/safe_mode` 后重启，模块开机阶段不做任何写入；删除该文件即恢复。

## 使用
WebUI 四个页签：
- 状态：总状态、温度伪装 / 提高温控墙 / 解除温控降频开关、实时读数
- 配置：只读节点伪装（连接器/主板、电池循环）、15 个分类开关
- 热区：全部热区与实时温度
- 设置：目标温度（28–42°C）、外观设置、重新应用、全部还原

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
