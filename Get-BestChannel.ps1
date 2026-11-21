<#
.SYNOPSIS
    为指定 SSID 寻找干扰最小的信道（支持多频路由器的多个波段）。

.DESCRIPTION
    流程：
      1) 确定目标 SSID：-SSID 指定，未指定则取当前接入的无线网络
      2) 扫周边 AP（netsh wlan show networks mode=bssid），找出该 SSID 的所有 BSSID
      3) 按波段分组，每个波段单独建模打分（多频路由器会给出多组建议）
      4) 建信道占用模型：按中心频率计算频谱重叠度，按信号功率加权叠加
      5) 对每个候选信道打分（分数越低干扰越小），叠加 DFS 惩罚
      6) 输出推荐信道、备选信道与是否值得切换（含滞后阈值，避免频繁换台）

    干扰模型说明：
      - 每个 AP 的信号百分比先还原成 dBm（rssi ≈ quality/2 - 100），再转成功率 mW
      - 信道重叠度 = 两个矩形频谱的交叠宽度 / 候选信道带宽，2.4G 相邻信道天然重叠，
        5G/6G 的 20MHz 信道基本不重叠，只有当邻居跑 40/80MHz 时才会互相压
      - 某个信道的干扰分 = Σ(邻居功率 mW × 重叠度 × 负载系数) / 参考 AP 功率 mW
        即以「相对自己 AP 的干扰功率」为单位，1.0 表示干扰与自身信号等强
      - DFS 信道（5G 的 52-144）可能因雷达检测被强制换台，默认加惩罚
      - 同一 SSID 的其它 BSSID 视为同一网络，不计入干扰

.PARAMETER SSID
    要分析的目标 SSID。不填则默认当前接入的 SSID（有线连接时必须显式指定）。

.PARAMETER Band
    只分析某个波段：2.4 / 5 / 6。不填则分析该 SSID 出现的所有波段。

.PARAMETER ChannelWidth
    候选信道带宽，默认 20。若你的 AP 实际跑 80MHz，传 80 会把 36/40/44/48 视为同一个块。

.PARAMETER NeighborWidth
    假设邻居 AP 的带宽，默认 20。扫不到邻居带宽，只能假设。

.PARAMETER Top
    展示前 N 个候选信道，默认 5。

.PARAMETER StayThreshold
    当前信道干扰分比最优信道高出不超过该比例时，建议保持不动（默认 0.15 即 15%）。

.PARAMETER IncludeDfs
    允许推荐 DFS 信道（默认排除）。

.EXAMPLE
    .\Get-BestChannel.ps1
    分析当前接入的 SSID。

.EXAMPLE
    .\Get-BestChannel.ps1 -SSID 'Maple'
    给指定 SSID 找信道；若它同时有 2.4G/5G 两个频段，会分别给建议。

.EXAMPLE
    .\Get-BestChannel.ps1 -SSID 'Maple' -Band 2.4

.EXAMPLE
    .\Get-BestChannel.ps1 -SSID 'Maple-5G' -ChannelWidth 80 -NeighborWidth 80
#>
[CmdletBinding()]
param(
    # 要分析的目标 SSID；不填则默认当前接入的无线网络
    [string]$SSID,

    # 只分析某个波段：2.4 / 5 / 6
    [ValidateSet('2.4', '5', '6')]
    [string]$Band,

    [ValidateSet(20, 40, 80, 160)]
    [int]$ChannelWidth = 20,

    [ValidateSet(20, 40, 80)]
    [int]$NeighborWidth = 20,

    [int]$Top = 5,

    [double]$StayThreshold = 0.15,

    # DFS 信道的等效干扰折价：雷达退避会带来 60s+ 静默与降功率，用常数惩罚参与比较
    [double]$DfsPenalty = 0.05,

    # 扫描轮数：netsh 读的是缓存，单次扫描经常漏 AP，多轮合并后才靠谱
    [int]$ScanRounds = 3,

    [int]$ScanGapMs = 1500,

    [switch]$IncludeDfs
)

# ============ 基础：执行 netsh 并正确解码 ============
function Invoke-NetshWlan {
    param([string]$Arguments)

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = Join-Path $env:SystemRoot 'System32\netsh.exe'
    $psi.Arguments = $Arguments
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.CreateNoWindow = $true

    $proc = [System.Diagnostics.Process]::Start($psi)
    $stream = $proc.StandardOutput.BaseStream
    $ms = New-Object System.IO.MemoryStream
    $buf = New-Object byte[] 8192
    while (($n = $stream.Read($buf, 0, $buf.Length)) -gt 0) { $ms.Write($buf, 0, $n) }
    $proc.WaitForExit()
    $bytes = $ms.ToArray()
    $ms.Dispose()

    if ($bytes.Length -eq 0) { return @() }

    $text = $null
    try {
        $text = (New-Object System.Text.UTF8Encoding($false, $true)).GetString($bytes)
    } catch {
        $enc = $null
        try { $enc = [Console]::OutputEncoding } catch { }
        if ($null -eq $enc) {
            $enc = [Text.Encoding]::GetEncoding([Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage)
        }
        $text = $enc.GetString($bytes)
    }
    return (($text.TrimStart([char]0xFEFF)) -split "`r?`n")
}

# ============ 读取当前连接 ============
function Get-CurrentConnection {
    $lines = Invoke-NetshWlan -Arguments 'wlan show interfaces'
    if (-not $lines) { return $null }

    $min = @{
        SSID = $null; BSSID = $null; Band = $null; Channel = $null
        Radio = $null; Signal = $null; Rssi = $null
    }

    foreach ($l in $lines) {
        if ($l -notmatch '^\s{2,}(\S.*?)\s{2,}:\s*(.*?)\s*$') { continue }
        $k = $Matches[1]
        $v = $Matches[2]

        if ($k -eq 'SSID' -and $null -eq $min.SSID) { $min.SSID = $v; continue }
        if ($k -eq 'AP BSSID' -and $null -eq $min.BSSID) { $min.BSSID = $v.ToUpper(); continue }
        if ($v -match '^\d{1,3}%$' -and $null -eq $min.Signal) { $min.Signal = [int]$v.TrimEnd('%'); continue }
        if ($v -match '^-\d{1,3}$' -and $null -eq $min.Rssi) { $min.Rssi = [int]$v; continue }
        if ($v -match '^((?:2\.4|5|6)\s*GHz)$' -and $null -eq $min.Band) { $min.Band = ($v -replace '\s+', ' '); continue }
        if ($v -match '^802\.11[a-zA-Z]+$' -and $null -eq $min.Radio) { $min.Radio = $v; continue }
        if ($null -ne $min.Band -and $null -eq $min.Channel -and $v -match '^(\d{1,4})$') {
            $ch = [int]$Matches[1]
            if ($ch -ge 1 -and $ch -le 233) { $min.Channel = $ch }
        }
    }

    if ($null -eq $min.Signal -and $null -eq $min.Rssi) { return $null }
    if ($null -eq $min.Rssi -and $null -ne $min.Signal) { $min.Rssi = [int]([math]::Round($min.Signal / 2) - 100) }
    [pscustomobject]$min
}

# ============ 扫描周边 AP（单次） ============
function ConvertTo-ScanAps {
    # -Lines 可注入已抓取的 netsh 输出，便于离线测试；不传则现场扫描
    param([string[]]$Lines)

    # 用 $PSBoundParameters 判断「有没有传」，而不是判断真假：
    # 传了空数组是「离线场景明确没有 AP」，不能退化成去扫网卡
    if (-not $PSBoundParameters.ContainsKey('Lines')) {
        $Lines = Invoke-NetshWlan -Arguments 'wlan show networks mode=bssid'
    }
    if (-not $Lines) { return @() }

    $blocks = New-Object System.Collections.Generic.List[object]
    $cur = $null
    $ssid = $null

    foreach ($line in $lines) {
        if ($line -match '^\s*SSID\s+\d+\s*:\s*(.*?)\s*$') {
            if ($null -ne $cur) { $blocks.Add($cur); $cur = $null }
            $ssid = $Matches[1]
            continue
        }
        if ($line -match '^\s*BSSID\s+\d+\s*:\s*([0-9a-fA-F]{2}(?::[0-9a-fA-F]{2}){5})') {
            if ($null -ne $cur) { $blocks.Add($cur) }
            $cur = [pscustomobject]@{
                SSID = $ssid; BSSID = $Matches[1].ToUpper()
                Lines = New-Object System.Collections.Generic.List[string]
            }
            continue
        }
        if ($null -ne $cur) { $cur.Lines.Add($line) }
    }
    if ($null -ne $cur) { $blocks.Add($cur) }

    $aps = New-Object System.Collections.Generic.List[object]
    foreach ($b in $blocks) {
        $band = $null; $channel = $null; $signal = $null; $util = $null; $radio = $null
        $seenChannel = $false
        foreach ($l in $b.Lines) {
            if ($l -notmatch '^\s+\S.*?\s*:\s*(.*?)\s*$') { continue }
            $v = $Matches[1]
            if ($null -eq $signal -and $v -match '^(\d{1,3})%$') { $signal = [int]$Matches[1]; continue }
            if ($null -eq $radio -and $v -match '^(802\.11[a-zA-Z]+)$') { $radio = $Matches[1]; continue }
            if ($null -eq $band -and $v -match '^((?:2\.4|5|6)\s*GHz)$') { $band = ($Matches[1] -replace '\s+', ' '); continue }
            if (-not $seenChannel -and $null -ne $band -and $v -match '^(\d{1,3})$') {
                $ch = [int]$Matches[1]
                if ($ch -ge 1 -and $ch -le 233) { $channel = $ch; $seenChannel = $true; continue }
            }
            if ($null -eq $util -and $v -match '\(\s*(\d{1,3})%\s*\)') { $util = [int]$Matches[1]; continue }
        }
        if ($null -eq $channel -or $null -eq $signal) { continue }
        $rssi = [int]([math]::Round($signal / 2) - 100)
        $aps.Add([pscustomobject]@{
            SSID     = $b.SSID
            BSSID    = $b.BSSID
            Band     = $band
            Channel  = $channel
            Radio    = $radio
            Signal   = $signal
            RssiEst  = $rssi
            ChanUtil = $util
        })
    }
    return $aps
}

# ============ 扫描周边 AP（多轮合并，抗缓存裁剪） ============
function Get-NeighborAp {
    param(
        [int]$Rounds = 3,
        [int]$GapMs = 1500
    )

    $rounds = [math]::Max(1, $Rounds)
    $seen = @{}   # BSSID -> 记录，保留信号更强的一次

    for ($r = 0; $r -lt $rounds; $r++) {
        foreach ($ap in (ConvertTo-ScanAps)) {
            if (-not $seen.ContainsKey($ap.BSSID)) {
                $seen[$ap.BSSID] = $ap
            }
            elseif ($ap.Signal -gt $seen[$ap.BSSID].Signal) {
                $seen[$ap.BSSID] = $ap
            }
        }
        if ($r -lt $rounds - 1) { Start-Sleep -Milliseconds $GapMs }
    }

    return @($seen.Values)
}

# ============ 信道 <-> 频率 ============
function Get-ChannelFreq {
    param([string]$Band, [int]$Channel)
    switch ($Band) {
        '2.4 GHz' { if ($Channel -eq 14) { return 2484 } else { return 2412 + 5 * ($Channel - 1) } }
        '5 GHz'   { return 5000 + 5 * $Channel }
        '6 GHz'   { return 5950 + 5 * $Channel }
        default   { return $null }
    }
}

# 宽信道块的中心频率：把主信道对齐到它所属的块，再取块中心
function Get-BlockCenterFreq {
    param([string]$Band, [int]$Channel, [int]$Width)

    $f = Get-ChannelFreq -Band $Band -Channel $Channel
    if ($null -eq $f -or $Width -le 20) { return $f }

    $span = [int]($Width / 20)
    $base = switch ($Band) {
        '5 GHz'   { if ($Channel -ge 149) { 149 } else { 36 } }
        '6 GHz'   { 1 }
        '2.4 GHz' { 1 }
        default   { $null }
    }
    if ($null -eq $base) { return $f }

    $blockCh = $span * 4
    $start = $base + [math]::Floor(($Channel - $base) / $blockCh) * $blockCh
    $fStart = Get-ChannelFreq -Band $Band -Channel ([int]$start)
    if ($null -eq $fStart) { return $f }
    return $fStart + ($span - 1) * 10
}

function Test-DfsChannel {
    param([string]$Band, [int]$Channel)
    if ($Band -ne '5 GHz') { return $false }
    return (($Channel -ge 52 -and $Channel -le 64) -or ($Channel -ge 100 -and $Channel -le 144))
}

# 两个带宽块的频谱交叠比例（0~1）
function Get-SpectrumOverlap {
    param([double]$FreqA, [double]$WidthA, [double]$FreqB, [double]$WidthB)
    $lo = [math]::Max($FreqA - $WidthA / 2, $FreqB - $WidthB / 2)
    $hi = [math]::Min($FreqA + $WidthA / 2, $FreqB + $WidthB / 2)
    if ($hi -le $lo) { return 0.0 }
    return ($hi - $lo) / $WidthA   # 以候选信道带宽为基准归一化
}

# 候选信道：能容纳指定带宽、且落在合法频段内
function Get-CandidateChannels {
    param([string]$Band, [int]$Width)

    # 非法带宽直接返回空集，别默默按 20MHz 算（会被误当成「结论可靠」）
    if ($Width -lt 20) { return @() }

    $span = [int]([math]::Max(1, $Width / 20))

    $list = switch ($Band) {
        '2.4 GHz' { @(1..13) }
        '5 GHz'   { @(@(36..64) | Where-Object { $_ % 4 -eq 0 }) +
                    @(@(100..144) | Where-Object { $_ % 4 -eq 0 }) +
                    @(@(149..165) | Where-Object { $_ % 4 -eq 1 }) }
        '6 GHz'   { @(@(1..233) | Where-Object { $_ % 4 -eq 1 }) }
        default   { @() }
    }
    $list = @($list)
    if ($list.Count -eq 0) { return @() }
    if ($span -le 1) { return $list }

    # 子信道中心频率间隔 20MHz，对应信道号 +4（2.4G/5G/6G 都是 5MHz 一个信道号）
    $out = @()
    foreach ($c in $list) {
        $ok = $true
        for ($j = 1; $j -lt $span; $j++) {
            if ($list -notcontains ($c + 4 * $j)) { $ok = $false; break }
        }
        if ($ok) { $out += $c }
    }
    $out = @($out | Select-Object -Unique)

    # 宽信道有对齐要求：80MHz 只能从 36/52/100/116/132（或 149）起，不能跨块
    if ($span -gt 1) {
        $step = $span * 4
        switch ($Band) {
            '5 GHz' {
                $out = @($out | Where-Object {
                        if ($_ -ge 149) { ($_ - 149) % $step -eq 0 } else { ($_ - 36) % $step -eq 0 }
                    })
            }
            '6 GHz' {
                $out = @($out | Where-Object { ($_ - 1) % $step -eq 0 })
            }
        }
    }
    return $out
}

# ============ 干扰评分 ============
function Get-ChannelRanking {
    param(
        [Parameter(Mandatory)] $Current,
        [object[]]$Neighbors = @(),
        [int]$Width = 20,
        [int]$NbWidth = 20,
        # DFS 惩罚作为参数而非读脚本级变量，保证函数可以脱离主流程单独调用/测试
        [double]$DfsPenalty = 0.05,
        [switch]$AllowDfs
    )

    $ownMw = [math]::Pow(10, $Current.Rssi / 10.0)
    if ($ownMw -le 0) { $ownMw = 1e-6 }

    $weighted = foreach ($ap in $Neighbors) {
        $mw = [math]::Pow(10, $ap.RssiEst / 10.0)
        $load = if ($null -ne $ap.ChanUtil) { 1 + $ap.ChanUtil / 100.0 } else { 1.0 }
        [pscustomobject]@{
            SSID     = $ap.SSID
            Channel  = $ap.Channel
            Signal   = $ap.Signal
            Weight   = $mw * $load
        }
    }
    $weighted = @($weighted)

    $candidates = @(Get-CandidateChannels -Band $Current.Band -Width $Width)
    if ($candidates.Count -eq 0) { return @() }

    $scored = foreach ($ch in $candidates) {
        $fCh = Get-ChannelFreq -Band $Current.Band -Channel $ch
        if ($null -eq $fCh) { continue }

        $total = 0.0
        $hitters = @()
        $fChCenter = Get-BlockCenterFreq -Band $Current.Band -Channel $ch -Width $Width
        foreach ($ap in $weighted) {
            $fApCenter = Get-BlockCenterFreq -Band $Current.Band -Channel $ap.Channel -Width $NbWidth
            if ($null -eq $fApCenter) { continue }
            $ov = Get-SpectrumOverlap -FreqA $fChCenter -WidthA $Width -FreqB $fApCenter -WidthB $NbWidth
            if ($ov -le 0) { continue }
            $total += $ap.Weight * $ov
            $hitters += [pscustomobject]@{
                SSID = $ap.SSID; Channel = $ap.Channel; Signal = $ap.Signal; Overlap = $ov
            }
        }

        $score = $total / $ownMw
        $dfs = Test-DfsChannel -Band $Current.Band -Channel $ch
        # 加法惩罚而不是乘法：空载 DFS 信道乘完还是 0，会盖过真正干净的普通信道
        if ($dfs -and -not $AllowDfs) { $score = $score + $DfsPenalty }

        [pscustomobject]@{
            Channel     = $ch
            Score       = [math]::Round($score, 3)
            ScoreRaw    = $score
            Dfs         = $dfs
            Interferers = $hitters.Count
            Detail      = ($hitters | Sort-Object -Property Overlap -Descending |
                ForEach-Object { "$($_.SSID)@ch$($_.Channel) $($_.Signal)%" }) -join '; '
        }
    }

    # 用未取整的原始分数排序（否则弱干扰会被抹平成一堆 0）；分数相同优先保留当前信道
    return @($scored | Sort-Object `
            @{Expression = { $_.ScoreRaw }}, `
            @{Expression = { if ($_.Channel -eq $Current.Channel) { 0 } else { 1 } }}, `
            @{Expression = { $_.Channel } })
}

# 干扰分的可读化输出（极小值不显示成 0）
function Format-Score {
    param([double]$Value)
    if ($Value -le 0) { return '0' }
    if ($Value -lt 0.001) { return '<0.001' }
    return ('{0:0.000}' -f $Value)
}


# ============ 主流程 ============

# ---- 1. 确定目标 SSID ----
$conn = Get-CurrentConnection
$connectedBssid = if ($null -ne $conn) { $conn.BSSID } else { $null }

$ssidFrom = '命令行 -SSID 指定'
if ([string]::IsNullOrWhiteSpace($SSID)) {
    if ($null -eq $conn -or [string]::IsNullOrWhiteSpace($conn.SSID)) {
        Write-Warning '当前不是无线连接，无法推断目标 SSID，请用 -SSID 指定要分析的网络名。'
        return
    }
    $SSID = $conn.SSID
    $ssidFrom = '默认取当前接入的 SSID'
}

Write-Host ''
Write-Host ('目标 SSID : {0}   （{1}）' -f $SSID, $ssidFrom) -ForegroundColor Cyan

# ---- 2. 扫描周边 ----
$neighbors = @(Get-NeighborAp -Rounds $ScanRounds -GapMs $ScanGapMs | Where-Object { $null -ne $_ })

# ---- 3. 找出目标 SSID 的所有 BSSID ----
$targets = @($neighbors | Where-Object { $_.SSID -eq $SSID })
if ($targets.Count -eq 0) {
    Write-Host ''
    Write-Host ('警告：当前环境未扫描到SSID: {0}, 请输入正确的SSID，或重试。' -f $SSID) -ForegroundColor Red
    Write-Host ('      本次扫描返回 {0} 个 BSSID / {1} 个 SSID，Windows 扫描缓存可能不含该网络。' -f `
            $neighbors.Count, @($neighbors | Select-Object -ExpandProperty SSID -Unique).Count) -ForegroundColor DarkGray
    Write-Host '      若确认该网络就在附近，请开关一次 Wi-Fi 强制重扫后重试。' -ForegroundColor DarkGray
    return
}

if ($Band) {
    $targets = @($targets | Where-Object { $_.Band -like "$Band*" })
    if ($targets.Count -eq 0) {
        Write-Host ('警告：SSID {0} 未在 {1} GHz 波段扫描到。' -f $SSID, $Band) -ForegroundColor Red
        return
    }
}

# ---- 4. 按波段逐段分析 ----
$groups = @($targets | Group-Object Band | Sort-Object Name)
$summary = New-Object System.Collections.Generic.List[object]
$idx = 0
$staleBands = 0

foreach ($g in $groups) {
    $idx++
    $apsInBand = @($g.Group)

    # 参考 AP：优先取当前连接的那个 BSSID（若它在该波段），否则取信号最强者
    $ref = $null
    if ($connectedBssid) {
        $ref = $apsInBand | Where-Object { $_.BSSID -eq $connectedBssid } | Select-Object -First 1
    }
    if ($null -eq $ref) {
        $ref = $apsInBand | Sort-Object Signal -Descending | Select-Object -First 1
    }

    $refRssi = $ref.RssiEst
    $refSignal = $ref.Signal
    if ($connectedBssid -and $ref.BSSID -eq $connectedBssid -and $null -ne $conn -and $null -ne $conn.Rssi) {
        $refRssi = $conn.Rssi          # 已连接的那个用真实 dBm，比百分比反推更准
        $refSignal = $conn.Signal
    }

    $cur = [pscustomobject]@{
        SSID    = $SSID
        BSSID   = $ref.BSSID
        Band    = $ref.Band
        Channel = $ref.Channel
        Rssi    = $refRssi
        Signal  = $refSignal
        Radio   = $ref.Radio
    }

    # 同波段邻居：排除该 SSID 自己的其它 BSSID（同一网络不互相算干扰）
    $sameBand = @($neighbors | Where-Object { $_.Band -eq $cur.Band -and $_.SSID -ne $SSID })

    Write-Host ''
    Write-Host ('========== [{0}/{1}] {2} @ {3} ==========' -f $idx, $groups.Count, $SSID, $cur.Band) -ForegroundColor Cyan
    Write-Host ('  参考 AP   : {0}' -f $cur.BSSID)
    Write-Host ('  当前信道  : ch{0}   协议 {1}   信号 {2}% ({3} dBm)' -f $cur.Channel, $cur.Radio, $cur.Signal, $cur.Rssi)
    Write-Host ('  分析带宽  : {0} MHz   (邻居按 {1} MHz 计)' -f $ChannelWidth, $NeighborWidth)

    Write-Host ''
    Write-Host ('----- 同波段邻居（{0} 个）-----' -f $sameBand.Count)
    if ($sameBand.Count -gt 0) {
        # ChanUtil 可能为空（Beacon 里没有 BSS Load），空单元格在某些终端里会渲染成怪字符，统一显示 '-'
        $sameBand | Sort-Object Channel |
            Format-Table SSID, BSSID, Channel, Signal, RssiEst,
            @{ Name = 'ChanUtil'; Expression = { if ($null -eq $_.ChanUtil -or "$($_.ChanUtil)" -eq '') { '-' } else { $_.ChanUtil } } } -AutoSize |
            Out-Host
        Write-Host ''
    }
    else {
        Write-Host '  未发现同波段的其他 AP。' -ForegroundColor DarkGray
    }

    $ranked = @(Get-ChannelRanking -Current $cur -Neighbors $sameBand `
            -Width $ChannelWidth -NbWidth $NeighborWidth -DfsPenalty $DfsPenalty -AllowDfs:$IncludeDfs)

    if ($ranked.Count -eq 0) {
        Write-Host ('  没有可用的候选信道（{0}，{1} MHz）。' -f $cur.Band, $ChannelWidth) -ForegroundColor Yellow
        $summary.Add([pscustomobject]@{
                Band = $cur.Band; Current = "ch$($cur.Channel)"; Best = '-'
                Decision = '无候选'; CurrentScore = '-'; BestScore = '-'
            })
        continue
    }

    $best = $ranked[0]
    $curRow = $ranked | Where-Object { $_.Channel -eq $cur.Channel } | Select-Object -First 1
    $curScore = if ($null -ne $curRow) { $curRow.ScoreRaw } else { $null }
    $bestScore = $best.ScoreRaw

    Write-Host ('----- 候选信道评分（越低越好，前 {0} 名）-----' -f [math]::Min($Top, $ranked.Count))
    $view = $ranked | Select-Object -First $Top
    $maxScore = ($view | Measure-Object -Property ScoreRaw -Maximum).Maximum
    # 用绝对下限做标尺，避免「最大值也很小」时把弱干扰画成满格
    $scale = [math]::Max([double]$maxScore, 0.02)
    foreach ($r in $view) {
        $barLen = if ($scale -gt 0) { [int]([math]::Round(($r.ScoreRaw / $scale) * 24)) } else { 0 }
        if ($barLen -gt 24) { $barLen = 24 }
        $bar = ('#' * $barLen).PadRight(24, '.')
        $flag = @()
        if ($r.Channel -eq $cur.Channel) { $flag += '当前' }
        if ($r.Dfs) { $flag += 'DFS' }
        $fstr = if ($flag.Count) { '  [' + ($flag -join ',') + ']' } else { '' }
        Write-Host ('  ch{0,-4} {1}  {2,8}{3}' -f $r.Channel, $bar, (Format-Score $r.ScoreRaw), $fstr)
    }

    Write-Host ''
    Write-Host '----- 结论 -----' -ForegroundColor Green

    $decision = '保持'
    if ($best.Channel -eq $cur.Channel) {
        Write-Host ('  保持 ch{0}：已是本波段干扰最小的信道（干扰分 {1}）。' -f $cur.Channel, (Format-Score $bestScore)) -ForegroundColor Green
    }
    elseif ($null -ne $curScore -and $curScore -gt 0 -and ($curScore - $bestScore) / $curScore -le $StayThreshold) {
        Write-Host ('  维持 ch{0}：最优 ch{1} 只比它好 {2:P0}，低于 {3:P0} 的切换阈值。' -f `
                $cur.Channel, $best.Channel, (($curScore - $bestScore) / $curScore), $StayThreshold) -ForegroundColor Yellow
        $decision = '维持'
    }
    else {
        $gain = if ($curScore -gt 0) { ($curScore - $bestScore) / $curScore } else { 1 }
        $gainStr = if ($gain -ge 0.995) { '>99%' } else { '{0:P0}' -f $gain }
        Write-Host ('  建议把 {0} 切到 ch{1}：干扰分 {2} → {3}，下降 {4}。' -f `
                $cur.Band, $best.Channel, (Format-Score $curScore), (Format-Score $bestScore), $gainStr) -ForegroundColor Green
        if ($best.Interferers -eq 0) {
            Write-Host '  该信道在本次扫描中没有任何同频/邻频 AP。' -ForegroundColor Green
        }
        else {
            Write-Host ('  仍有 {0} 个 AP 频谱重叠：{1}' -f $best.Interferers, $best.Detail) -ForegroundColor DarkGray
        }
        $decision = '切换'
    }

    if ($sameBand.Count -eq 0 -and $neighbors.Count -gt 0) {
        $staleBands++
        Write-Host '  注意：同波段无邻居但其它波段有 AP，本波段扫描缓存可能陈旧，建议强制重扫后再定。' -ForegroundColor Yellow
    }

    $summary.Add([pscustomobject]@{
            Band         = $cur.Band
            Current      = "ch$($cur.Channel)"
            Best         = "ch$($best.Channel)"
            Decision     = $decision
            CurrentScore = (Format-Score $curScore)
            BestScore    = (Format-Score $bestScore)
        })
}

# ---- 5. 汇总 ----
if ($summary.Count -gt 0) {
    Write-Host ''
    Write-Host '========== 汇总 ==========' -ForegroundColor Green
    foreach ($s in $summary) {
        Write-Host ('  {0,-8} 当前 {1,-6} → 建议 {2,-6} [{3}]   干扰分 {4} → {5}' -f `
                $s.Band, $s.Current, $s.Best, $s.Decision, $s.CurrentScore, $s.BestScore)
    }
}

Write-Host ''
Write-Host '========== 说明 ==========' -ForegroundColor DarkGray
Write-Host '  · 干扰分 = Σ(邻居功率×频谱重叠度×负载)/本机功率，1.0 ≈ 干扰与自身信号等强' -ForegroundColor DarkGray
Write-Host '  · 多频 SSID 会按波段分别给建议；同一 SSID 的其它 BSSID 不计入干扰' -ForegroundColor DarkGray
Write-Host '  · 邻居信号由百分比反推 dBm（估算值，强信号端偏差可达 10dB）；带宽用 -NeighborWidth 指定' -ForegroundColor DarkGray
Write-Host '  · 信道可用性受地区法规与固件限制，最终以路由器可选列表为准' -ForegroundColor DarkGray
if ($ChannelWidth -eq 20) {
    Write-Host '  · 邻居多为 80MHz 时，建议加 -ChannelWidth 80 -NeighborWidth 80 复核' -ForegroundColor DarkGray
}
if ($staleBands -gt 0) {
    Write-Host '  · 检测到部分波段扫描缓存陈旧，结论仅供参考，强制重扫后复查更可靠' -ForegroundColor DarkGray
}
