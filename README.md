# iQOO 温控模块仓库

这个仓库用分支分别存放 iQOO 设备的温度伪装 / 解除温控模块：

| 分支 | 设备 | 说明 |
|---|---|---|
| [iqoo15-thermal](../../tree/iqoo15-thermal) | iQOO 15（V2505A / PD2505） | 15 分类温度伪装 34°C + 只读节点伪装 + 电池循环伪装 + 解除温控降频 |
| [iqoo9-thermal](../../tree/iqoo9-thermal) | iQOO 9 | AaTempSpoof 内核模块版：温度伪装 + 温控墙解除 |
| [iqoo9-chg-temp-spoof](../../tree/iqoo9-chg-temp-spoof) | iQOO 9 | 充电链路温度伪装（kretprobe，36°C） |

## 安装
1. 切到对应分支，或直接下载该分支 `release/`（部分分支在 `out/`）下的 zip
2. 在 KernelSU / Magisk 管理器中安装
3. 重启（iQOO 15 可免重启立即生效）后打开 WebUI 配置

## 说明
- 模块都按对应机型的内核节点适配，跨机型安装会拒绝或部分失效
- 温度伪装会让系统热控读不到真实温度；解除温控会放开温度墙与频率限制，长期高温运行有硬件风险，请自行评估
- 仓库只存放模块源码与发布包

## 许可证
仅限个人学习与自用，禁止商业售卖。
