# iQOO 9 充电链路温度伪装（iqoo9-chg-temp-spoof）

适配：iQOO 9（V2171A / PD2171，内核 5.10.233-gki），KernelSU / Magisk

## 功能
- 内核 kretprobe 把充电链路读取的温度统一伪装为 36.0°C：
  - cms 主板 NTC、并联板 NTC、USB 连接器 NTC（两路）、电池 NTC（两路）
  - STM32 MCU 的 NTC 通道（bat_conn_temp / master_bat_conn_temp / bat_board_temp，经 `stm32l011_temp_from_voltage` 统一改写）
  - `thermal_zone_get_temp` 覆盖指定热区
- 电池 FG / 热区 / 系统上报温度通过 vivo `cms_class/fixed_temp` 锁定
- 总开关 + 分项掩码（func_mask / zone_mask）可调，关闭立即恢复真实温度
- v0.3.0 增加只读观察钩子（step 充电电流 / fastchg 检查 / keep-soc 上限），不改变充电行为

## 目录
```
src/iq9_chg_temp_spoof.c        内核模块源码（kretprobe）
scripts/build_iq9_chg.sh        交叉编译脚本
scripts/gen_versions.py         生成 __versions
scripts/package.py              打包脚本
out/                            编译产物（.ko / release zip）
magisk-module/iq9_chg_temp_spoof/  模块本体（setup / service / module.prop）
```

## 安装
管理器安装 `out/iq9_chg_temp_spoof_v0.3.0.zip`，重启生效。总开关与分项掩码在模块配置中调整。

## 注意
- 内核模块需要与内核版本匹配，系统升级后需要重新编译
- 与其它温度伪装 / 去温控模块冲突，不要同时安装
- 仅限个人自用，使用风险自担
