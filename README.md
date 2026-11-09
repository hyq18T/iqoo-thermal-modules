# iQOO 9 温度伪装模块（iqoo9-thermal）

基于 AaTempSpoof 框架定制的 iQOO 9 温度伪装模块（内核模块 + 用户态配置）。

## 功能
- 通过内核模块 hook 温度读取接口，伪装 CPU / GPU / DDR / 电池 / 充电相关温度
- 电池循环次数伪装
- WebUI 状态 / 配置 / 设置三个页签
- 充电温度伪装：bat_board_temp、usb_conn_temp、master_bat_conn_temp、bat_conn_temp 等

## 内容
- `bin/AaTempSpoof`：主程序
- `bin/bq_pwr_aux.ko`：充电相关内核模块
- `bin/lkm_setup`：内核模块加载脚本
- `bin/config/AaTempSpoof/`：开关与参数
- `webroot/index.html`：WebUI
- `release/AAaTempSpoof_iQOO9_v13.5-iqoo9.3.zip`：发布包

## 注意
- 仅适配 iQOO 9，其他机型不要安装
- 内核模块需要与内核版本匹配，系统升级后可能失效
- 仍有两处无法伪装：MCU 固件级保护、`/sys/class/stm32_debug/*` 调试节点（只显示真实值，不影响充电算法）
- 仅限个人自用

## 安装
管理器安装 release 下的 zip，重启生效。
