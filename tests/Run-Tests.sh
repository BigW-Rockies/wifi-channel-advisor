#!/usr/bin/env bash
#
# Run-Tests.sh — Get-BestChannel.sh 的离线回归测试
#
# 全部基于 tests/fixtures 下的静态样本，不接触网卡，可在 CI 与 WSL 里直接跑。
# 用法： bash tests/Run-Tests.sh
#
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
SCRIPT="$ROOT/Get-BestChannel.sh"
FIX="$HERE/fixtures"
CSV_24="$ROOT/examples/scan-sample.csv"
CSV_MB="$FIX/scan-multiband.csv"
NMCLI_TXT="$FIX/nmcli-scan.txt"
IW_TXT="$FIX/iw-scan.txt"

pass=0; fail=0; OUT=''; RC=0

ok()   { pass=$((pass + 1)); printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
no()   { fail=$((fail + 1)); printf '  \033[31mFAIL\033[0m  %s\n' "$1"; printf '        %s\n' "${2:-}"; }
has()  { case "$2" in *"$3"*) ok "$1" ;; *) no "$1" "输出里找不到：[$3]" ;; esac; }
hasnt(){ case "$2" in *"$3"*) no "$1" "输出里不该出现：[$3]" ;; *) ok "$1" ;; esac; }
eq()   { if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "期望 [$3]，实际 [$2]"; fi; }
run()  { OUT=$(bash "$SCRIPT" "$@" 2>&1); RC=$?; }
# 只取候选信道那一节的信道号，按出现顺序
cands(){ printf '%s\n' "$1" | sed -n '/候选信道评分/,/结论/p' | grep -oE 'ch[0-9]+' | sed 's/ch//' | tr '\n' ' ' | sed 's/ $//'; }
# 同上，但按数值排序，用于比对候选集合而不是展示顺序
candset(){ printf '%s\n' "$1" | sed -n '/候选信道评分/,/结论/p' | grep -oE 'ch[0-9]+' | sed 's/ch//' | sort -n | tr '\n' ' ' | sed 's/ $//'; }

printf '\n\033[36m=== Get-BestChannel.sh 离线回归测试 ===\033[0m\n'

# ---------------------------------------------------------------------------
printf '\n\033[36m--- 1. 脚本本体 ---\033[0m\n'

if [ -f "$SCRIPT" ]; then ok '脚本存在'; else no '脚本存在'; fi
if bash -n "$SCRIPT" 2>/dev/null; then ok 'bash 语法检查通过'; else no 'bash 语法检查通过'; fi

run --help
eq '--help 退出码为 0' "$RC" '0'
has '--help 提到 --ssid' "$OUT" '--ssid'
has '--help 提到 --csv' "$OUT" '--csv'

run --version
eq '--version 退出码为 0' "$RC" '0'
has '--version 含版本号' "$OUT" '1.0.0'

# ---------------------------------------------------------------------------
printf '\n\033[36m--- 2. CSV 单波段（examples/scan-sample.csv）---\033[0m\n'

run --ssid Maple --csv "$CSV_24"
eq '  CSV 分析退出码为 0' "$RC" '0'
has '  目标 SSID 正确' "$OUT" '目标 SSID : Maple'
has '  当前信道 ch6 / -52 dBm' "$OUT" '当前信道  : ch6'
has '  推荐 ch13' "$OUT" '建议把 2.4 GHz 切到 ch13'
has '  当前信道干扰分 0.037' "$OUT" '干扰分 0.037 → 0.006'
has '  降幅 83%' "$OUT" '下降 83%'
has '  邻居计数为 11' "$OUT" '同波段邻居（11 个）'
hasnt '  邻居表里不含目标 SSID 自己' "$OUT" '  Maple  '

run --ssid Maple --csv "$CSV_24" --top 3
eq '  --top 3 只显示 3 行' "$(printf '%s\n' "$OUT" | sed -n '/候选信道评分/,/结论/p' | grep -c '^  ch')" '3'

run --ssid Maple --csv "$CSV_24" --band 2.4
eq '  --band 2.4 正常' "$RC" '0'
has '  --band 2.4 命中 2.4 GHz 段' "$OUT" 'Maple @ 2.4 GHz'

# ---------------------------------------------------------------------------
printf '\n\033[36m--- 3. 多频 SSID 按波段分组 ---\033[0m\n'

run --ssid Maple --csv "$CSV_MB"
eq '  多波段分析退出码为 0' "$RC" '0'
has '  第 1 段是 2.4 GHz' "$OUT" '[1/2] Maple @ 2.4 GHz'
has '  第 2 段是 5 GHz' "$OUT" '[2/2] Maple @ 5 GHz'
has '  2.4 GHz 推荐 ch13' "$OUT" '建议把 2.4 GHz 切到 ch13'
has '  5 GHz 推荐 ch40' "$OUT" '建议把 5 GHz 切到 ch40'
has '  5 GHz 当前分 0.158' "$OUT" '干扰分 0.158 → 0'
eq '  汇总表有 2 行' "$(printf '%s\n' "$OUT" | grep -c '→ 建议')" '2'
has '  汇总含 5 GHz 行' "$OUT" '5 GHz    当前 ch36'

run --ssid Maple --csv "$CSV_MB" --band 5
eq '  --band 5 只有 1 段' "$(printf '%s\n' "$OUT" | grep -c '========== \[')" '1'
has '  --band 5 命中 5 GHz 段' "$OUT" '[1/1] Maple @ 5 GHz'
hasnt '  --band 5 不输出 2.4 GHz 段' "$OUT" 'Maple @ 2.4 GHz'

# ---------------------------------------------------------------------------
printf '\n\033[36m--- 4. 两个后端对同一份数据应给出一致结论 ---\033[0m\n'

run --ssid Maple --input "$NMCLI_TXT"
eq '  nmcli 夹具退出码为 0' "$RC" '0'
has '  nmcli 自动识别为离线抓取' "$OUT" '数据来源  : 离线抓取'
has '  nmcli 2.4 GHz 推荐 ch13' "$OUT" '建议把 2.4 GHz 切到 ch13'
has '  nmcli 5 GHz 推荐 ch40' "$OUT" '建议把 5 GHz 切到 ch40'
has '  nmcli 无 BSS Load，负载系数为 1（0.030）' "$OUT" '干扰分 0.030 → 0.006'

run --ssid Maple --input "$IW_TXT"
eq '  iw 夹具退出码为 0' "$RC" '0'
has '  iw 2.4 GHz 推荐 ch13' "$OUT" '建议把 2.4 GHz 切到 ch13'
has '  iw 5 GHz 推荐 ch40' "$OUT" '建议把 5 GHz 切到 ch40'
has '  iw 读到了 BSS Load（0.037）' "$OUT" '干扰分 0.037 → 0.006'
eq '  iw 与 CSV 的信道结论一致' "$(cands "$OUT")" "$(run --ssid Maple --csv "$CSV_MB"; cands "$OUT")"

# ---------------------------------------------------------------------------
printf '\n\033[36m--- 5. 宽信道对齐 ---\033[0m\n'

run --ssid Maple --csv "$CSV_MB" --band 5 --width 80 --top 20
eq '  80MHz 候选只落在块边界' "$(candset "$OUT")" '36 52 100 116 132 149'

run --ssid Maple --csv "$CSV_MB" --band 5 --width 80 --neighbor-width 80
has '  80MHz 邻居下改推 ch149' "$OUT" '建议把 5 GHz 切到 ch149'

run --ssid Maple --csv "$CSV_MB" --band 5 --width 40 --top 20
eq '  40MHz 候选集合正确' "$(candset "$OUT")" '36 44 52 60 100 108 116 124 132 140 149 157'

# ---------------------------------------------------------------------------
printf '\n\033[36m--- 6. DFS 惩罚 ---\033[0m\n'

run --ssid Maple --csv "$CSV_MB" --band 5 --top 12
has '  默认给 DFS 信道加 0.05' "$OUT" '0.050  [DFS]'
run --ssid Maple --csv "$CSV_MB" --band 5 --top 12 --include-dfs
has '  --include-dfs 后 DFS 惩罚归零' "$OUT" '     0  [DFS]'

run --ssid Maple --csv "$CSV_MB" --band 5 --top 12 --dfs-penalty 0.5
has '  --dfs-penalty 可调' "$OUT" '0.500  [DFS]'

# ---------------------------------------------------------------------------
printf '\n\033[36m--- 7. 错误处理 ---\033[0m\n'

run --ssid 'NoSuchWiFi-9527' --csv "$CSV_MB"
eq '  未扫到的 SSID 退出码为 2' "$RC" '2'
has '  输出约定的警告原文' "$OUT" '警告：当前环境未扫描到SSID: NoSuchWiFi-9527, 请输入正确的SSID，或重试。'
has '  附带本次扫描规模' "$OUT" '本次扫描返回 17 个 BSSID'

run --csv "$CSV_MB"
eq '  离线且未给 --ssid 时退出码为 2' "$RC" '2'
has '  提示无法推断 SSID' "$OUT" '当前没有无线连接'

run --width 30 --csv "$CSV_MB"
eq '  非法带宽退出码为 1' "$RC" '1'
has '  非法带宽报错' "$OUT" '--width 只能是 20/40/80/160'

run --band 9 --csv "$CSV_MB"
eq '  非法波段退出码为 1' "$RC" '1'

run --bogus-option
eq '  未知参数退出码为 1' "$RC" '1'
has '  未知参数给出提示' "$OUT" '未知参数'

run --csv "$FIX/does-not-exist.csv"
eq '  文件不存在退出码为 1' "$RC" '1'

run --csv "$CSV_MB" --input "$IW_TXT"
eq '  --csv 与 --input 互斥' "$RC" '1'

# ---------------------------------------------------------------------------
printf '\n\033[36m--- 8. 无网卡环境的提示 ---\033[0m\n'

if [ -z "$(ls -d /sys/class/net/*/wireless 2>/dev/null)" ] && ! command -v nmcli >/dev/null 2>&1; then
    run --ssid Maple
    has '  无无线设备时提示 WSL/容器限制' "$OUT" 'WSL2'
    has '  建议改用离线样本' "$OUT" '--csv'
else
    printf '  \033[33mSKIP\033[0m  本机有无线设备，跳过「无网卡」提示测试\n'
fi

# ---------------------------------------------------------------------------
printf '\n\033[36m=== 结果：%d passed, %d failed ===\033[0m\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
