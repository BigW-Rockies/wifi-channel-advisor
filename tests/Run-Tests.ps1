#Requires -Version 5.1
<#
.SYNOPSIS
    Get-BestChannel.ps1 的离线测试。不需要无线网卡，可在 CI 或任意 Windows 上运行。

.DESCRIPTION
    只把 Get-BestChannel.ps1 里的「函数定义」加载进来（用 AST 提取），
    不执行主流程，因此不会扫网卡、不会打印分析结果。

    覆盖点：
      - 脚本语法、UTF-8 BOM
      - 频谱重叠度、宽信道块中心、DFS 判定、候选信道集合
      - 干扰评分排序、DFS 加法惩罚
      - netsh 解析器：中文/英文两套样本输出必须得到完全一致的结果

.EXAMPLE
    .\tests\Run-Tests.ps1
#>
[CmdletBinding()]
param(
    [string]$ScriptUnderTest = (Join-Path $PSScriptRoot '..\Get-BestChannel.ps1')
)

$ErrorActionPreference = 'Stop'

# ---------------- 断言 ----------------
$script:Passed = 0
$script:Failed = 0
$script:Failures = New-Object System.Collections.Generic.List[string]

function Write-Result {
    param([bool]$Ok, [string]$Name, [string]$Detail)

    if ($Ok) {
        $script:Passed++
        Write-Host ('  PASS  {0}' -f $Name) -ForegroundColor DarkGreen
    }
    else {
        $script:Failed++
        $script:Failures.Add($Name)
        Write-Host ('  FAIL  {0}' -f $Name) -ForegroundColor Red
        if ($Detail) { Write-Host ('        {0}' -f $Detail) -ForegroundColor DarkGray }
    }
}

function Assert-Equal {
    param($Expected, $Actual, [string]$Name)
    $ok = ($Expected -eq $Actual)
    $detail = if ($ok) { '' } else { "expected [$Expected], got [$Actual]" }
    Write-Result -Ok $ok -Name $Name -Detail $detail
}

function Assert-Near {
    param([double]$Expected, [double]$Actual, [double]$Tolerance, [string]$Name)
    $ok = ([math]::Abs($Expected - $Actual) -le $Tolerance)
    $detail = if ($ok) { '' } else { "expected $Expected +/- $Tolerance, got $Actual" }
    Write-Result -Ok $ok -Name $Name -Detail $detail
}

function Assert-True {
    param([bool]$Condition, [string]$Name, [string]$Detail = '')
    Write-Result -Ok $Condition -Name $Name -Detail $(if ($Condition) { '' } else { $Detail })
}

# ---------------- 只加载函数定义，不跑主流程 ----------------
# 注意：不能在函数内部 dot-source，否则函数只存在于那个作用域、返回后就没了。
# 这里只负责返回 AST 节点，由调用方在脚本作用域自己 dot-source。
function Get-AnalyzerFunctionAst {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { throw "找不到被测脚本: $Path" }

    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        (Resolve-Path -LiteralPath $Path).Path, [ref]$tokens, [ref]$errors)
    if ($errors -and $errors.Count -gt 0) {
        throw ("脚本存在语法错误: " + ($errors[0].Message))
    }

    return @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false))
}

# ================= 1. 脚本本身 =================
Write-Host ''
Write-Host '=== Script integrity ===' -ForegroundColor Cyan

$defs = @(Get-AnalyzerFunctionAst -Path $ScriptUnderTest)
. ([scriptblock]::Create((($defs | ForEach-Object { $_.Extent.Text }) -join "`r`n")))

$loaded = @($defs.Name)
Assert-True ($loaded.Count -ge 10) 'functions are loadable via AST' "loaded $($loaded.Count) functions"
Assert-True ($loaded -contains 'Get-ChannelRanking') 'Get-ChannelRanking is present'
Assert-True ($loaded -contains 'ConvertTo-ScanAps') 'ConvertTo-ScanAps is present'
Assert-True ($null -ne (Get-Command Get-SpectrumOverlap -ErrorAction SilentlyContinue)) 'functions are visible in script scope'

# BOM：PS 5.1 读无 BOM 的 UTF-8 会按 ANSI 解释，脚本里的中文正则会失效
$bytes = [System.IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $ScriptUnderTest))
$hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
Assert-True $hasBom 'script is saved as UTF-8 with BOM' "first bytes: $($bytes[0..2] -join ',')"

# ================= 2. 频谱数学 =================
Write-Host ''
Write-Host '=== Spectrum math ===' -ForegroundColor Cyan

Assert-Near 1.0 (Get-SpectrumOverlap 2412 20 2412 20) 0.001 '2.4 GHz ch1 vs ch1 = full overlap'
Assert-Near 0.75 (Get-SpectrumOverlap 2412 20 2417 20) 0.001 '2.4 GHz ch1 vs ch2 = 0.75'
Assert-Near 0.5 (Get-SpectrumOverlap 2412 20 2422 20) 0.001 '2.4 GHz ch1 vs ch3 = 0.5'
Assert-Near 0.0 (Get-SpectrumOverlap 2412 20 2432 20) 0.001 '2.4 GHz ch1 vs ch5 = 0'
Assert-Near 0.0 (Get-SpectrumOverlap 5180 20 5200 20) 0.001 '5 GHz ch36 vs ch40 = 0 (20 MHz each)'
Assert-Near 1.0 (Get-SpectrumOverlap 5210 80 5210 80) 0.001 '5 GHz 80 MHz block overlaps itself fully'

Assert-Equal 5210 (Get-BlockCenterFreq '5 GHz' 48 80) 'ch48 @ 80 MHz is centered at 5210'
Assert-Equal 5290 (Get-BlockCenterFreq '5 GHz' 60 80) 'ch60 @ 80 MHz is centered at 5290'
Assert-Equal 5210 (Get-BlockCenterFreq '5 GHz' 36 80) 'ch36 @ 80 MHz is centered at 5210'
Assert-Equal 5775 (Get-BlockCenterFreq '5 GHz' 149 80) 'ch149 @ 80 MHz is centered at 5775'
Assert-Equal 5180 (Get-BlockCenterFreq '5 GHz' 36 20) 'ch36 @ 20 MHz is centered at 5180'

Assert-True (-not (Test-DfsChannel '5 GHz' 36)) 'ch36 is not DFS'
Assert-True (Test-DfsChannel '5 GHz' 52) 'ch52 is DFS'
Assert-True (Test-DfsChannel '5 GHz' 144) 'ch144 is DFS'
Assert-True (-not (Test-DfsChannel '5 GHz' 149)) 'ch149 is not DFS'
Assert-True (-not (Test-DfsChannel '2.4 GHz' 6)) '2.4 GHz ch6 is not DFS'

Assert-Equal 13 (@(Get-CandidateChannels '2.4 GHz' 20).Count) '2.4 GHz / 20 MHz has 13 candidates'
Assert-Equal '36,52,100,116,132,149' ((Get-CandidateChannels '5 GHz' 80) -join ',') '5 GHz / 80 MHz blocks'
Assert-Equal '36,100' ((Get-CandidateChannels '5 GHz' 160) -join ',') '5 GHz / 160 MHz blocks'
Assert-Equal 0 (@(Get-CandidateChannels '5 GHz' 0).Count) 'unknown/zero width yields no candidates'

# ================= 3. 干扰评分 =================
Write-Host ''
Write-Host '=== Interference scoring ===' -ForegroundColor Cyan

$cur5 = [pscustomobject]@{
    SSID = 'Maple'; BSSID = '02:11:22:33:44:01'; Band = '5 GHz'
    Channel = 36; Rssi = -50; Signal = 100
}
$strongNeighborOn36 = @([pscustomobject]@{
        SSID = 'Birch'; BSSID = '02:11:22:33:44:02'; Band = '5 GHz'
        Channel = 36; Signal = 90; RssiEst = -55; ChanUtil = 40
    })

$ranking = @(Get-ChannelRanking -Current $cur5 -Neighbors $strongNeighborOn36 -Width 20 -NbWidth 20)
$scoreOf = { param($ch) ($ranking | Where-Object { $_.Channel -eq $ch } | Select-Object -First 1).ScoreRaw }

Assert-True ($ranking[0].Channel -ne 36) 'channel with a strong neighbor is not recommended' "top candidate: ch$($ranking[0].Channel)"
Assert-Near 0.0 (& $scoreOf 40) 0.0001 'clean adjacent 20 MHz channel scores 0'
Assert-True ((& $scoreOf 36) -gt 0.1) 'current channel scored as interfered' "score: $(& $scoreOf 36)"

# DFS 惩罚必须是加法：乘法对 0 分信道无效
$dfsOn = (& $scoreOf 52)
$r2 = @(Get-ChannelRanking -Current $cur5 -Neighbors $strongNeighborOn36 -DfsPenalty 0)
$dfsOff = ($r2 | Where-Object { $_.Channel -eq 52 } | Select-Object -First 1).ScoreRaw
Assert-Near 0.05 $dfsOn 0.0001 'DFS channel gets a flat +0.05 penalty'
Assert-Near 0.0 $dfsOff 0.0001 'DFS penalty can be disabled via -DfsPenalty 0'

# 邻居跑 80 MHz 时，会压住整块 4 个 20 MHz 信道（README 里那条结论的回归测试）
$neighbor80On48 = @([pscustomobject]@{
        SSID = 'Willow'; BSSID = '02:11:22:33:44:04'; Band = '5 GHz'
        Channel = 48; Signal = 87; RssiEst = -56; ChanUtil = 7
    })
$r80 = @(Get-ChannelRanking -Current $cur5 -Neighbors $neighbor80On48 -Width 20 -NbWidth 80)
$score36 = ($r80 | Where-Object { $_.Channel -eq 36 } | Select-Object -First 1).ScoreRaw
Assert-True ($score36 -gt 0.1) 'ch48 at 80 MHz spills onto ch36' "ch36 score: $score36"

# 同 SSID 的其它 BSSID 不该被当成干扰（由主流程过滤，这里验证评分本身不含 SSID 逻辑）
$emptyDb = New-Object System.Collections.Generic.List[object]
$emptyRanking = @(Get-ChannelRanking -Current $cur5 -Neighbors $emptyDb -Width 20)
Assert-True ($emptyRanking.Count -gt 0) 'ranking works with no neighbors'
Assert-Near 0.0 $emptyRanking[0].ScoreRaw 0.0001 'clean environment scores 0'

Assert-Equal '0' (Format-Score 0) 'Format-Score: 0'
Assert-Equal '<0.001' (Format-Score 0.0004) 'Format-Score: tiny value'
Assert-Equal '0.020' (Format-Score 0.02) 'Format-Score: normal value'

# ================= 4. netsh 解析器（中英文一致性） =================
Write-Host ''
Write-Host '=== netsh parser (locale independence) ===' -ForegroundColor Cyan

$fixtureDir = Join-Path $PSScriptRoot 'fixtures'
$normalize = {
    param($aps)
    $aps | Sort-Object BSSID | ForEach-Object {
        '{0}|{1}|{2}|{3}|{4}|{5}|{6}' -f $_.BSSID, $_.SSID, $_.Band, $_.Channel, $_.Signal, $_.Radio, $_.RssiEst
    }
}

$zhLines = Get-Content -LiteralPath (Join-Path $fixtureDir 'netsh-scan-zh.txt') -Encoding UTF8
$zh = @(ConvertTo-ScanAps -Lines $zhLines)
Assert-Equal 4 $zh.Count 'Chinese fixture parses 4 BSSIDs'

$enLines = Get-Content -LiteralPath (Join-Path $fixtureDir 'netsh-scan-en.txt') -Encoding UTF8
$en = @(ConvertTo-ScanAps -Lines $enLines)
Assert-Equal 4 $en.Count 'English fixture parses 4 BSSIDs'

$first = $zh | Where-Object { $_.BSSID -eq '02:11:22:33:44:01' } | Select-Object -First 1
Assert-Equal 'Maple' $first.SSID 'SSID parsed'
Assert-Equal '2.4 GHz' $first.Band 'band parsed'
Assert-Equal 6 $first.Channel 'channel parsed (not the basic-rate list)'
Assert-Equal 95 $first.Signal 'signal percent parsed'
Assert-Equal '802.11ax' $first.Radio 'radio type parsed'
Assert-Equal (-52) $first.RssiEst 'RSSI estimated from percent'

$hidden = $zh | Where-Object { $_.BSSID -eq '02:11:22:33:44:04' } | Select-Object -First 1
Assert-Equal '' $hidden.SSID 'hidden SSID parsed as empty string'
Assert-Equal 1 $hidden.Channel 'hidden SSID channel parsed'

Assert-Equal ((& $normalize $zh) -join ' >> ') ((& $normalize $en) -join ' >> ') 'zh and en fixtures produce identical results'

Assert-Equal 0 (@(ConvertTo-ScanAps -Lines @()).Count) 'empty netsh output yields no APs'
Assert-Equal 0 (@(ConvertTo-ScanAps -Lines @('乱码', 'no bssid here')).Count) 'garbage input yields no APs'

# ================= 汇总 =================
Write-Host ''
Write-Host ('=== {0} passed, {1} failed ===' -f $script:Passed, $script:Failed) -ForegroundColor $(if ($script:Failed -eq 0) { 'Green' } else { 'Red' })

if ($script:Failed -gt 0) {
    Write-Host 'Failed checks:' -ForegroundColor Red
    $script:Failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}
exit 0
