<#
.SYNOPSIS
    读取当前无线网络的信号数据（纯系统自带命令，无需第三方模块）。

.DESCRIPTION
    解析 `netsh wlan show interfaces` 的输出。
    中文/英文系统下字段名不同（信号 / Signal、通道 / Channel），因此这里
    不按字段名匹配，而是按「值的形态」匹配（97%、-39 这类），跨语言可用。

.PARAMETER Samples
    采样次数，默认 1（只输出一个对象，可用于管道）。

.PARAMETER IntervalMs
    多次采样时的间隔毫秒数，默认 500。

.EXAMPLE
    .\Get-WifiSignal.ps1

.EXAMPLE
    .\Get-WifiSignal.ps1 -Samples 20 -IntervalMs 500

.EXAMPLE
    .\Get-WifiSignal.ps1 | Select-Object SSID, Signal, Rssi
#>
[CmdletBinding()]
param(
    [int]$Samples = 1,
    [int]$IntervalMs = 500
)

function Invoke-NetshWlan {
    <#
      直接启动 netsh，并按字节读取输出后自动判码。
      直接用 `netsh ...` 赋值给变量时，代码页不匹配会把中文键名读成乱码
      （同一台机器上 netsh 的编码可能是 UTF-8，也可能是 OEM 代码页）。
    #>
    param([string]$Arguments = 'wlan show interfaces')

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
        # 严格 UTF-8 解码：非法字节序列会抛异常，从而自动退回 OEM 代码页
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

function Get-WifiSignal {
    [CmdletBinding()]
    param()

    $res = [ordered]@{
        SSID   = $null
        BSSID  = $null
        Band   = $null
        Channel = $null
        Radio  = $null
        Signal = $null   # 百分比 0-100
        Rssi   = $null   # dBm，负值
        RxMbps = $null
        TxMbps = $null
    }

    $raw = Invoke-NetshWlan -Arguments 'wlan show interfaces'
    if (-not $raw -or -not ($raw -join '').Contains(':')) { return $null }

    foreach ($line in $raw) {
        if ($line -notmatch '^\s{2,}(\S.*?)\s{2,}:\s*(.*?)\s*$') { continue }
        $key = $Matches[1]
        $val = $Matches[2]

        switch ($true) {
            { $val -match '^\d{1,3}%$' -and $null -eq $res.Signal } {
                $res.Signal = [int]$val.TrimEnd('%'); break
            }
            { $val -match '^-\d{1,3}$' -and $null -eq $res.Rssi } {
                $res.Rssi = [int]$val; break
            }
            { $key -eq 'SSID' -and $null -eq $res.SSID } {
                $res.SSID = $val; break
            }
            { $key -eq 'AP BSSID' -and $null -eq $res.BSSID } {
                $res.BSSID = $val; break
            }
            { $val -match '^(2\.4|5|6) GHz$' } {
                $res.Band = $val; break
            }
            { $val -match '^802\.11\w+$' -and $null -eq $res.Radio } {
                $res.Radio = $val; break
            }
            { $val -match '^\d{1,4}(\.\d+)?$' -and $null -eq $res.Channel -and $key -notmatch 'SSID|BSSID' -and [int]($val.Split('.')[0]) -le 233 } {
                # 通道号：紧跟在波段/无线电类型之后的纯数字，取值 1-233
                if ($null -ne $res.Band -or $null -ne $res.Radio) { $res.Channel = [int]$val.Split('.')[0] }
                continue
            }
        }
    }

    # 速率行：中文「接收速率(Mbps)」/ 英文「Receive rate (Mbps)」，含括号，单独再扫一遍
    foreach ($line in $raw) {
        if ($line -match '(?i)receive rate|接收速率') {
            if ($line -match ':\s*([\d.]+)') { $res.RxMbps = [double]$Matches[1] }
        }
        elseif ($line -match '(?i)transmit rate|传输速率') {
            if ($line -match ':\s*([\d.]+)') { $res.TxMbps = [double]$Matches[1] }
        }
    }

    if ($null -eq $res.Signal -and $null -eq $res.Rssi) { return $null }

    # 由 RSSI 估算链路质量（Windows 的常用近似，0-100 截断）
    $quality = if ($null -ne $res.Rssi) {
        [math]::Min(100, [math]::Max(0, 2 * ($res.Rssi + 100)))
    } else { $null }

    [pscustomobject]@{
        Time     = Get-Date
        SSID     = $res.SSID
        BSSID    = $res.BSSID
        Band     = $res.Band
        Channel  = $res.Channel
        Radio    = $res.Radio
        Signal   = $res.Signal
        Quality  = $quality
        Rssi     = $res.Rssi
        RxMbps   = $res.RxMbps
        TxMbps   = $res.TxMbps
    }
}

$first = Get-WifiSignal
if ($null -eq $first) {
    Write-Warning '未检测到已连接的无线网络（网卡未连接，或本机没有无线网卡）。'
    return
}

if ($Samples -le 1) {
    $first
    return
}

$last = $first
for ($n = 1; $n -le $Samples; $n++) {
    $s = if ($n -eq 1) { $first } else { Get-WifiSignal }
    if ($null -eq $s) { Write-Warning '采样中断：无线已断开。'; break }
    '{0}  {1,6}  {2,3}%  {3,4} dBm  CH{4,-3} {5}' -f `
        $s.Time.ToString('HH:mm:ss'), $s.SSID, $s.Signal, $s.Rssi, $s.Channel, $s.Band
    $last = $s
    if ($n -lt $Samples) { Start-Sleep -Milliseconds $IntervalMs }
}
