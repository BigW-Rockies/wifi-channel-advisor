# Wi-Fi 信道顾问

> 为指定 SSID 找出干扰最小的信道。Windows 走系统自带的 `netsh`（PowerShell），Linux 走 `nmcli` 或 `iw`（bash），零第三方依赖、零编译。

![Platform](https://img.shields.io/badge/platform-Windows%2010%20%7C%2011%20%7C%20Linux-0078D6?logo=linux&logoColor=white)
![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-5391FE?logo=powershell&logoColor=white)
![Bash](https://img.shields.io/badge/Bash-4.4%2B-4EAA25?logo=gnubash&logoColor=white)
![License](https://img.shields.io/badge/license-MIT-green)
![Dependencies](https://img.shields.io/badge/dependencies-none-brightgreen)

**简体中文** | [English](README.en.md)

---

## 这是什么

路由器默认的「自动信道」经常把 2.4 GHz 选在整栋楼最挤的位置。想手动固定信道，但手机上的 Wi-Fi 分析 App 只能看信号强弱，看不出**当前信道到底被压了多少**，也说不清换成哪个信道会更好。

这个工具做三件事：

1. **读当前连接**——SSID、BSSID、波段、信道、协议、信号、协商速率
2. **扫周边 AP**——所有可见热点（含未连接的），按 BSSID 逐个列出波段、信道、信号、信道利用率、加密方式
3. **算信道干扰并给结论**——把同波段邻居按功率和频谱重叠度叠加成「干扰分」，对每个候选信道打分，直接告诉你该切到哪个信道、能降多少

Windows 和 Linux 两个版本**共用同一套干扰模型**：对同一份扫描数据，两者会给出完全相同的信道排序（`tests/` 里有专门的交叉验证）。你可以在 Windows 笔记本上抓数据，拿到路由器上跑 Linux 版复核。

全部基于系统自带工具：**不装模块、不装驱动**，复制一个脚本就能跑。

---

## 两个版本

| | Windows | Linux |
|---|---|---|
| **入口脚本** | [`windows/Get-BestChannel.ps1`](windows/Get-BestChannel.ps1) | [`linux/Get-BestChannel.sh`](linux/Get-BestChannel.sh) |
| **运行环境** | Windows 10 / 11，Windows PowerShell 5.1 或 PowerShell 7 | 任意带 `bash 4.4+` 与 `awk` 的发行版（含 OpenWrt） |
| **数据来源** | `netsh wlan` | `nmcli`（免 root）→ `iw`（需 root）→ 离线文件 |
| **权限** | 普通用户 | `nmcli` 免 root，`iw` 扫 AP 需 root |
| **配套小工具** | `Get-WifiNeighbors.ps1`、`Get-WifiSignal.ps1` | — |
| **离线回归测试** | 49 项断言 | 59 项断言 |
| **文档** | [中文](windows/README.md) · [English](windows/README.en.md) | [中文](linux/README.md) · [English](linux/README.en.md) |

Linux 版没有单独的邻居列表工具，因为 `Get-BestChannel.sh` 本身就会把同波段邻居整表打出来；Windows 版把它们拆成独立脚本，方便接管道、导 CSV。

---

## 目录结构

```
wifi-channel-advisor/
├── windows/                      # Windows 版（PowerShell 5.1+）
│   ├── Get-BestChannel.ps1       # 干扰分析 + 信道推荐
│   ├── Get-WifiNeighbors.ps1     # 周边 AP 结构化列表
│   ├── Get-WifiSignal.ps1        # 当前连接实时信号
│   ├── README.md                 # Windows 版文档（中文）
│   ├── README.en.md              # Windows 版文档（英文）
│   ├── examples/                 # 合成样本 + 离线分析脚本
│   └── tests/                    # 49 项离线断言 + netsh 中英文夹具
├── linux/                        # Linux 版（bash 4.4+）
│   ├── Get-BestChannel.sh
│   ├── README.md                 # Linux 版文档（中文）
│   ├── README.en.md              # Linux 版文档（英文）
│   ├── examples/                 # 与 Windows 版同一份合成样本
│   └── tests/                    # 59 项离线断言 + nmcli / iw 夹具
├── .github/workflows/ci.yml      # 4 个 job：test / lint / test-linux / shellcheck
├── LICENSE
├── README.md                     # 你在这里
└── README.en.md
```

---

## 快速开始

```bash
git clone https://github.com/BigW-Rockies/wifi-channel-advisor.git
cd wifi-channel-advisor
```

**Windows**（PowerShell 5.1 或 7）：

```powershell
# 分析当前接入的 SSID
powershell -ExecutionPolicy Bypass -File .\windows\Get-BestChannel.ps1

# 有线连接、或想提前规划还没连的网络
powershell -ExecutionPolicy Bypass -File .\windows\Get-BestChannel.ps1 -SSID 'Maple'
```

> 如果执行策略拦住脚本，就用上面带 `-ExecutionPolicy Bypass` 的形式，或先 `Unblock-File .\windows\*.ps1`。

**Linux**：

```bash
chmod +x linux/Get-BestChannel.sh

# 分析当前连接的 SSID（NetworkManager 环境走 nmcli，免 root）
./linux/Get-BestChannel.sh

# 给指定 SSID 找信道
./linux/Get-BestChannel.sh --ssid 'Maple'

# 没有 NetworkManager（路由器 / 精简发行版）时走 iw，扫 AP 需要 root
sudo ./linux/Get-BestChannel.sh --ssid 'Maple'
```

**没有无线网卡也能先跑通**——用仓库自带的合成样本（SSID / MAC 全是占位数据）：

```powershell
powershell -ExecutionPolicy Bypass -File .\windows\examples\Analyze-Sample.ps1
```

```bash
bash linux/Get-BestChannel.sh --ssid Maple --csv linux/examples/scan-sample.csv
```

两份样本内容一致，所以两边的结论也应该一致：**2.4 GHz 从 ch6 切到 ch13，干扰分 0.037 → 0.006（下降 83%）**。这也是 CI 用来证明「两个实现没跑偏」的方式。

---

## 输出长什么样

真实环境（2.4 GHz，扫到 18 个同波段邻居，SSID 与 MAC 已匿名化）：

```
目标 SSID : Maple   （命令行 -SSID 指定）

========== [1/1] Maple @ 2.4 GHz ==========
  参考 AP   : 02:11:22:33:44:01
  当前信道  : ch6   协议 802.11ax   信号 95% (-52 dBm)
  分析带宽  : 20 MHz   (邻居按 20 MHz 计)

----- 同波段邻居（18 个）-----
SSID              BSSID              Channel Signal RssiEst ChanUtil
Birch             02:11:22:33:44:02        6     42     -79        -
Cedar             02:11:22:33:44:03        6     38     -81        -
Willow            02:11:22:33:44:04       11     55     -72        8
...

----- 候选信道评分（越低越好，前 5 名）-----
  ch13   #.......................    <0.001
  ch10   ##......................     0.001
  ch12   ##......................     0.001
  ch11   ##......................     0.002
  ch9    #######.................     0.006

----- 结论 -----
  建议把 2.4 GHz 切到 ch13：干扰分 0.020 → <0.001，下降 96%。
```

评分条越短越好，`[当前]` 标记现在的信道，`[DFS]` 表示雷达信道。

多频路由器（同名 SSID 同时广播 2.4 GHz 和 5 GHz）会**按波段分段分析，每段各给一个结论**，最后一张汇总表：

```
========== 汇总 ==========
  2.4 GHz  当前 ch6    → 建议 ch13   [切换]   干扰分 0.020 → <0.001
  5 GHz    当前 ch36   → 建议 ch40   [切换]   干扰分 0.046 → 0
```

扫不到目标 SSID 时会明确告知，而不是给一个假结论：

```
警告：当前环境未扫描到SSID: NoSuchWiFi-9527, 请输入正确的SSID，或重试。
      本次扫描返回 21 个 BSSID / 15 个 SSID，Windows 扫描缓存可能不含该网络。
      若确认该网络就在附近，请开关一次 Wi-Fi 强制重扫后重试。
```

---

## 干扰模型

两个版本共用这套公式：

```
干扰分(ch) = Σ[ 邻居功率(mW) × 频谱重叠度 × 负载系数 ] / 参考AP功率(mW)
```

- **功率**：扫描结果只给百分比，先按 `rssi ≈ quality/2 - 100` 反推 dBm，再转毫瓦按功率律叠加。两个 -70 dBm 的邻居约等于一个 -67 dBm，不是简单地数 AP 个数。注意百分比→dBm 在 Windows 里**不是线性映射**，公式在强信号端会偏低（实测 97% 的真实值是 -39 dBm，公式给 -52 dBm），所以干扰分是**相对量级**，不要当绝对 dB 读。
- **频谱重叠度**：把两个 AP 的频谱当矩形，算交叠宽度 / 候选带宽。2.4 GHz 的 ch1 与 ch3 重叠 0.5、ch1 与 ch5 为 0；5 GHz 相邻 20 MHz 信道基本不重叠——**但当邻居跑 80 MHz 时，它会压住整块 4 个信道**。这是最容易被忽略的一点。
- **负载系数**：用 Beacon 帧里的 BSS Load（信道利用率），邻家用得越满，干扰越实。Linux 的 `nmcli` 后端拿不到这个字段，负载系数恒为 1。
- **归一化**：除以参考 AP 的功率，所以 `1.0` 表示「干扰功率和自身信号一样强」，不同环境之间可直接比较。
- **DFS 惩罚**：5 GHz 的 ch52–144 是雷达信道，一旦检测到雷达会强制静默 60 秒以上并降功率。默认加 0.05 的**加法**惩罚——注意是加法，乘法惩罚对 0 分信道无效（0 × 3 还是 0）。
- **滞后阈值**：当前信道比最优信道差不到 15% 时建议保持不动。换信道意味着客户端集体重连，收益不够就别折腾。

完整推导、逐条参数与实现细节见各子目录文档。

---

## 被问得最多的两件事

**「邻居到底跑 20 还是 80 MHz？」**

`netsh` 不告诉你。所以同一个网络，带宽假设不同结论可能完全相反：

```
邻居按 20MHz 算           邻居按 80MHz 算
ch36 [当前] 0  ← 无重叠    ch165  0        ← 推荐
ch40        0              ch149  <0.001
ch44        0              ch36   0.026 [当前]
→ 保持 ch36                → 切到 ch165，干扰降 >99%
```

原因：ch36 与 ch48 在 20 MHz 下相隔 60 MHz，互不干扰；但若那个 ch48 的 AP 实际跑 80 MHz（块 36–48，中心 5210 MHz），它就直接压在 ch36 上。

**结论**：邻居多是近几年的路由器，用 `-NeighborWidth 80`（Linux 是 `--neighbor-width 80`）复核一遍；自己的 AP 也要开 80 MHz 就把带宽参数一起调。两个结果都指向同一信道，才放心改。

**「为什么扫不到邻居 / 只扫到自己？」**

Windows 下 `netsh` 读的是**扫描缓存**，不会主动触发扫描，系统按省电策略裁剪，同一台机器几分钟内可能从「18 个邻居」变成「0 个邻居」。排查顺序：开关一次 Wi-Fi 强制重扫 → 提高扫描轮数（`-ScanRounds 6 -ScanGapMs 3000`）→ 检查 Windows 11 的位置服务是否关闭 → 别忽略脚本给出的「缓存可能陈旧」提示。

Linux 下则是权限问题居多：`nmcli` 拿不到 BSS Load，`iw` 扫 AP 需要 root；WSL2 和容器里根本看不到无线设备（Hyper-V 虚拟网卡没有射频能力）。详见 [Linux 文档](linux/README.md)。

---

## 质量保证

```bash
# Windows：49 项，PS 5.1 与 7 均通过
powershell -ExecutionPolicy Bypass -File .\windows\tests\Run-Tests.ps1

# Linux：59 项，任意 bash 4.4+
bash linux/tests/Run-Tests.sh
```

两套测试全部离线，不需要无线网卡，因此能在 CI 里稳定复现。`.github/workflows/ci.yml` 四个 job：

| Job | 内容 |
|---|---|
| **test** | windows-latest 上分别用 PowerShell 5.1 和 7 跑 Windows 版测试与示例分析 |
| **lint** | PSScriptAnalyzer，只卡 Error / ParseError，不卡 `Write-Host` 这类风格建议（本项目是给人看的 CLI 输出，故意用它） |
| **test-linux** | ubuntu-latest 上跑 Linux 版测试，并用同一份 `scan-sample.csv` 跑一遍 bash 版分析 |
| **shellcheck** | shellcheck `-S warning` 静态检查 `Get-BestChannel.sh` 与 bash 测试脚本 |

除了功能断言，还有两条「防止静默跑偏」的护栏：

- **中英文 `netsh` 样本必须解析出完全相同的结果**——按值形态解析的回归哨兵，同时也监测 `.ps1` 的 UTF-8 BOM 是否被破坏
- **`nmcli` 与 `iw` 两种抓取格式必须给出相同的信道排序**——证明后端差异只影响分数细节，不影响结论

---

## 已知局限（摘要）

| 局限 | 影响 |
|---|---|
| RSSI 是反推值 | 未连接邻居只能用百分比估算，强信号端偏差可达 10 dB 以上；干扰分宜作相对量级看 |
| 邻居带宽未知 | 只能用参数假设，20 / 80 MHz 结论可能相反 |
| Windows 扫描缓存不可靠 | 可能只看到部分 AP，需要强制重扫 |
| `nmcli` 没有 BSS Load | Linux 走 `nmcli` 时负载系数恒为 1，分数略低于 `iw` |
| 区域法规 | ch12/13、ch149+、6 GHz 的可用性取决于国家代码与固件 |

各版本的完整局限列表见 [Windows 文档](windows/README.md#已知局限) 与 [Linux 文档](linux/README.md#已知局限)。

---

## 兼容性

- **Windows**：Windows 10 / 11（依赖 `netsh wlan`，Windows 7 未测试）；Windows PowerShell 5.1 与 PowerShell 7.x 均可；普通用户权限即可
- **Linux**：任何有 `bash 4.4+` 与 `awk` 的发行版（Ubuntu / Debian / Fedora / Arch / OpenWrt 均可）；`nmcli` 走普通用户，`iw` 扫 AP 需要 root
- 两个版本都是函数式 / 函数化组织，可 dot-source / source 复用里面的解析与评分函数

---

## 许可证

[MIT](LICENSE) © 2026 Rockies

## 免责声明

本工具只**读取**系统的无线状态，不会修改路由器或网卡配置，改信道需要你自己登录路由器后台操作。结论基于当时的扫描快照，邻居环境会变，建议分不同时段多跑几次再决定。
