# Wi-Fi 信道顾问

> 用 Windows 自带的 `netsh`，分析周边 AP 的干扰，为指定 SSID 推荐最干净的信道。

![Platform](https://img.shields.io/badge/platform-Windows%2010%20%7C%2011-0078D6?logo=windows&logoColor=white)
![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-5391FE?logo=powershell&logoColor=white)
![License](https://img.shields.io/badge/license-MIT-green)
![Dependencies](https://img.shields.io/badge/dependencies-none-brightgreen)

[English](README.en.md) | **简体中文**

---

## 这是什么

路由器默认的「自动信道」经常把 2.4 GHz 选在整栋楼最挤的位置。想手动固定信道，但手机上的 Wi-Fi 分析 App 只能看信号强弱，看不出**当前信道到底被压了多少**，也说不清换成哪个信道会更好。

这个工具做三件事：

1. **读当前连接**——SSID、BSSID、波段、信道、协议、信号、协商速率
2. **扫周边 AP**——所有可见热点（含未连接的），按 BSSID 逐个列出波段、信道、信号、信道利用率、加密方式
3. **算信道干扰并给结论**——把同波段邻居按功率和频谱重叠度叠加成「干扰分」，对每个候选信道打分，直接告诉你该切到哪个信道、能降多少

全部基于系统自带的 `netsh wlan`，**不装模块、不装驱动、不用管理员权限**，复制一个 `.ps1` 就能跑。

---

## 三个脚本

| 脚本 | 作用 | 适用场景 |
|---|---|---|
| **`Get-BestChannel.ps1`** | 分析干扰，推荐最优信道 | 想给路由器定一个固定信道 |
| `Get-WifiNeighbors.ps1` | 列出周边所有 AP 的结构化信息 | 看邻居都占哪些信道、哪些是 80 MHz |
| `Get-WifiSignal.ps1` | 读取当前连接的实时信号 | 排查掉线、看 RSSI 波动 |

---

## 快速开始

```powershell
git clone https://github.com/BigW-Rockies/wifi-channel-advisor.git
cd wifi-channel-advisor

# 分析当前接入的 SSID
powershell -ExecutionPolicy Bypass -File .\Get-BestChannel.ps1
```

> 如果双击运行被策略拦住，用上面带 `-ExecutionPolicy Bypass` 的形式。
> 也可以先 `Unblock-File .\*.ps1` 解除「来自 Internet」标记。

### 给指定的 SSID 找信道

```powershell
powershell -ExecutionPolicy Bypass -File .\Get-BestChannel.ps1 -SSID 'Maple'
```

有线连接、或者想提前规划还没连的网络，就靠 `-SSID` 指定。多频路由器（同名 SSID 同时广播 2.4 GHz 和 5 GHz）会**按波段分段分析，每段各给一个结论**，最后一张汇总表：

```
========== [1/2] Maple @ 2.4 GHz ==========
  参考 AP   : 02:11:22:33:44:01
  当前信道  : ch6   协议 802.11ax   信号 95% (-52 dBm)
  ...
  建议把 2.4 GHz 切到 ch13：干扰分 0.020 → <0.001，下降 96%

========== [2/2] Maple @ 5 GHz ==========
  建议把 5 GHz 切到 ch40：干扰分 0.046 → 0，下降 100%

========== 汇总 ==========
  2.4 GHz  当前 ch6    → 建议 ch13   [切换]   干扰分 0.020 → <0.001
  5 GHz    当前 ch36   → 建议 ch40   [切换]   干扰分 0.046 → 0
```

扫不到时会明确告知（而不是给一个假结论）：

```
警告：当前环境未扫描到SSID: NoSuchWiFi-9527, 请输入正确的SSID，或重试。
      本次扫描返回 21 个 BSSID / 15 个 SSID，Windows 扫描缓存可能不含该网络。
      若确认该网络就在附近，请开关一次 Wi-Fi 强制重扫后重试。
```

---

## 输出示例

真实环境（2.4 GHz，扫到 18 个同波段邻居）。**其中的 SSID 与 MAC 已做匿名化处理**，`02:` 开头的 MAC 是保留给本地实验用的地址段，不对应任何真实设备：

```
目标 SSID : Maple   （命令行 -SSID 指定）

========== [1/1] Maple @ 2.4 GHz ==========
  参考 AP   : 02:11:22:33:44:01
  当前信道  : ch6   协议 802.11ax   信号 95% (-52 dBm)
  分析带宽  : 20 MHz   (邻居按 20 MHz 计)

----- 同波段邻居（18 个）-----
SSID              BSSID              Channel Signal RssiEst ChanUtil
Maple             02:11:22:33:44:01        6     95     -52       12
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

---

## 干扰模型

```
干扰分(ch) = Σ[ 邻居功率(mW) × 频谱重叠度 × 负载系数 ] / 参考AP功率(mW)
```

- **功率**：扫描结果只给百分比，先按 `rssi ≈ quality/2 - 100` 反推 dBm，再转毫瓦按功率律叠加。两个 -70 dBm 的邻居约等于一个 -67 dBm，不是简单地数 AP 个数。注意百分比→dBm 在 Windows 里**不是线性映射**，公式在强信号端会偏低（实测 97% 的真实值是 -39 dBm，公式给 -52 dBm），所以干扰分是**相对量级**，不要当绝对 dB 读。
- **频谱重叠度**：把两个 AP 的频谱当矩形，算交叠宽度 / 候选带宽。2.4 GHz 的 ch1 与 ch3 重叠 0.5、ch1 与 ch5 为 0；5 GHz 相邻 20 MHz 信道基本不重叠——**但当邻居跑 80 MHz 时，它会压住整块 4 个信道**。这是最容易被忽略的一点。
- **负载系数**：用 Beacon 帧里的 BSS Load（信道利用率），邻家用得越满，干扰越实。
- **归一化**：除以参考 AP 的功率，所以 `1.0` 表示「干扰功率和自身信号一样强」，不同环境之间可直接比较。
- **DFS 惩罚**：5 GHz 的 ch52–144 是雷达信道，一旦检测到雷达会强制静默 60 秒以上并降功率。默认加 0.05 的**加法**惩罚——注意是加法，乘法惩罚对 0 分信道无效（0 × 3 还是 0）。
- **滞后阈值**：当前信道比最优信道差不到 15% 时建议保持不动。换信道意味着客户端集体重连，收益不够就别折腾。

---

## 参数

### Get-BestChannel.ps1

| 参数 | 默认 | 说明 |
|---|---|---|
| `-SSID <string>` | 当前接入的 SSID | 目标网络名；有线连接时必须指定 |
| `-Band <2.4\|5\|6>` | 全部 | 只分析某个波段 |
| `-ChannelWidth <20\|40\|80\|160>` | `20` | 候选信道带宽；AP 实际跑 80 MHz 就传 80（36/40/44/48 视为同一块） |
| `-NeighborWidth <20\|40\|80>` | `20` | 假设邻居的带宽。扫不到邻居带宽，只能假设 |
| `-Top <int>` | `5` | 展示前 N 个候选信道 |
| `-StayThreshold <double>` | `0.15` | 差异小于该比例时建议不换台 |
| `-DfsPenalty <double>` | `0.05` | DFS 信道的固定惩罚分 |
| `-IncludeDfs` | 关闭 | 允许推荐 DFS 信道 |
| `-ScanRounds <int>` | `3` | 扫描轮数，多轮合并抗缓存裁剪 |
| `-ScanGapMs <int>` | `1500` | 轮次间隔毫秒 |

### Get-WifiNeighbors.ps1

| 参数 | 说明 |
|---|---|
| `-SortBy <Signal\|Channel\|Band\|SSID>` | 排序字段，默认信号降序 |
| `-Top <int>` | 只显示前 N 个 |
| `-ConnectedOnly` | 只看当前连接的那个 AP |
| `-Table` | 直接渲染表格（默认输出对象，便于接管道） |

```powershell
# 周边 AP 导出 CSV，自己画信道占用图
.\Get-WifiNeighbors.ps1 | Export-Csv ap.csv -NoTypeInformation -Encoding UTF8
```

### Get-WifiSignal.ps1

| 参数 | 说明 |
|---|---|
| `-Samples <int>` | 采样次数，默认 1（输出单个对象，可直接接管道） |
| `-IntervalMs <int>` | 采样间隔，默认 500 ms |

```powershell
# 观察 RSSI 波动，判断是不是走到死角了
.\Get-WifiSignal.ps1 -Samples 30 -IntervalMs 500 |
    Select-Object Time, Rssi, Signal, RxMbps | Format-Table
```

---

## 离线示例与测试

不用无线网卡也能把整套逻辑跑通——CI 就是这么验证的。

```powershell
# 用自带的合成样本跑一遍分析（SSID/MAC 全是占位数据）
.\examples\Analyze-Sample.ps1

# 换成你自己导出的真实扫描结果
.\Get-WifiNeighbors.ps1 | Export-Csv my-scan.csv -NoTypeInformation -Encoding UTF8
.\examples\Analyze-Sample.ps1 -CsvPath .\my-scan.csv -SSID '你的SSID'
```

```
--- 2.4 GHz · 参考 AP 02:11:22:33:44:01 · 当前 ch6 · 95% (-52 dBm) · 邻居 11 个 ---

SSID    BSSID             Channel Signal RssiEst ChanUtil
Bramble 02:11:22:33:44:22       1     32     -84        -
Reed    02:11:22:33:44:13       6     64     -68       30
...
  ch13   ###########.............    0.006
  ch10   ################........    0.010
  结论：建议把 2.4 GHz 切到 ch13，干扰分 0.037 → 0.006（下降 83%）
```

跑测试（49 项，PS 5.1 与 7 均通过）：

```powershell
.\tests\Run-Tests.ps1
```

覆盖频谱重叠度、宽信道块中心、DFS 判定、候选信道集合、干扰排序、DFS 加法惩罚，以及**中英文两套 `netsh` 样本输出必须得到完全相同的结果**（`tests/fixtures/`）。最后这条是「按值形态解析」这个设计的回归护栏——它同时也是源码里 BOM 是否被破坏的哨兵。

## CI

`.github/workflows/ci.yml` 两个 job：

| Job | 内容 |
|---|---|
| **test** | windows-latest 上分别用 PowerShell 5.1 和 7 跑 `tests/Run-Tests.ps1` 与示例分析 |
| **lint** | PSScriptAnalyzer，只卡 Error / ParseError，不卡 `Write-Host` 这类风格建议（本项目是给人看的 CLI 输出，故意用它） |

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

**结论**：邻居多是近几年的路由器，用 `-NeighborWidth 80` 复核一遍；自己的 AP 也要开 80 MHz 就把 `-ChannelWidth` 一起传 80。两个结果都指向同一信道，才放心改。

**「为什么扫不到邻居 / 只扫到自己？」**

`netsh` 读的是 Windows 的**扫描缓存**，不会主动触发扫描。系统按省电策略裁剪缓存，同一台机器几分钟内可能从「18 个邻居」变成「0 个邻居」。排查顺序：

1. 开关一次 Wi-Fi（或 `netsh wlan disconnect` / 连回），强制重扫
2. 提高 `-ScanRounds 6 -ScanGapMs 3000`
3. 检查 **设置 → 隐私和安全性 → 位置** 是否开启。Windows 11 关闭位置服务会限制 Wi-Fi 扫描结果，`netsh` 也可能只返回已连接的那个 AP
4. 脚本检测到「本波段 0 邻居但其它波段有 AP」时会提示缓存可能陈旧，别忽略这句话

---

## 已知局限

| 局限 | 说明 |
|---|---|
| **RSSI 是反推值** | 扫描列表只给百分比，脚本按 `quality/2 - 100` 估 dBm。这条曲线在 Windows 里是非线性的，强信号端偏差可达 10 dB 以上（实测 97% 对应真实 -39 dBm，公式反推 -52 dBm）。已连接的 AP 用真实 dBm，未连接的邻居只能用估算值 |
| **邻居带宽未知** | 见上文，只能用 `-NeighborWidth` 假设 |
| **扫描缓存不可靠** | 见上文，这是 `netsh` 方案的硬伤 |
| **拿不到 SNR / CSI** | 公开 API 不提供噪声底和子载波信息，需要厂商驱动或专业抓包工具 |
| **区域法规** | ch12/13、ch149+、6 GHz 的可用性取决于国家代码与固件，最终以路由器可选列表为准 |

更精确的方案是 P/Invoke `wlanapi.dll` 的 `WlanGetNetworkBssList`（能拿到真实 `lRssi`、信道宽度、beacon 间隔），代价是要 `Add-Type` 内联编译 C#，在受限环境里会被安全策略拦。本项目有意只用 `netsh`，换来「复制即用」。

---

## 实现中踩过的坑

写这个工具踩的坑比想象的多数倍，记在这里省得别人再踩：

1. **`netsh` 输出编码不固定。** 同一台机器上，`netsh` 输出的字节是 UTF-8，而 `[Console]::OutputEncoding` 报的是 936，直接 `$raw = netsh ...` 会把「接收速率」读成 `鎺ユ敹閫熺巼`。正确做法是读 `StandardOutput.BaseStream` 原始字节，先严格 UTF-8 解码，失败再退回 OEM 代码页。
2. **字段名随系统语言变。** 「信号/Signal」「通道/Channel」在中文、英文系统下不同，按字段名匹配换台机器就废。脚本改为按**值的形态**判定（`97%`、`-39`、`5 GHz`、`802.11ax`），跨语言通用。
3. **`BSSID 1                 : 02:11:22:...` 冒号前是多个空格。** 正则写成 `BSSID \d+ :` 一个都匹配不到，必须 `BSSID\s+\d+\s*:`。
4. **宽信道的主信道和中心频率不是一回事。** 主信道 48 跑 80 MHz 时，块中心是 5210 MHz 而不是 5240 MHz。按主信道频率算重叠度会把整块算错位。
5. **乘法惩罚治不了 0 分信道。** DFS 信道如果干扰本身为 0，`0 × 3` 还是 0，会被误推荐成最优。改成加法惩罚。
6. **`.ps1` 必须存成 UTF-8 with BOM。** PowerShell 5.1 读无 BOM 的 UTF-8 会按 ANSI 解释，脚本里的中文正则会失效。仓库里三个脚本都带 BOM，`.gitattributes` 也关掉了行尾转换，请别用会改编码的编辑器另存。
7. **带 `[CmdletBinding()]` 时，`param()` 默认值里的 `$PSScriptRoot` 是空的。** 用 `powershell -File .\x.ps1` 调用时（CI 就是这么调的），参数默认值求值阶段它还不可用，`Join-Path` 直接报「参数为空字符串」；而本地 `& .\x.ps1` 调用一切正常，所以极易漏测。本项目第一次 CI 就挂在这上面，`tests/` 和 `examples/` 现在都改成在脚本体里取路径并带 `$MyInvocation` 兜底。

---

## 兼容性

- Windows 10 / 11（依赖 `netsh wlan`，Windows 7 未测试）
- Windows PowerShell 5.1 与 PowerShell 7.x 均可
- 普通用户权限即可，不需要管理员
- 函数式组织，可 dot-source 复用里面的解析与评分函数

---

## 许可证

[MIT](LICENSE) © 2026 Rockies

## 免责声明

本工具只**读取**系统的无线状态，不会修改路由器或网卡配置，改信道需要你自己登录路由器后台操作。结论基于当时的扫描快照，邻居环境会变，建议分不同时段多跑几次再决定。
