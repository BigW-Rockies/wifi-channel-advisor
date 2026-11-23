# Wi-Fi Channel Advisor · Linux

> Pick the cleanest Wi-Fi channel for a given SSID by measuring real interference from nearby APs — needs only `bash 4.4+` and any `awk`. No Python, no build step.

![Platform](https://img.shields.io/badge/platform-Linux-4EAA25?logo=linux&logoColor=white)
![Bash](https://img.shields.io/badge/Bash-4.4%2B-4EAA25?logo=gnubash&logoColor=white)
![License](https://img.shields.io/badge/license-MIT-green)
![Dependencies](https://img.shields.io/badge/dependencies-none-brightgreen)

**English** | [简体中文](README.md) · [← Project home](../README.en.md) · [Windows build](../windows/README.en.md)

---

## Why

Your router's "auto channel" often lands on the most crowded spot in the building. Phone Wi-Fi analyzer apps show signal bars but can't tell you **how much your current channel is actually being crushed**, or which channel would be better.

`Get-BestChannel.sh` is the bash port of the [Windows build](../windows/README.en.md) and does the same three things:

1. **Read the current link** — SSID, BSSID, band, channel, PHY, signal
2. **Scan nearby APs** — every visible BSSID (connected or not) with band, channel, signal, channel utilization
3. **Score channels and recommend one** — neighbors are summed into an *interference score* weighted by transmit power and spectral overlap; every candidate channel is ranked and you get a direct verdict

The scoring formula is identical to the Windows build, and **the same scan data yields the same channel ranking** (there's a cross-check in `tests/`). Capture on Windows, verify on the router — or the other way around.

It's meant for OpenWrt routers, NAS boxes, Raspberry Pis, and any Linux machine you don't want to install things on.

---

## Quick start

```bash
git clone https://github.com/BigW-Rockies/wifi-channel-advisor.git
cd wifi-channel-advisor/linux
chmod +x Get-BestChannel.sh

# Analyze the SSID you're connected to (uses nmcli, no root needed)
./Get-BestChannel.sh

# Target a specific SSID
./Get-BestChannel.sh --ssid 'Maple'

# No NetworkManager (OpenWrt, minimal installs): falls back to iw, needs root
sudo ./Get-BestChannel.sh --ssid 'Maple'

# Neighbors are mostly 80 MHz? Re-check with that assumption
sudo ./Get-BestChannel.sh --ssid 'Maple' --width 80 --neighbor-width 80
```

Dual-band routers that broadcast one SSID on both bands are analyzed **per band, with a separate verdict each**, plus a summary table. If the target SSID isn't in the scan, it says so instead of inventing an answer.

### Three backends, picked automatically

| Order | Backend | Root | What it provides |
|---|---|---|---|
| 1 | `nmcli` | no | SSID / BSSID / channel / frequency / signal %. **No BSS Load**, so the load factor stays 1 |
| 2 | `iw dev <if> scan` | yes (CAP_NET_ADMIN) | **Real dBm**, BSS Load (channel utilization), primary channel from the DS parameter |
| 3 | `--csv` / `--input` | no | Offline analysis, never touches the radio |

That's why the two backends can produce slightly different scores — `iw` adds channel utilization as a factor. The channel *ranking* is unaffected, and the test suite asserts exactly that.

---

## Sample output

From the offline sample (`examples/scan-sample.csv`; all SSIDs and MACs are placeholders):

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
```

Shorter bar = cleaner channel. The output itself is Chinese-only: `[当前]` tags the channel currently in use, `[DFS]` tags radar channels. The trailing "仍有 N 个 AP 频谱重叠" line is a reminder that the best channel is not the same as a zero-interference channel.

---

## Options

| Option | Meaning |
|---|---|
| `--ssid NAME` | Target SSID; defaults to the currently connected one |
| `--band 2.4\|5\|6` | Restrict to one band |
| `--width N` | Candidate channel width: 20/40/80/160 |
| `--neighbor-width N` | Assumed neighbor width, default 20 |
| `--top N` | Show the top N candidates, default 5 |
| `--stay-threshold R` | Stay put if the current channel is within R, default 0.15 |
| `--include-dfs` / `--dfs-penalty R` | Relax / tune the DFS penalty |
| `--iface NAME` | Wireless interface; auto-detected by default |
| `--scan-rounds N` / `--gap-ms N` | Multi-round scan merge, default 3 rounds / 1500 ms |
| `--input FILE` | Analyze a saved `nmcli` dump or `iw ... scan` output (format auto-detected) |
| `--csv FILE` | Analyze a scan CSV with the same header as `examples/` |
| `-q` / `--help` / `--version` | Quiet mode / help / version |

`--input` detects the format and accepts both `nmcli` and `iw` captures:

```bash
nmcli -f SSID,BSSID,CHAN,SIGNAL dev wifi list --rescan yes > scan.txt
sudo iw dev wlan0 scan > scan.txt
./Get-BestChannel.sh --input scan.txt --ssid 'Maple'
```

A `netsh` capture from Windows **cannot** be fed to `--input` (its format differs from both `iw` and `nmcli`). The right path is to export CSV on Windows with `Get-WifiNeighbors.ps1 | Export-Csv`, since both builds share the same header:

```powershell
.\Get-WifiNeighbors.ps1 | Export-Csv my-scan.csv -NoTypeInformation -Encoding UTF8
```

```bash
./Get-BestChannel.sh --csv my-scan.csv --ssid 'Maple'
```

---

## A note on WSL

**WSL2 cannot scan Wi-Fi, and that's not a bug in this script.** WSL2 only sees a Hyper-V virtual NIC, so `iw` and `nmcli` find no wireless device at all. In WSL you can only use the offline path:

```bash
# The bundled synthetic sample
./Get-BestChannel.sh --ssid 'Maple' --csv examples/scan-sample.csv

# Or export a real scan on Windows, then analyze it here
#   Windows: .\Get-WifiNeighbors.ps1 | Export-Csv my-scan.csv -NoTypeInformation -Encoding UTF8
./Get-BestChannel.sh --ssid 'Maple' --csv /mnt/c/Users/<you>/my-scan.csv
```

For live scanning you need real Linux hardware, or a USB adapter passed through to the VM.

---

## The interference model

```
score(ch) = Σ[ neighbor_power_mW × spectral_overlap × load_factor ] / reference_AP_power_mW
```

- **Power** — `iw` reports real dBm; `nmcli` only reports a percentage, mapped back with `rssi ≈ quality/2 - 100`. That curve is **not linear**, with up to ~10 dB of error at the strong end, so treat the score as a **relative magnitude**, not an absolute dB figure.
- **Spectral overlap** — each AP is a rectangle in the frequency domain; overlap is the intersection width divided by the candidate bandwidth. On 2.4 GHz, ch1 overlaps ch3 by 0.5 and ch5 by 0. On 5 GHz, adjacent 20 MHz channels barely overlap — **but an 80 MHz neighbor blocks the whole 4-channel block**.
- **Load factor** — BSS Load (channel utilization) from the beacon. Only the `iw` backend provides it; `nmcli` always counts as 1.
- **Normalization** — dividing by the reference AP's power makes `1.0` mean "interference as strong as my own signal".
- **DFS penalty** — 5 GHz ch52–144 are radar channels; a flat `+0.05` penalty is applied. It's *additive*: a multiplicative penalty does nothing to a channel that already scores 0.
- **Hysteresis** — if the current channel is within 15% of the best one, the tool tells you to stay put. Changing channels kicks every client off.
- **Self-exclusion** — other BSSIDs under the target SSID are not counted as interferers, otherwise your own power divided by itself would add a free 1.0.

---

## Tests

59 checks, fully offline, no wireless adapter needed (so it runs in CI and in WSL):

```bash
bash tests/Run-Tests.sh
```

Covers:

- Parsing of both `nmcli` and `iw` capture formats
- **Identical channel rankings from both backends on the same data**
- Agreement between `--csv` and `--input` verdicts
- Wide-channel block centers, the additive DFS penalty, candidate sets, hysteresis
- The "no wireless device" path you hit inside WSL or a container
- Passing under `gawk --posix` (POSIX awk subset, so swapping in mawk on a router won't break it)

CI also runs the bundled sample and asserts the verdict must be **ch13** — otherwise the scoring model has been broken.

## CI

The two Linux jobs in `.github/workflows/ci.yml`:

| Job | What it does |
|---|---|
| **test-linux** | Runs `linux/tests/Run-Tests.sh` on `ubuntu-latest`, analyzes `linux/examples/scan-sample.csv` with the bash build, asserts the verdict is ch13, and checks the script is executable |
| **shellcheck** | `shellcheck -S warning` on `Get-BestChannel.sh` and the bash test script |

The Windows jobs (`test`, `lint`) are documented in the [Windows build docs](../windows/README.en.md#ci).

---

## Known limitations

| Limitation | Detail |
|---|---|
| **`nmcli` has no BSS Load** | NetworkManager doesn't expose channel utilization, so the load factor is always 1 and scores come out slightly lower than with `iw`. Use the `iw` backend if you need that factor |
| **`iw` needs root to scan** | Scanning requires `CAP_NET_ADMIN`. Without sudo, fall back to `nmcli` or offline mode |
| **WSL2 and containers can't scan** | The Hyper-V virtual NIC has no radio, so `iw`/`nmcli` see no wireless device. Physical limitation, not a bug |
| **`iw` primary channel comes from the DS parameter** | Some drivers omit `DS Parameter set`; the script then derives the channel from the center frequency, which can be off by one block on wide channels |
| **Neighbor bandwidth unknown** | Scan results don't include it; `--neighbor-width` is an assumption, and 20 vs 80 MHz can flip the verdict |
| **Regulatory domain** | Availability of ch12/13, ch149+, and 6 GHz depends on country code and firmware — trust your router's channel list |

---

## Implementation notes

Beyond the gotchas inherited from the Windows build, the bash port has its own:

1. **`nmcli -t` escaping splits your fields.** Colons inside values are escaped as `\:`, so a naive split on `:` shreds a BSSID into six pieces. Replace `\:` with a placeholder first, split, then restore.
2. **Counting your own AP as an interferer.** The first version fed the target SSID's own BSSID into the scorer, which handed the current channel a free 1.0 of interference (its own power divided by itself). Multiple BSSIDs under one SSID are one network and must be excluded — caught only by diffing against the PowerShell output.
3. **`awk` dialects differ.** Routers usually ship mawk or busybox awk, not gawk. The script sticks to the POSIX subset (no `gensub`, no `length(array)`) and was verified under `gawk --posix` as a stand-in.
4. **`.sh` must be LF.** CRLF turns the shebang into `/bin/bash\r` and produces a wildly misleading "no such file or directory" error. `.gitattributes` pins `*.sh text eol=lf`.
5. **`shellcheck` catches write-only variables.** The first version computed an `inuse` variable and dropped it, which tripped `SC2034` — it now prints the current connection info instead.
6. **No `set -e` is deliberate.** A failed scan should print a readable message and fall back to the next backend, not exit silently. Every error path is handled explicitly.

The encoding, localized-field-name, wide-channel-center and additive-DFS-penalty gotchas are shared with the Windows build and documented in the [Windows docs](../windows/README.en.md#implementation-notes).

---

## Compatibility

- **Shell** — `bash 4.4+` (associative arrays); `#!/usr/bin/env bash`, no `/bin/sh` dependency
- **awk** — any POSIX awk (mawk / gawk / busybox awk); the suite passes under `gawk --posix`
- **Distros** — Ubuntu / Debian / Fedora / Arch / Alpine (with bash) / OpenWrt
- **Privileges** — `nmcli` unprivileged; `iw` needs root to scan; offline mode needs nothing
- Functions are `source`-friendly if you want to reuse the parsers

---

## License

[MIT](../LICENSE) © 2026 Rockies

## Disclaimer

This tool only **reads** wireless state — it never changes router or adapter settings; you still log into the router to apply a channel. Verdicts are based on a point-in-time scan, and neighborhoods change: run it a few times at different hours before committing.
