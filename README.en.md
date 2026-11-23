# Wi-Fi Channel Advisor

> Pick the cleanest Wi-Fi channel for a given SSID by measuring real interference from nearby APs — using nothing but built-in tools: `netsh` on Windows (PowerShell), `nmcli` or `iw` on Linux (bash). No dependencies, no build step.

![Platform](https://img.shields.io/badge/platform-Windows%2010%20%7C%2011%20%7C%20Linux-0078D6?logo=linux&logoColor=white)
![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-5391FE?logo=powershell&logoColor=white)
![Bash](https://img.shields.io/badge/Bash-4.4%2B-4EAA25?logo=gnubash&logoColor=white)
![License](https://img.shields.io/badge/license-MIT-green)
![Dependencies](https://img.shields.io/badge/dependencies-none-brightgreen)

[简体中文](README.md) | **English**

---

## Why

Your router's "auto channel" often lands on the most crowded spot in the building. Phone Wi-Fi analyzer apps show signal bars but can't tell you **how much your current channel is actually being crushed**, or which channel would be better.

This toolkit does three things:

1. **Read the current link** — SSID, BSSID, band, channel, PHY, signal, negotiated rates
2. **Scan nearby APs** — every visible BSSID (connected or not) with band, channel, signal, channel utilization, security
3. **Score channels and recommend one** — neighbors are summed into an *interference score* weighted by transmit power and spectral overlap; every candidate channel is ranked and you get a direct verdict

The Windows and Linux builds share **one interference model**: fed the same scan data, they produce an identical channel ranking (there's a dedicated cross-check in `tests/`). Capture on a Windows laptop, then re-verify on the router with the bash build.

Everything is built on tools the OS already ships. **No modules, no drivers** — copy a script and run it.

---

## Two builds

| | Windows | Linux |
|---|---|---|
| **Entry point** | [`windows/Get-BestChannel.ps1`](windows/Get-BestChannel.ps1) | [`linux/Get-BestChannel.sh`](linux/Get-BestChannel.sh) |
| **Runs on** | Windows 10 / 11, Windows PowerShell 5.1 or PowerShell 7 | Any distro with `bash 4.4+` and `awk` (OpenWrt included) |
| **Data source** | `netsh wlan` | `nmcli` (no root) → `iw` (root) → offline files |
| **Privileges** | Standard user | `nmcli` unprivileged, `iw` needs root to scan |
| **Companion tools** | `Get-WifiNeighbors.ps1`, `Get-WifiSignal.ps1` | — |
| **Offline test suite** | 49 checks | 59 checks |
| **Docs** | [English](windows/README.en.md) · [中文](windows/README.md) | [English](linux/README.en.md) · [中文](linux/README.md) |

The Linux build has no separate neighbor-listing tool because `Get-BestChannel.sh` already prints the full same-band neighbor table. The Windows build splits that out so you can pipe it or export CSV.

---

## Layout

```
wifi-channel-advisor/
├── windows/                      # Windows build (PowerShell 5.1+)
│   ├── Get-BestChannel.ps1       # Interference analysis + channel verdict
│   ├── Get-WifiNeighbors.ps1     # Structured list of nearby APs
│   ├── Get-WifiSignal.ps1        # Live signal of the current link
│   ├── README.md                 # Windows docs (Chinese)
│   ├── README.en.md              # Windows docs (English)
│   ├── examples/                 # Synthetic sample + offline analysis script
│   └── tests/                    # 49 offline checks + zh/en netsh fixtures
├── linux/                        # Linux build (bash 4.4+)
│   ├── Get-BestChannel.sh
│   ├── README.md                 # Linux docs (Chinese)
│   ├── README.en.md              # Linux docs (English)
│   ├── examples/                 # Same synthetic sample as the Windows build
│   └── tests/                    # 59 offline checks + nmcli / iw fixtures
├── .github/workflows/ci.yml      # 4 jobs: test / lint / test-linux / shellcheck
├── LICENSE
├── README.md
└── README.en.md                  # You are here
```

---

## Quick start

```bash
git clone https://github.com/BigW-Rockies/wifi-channel-advisor.git
cd wifi-channel-advisor
```

**Windows** (PowerShell 5.1 or 7):

```powershell
# Analyze the SSID you are currently connected to
powershell -ExecutionPolicy Bypass -File .\windows\Get-BestChannel.ps1

# Wired connection, or planning a network you haven't joined yet
powershell -ExecutionPolicy Bypass -File .\windows\Get-BestChannel.ps1 -SSID 'Maple'
```

> If execution policy blocks the script, use the `-ExecutionPolicy Bypass` form above, or run `Unblock-File .\windows\*.ps1` once.

**Linux**:

```bash
chmod +x linux/Get-BestChannel.sh

# Analyze the SSID you're connected to (uses nmcli, no root needed)
./linux/Get-BestChannel.sh

# Target a specific SSID
./linux/Get-BestChannel.sh --ssid 'Maple'

# No NetworkManager (OpenWrt, minimal installs): falls back to iw, needs root
sudo ./linux/Get-BestChannel.sh --ssid 'Maple'
```

**No wireless adapter? You can still run the whole pipeline** against the bundled synthetic sample (all SSIDs/MACs are placeholders):

```powershell
powershell -ExecutionPolicy Bypass -File .\windows\examples\Analyze-Sample.ps1
```

```bash
bash linux/Get-BestChannel.sh --ssid Maple --csv linux/examples/scan-sample.csv
```

Both samples are identical, so both verdicts should be too: **move 2.4 GHz from ch6 to ch13, score 0.037 → 0.006 (-83%)**. That's exactly how CI proves the two implementations haven't drifted apart.

---

## What the output looks like

Real run, 2.4 GHz band, 18 same-band neighbors, SSIDs and MACs anonymized:

```
Target SSID : Maple   (from -SSID)

========== [1/1] Maple @ 2.4 GHz ==========
  Reference AP : 02:11:22:33:44:01
  Current      : ch6   802.11ax   signal 95% (-52 dBm)
  Bandwidth    : 20 MHz  (neighbors assumed 20 MHz)

----- Same-band neighbors (18) -----
SSID              BSSID              Channel Signal RssiEst ChanUtil
Birch             02:11:22:33:44:02        6     42     -79        -
Cedar             02:11:22:33:44:03        6     38     -81        -
Willow            02:11:22:33:44:04       11     55     -72        8
...

----- Candidate scores (lower is better, top 5) -----
  ch13   #.......................    <0.001
  ch10   ##......................     0.001
  ch12   ##......................     0.001
  ch11   ##......................     0.002
  ch9    #######.................     0.006

----- Verdict -----
  Switch 2.4 GHz to ch13: score 0.020 -> <0.001, -96%.
```

Shorter bar = cleaner channel. The output itself is Chinese-only: `[当前]` tags the channel currently in use, `[DFS]` tags radar channels.

Dual-band routers that broadcast one SSID on both bands are analyzed **per band, with a separate verdict each**, plus a summary table:

```
========== Summary ==========
  2.4 GHz  ch6  -> ch13  [switch]   0.020 -> <0.001
  5 GHz    ch36 -> ch40  [switch]   0.046 -> 0
```

If the SSID isn't in the scan result it says so, instead of inventing an answer:

```
Warning: SSID not found in the current scan: NoSuchWiFi-9527
         Scan returned 21 BSSIDs / 15 SSIDs; the Windows scan cache may not include it.
```

---

## The interference model

Both builds use the same formula:

```
score(ch) = Σ[ neighbor_power_mW × spectral_overlap × load_factor ] / reference_AP_power_mW
```

- **Power** — the scan only reports a percentage, so it's mapped back to dBm with `rssi ≈ quality/2 - 100` and converted to milliwatts, then summed in the power domain. Two neighbors at -70 dBm behave roughly like one at -67 dBm; counting APs would be wrong. Note that the percentage→dBm curve in Windows is **not linear** and this formula under-estimates strong signals (measured: 97% is actually -39 dBm, the formula says -52 dBm), so treat the score as a **relative magnitude**, not an absolute dB figure.
- **Spectral overlap** — each AP is a rectangle in the frequency domain; overlap is the intersection width divided by the candidate bandwidth. On 2.4 GHz, ch1 overlaps ch3 by 0.5 and ch5 by 0. On 5 GHz, adjacent 20 MHz channels barely overlap — **but an 80 MHz neighbor blocks the whole 4-channel block**. This is the single most overlooked factor.
- **Load factor** — BSS Load (channel utilization) from the beacon, so a busy neighbor counts for more than an idle one. The `nmcli` backend on Linux doesn't expose it, so the factor stays 1 there.
- **Normalization** — dividing by the reference AP's power makes `1.0` mean "interference as strong as my own signal", comparable across environments.
- **DFS penalty** — 5 GHz ch52–144 are radar channels; a radar event forces a 60 s+ silent period plus reduced power. A flat `+0.05` penalty is applied. Note it's *additive*: a multiplicative penalty does nothing to a channel that already scores 0.
- **Hysteresis** — if the current channel is within 15% of the best one, the tool tells you to stay put. Changing channels kicks every client off; don't do it for a marginal gain.

Full derivations, every parameter and the implementation notes live in each build's docs.

---

## Two questions people always ask

**"Is my neighbor on 20 or 80 MHz?"**

`netsh` doesn't say. The same network can produce opposite verdicts depending on the assumption:

```
neighbors @ 20 MHz          neighbors @ 80 MHz
ch36 [current] 0  <- clear  ch165  0        <- recommended
ch40           0            ch149  <0.001
ch44           0            ch36   0.026 [current]
-> stay on ch36             -> move to ch165, -99% interference
```

Reason: ch36 and ch48 are 60 MHz apart at 20 MHz and don't touch — but if that ch48 AP actually runs 80 MHz (block 36–48, center 5210 MHz), it sits right on top of ch36.

**Rule of thumb**: re-run with `-NeighborWidth 80` (`--neighbor-width 80` on Linux) if your neighbors look modern; if you also plan to run 80 MHz yourself, pass both width options. Only trust a channel that wins under both assumptions.

**"Why do I see no neighbors / only my own AP?"**

On Windows, `netsh` reads the **scan cache** — it never forces a scan. The OS trims that cache aggressively, so the same machine can go from "18 neighbors" to "0 neighbors" within minutes. In order: toggle Wi-Fi to force a rescan → raise the scan rounds (`-ScanRounds 6 -ScanGapMs 3000`) → check whether Location services are disabled in Windows 11 → and don't ignore the tool's "cache may be stale" warning.

On Linux it's usually permissions: `nmcli` can't see BSS Load, `iw` needs root to scan, and inside WSL2 or a container there is no wireless device at all (a Hyper-V virtual NIC has no radio). See the [Linux docs](linux/README.en.md).

---

## Test coverage

```bash
# Windows: 49 checks, green on PowerShell 5.1 and 7
powershell -ExecutionPolicy Bypass -File .\windows\tests\Run-Tests.ps1

# Linux: 59 checks, any bash 4.4+
bash linux/tests/Run-Tests.sh
```

Both suites are fully offline and need no wireless adapter, which is why CI can reproduce them reliably. `.github/workflows/ci.yml` runs four jobs:

| Job | What it does |
|---|---|
| **test** | Runs the Windows suite and the sample analysis on `windows-latest`, once with PowerShell 5.1 and once with 7 |
| **lint** | PSScriptAnalyzer, failing only on Error / ParseError — not on style rules like `Write-Host`, which this CLI uses on purpose |
| **test-linux** | Runs the Linux suite on `ubuntu-latest` and analyzes the same `scan-sample.csv` with the bash build |
| **shellcheck** | `shellcheck -S warning` on `Get-BestChannel.sh` and the bash test script |

Beyond functional assertions there are two "never drift silently" guards:

- **The Chinese and English `netsh` fixtures must parse identically** — the regression guard for the "match on value shape, not field names" design, and a sentinel for the `.ps1` UTF-8 BOM
- **`nmcli` and `iw` captures must yield the same channel ranking** — proving backend differences only affect score details, never the conclusion

---

## Known limitations (summary)

| Limitation | Impact |
|---|---|
| RSSI is estimated | Unassociated neighbors are derived from a percentage; error can exceed 10 dB at the strong end, so read the score as relative |
| Neighbor bandwidth unknown | It's an assumption; 20 vs 80 MHz can flip the verdict |
| Windows scan cache is unreliable | You may only see part of the neighborhood; force a rescan |
| `nmcli` has no BSS Load | The Linux `nmcli` backend keeps the load factor at 1, so scores run slightly lower than with `iw` |
| Regulatory domain | Availability of ch12/13, ch149+, and 6 GHz depends on country code and firmware |

Per-build limitation tables: [Windows docs](windows/README.en.md#known-limitations), [Linux docs](linux/README.en.md#known-limitations).

---

## Compatibility

- **Windows** — Windows 10 / 11 (`netsh wlan`; Windows 7 untested); Windows PowerShell 5.1 and PowerShell 7.x; standard user, no elevation
- **Linux** — any distro with `bash 4.4+` and `awk` (Ubuntu / Debian / Fedora / Arch / OpenWrt all fine); `nmcli` runs unprivileged, `iw` needs root to scan
- Both builds are organized as functions, so you can dot-source / source the parsers and scorer

---

## License

[MIT](LICENSE) © 2026 Rockies

## Disclaimer

This tool only **reads** wireless state — it never changes router or adapter settings; you still log into the router to apply a channel. Verdicts are based on a point-in-time scan, and neighborhoods change: run it a few times at different hours before committing.
