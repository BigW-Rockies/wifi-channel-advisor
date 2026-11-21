<#
.SYNOPSIS
    扫描并列出周边所有可见的无线接入点（含未连接的邻居热点）。

.DESCRIPTION
    数据来源：`netsh wlan show networks mode=bssid`
    这是 Windows 自带的扫描结果缓存，每个 BSSID 都包含信号百分比、波段、信道、
    信道利用率、加密方式、协商速率集合等。

    实现要点：
    1) netsh 输出编码不固定（本机实测为 UTF-8，控制台却是 936），因此直接读
       StandardOutput 原始字节，先严格按 UTF-8 解码，失败再退回 OEM 代码页。
    2) 字段名随系统语言变化（信号/Signal、通道/Channel），所以不匹配字段名，
       而是按「值的形态 + 出现顺序」解析，中英文系统通用。

.PARAMETER SortBy
    排序字段：Signal（默认）、Channel、Band、SSID。

.PARAMETER Top
    只显示前 N 个，默认全部。

.PARAMETER ConnectedOnly
    只看当前已连接的那个 AP（按 BSSID 匹配）。

.EXAMPLE
    .\Get-WifiNeighbors.ps1

.EXAMPLE
    .\Get-WifiNeighbors.ps1 -SortBy Signal -Top 10

.EXAMPLE
    .\Get-WifiNeighbors.ps1 | Export-Csv ap.csv -NoTypeInformation -Encoding UTF8
#>
[CmdletBinding()]
param(
    [ValidateSet('Signal', 'Channel', 'Band', 'SSID')]
    [string]$SortBy = 'Signal',

    [int]$Top = 0,

    [switch]$ConnectedOnly,

    [switch]$Table
)

function Invoke-NetshWlan {
    param([string]$Arguments = 'wlan show networks mode=bssid')

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

    $text = $text.TrimStart([char]0xFEFF)
    return ($text -split "`r?`n")
}

function ConvertTo-NeighborAp {
    [CmdletBinding()]
    param([string[]]$Lines)

    # 第一步：按 SSID / BSSID 切成块
    $blocks = New-Object System.Collections.Generic.List[object]
    $cur = $null
    $ssid = $null
    $auth = $null
    $cipher = $null

    foreach ($line in $Lines) {
        if ($line -match '^\s*SSID\s+\d+\s*:\s*(.*?)\s*$') {
            if ($null -ne $cur) { $blocks.Add($cur); $cur = $null }
            $ssid = $Matches[1]
            $auth = $null
            $cipher = $null
            continue
        }

        if ($line -match '^\s*BSSID\s+\d+\s*:\s*([0-9a-fA-F]{2}(?::[0-9a-fA-F]{2}){5})') {
            if ($null -ne $cur) { $blocks.Add($cur) }
            $cur = [pscustomobject]@{
                SSID  = $ssid
                BSSID = $Matches[1].ToUpper()
                Lines = New-Object System.Collections.Generic.List[string]
            }
            continue
        }

        if ($null -ne $cur) {
            $cur.Lines.Add($line)
            continue
        }

        # SSID 头与 BSSID 头之间的加密/认证行（此时 $cur 还是空）
        if ($line -match '^\s+\S.*?\s*:\s*(.*?)\s*$') {
            $v = $Matches[1]
            if ($null -eq $auth -and $v -match '^(WPA|Open|OWE|WEP|RSNA|Shared)') { $auth = $v; continue }
            if ($null -eq $cipher -and $v -match '^(CCMP|GCMP|TKIP|WEP|None)') { $cipher = $v; continue }
        }
    }
    if ($null -ne $cur) { $blocks.Add($cur) }

    # 第二步：逐块按值形态取字段
    $aps = New-Object System.Collections.Generic.List[object]
    foreach ($b in $blocks) {
        $band = $null; $channel = $null; $radio = $null
        $signal = $null; $util = $null; $stations = $null
        $seenChannel = $false

        foreach ($l in $b.Lines) {
            if ($l -notmatch '^\s+\S.*?\s*:\s*(.*?)\s*$') { continue }
            $v = $Matches[1]

            if ($null -eq $signal -and $v -match '^(\d{1,3})%$') { $signal = [int]$Matches[1]; continue }
            if ($null -eq $radio -and $v -match '^(802\.11[a-zA-Z]+)$') { $radio = $Matches[1]; continue }
            if ($null -eq $band -and $v -match '^((?:2\.4|5|6)\s*GHz)$') { $band = ($Matches[1] -replace '\s+', ' '); continue }

            if (-not $seenChannel -and $v -match '^(\d{1,3})$' -and $null -ne $band) {
                $ch = [int]$Matches[1]
                if ($ch -ge 1 -and $ch -le 233) { $channel = $ch; $seenChannel = $true; continue }
            }
            if ($null -eq $util -and $v -match '\(\s*(\d{1,3})%\s*\)') { $util = [int]$Matches[1]; continue }
            if ($seenChannel -and $null -eq $stations -and $v -match '^(\d{1,3})$') { $stations = [int]$Matches[1]; continue }
        }

        # RSSI 由信号百分比反推（Windows 的映射关系近似 quality = 2*(rssi+100)）
        $rssi = if ($null -ne $signal) { [int]([math]::Round($signal / 2) - 100) } else { $null }

        $aps.Add([pscustomobject]@{
            SSID     = $b.SSID
            BSSID    = $b.BSSID
            Band     = $band
            Channel  = $channel
            Radio    = $radio
            Signal   = $signal
            RssiEst  = $rssi
            ChanUtil = $util
            Stations = $stations
            Auth     = $auth
            Cipher   = $cipher
        })
    }

    return $aps
}

# ---- 扫描 ----
$lines = Invoke-NetshWlan
if (-not $lines -or $lines.Count -lt 2) {
    Write-Warning '未获取到扫描结果，请确认无线网卡已启用。'
    return
}

$result = ConvertTo-NeighborAp -Lines $lines

if ($ConnectedOnly) {
    $ifaceLine = Invoke-NetshWlan -Arguments 'wlan show interfaces' |
        Where-Object { $_ -match '^\s*AP BSSID\s*:\s*(\S+)' } | Select-Object -First 1
    if ($ifaceLine -match '([0-9A-Fa-f]{2}(?::[0-9A-Fa-f]{2}){5})') {
        $curBssid = $Matches[1].ToUpper()
        $result = $result | Where-Object { $_.BSSID -eq $curBssid }
    }
}

if (-not $result -or @($result).Count -eq 0) {
    Write-Warning '没有解析到接入点信息。'
    return
}

$sorted = switch ($SortBy) {
    'Signal'  { $result | Sort-Object -Property @{Expression = 'Signal'; Descending = $true} }
    'Channel' { $result | Sort-Object -Property Channel, SSID }
    'Band'    { $result | Sort-Object -Property Band, Channel }
    'SSID'    { $result | Sort-Object -Property SSID, @{Expression = 'Signal'; Descending = $true} }
}

if ($Top -gt 0) { $sorted = @($sorted)[0..([math]::Min($Top, @($sorted).Count) - 1)] }

# 默认输出对象，便于管道 / Export-Csv；要看表格用 -Table
if ($Table) {
    # ChanUtil 可能为空（Beacon 里没有 BSS Load），空单元格在某些终端里会渲染成怪字符，统一显示 '-'
    $sorted | Format-Table -AutoSize `
        SSID, BSSID, Band, Channel, Radio, Signal, RssiEst,
        @{ Name = 'ChanUtil'; Expression = { if ($null -eq $_.ChanUtil -or "$($_.ChanUtil)" -eq '') { '-' } else { $_.ChanUtil } } },
        Stations, Auth, Cipher
}
else {
    $sorted
}
