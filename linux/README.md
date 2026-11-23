# Wi-Fi 信道顾问 · Linux 版

> 分析周边 AP 的干扰，为指定 SSID 推荐最干净的信道。只需要 `bash 4.4+` 和任意 `awk`，不装 Python、不用编译。

![Platform](https://img.shields.io/badge/platform-Linux-4EAA25?logo=linux&logoColor=white)
![Bash](https://img.shields.io/badge/Bash-4.4%2B-4EAA25?logo=gnubash&logoColor=white)
![License](https://img.shields.io/badge/license-MIT-green)
![Dependencies](https://img.shields.io/badge/dependencies-none-brightgreen)

**简体中文** | [English](README.en.md) · [← 项目首页](../README.md) · [Windows 版文档](../windows/README.md)

---

## 这是什么

路由器默认的「自动信道」经常把 2.4 GHz 选在整栋楼最挤的位置。手机上的 Wi-Fi 分析 App 只能看信号强弱，看不出**当前信道到底被压了多少**，也说不清换成哪个信道会更好。

`Get-BestChannel.sh` 是 [Windows 版](../windows/README.md) 的 bash 移植，做同样三件事：

1. **读当前连接**——SSID、BSSID、波段、信道、协议、信号
2. **扫周边 AP**——所有可见热点（含未连接的），按 BSSID 逐个列出波段、信道、信号、信道利用率
3. **算信道干扰并给结论**——把同波段邻居按功率和频谱重叠度叠加成「干扰分」，对每个候选信道打分，直接告诉你该切到哪个信道、能降多少

评分公式与 Windows 版完全一致，**对同一份扫描数据会给出相同的信道排序**（`tests/` 里有交叉验证）。所以可以直接拿 Windows 上抓的数据到这里复核，或者反过来。

适合跑在 OpenWrt 路由器、NAS、树莓派、以及任何一台懒得装东西的 Linux 机器上。

---

## 快速开始

```bash
git clone https://github.com/BigW-Rockies/wifi-channel-advisor.git
cd wifi-channel-advisor/linux
chmod +x Get-BestChannel.sh

# 分析当前连接的 SSID（NetworkManager 环境走 nmcli，免 root）
./Get-BestChannel.sh

# 给指定 SSID 找信道
./Get-BestChannel.sh --ssid 'Maple'

# 没有 NetworkManager（路由器 / 精简发行版）时走 iw，扫 AP 需要 root
sudo ./Get-BestChannel.sh --ssid 'Maple'

# 邻居多为 80MHz 时复核
sudo ./Get-BestChannel.sh --ssid 'Maple' --width 80 --neighbor-width 80
```

多频路由器（同名 SSID 同时广播 2.4 GHz 和 5 GHz）会**按波段分段分析，每段各给一个结论**，最后一张汇总表。扫不到目标 SSID 时会明确告知，而不是给一个假结论。

### 三个后端，自动选择

| 顺序 | 后端 | 需要 root | 能提供 |
|---|---|---|---|
| 1 | `nmcli` | 否 | SSID / BSSID / 信道 / 频率 / 信号百分比。**拿不到 BSS Load**，负载系数恒为 1 |
| 2 | `iw dev <if> scan` | 是（CAP_NET_ADMIN） | **真实 dBm**、BSS Load（信道利用率）、DS 参数里的主信道 |
| 3 | `--csv` / `--input` | 否 | 离线分析，完全不碰网卡 |

所以两个后端算出的分数会有细微差别——`iw` 多了信道利用率这个因子。同一个信道排序不受影响，测试里专门验证了这一点。

---

## 输出示例

离线样本（`examples/scan-sample.csv`，SSID 与 MAC 全是占位数据）：

```
目标 SSID : Maple   （命令行 --ssid 指定）
数据来源  : CSV (examples/scan-sample.csv)

========== [1/1] Maple @ 2.4 GHz ==========
  参考 AP   : 02:11:22:33:44:01
  当前信道  : ch6   协议 802.11ax   信号 95% (-52 dBm)
  分析带宽  : 20 MHz   (邻居按 20 MHz 计)

----- 同波段邻居（11 个）-----
  SSID                   BSSID               Chan  Signal     dBm   Util
  Aspen                  02:11:22:33:44:21      1     58%     -71     10
  Bramble                02:11:22:33:44:22      1     32%     -84      -
  Elm                    02:11:22:33:44:33     11     28%     -86      -
  Fern                   02:11:22:33:44:23      1     24%     -88      -
  Juniper                02:11:22:33:44:11      6     46%     -77      -
  ...

----- 候选信道评分（越低越好，前 5 名）-----
  ch13   ########................     0.006
  ch10   ############............     0.010
  ch12   ############............     0.010
  ch11   ###############.........     0.013
  ch2    #################.......     0.014

----- 结论 -----
  建议把 2.4 GHz 切到 ch13：干扰分 0.037 → 0.006，下降 83%。
  仍有 3 个 AP 频谱重叠：Elm@ch11 28%; Sage@ch11 56%; Thyme@ch11 40%

========== 汇总 ==========
  2.4 GHz  当前 ch6    → 建议 ch13   [切换]   干扰分 0.037 → 0.006

========== 说明 ==========
  · 干扰分 = Σ(邻居功率×频谱重叠度×负载)/本机功率，1.0 ≈ 干扰与自身信号等强
  ...
```

评分条越短越好；`[当前]` 标记现在的信道，`[DFS]` 表示雷达信道。末尾的「仍有 N 个 AP 频谱重叠」是提醒：最优信道不等于零干扰。

---

## 参数

| 参数 | 说明 |
|---|---|
| `--ssid NAME` | 目标 SSID，缺省取当前接入的 SSID |
| `--band 2.4\|5\|6` | 只看某个波段 |
| `--width N` | 候选信道带宽，20/40/80/160 |
| `--neighbor-width N` | 假设邻居带宽，默认 20 |
| `--top N` | 展示前 N 个候选信道，默认 5 |
| `--stay-threshold R` | 当前信道只差 R 以内就不建议动，默认 0.15 |
| `--include-dfs` / `--dfs-penalty R` | 放宽 / 调整 DFS 惩罚 |
| `--iface NAME` | 指定无线接口，缺省自动探测 |
| `--scan-rounds N` / `--gap-ms N` | 多轮扫描合并，默认 3 轮 / 1500ms |
| `--input FILE` | 离线分析 `nmcli` 导出或 `iw ... scan` 原始输出（格式自动识别） |
| `--csv FILE` | 离线分析带表头的扫描 CSV（与 `examples/` 同格式） |
| `-q` / `--help` / `--version` | 安静模式（不输出说明段）/ 帮助 / 版本 |

`--input` 会自动识别格式，`nmcli` 与 `iw` 两种都能吃：

```bash
nmcli -f SSID,BSSID,CHAN,SIGNAL dev wifi list --rescan yes > scan.txt
sudo iw dev wlan0 scan > scan.txt
./Get-BestChannel.sh --input scan.txt --ssid 'Maple'
```

Windows 上抓的 `netsh` 输出**不能**直接喂给 `--input`（格式与 `iw`/`nmcli` 都不同）。正确做法是在 Windows 上用 `Get-WifiNeighbors.ps1 | Export-Csv` 导出 CSV，再拿到 Linux 上 `--csv` 分析——两边表头是同一套：

```powershell
.\Get-WifiNeighbors.ps1 | Export-Csv my-scan.csv -NoTypeInformation -Encoding UTF8
```

```bash
./Get-BestChannel.sh --csv my-scan.csv --ssid 'Maple'
```

---

## 关于 WSL

**WSL2 里扫不到 Wi-Fi，这不是脚本的问题。** WSL2 拿到的是 Hyper-V 虚拟网卡，`iw` / `nmcli` 在里面看不到任何无线设备，物理上就无法扫描。在 WSL 里只能用离线模式验证分析逻辑：

```bash
# 用仓库自带的合成样本
./Get-BestChannel.sh --ssid 'Maple' --csv examples/scan-sample.csv

# 或者先在 Windows 侧导出真实扫描结果，再拿到 WSL 里分析
#   Windows: .\Get-WifiNeighbors.ps1 | Export-Csv my-scan.csv -NoTypeInformation -Encoding UTF8
./Get-BestChannel.sh --ssid 'Maple' --csv /mnt/c/Users/<你>/my-scan.csv
```

要真实扫描，得在真机 Linux、或把 USB 无线网卡直通给虚拟机。

---

## 干扰模型

```
干扰分(ch) = Σ[ 邻居功率(mW) × 频谱重叠度 × 负载系数 ] / 参考AP功率(mW)
```

- **功率**：`iw` 给的是真实 dBm；`nmcli` 只给百分比，按 `rssi ≈ quality/2 - 100` 反推。百分比的曲线**不是线性**的，强信号端偏差可达 10 dB，所以干扰分是**相对量级**，不要当绝对 dB 读。
- **频谱重叠度**：把两个 AP 的频谱当矩形，算交叠宽度 / 候选带宽。2.4 GHz 的 ch1 与 ch3 重叠 0.5、ch1 与 ch5 为 0；5 GHz 相邻 20 MHz 信道基本不重叠——**但当邻居跑 80 MHz 时，它会压住整块 4 个信道**。
- **负载系数**：Beacon 帧里的 BSS Load（信道利用率）。只有 `iw` 后端能给，`nmcli` 一律按 1 计。
- **归一化**：除以参考 AP 的功率，所以 `1.0` 表示「干扰功率和自身信号一样强」。
- **DFS 惩罚**：5 GHz 的 ch52–144 是雷达信道，默认加 0.05 的**加法**惩罚——乘法惩罚对 0 分信道无效（0 × 3 还是 0）。
- **滞后阈值**：当前信道比最优信道差不到 15% 时建议保持不动。换信道意味着客户端集体重连。
- **排除自身**：同一 SSID 的其它 BSSID 不计入干扰，否则自己的功率除以自己会凭空多出 1.0。

---

## 测试

59 项断言，全部离线，不需要无线网卡（CI 与 WSL 里都能跑）：

```bash
bash tests/Run-Tests.sh
```

覆盖：

- `nmcli` 与 `iw` 两种抓取格式的解析
- **同一份数据，两个后端必须给出相同的信道排序**
- `--csv` 与 `--input` 的结论一致性
- 宽信道块中心、DFS 加法惩罚、候选信道集合、滞后阈值
- WSL / 容器里「没有无线设备」的提示路径
- `gawk --posix` 下同样通过（兼容 mawk 的语法子集，路由器上换 awk 不会挂）

CI 里另跑一遍示例，断言结论必须落在 **ch13**，否则说明评分模型被改坏了。

## CI

`.github/workflows/ci.yml` 里与 Linux 相关的两个 job：

| Job | 内容 |
|---|---|
| **test-linux** | ubuntu-latest 上跑 `linux/tests/Run-Tests.sh`，并用 `linux/examples/scan-sample.csv` 跑一遍 bash 版分析，校验结论为 ch13、脚本可执行 |
| **shellcheck** | `shellcheck -S warning` 检查 `Get-BestChannel.sh` 与 bash 测试脚本 |

Windows 的两个 job（`test`、`lint`）见 [Windows 版文档](../windows/README.md#ci)。

---

## 已知局限

| 局限 | 说明 |
|---|---|
| **`nmcli` 没有 BSS Load** | NetworkManager 不暴露信道利用率，负载系数恒为 1，分数会略低于 `iw` 的结果。要这个因子就用 `iw` 后端 |
| **`iw` 扫 AP 需要 root** | 扫描要 `CAP_NET_ADMIN`。不想 sudo 就退回 `nmcli`，或者用离线模式 |
| **WSL2 / 容器扫不到 Wi-Fi** | Hyper-V 虚拟网卡没有无线能力，`iw`/`nmcli` 里看不到任何无线设备。这不是脚本 bug，物理限制 |
| **`iw` 的主信道靠 DS 参数** | 部分网卡/驱动不输出 `DS Parameter set`，此时由中心频率反推信道号，宽信道下可能与实际主信道差一格 |
| **邻居带宽未知** | 扫描结果里没有邻居带宽，只能用 `--neighbor-width` 假设，20 / 80 MHz 结论可能相反 |
| **区域法规** | ch12/13、ch149+、6 GHz 的可用性取决于国家代码与固件，最终以路由器可选列表为准 |

---

## 实现中踩过的坑

bash 版除了继承 Windows 版的坑，还有几个自己的：

1. **`nmcli -t` 的转义会切断字段。** 值里的冒号被转义成 `\:`，直接按 `:` 切分会把 BSSID 切成六段。要先把 `\:` 替换成占位符再切，切完再还原。
2. **把自己当成了干扰源。** 第一版把目标 SSID 自己的 BSSID 也喂给了评分器，结果当前信道凭空多出 1.0 的干扰分（自己的功率除以自己）。同一 SSID 的多个 BSSID 属于同一网络，必须排除——这条是拿 PowerShell 版的结果对照才发现的。
3. **`awk` 方言差异。** 路由器上多半是 mawk 或 busybox awk，不是 gawk。脚本只用 POSIX 子集（不用 `gensub`、不用 `length(array)`），并且用 `gawk --posix` 当替身跑过全部测试。
4. **`.sh` 必须是 LF 行尾。** CRLF 会让 shebang 变成 `/bin/bash\r`，报「no such file or directory」这种极具误导性的错。`.gitattributes` 里锁了 `*.sh text eol=lf`。
5. **`shellcheck` 会揪出只赋值不读的变量。** 第一版有个 `inuse` 变量算完就丢，被 `SC2034` 拦下——后来干脆改成把当前连接信息显示出来。
6. **不设 `set -e` 是刻意的。** 扫描失败要给出可读提示并降级到下一个后端，而不是静默退出。所有错误路径都显式处理。

编码、字段名本地化、宽信道块中心、DFS 加法惩罚这几个通用坑，记在 [Windows 版文档](../windows/README.md#实现中踩过的坑) 里。

---

## 兼容性

- **Shell**：`bash 4.4+`（关联数组）；用 `#!/usr/bin/env bash`，不依赖 `/bin/sh`
- **awk**：任意 POSIX awk（mawk / gawk / busybox awk），测试在 `gawk --posix` 下全过
- **发行版**：Ubuntu / Debian / Fedora / Arch / Alpine（装 bash 后）/ OpenWrt 均可
- **权限**：`nmcli` 普通用户；`iw` 扫 AP 需 root；离线模式不需要任何权限
- 函数化组织，可 `source` 复用里面的解析与评分函数

---

## 许可证

[MIT](../LICENSE) © 2026 Rockies

## 免责声明

本工具只**读取**系统的无线状态，不会修改路由器或网卡配置，改信道需要你自己登录路由器后台操作。结论基于当时的扫描快照，邻居环境会变，建议分不同时段多跑几次再决定。
