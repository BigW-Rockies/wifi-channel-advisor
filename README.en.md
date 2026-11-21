# Wi-Fi Channel Advisor

> Pick the cleanest Wi-Fi channel for a given SSID by measuring real interference from nearby APs — using nothing but Windows' built-in `netsh`.

![Platform](https://img.shields.io/badge/platform-Windows%2010%20%7C%2011-0078D6?logo=windows&logoColor=white)
![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-5391FE?logo=powershell&logoColor=white)
![License](https://img.shields.io/badge/license-MIT-green)
![Dependencies](https://img.shields.io/badge/dependencies-none-brightgreen)

**English** | [简体中文](README.md)

---

## Why

Your router's "auto channel" often lands on the most crowded spot in the building. Phone Wi-Fi analyzer apps show signal bars but can't tell you **how much your current channel is actually being crushed**, or which channel would be better.

This toolkit does three things:

1. **Read the current link** — SSID, BSSID, band, channel, PHY, signal, negotiated rates
2. **Scan nearby APs** — every visible BSSID (connected or not) with band, channel, signal, channel utilization, security
3. **Score channels and recommend one** — neighbors are summed into an *interference score* weighted by transmit power and spectral overlap; every candidate channel is ranked and you get a direct verdict

Pure `netsh wlan`, **no modules, no drivers, no admin rights**. Copy a `.ps1` and run it.

---

## The three scripts

| Script | Purpose | Use when |
|---|---|---|
| **`Get-BestChannel.ps1`** | Analyze interference, recommend the best channel | You want to pin your router to a fixed channel |
| `Get-WifiNeighbors.ps1` | List all nearby APs as structured objects | You want to see which channels neighbors occupy |
| `Get-WifiSignal.ps1` | Read live signal of the current link | Diagnosing drops, watching RSSI |

---

## Quick start

```powershell
git clone https://github.com/<your-name>/wifi-channel-advisor.git
cd wifi-channel-advisor

# Analyze the SSID you are currently connected to
powershell -ExecutionPolicy Bypass -File .\Get-BestChannel.ps1
```

> If execution policy blocks you, use the `-ExecutionPolicy Bypass` form above, or run `Unblock-File .\*.ps1` once.

### Target a specific SSID

```powershell
powershell -ExecutionPolicy Bypass -File .\Get-BestChannel.ps1 -SSID 'Maple'
```

Works on a wired connection too, or for a network you haven't joined. Dual-band routers that broadcast one SSID on both bands are analyzed **per band, with a separate verdict each**, plus a summary table:

```
========== [1/2] Maple @ 2.4 GHz ==========
  Reference AP : 02:11:22:33:44:01
  Current      : ch6   802.11ax   signal 95% (-52 dBm)
  ...
  Switch 2.4 GHz to ch13: score 0.020 -> <0.001, -96%

========== [2/2] Maple @ 5 GHz ==========
  Switch 5 GHz to ch40: score 0.046 -> 0, -100%

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

## Sample output

Real run, 2.4 GHz band, 18 same-band neighbors:

```
Target SSID : Maple   (from -SSID)

========== [1/1] Maple @ 2.4 GHz ==========
  Reference AP : 02:11:22:33:44:01
  Current      : ch6   802.11ax   signal 95% (-52 dBm)
  Bandwidth    : 20 MHz  (neighbors assumed 20 MHz)

----- Same-band neighbors (18) -----
SSID                BSSID             Channel Signal RssiEst ChanUtil
Maple          02:11:22:33:44:01        6     95     -52       12
Birch        02:11:22:33:44:02        6     42     -79        -
Cedar      02:11:22:33:44:03        6     38     -81        -
Willow             02:11:22:33:44:04       11     55     -72        8
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

Shorter bar = cleaner channel. The output is Chinese-only: `[当前]` tags the channel currently in use, `[DFS]` tags radar channels.

---

## The interference model

```
score(ch) = Σ[ neighbor_power_mW × spectral_overlap × load_factor ] / reference_AP_power_mW
```

- **Power** — the scan only reports a percentage, so it's mapped back to dBm with `rssi ≈ quality/2 - 100` and converted to milliwatts, then summed in the power domain. Two neighbors at -70 dBm behave roughly like one at -67 dBm; counting APs would be wrong. Note that the percentage→dBm curve in Windows is **not linear** and this formula under-estimates strong signals (measured: 97% is actually -39 dBm, the formula says -52 dBm), so treat the score as a **relative magnitude**, not an absolute dB figure.
- **Spectral overlap** — each AP is a rectangle in the frequency domain; overlap is the intersection width divided by the candidate bandwidth. On 2.4 GHz, ch1 overlaps ch3 by 0.5 and ch5 by 0. On 5 GHz, adjacent 20 MHz channels barely overlap — **but an 80 MHz neighbor blocks the whole 4-channel block**. This is the single most overlooked factor.
- **Load factor** — BSS Load (channel utilization) from the beacon, so a busy neighbor counts for more than an idle one.
- **Normalization** — dividing by the reference AP's power makes `1.0` mean "interference as strong as my own signal", comparable across environments.
- **DFS penalty** — 5 GHz ch52–144 are radar channels; a radar event forces a 60 s+ silent period plus reduced power. A flat `+0.05` penalty is applied. Note it's *additive*: a multiplicative penalty does nothing to a channel that already scores 0.
- **Hysteresis** — if the current channel is within 15% of the best one, the tool tells you to stay put. Changing channels kicks every client off; don't do it for a marginal gain.

---

## Parameters

### Get-BestChannel.ps1

| Parameter | Default | Description |
|---|---|---|
| `-SSID <string>` | currently connected SSID | Target network; required on a wired connection |
| `-Band <2.4\|5\|6>` | all bands | Analyze a single band only |
| `-ChannelWidth <20\|40\|80\|160>` | `20` | Candidate bandwidth; if your AP runs 80 MHz, pass 80 (36/40/44/48 become one block) |
| `-NeighborWidth <20\|40\|80>` | `20` | Assumed neighbor bandwidth (not exposed by `netsh`) |
| `-Top <int>` | `5` | How many candidates to show |
| `-StayThreshold <double>` | `0.15` | Recommend staying if the gap is below this ratio |
| `-DfsPenalty <double>` | `0.05` | Flat penalty added to DFS channels |
| `-IncludeDfs` | off | Allow DFS channels to be recommended |
| `-ScanRounds <int>` | `3` | Scan rounds, merged to fight cache trimming |
| `-ScanGapMs <int>` | `1500` | Delay between rounds |

### Get-WifiNeighbors.ps1

| Parameter | Description |
|---|---|
| `-SortBy <Signal\|Channel\|Band\|SSID>` | Sort order, signal descending by default |
| `-Top <int>` | Show only the first N |
| `-ConnectedOnly` | Only the AP you are associated with |
| `-Table` | Render a table (default emits objects for the pipeline) |

```powershell
# Export neighbors to CSV and plot channel occupancy yourself
.\Get-WifiNeighbors.ps1 | Export-Csv ap.csv -NoTypeInformation -Encoding UTF8
```

### Get-WifiSignal.ps1

| Parameter | Description |
|---|---|
| `-Samples <int>` | Sample count, default 1 (single object, safe for pipelines) |
| `-IntervalMs <int>` | Interval between samples, default 500 ms |

```powershell
# Watch RSSI to find dead spots
.\Get-WifiSignal.ps1 -Samples 30 -IntervalMs 500 |
    Select-Object Time, Rssi, Signal, RxMbps | Format-Table
```

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

**Rule of thumb**: re-run with `-NeighborWidth 80` if your neighbors look modern; if you also plan to run 80 MHz yourself, pass both `-ChannelWidth 80 -NeighborWidth 80`. Only trust a channel that wins under both assumptions.

**"Why do I see no neighbors / only my own AP?"**

`netsh` reads the **Windows scan cache** — it never forces a scan. The OS trims that cache aggressively, so the same machine can go from "18 neighbors" to "0 neighbors" within minutes. In order:

1. Toggle Wi-Fi off/on (or `netsh wlan disconnect` and reconnect) to force a rescan
2. Raise `-ScanRounds 6 -ScanGapMs 3000`
3. Check **Settings → Privacy & security → Location**. On Windows 11, disabling location can restrict Wi-Fi scan results, sometimes down to the connected AP only
4. Don't ignore the tool's warning when it says the cache looks stale (band has 0 neighbors while other bands have dozens)

---

## Known limitations

| Limitation | Detail |
|---|---|
| **RSSI is estimated** | The scan exposes only a percentage, mapped to dBm with `quality/2 - 100`. That curve is non-linear in Windows, and the error can exceed 10 dB at the strong end (measured: 97% = -39 dBm, formula says -52 dBm). The connected AP uses its real dBm; unassociated neighbors can only be estimated |
| **Neighbor bandwidth unknown** | See above; `-NeighborWidth` is a guess by design |
| **Scan cache is unreliable** | The fundamental weakness of the `netsh` approach |
| **No SNR / CSI** | Public APIs expose neither noise floor nor per-subcarrier state; that requires vendor drivers or a capture tool |
| **Regulatory domain** | Availability of ch12/13, ch149+, and 6 GHz depends on country code and firmware — trust your router's channel list |

The precise route is P/Invoke on `wlanapi.dll` / `WlanGetNetworkBssList`, which returns real `lRssi`, channel width and beacon interval — at the cost of `Add-Type` inline C# compilation, which some hardened environments block. This project deliberately sticks to `netsh` so it stays copy-and-run.

---

## Implementation notes

The gotchas here cost more time than the algorithm:

1. **`netsh` output encoding is not stable.** On the same machine the bytes can be UTF-8 while `[Console]::OutputEncoding` reports code page 936, so `$raw = netsh ...` turns Chinese field names into mojibake. Fix: read raw bytes from `StandardOutput.BaseStream`, try strict UTF-8, fall back to the OEM code page.
2. **Field names are localized.** "Signal" is "信号", "Channel" is "通道" — matching on names breaks on the next machine. Every parser here matches on **value shape** (`97%`, `-39`, `5 GHz`, `802.11ax`), which is locale-independent.
3. **`BSSID 1                 : 02:11:22:...` has multiple spaces before the colon.** A regex like `BSSID \d+ :` matches nothing; use `BSSID\s+\d+\s*:`.
4. **Primary channel ≠ center frequency.** Primary ch48 running 80 MHz is centered at 5210 MHz, not 5240. Using the primary frequency for overlap shifts the whole block.
5. **Multiplicative DFS penalty can't fix a zero score.** `0 × 3 = 0`, so a clean DFS channel would win by accident. Use an additive penalty.
6. **`.ps1` files must be UTF-8 with BOM.** PowerShell 5.1 reads BOM-less UTF-8 as ANSI and the Chinese regexes silently stop matching. All three scripts ship with a BOM, and `.gitattributes` disables EOL conversion — don't re-save them with an editor that rewrites the encoding.

---

## Compatibility

- Windows 10 / 11 (relies on `netsh wlan`; Windows 7 untested)
- Windows PowerShell 5.1 and PowerShell 7.x
- Standard user — no elevation required
- Functions are dot-source friendly if you want to reuse the parsers

---

## License

[MIT](LICENSE) © 2026 Rockies

## Disclaimer

This tool only **reads** wireless state — it never changes router or adapter settings; you still log into the router to apply a channel. Verdicts are based on a point-in-time scan, and neighborhoods change: run it a few times at different hours before committing.
