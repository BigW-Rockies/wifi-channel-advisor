#Requires -Version 5.1
<#
.SYNOPSIS
    用一份离线 CSV 跑通信道分析逻辑，不需要无线网卡。

.DESCRIPTION
    先把 Get-BestChannel.ps1 里的函数定义用 AST 提取出来执行（不跑主流程，
    所以不会去扫网卡），然后用 examples/scan-sample.csv 里的邻居数据调用
    Get-ChannelRanking，输出和真实运行一致的评分与结论。

    这份 CSV 是**合成样本**：SSID 用常见单词、MAC 用 02: 开头的本地管理地址，
    不对应任何真实设备，可以放心当作演示数据。

.EXAMPLE
    .\examples\Analyze-Sample.ps1

.EXAMPLE
    .\examples\Analyze-Sample.ps1 -SSID Maple -NeighborWidth 40

.EXAMPLE
    # 换成你自己导出的扫描结果
    .\Get-WifiNeighbors.ps1 | Export-Csv my-scan.csv -NoTypeInformation -Encoding UTF8
    .\examples\Analyze-Sample.ps1 -CsvPath .\my-scan.csv -SSID 'Maple'
#>
[CmdletBinding()]
param(
    [string]$CsvPath = (Join-Path $PSScriptRoot 'scan-sample.csv'),

    [string]$SSID = 'Maple',

    [ValidateSet(20, 40, 80, 160)]
    [int]$ChannelWidth = 20,

    [ValidateSet(20, 40, 80)]
    [int]$NeighborWidth = 20,

    [int]$Top = 5
)

$ErrorActionPreference = 'Stop'

# ---------------- 只加载函数定义 ----------------
$analyzerPath = Join-Path $PSScriptRoot '..\Get-BestChannel.ps1'
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path -LiteralPath $analyzerPath).Path, [ref]$null, [ref]$null)
foreach ($def in $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
    . ([scriptblock]::Create($def.Extent.Text))
}

if (-not (Test-Path -LiteralPath $CsvPath)) { throw "找不到 CSV: $CsvPath" }

# ---------------- 读样本，统一字段类型 ----------------
# 注意：PS 5.1 里不能把 if 当表达式写进哈希表（那是 PS7 的语法），
# 这里用显式语句先算好再赋值。
$rows = Import-Csv -LiteralPath $CsvPath -Encoding UTF8 | ForEach-Object {
    $rssi = $null
    if ([string]::IsNullOrWhiteSpace($_.RssiEst)) {
        $rssi = [int]([math]::Round([int]$_.Signal / 2) - 100)
    }
    else {
        $rssi = [int]$_.RssiEst
    }

    $util = $null
    if (-not [string]::IsNullOrWhiteSpace($_.ChanUtil)) { $util = [int]$_.ChanUtil }

    [pscustomobject]@{
        SSID     = $_.SSID
        BSSID    = $_.BSSID
        Band     = $_.Band
        Channel  = [int]$_.Channel
        Radio    = $_.Radio
        Signal   = [int]$_.Signal
        RssiEst  = $rssi
        ChanUtil = $util
    }
}

$mine = @($rows | Where-Object { $_.SSID -eq $SSID })
if ($mine.Count -eq 0) {
    Write-Host ("警告：样本里没有 SSID: {0}，可用的是：{1}" -f $SSID,
        (($rows | Select-Object -ExpandProperty SSID -Unique) -join ', ')) -ForegroundColor Red
    return
}

Write-Host ''
Write-Host '=== 离线示例分析（数据来自 CSV，不是实时扫描）===' -ForegroundColor Cyan
Write-Host ('样本文件 : {0}' -f (Split-Path -Leaf $CsvPath))
Write-Host ('目标 SSID: {0}' -f $SSID)

foreach ($group in ($mine | Group-Object Band | Sort-Object Name)) {
    $ref = $group.Group | Sort-Object Signal -Descending | Select-Object -First 1

    # 同波段邻居：排除该 SSID 自己的其它 BSSID
    $neighbors = @($rows | Where-Object { $_.Band -eq $ref.Band -and $_.SSID -ne $SSID })

    $cur = [pscustomobject]@{
        SSID = $SSID; BSSID = $ref.BSSID; Band = $ref.Band
        Channel = $ref.Channel; Rssi = $ref.RssiEst; Signal = $ref.Signal
    }

    Write-Host ''
    Write-Host ('--- {0} · 参考 AP {1} · 当前 ch{2} · {3}% ({4} dBm) · 邻居 {5} 个 ---' -f `
            $ref.Band, $ref.BSSID, $ref.Channel, $ref.Signal, $ref.RssiEst, $neighbors.Count)

    if ($neighbors.Count -gt 0) {
        $neighbors | Sort-Object Channel |
            Format-Table SSID, BSSID, Channel, Signal, RssiEst,
            @{ Name = 'ChanUtil'; Expression = { if ($null -eq $_.ChanUtil -or "$($_.ChanUtil)" -eq '') { '-' } else { $_.ChanUtil } } } -AutoSize |
            Out-Host
        Write-Host ''
    }

    $ranked = @(Get-ChannelRanking -Current $cur -Neighbors $neighbors -Width $ChannelWidth -NbWidth $NeighborWidth)
    if ($ranked.Count -eq 0) { Write-Host '  没有候选信道。' -ForegroundColor Yellow; continue }

    $best = $ranked[0]
    $curScore = ($ranked | Where-Object { $_.Channel -eq $cur.Channel } | Select-Object -First 1).ScoreRaw
    $max = ($ranked | Select-Object -First $Top | Measure-Object -Property ScoreRaw -Maximum).Maximum

    foreach ($r in ($ranked | Select-Object -First $Top)) {
        $len = if ($max -gt 0) { [int][math]::Round(($r.ScoreRaw / $max) * 24) } else { 0 }
        $bar = ('#' * $len).PadRight(24, '.')
        $flag = @()
        if ($r.Channel -eq $cur.Channel) { $flag += '当前' }
        if ($r.Dfs) { $flag += 'DFS' }
        Write-Host ('  ch{0,-4} {1} {2,8}  {3}' -f $r.Channel, $bar, (Format-Score $r.ScoreRaw), ($flag -join ','))
    }

    if ($best.Channel -eq $cur.Channel) {
        Write-Host ('  结论：保持 ch{0}，它已经是本波段最干净的信道。' -f $cur.Channel) -ForegroundColor Green
    }
    else {
        $gain = if ($null -ne $curScore -and $curScore -gt 0) { ($curScore - $best.ScoreRaw) / $curScore } else { $null }
        $tail = if ($null -ne $gain) { ('，干扰分 {0} → {1}（下降 {2:P0}）' -f (Format-Score $curScore), (Format-Score $best.ScoreRaw), $gain) } else { '' }
        Write-Host ('  结论：建议把 {0} 切到 ch{1}{2}' -f $ref.Band, $best.Channel, $tail) -ForegroundColor Green
    }
}

Write-Host ''
Write-Host '提示：这是离线样本。真实环境请直接运行 .\Get-BestChannel.ps1' -ForegroundColor DarkGray
