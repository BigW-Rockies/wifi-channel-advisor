#!/usr/bin/env bash
#
# Get-BestChannel.sh — 为指定 SSID 寻找干扰最小的 Wi-Fi 信道（Linux 版）
#
# 与 Get-BestChannel.ps1 共用同一套干扰模型，两者对同一份扫描数据会给出相同的信道排序：
#   干扰分 = Σ(邻居功率 mW × 频谱重叠度 × 负载系数) / 本机 AP 功率 mW
#
# 依赖：bash 4.4+、awk（mawk / gawk 均可）
# 扫描后端优先级：--csv / --input（离线） > nmcli（免 root） > iw（需 CAP_NET_ADMIN）
#
# 许可证：MIT
#
set -uo pipefail

VERSION='1.0.0'
PROG="${0##*/}"

# ---------------------------------------------------------------------------
# 默认参数
# ---------------------------------------------------------------------------
TARGET_SSID=''
BAND_FILTER=''
CHANNEL_WIDTH=20
NEIGHBOR_WIDTH=20
TOP=5
STAY_THRESHOLD='0.15'
DFS_PENALTY='0.05'
INCLUDE_DFS=0
SCAN_ROUNDS=3
GAP_MS=1500
IFACE=''
INPUT_FILE=''
CSV_FILE=''
QUIET=0

# ---------------------------------------------------------------------------
# 输出小工具
# ---------------------------------------------------------------------------
c_reset=''; c_cyan=''; c_green=''; c_yellow=''; c_red=''; c_gray=''
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    c_reset=$'\033[0m'; c_cyan=$'\033[36m'; c_green=$'\033[32m'
    c_yellow=$'\033[33m'; c_red=$'\033[31m'; c_gray=$'\033[90m'
fi

info()  { printf '%s\n' "$*"; }
cyan()  { printf '%s%s%s\n' "$c_cyan"   "$*" "$c_reset"; }
green() { printf '%s%s%s\n' "$c_green"  "$*" "$c_reset"; }
yellow(){ printf '%s%s%s\n' "$c_yellow" "$*" "$c_reset"; }
red()   { printf '%s%s%s\n' "$c_red"    "$*" "$c_reset"; }
gray()  { [ "$QUIET" -eq 1 ] && return 0; printf '%s%s%s\n' "$c_gray" "$*" "$c_reset"; }

die() { red "错误：$*" >&2; exit 1; }

usage() {
    cat <<EOF
$PROG $VERSION — 为指定 SSID 寻找干扰最小的 Wi-Fi 信道（Linux）

用法:
  $PROG [选项]

目标:
  --ssid NAME            指定要分析的 SSID；缺省取当前接入的 SSID
  --band 2.4|5|6         只看某个波段（多频 SSID 同名时有用）

模型:
  --width N              候选信道带宽，20/40/80/160（默认 20）
  --neighbor-width N     假设邻居 AP 的带宽（默认 20，现代路由器多为 80）
  --top N                展示前 N 个候选信道（默认 5）
  --stay-threshold R     当前信道只差 R 以内就建议别动（默认 0.15）
  --include-dfs          允许推荐 DFS 信道（52-144），默认加 0.05 惩罚
  --dfs-penalty R        DFS 惩罚值（默认 0.05）

扫描:
  --iface NAME           指定无线接口，缺省自动探测
  --scan-rounds N        扫描轮数，多轮合并抗缓存裁剪（默认 3）
  --gap-ms N             轮询间隔毫秒（默认 1500）
  --input FILE           离线分析：nmcli 导出或 iw scan 原始输出
  --csv FILE             离线分析：带表头的扫描 CSV（与仓库 examples/ 同格式）

其它:
  -q, --quiet            不输出说明段
  -h, --help             显示本帮助
  -V, --version          显示版本

示例:
  sudo $PROG                            # 分析当前连接的 SSID
  $PROG --ssid 'Maple'                  # 指定 SSID（走 nmcli，免 root）
  sudo $PROG --ssid 'Maple-5G' --width 80 --neighbor-width 80
  $PROG --ssid 'Maple' --csv examples/scan-sample.csv --top 8

注意:
  WSL2 / 容器 / 普通虚拟机没有无线设备，无法真实扫描；
  这类环境请用 --csv 或 --input 分析离线抓取的结果。
EOF
}

# ---------------------------------------------------------------------------
# 参数解析
# ---------------------------------------------------------------------------
need_val() {
    [ $# -ge 2 ] && [ -n "${2:-}" ] || die "参数 $1 缺少取值"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --ssid)            need_val "$@"; TARGET_SSID="$2"; shift 2 ;;
        --ssid=*)          TARGET_SSID="${1#*=}"; shift ;;
        --band)            need_val "$@"; BAND_FILTER="$2"; shift 2 ;;
        --band=*)          BAND_FILTER="${1#*=}"; shift ;;
        --width)           need_val "$@"; CHANNEL_WIDTH="$2"; shift 2 ;;
        --width=*)         CHANNEL_WIDTH="${1#*=}"; shift ;;
        --neighbor-width)  need_val "$@"; NEIGHBOR_WIDTH="$2"; shift 2 ;;
        --neighbor-width=*) NEIGHBOR_WIDTH="${1#*=}"; shift ;;
        --top)             need_val "$@"; TOP="$2"; shift 2 ;;
        --top=*)           TOP="${1#*=}"; shift ;;
        --stay-threshold)  need_val "$@"; STAY_THRESHOLD="$2"; shift 2 ;;
        --stay-threshold=*) STAY_THRESHOLD="${1#*=}"; shift ;;
        --include-dfs)     INCLUDE_DFS=1; shift ;;
        --dfs-penalty)     need_val "$@"; DFS_PENALTY="$2"; shift 2 ;;
        --dfs-penalty=*)   DFS_PENALTY="${1#*=}"; shift ;;
        --iface)           need_val "$@"; IFACE="$2"; shift 2 ;;
        --iface=*)         IFACE="${1#*=}"; shift ;;
        --scan-rounds)     need_val "$@"; SCAN_ROUNDS="$2"; shift 2 ;;
        --scan-rounds=*)   SCAN_ROUNDS="${1#*=}"; shift ;;
        --gap-ms)          need_val "$@"; GAP_MS="$2"; shift 2 ;;
        --gap-ms=*)        GAP_MS="${1#*=}"; shift ;;
        --input)           need_val "$@"; INPUT_FILE="$2"; shift 2 ;;
        --input=*)         INPUT_FILE="${1#*=}"; shift ;;
        --csv)             need_val "$@"; CSV_FILE="$2"; shift 2 ;;
        --csv=*)           CSV_FILE="${1#*=}"; shift ;;
        -q|--quiet)        QUIET=1; shift ;;
        -h|--help)         usage; exit 0 ;;
        -V|--version)      echo "$PROG $VERSION"; exit 0 ;;
        *)                 die "未知参数：$1（用 --help 查看用法）" ;;
    esac
done

# ---- 参数合法性 ----
case "$CHANNEL_WIDTH" in
    20|40|80|160) ;;
    *) die "--width 只能是 20/40/80/160，收到：$CHANNEL_WIDTH" ;;
esac
case "$NEIGHBOR_WIDTH" in
    20|40|80|160) ;;
    *) die "--neighbor-width 只能是 20/40/80/160，收到：$NEIGHBOR_WIDTH" ;;
esac
case "$TOP" in ''|*[!0-9]*) die "--top 需要正整数";; esac
[ "$TOP" -ge 1 ] || die "--top 需要正整数"
case "$SCAN_ROUNDS" in ''|*[!0-9]*) die "--scan-rounds 需要正整数";; esac
[ "$SCAN_ROUNDS" -ge 1 ] || die "--scan-rounds 需要正整数"
case "$GAP_MS" in ''|*[!0-9]*) die "--gap-ms 需要非负整数";; esac
if [ -n "$BAND_FILTER" ]; then
    case "$BAND_FILTER" in
        2.4|2|24)   BAND_FILTER='2.4' ;;
        5|50)       BAND_FILTER='5' ;;
        6|60)       BAND_FILTER='6' ;;
        *) die "--band 只能是 2.4 / 5 / 6，收到：$BAND_FILTER" ;;
    esac
fi
[ -z "$INPUT_FILE" ] || [ -f "$INPUT_FILE" ] || die "找不到 --input 指定的文件：$INPUT_FILE"
[ -z "$CSV_FILE" ]   || [ -f "$CSV_FILE" ]   || die "找不到 --csv 指定的文件：$CSV_FILE"
[ -z "$CSV_FILE" ]   || [ -z "$INPUT_FILE" ] || die "--csv 与 --input 不能同时使用"

# ---------------------------------------------------------------------------
# 临时目录
# ---------------------------------------------------------------------------
TMPDIR_RUN=$(mktemp -d "${TMPDIR:-/tmp}/gbc.XXXXXX") || die "无法创建临时目录"
# 某些环境（沙箱/受限容器）会拦截 rm -rf，失败也不能影响退出码与输出
cleanup() { [ -n "${TMPDIR_RUN:-}" ] && rm -rf -- "$TMPDIR_RUN" 2>/dev/null || true; }
trap cleanup EXIT INT TERM
RECORDS="$TMPDIR_RUN/records.tsv"
: > "$RECORDS"

# ---------------------------------------------------------------------------
# 内置 awk 评分器（POSIX awk，mawk/gawk 通用）
# ---------------------------------------------------------------------------
AWK_SCORE="$TMPDIR_RUN/score.awk"
cat > "$AWK_SCORE" <<'AWK_EOF'
BEGIN { FS = "\t"; nn = 0; hasOwn = 0 }

$1 == "OWN" {
    ownSsid = $2; ownBssid = $3; band = $4; ownCh = $5 + 0
    ownRssi = $6 + 0; ownSig = $7 + 0; ownRadio = $9
    hasOwn = 1
    next
}

$1 == "NB" {
    nn++
    nbSsid[nn]  = $2
    nbChan[nn]  = $5 + 0
    nbRssi[nn]  = $6 + 0
    nbSig[nn]   = $7 + 0
    nbUtil[nn]  = ($8 == "" ? "" : $8 + 0)
    next
}

function banddisp(b) {
    if (b == "2.4") return "2.4 GHz"
    if (b == "5")   return "5 GHz"
    if (b == "6")   return "6 GHz"
    return b
}

function chan2freq(b, ch) {
    if (b == "2.4") { if (ch == 14) return 2484; return 2412 + 5 * (ch - 1) }
    if (b == "5")   return 5000 + 5 * ch
    if (b == "6")   return 5950 + 5 * ch
    return 0
}

# 宽信道块的中心频率：先把主信道对齐到所属块，再取块中心
function blockcenter(b, ch, w,   f, span, base, blockCh, start, fs) {
    f = chan2freq(b, ch)
    if (f == 0 || w <= 20) return f
    span = int(w / 20); if (span < 1) span = 1
    if (b == "5")      base = (ch >= 149 ? 149 : 36)
    else if (b == "6") base = 1
    else               base = 1
    blockCh = span * 4
    start = base + int((ch - base) / blockCh) * blockCh
    fs = chan2freq(b, start)
    if (fs == 0) return f
    return fs + (span - 1) * 10
}

function is_dfs(b, ch) {
    if (b != "5") return 0
    return ((ch >= 52 && ch <= 64) || (ch >= 100 && ch <= 144)) ? 1 : 0
}

# 两个频谱块的交叠比例，以候选信道带宽归一化
function overlap(fa, wa, fb, wb,   lo, hi) {
    lo = (fa - wa / 2 > fb - wb / 2) ? fa - wa / 2 : fb - wb / 2
    hi = (fa + wa / 2 < fb + wb / 2) ? fa + wa / 2 : fb + wb / 2
    if (hi <= lo) return 0
    return (hi - lo) / wa
}

function fmt(v) {
    if (v <= 0) return "0"
    if (v < 0.001) return "<0.001"
    return sprintf("%.3f", v)
}

function pct(x) { return sprintf("%d%%", int(x * 100 + 0.5)) }

function cadd(c) { NC++; CAND[NC] = c }

# 候选信道：能容纳指定带宽、且落在合法频段内
function gen_candidates(b, w,   i, ch, span, step, m, ok, j, k, good) {
    NC = 0
    if (w < 20) return 0
    span = int(w / 20); if (span < 1) span = 1

    if (b == "2.4") {
        for (ch = 1; ch <= 13; ch++) cadd(ch)
    } else if (b == "5") {
        for (ch = 36; ch <= 64; ch += 4) cadd(ch)
        for (ch = 100; ch <= 144; ch += 4) cadd(ch)
        for (ch = 149; ch <= 165; ch += 4) cadd(ch)
    } else if (b == "6") {
        for (ch = 1; ch <= 233; ch += 4) cadd(ch)
    }
    if (span <= 1) return NC

    for (i = 1; i <= NC; i++) EXIST[CAND[i]] = 1
    m = 0
    for (i = 1; i <= NC; i++) {
        ch = CAND[i]; ok = 1
        for (j = 1; j < span; j++) if (!((ch + 4 * j) in EXIST)) { ok = 0; break }
        if (ok) TMPC[++m] = ch
    }
    for (i in EXIST) delete EXIST[i]

    for (i = 1; i <= m; i++) CAND[i] = TMPC[i]
    NC = m

    # 宽信道要对齐到块边界，不能跨块
    step = span * 4
    k = 0
    for (i = 1; i <= NC; i++) {
        ch = CAND[i]; good = 1
        if (b == "5") {
            if (ch >= 149) { if ((ch - 149) % step != 0) good = 0 }
            else           { if ((ch - 36) % step != 0)  good = 0 }
        } else if (b == "6") {
            if ((ch - 1) % step != 0) good = 0
        }
        if (good) CAND[++k] = ch
    }
    NC = k
    return NC
}

END {
    if (!hasOwn) { print "@ERR@ 缺少 OWN 记录"; exit 1 }

    ownMw = 10 ^ (ownRssi / 10.0)
    if (ownMw <= 0) ownMw = 1e-6

    for (i = 1; i <= nn; i++) {
        mw = 10 ^ (nbRssi[i] / 10.0)
        load = (nbUtil[i] == "") ? 1.0 : 1.0 + nbUtil[i] / 100.0
        nbWt[i] = mw * load
    }

    n = gen_candidates(band, width)
    if (n == 0) { print "@NOCAND@"; exit 0 }

    for (k = 1; k <= n; k++) {
        ch = CAND[k]
        fc = blockcenter(band, ch, width)
        total = 0.0; nh = 0

        for (i = 1; i <= nn; i++) {
            fa = blockcenter(band, nbChan[i], nbw)
            if (fa == 0) continue
            ov = overlap(fc, width, fa, nbw)
            if (ov <= 0) continue
            total += nbWt[i] * ov
            nh++
            hS[nh] = nbSsid[i]; hC[nh] = nbChan[i]; hSig[nh] = nbSig[i]; hOv[nh] = ov
        }

        raw = total / ownMw
        dfs = is_dfs(band, ch)
        if (dfs && !allowDfs) raw += dfsPen

        RCH[k] = ch; RRAW[k] = raw; RDFS[k] = dfs; RHIT[k] = nh

        # 干扰源按重叠度降序拼接，便于判断「到底是谁压着」
        for (a = 2; a <= nh; a++) {
            so = hOv[a]; ss = hS[a]; sc = hC[a]; sg = hSig[a]; b2 = a - 1
            while (b2 >= 1 && hOv[b2] < so) {
                hOv[b2 + 1] = hOv[b2]; hS[b2 + 1] = hS[b2]
                hC[b2 + 1] = hC[b2];   hSig[b2 + 1] = hSig[b2]
                b2--
            }
            hOv[b2 + 1] = so; hS[b2 + 1] = ss; hC[b2 + 1] = sc; hSig[b2 + 1] = sg
        }
        det = ""
        for (a = 1; a <= nh; a++) {
            piece = hS[a] "@ch" hC[a] " " hSig[a] "%"
            det = (det == "") ? piece : det "; " piece
        }
        RDET[k] = det
    }

    # 用未取整的分数排序，避免弱干扰被抹平成一堆 0；同分优先保留当前信道
    for (k = 1; k <= n; k++) ORD[k] = k
    for (a = 2; a <= n; a++) {
        v = ORD[a]; b2 = a - 1
        while (b2 >= 1) {
            p = ORD[b2]
            better = 0
            if (RRAW[v] < RRAW[p]) better = 1
            else if (RRAW[v] == RRAW[p]) {
                if ((RCH[v] == ownCh) && (RCH[p] != ownCh)) better = 1
                else if ((RCH[v] == ownCh) == (RCH[p] == ownCh) && RCH[v] < RCH[p]) better = 1
            }
            if (!better) break
            ORD[b2 + 1] = ORD[b2]; b2--
        }
        ORD[b2 + 1] = v
    }

    curKnown = 0; curRaw = 0
    for (k = 1; k <= n; k++) if (RCH[k] == ownCh) { curKnown = 1; curRaw = RRAW[k]; break }

    best = ORD[1]; bch = RCH[best]; braw = RRAW[best]

    # ---- 候选信道柱状图 ----
    shown = (top < n) ? top : n
    scale = RRAW[ORD[1]]
    for (k = 2; k <= shown; k++) if (RRAW[ORD[k]] > scale) scale = RRAW[ORD[k]]
    if (scale < 0.02) scale = 0.02

    printf "----- 候选信道评分（越低越好，前 %d 名）-----\n", shown
    for (k = 1; k <= shown; k++) {
        idx = ORD[k]; ch = RCH[idx]
        blen = (scale > 0) ? int(RRAW[idx] / scale * 24 + 0.5) : 0
        if (blen > 24) blen = 24
        if (blen < 0) blen = 0
        bar = ""
        for (j = 1; j <= 24; j++) bar = bar ((j <= blen) ? "#" : ".")
        flag = ""
        if (ch == ownCh) flag = "当前"
        if (RDFS[idx])   flag = (flag == "" ? "DFS" : flag ",DFS")
        fstr = (flag == "") ? "" : "  [" flag "]"
        printf "  ch%-4d %s  %8s%s\n", ch, bar, fmt(RRAW[idx]), fstr
    }

    # ---- 结论 ----
    print ""
    print "----- 结论 -----"
    decision = "保持"
    if (bch == ownCh) {
        printf "  保持 ch%d：已是本波段干扰最小的信道（干扰分 %s）。\n", ownCh, fmt(braw)
    } else if (curKnown && curRaw > 0 && (curRaw - braw) / curRaw <= thr) {
        printf "  维持 ch%d：最优 ch%d 只比它好 %s，低于 %s 的切换阈值。\n", \
               ownCh, bch, pct((curRaw - braw) / curRaw), pct(thr)
        decision = "维持"
    } else {
        if (curKnown) {
            gain = (curRaw > 0) ? (curRaw - braw) / curRaw : 1
            gs = (gain >= 0.995) ? ">99%" : pct(gain)
            printf "  建议把 %s 切到 ch%d：干扰分 %s → %s，下降 %s。\n", \
                   banddisp(band), bch, fmt(curRaw), fmt(braw), gs
        } else {
            printf "  建议把 %s 切到 ch%d：干扰分 %s。\n", banddisp(band), bch, fmt(braw)
        }
        if (RHIT[best] == 0)
            print "  该信道在本次扫描中没有任何同频/邻频 AP。"
        else
            printf "  仍有 %d 个 AP 频谱重叠：%s\n", RHIT[best], RDET[best]
        decision = "切换"
    }

    printf "@SUM@\t%s\tch%d\tch%d\t%s\t%s\t%s\n", \
           banddisp(band), ownCh, bch, decision, \
           (curKnown ? fmt(curRaw) : "-"), fmt(braw)
}
AWK_EOF

# ---------------------------------------------------------------------------
# 无线接口探测
# ---------------------------------------------------------------------------
detect_iface() {
    if [ -n "$IFACE" ]; then
        printf '%s\n' "$IFACE"
        return 0
    fi
    local d name
    for d in /sys/class/net/*; do
        [ -e "$d" ] || continue
        if [ -d "$d/wireless" ] || [ -e "$d/phy80211" ]; then
            name="${d##*/}"
            printf '%s\n' "$name"
            return 0
        fi
    done
    return 1
}

# ---------------------------------------------------------------------------
# 记录写入：ssid bssid band chan rssi signal util radio
# ---------------------------------------------------------------------------
emit() {
    # emit <ssid> <bssid> <band> <chan> <rssi> <signal> <util> <radio>
    printf 'NB\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$1" "$2" "$3" "$4" "$5" "$6" "$7" "${8:-}"
}

band_of_freq() {
    local f=$1
    if   [ "$f" -lt 3000 ]; then printf '2.4'
    elif [ "$f" -lt 5925 ]; then printf '5'
    else                         printf '6'
    fi
}

chan_of_freq() {
    local band=$1 f=$2
    case "$band" in
        2.4) [ "$f" -eq 2484 ] && { printf '14'; return; }; printf '%d' $(( (f - 2412) / 5 + 1 )) ;;
        5)   printf '%d' $(( (f - 5000) / 5 )) ;;
        6)   printf '%d' $(( (f - 5950) / 5 )) ;;
        *)   printf '0' ;;
    esac
}

# ---------------------------------------------------------------------------
# 后端 1：CSV（与 examples/scan-sample.csv 同格式）
# ---------------------------------------------------------------------------
load_csv() {
    local f="$1"
    awk -F',' '
        function trim(s) { gsub(/^[ \t\r"]+/, "", s); gsub(/[ \t\r"]+$/, "", s); return s }
        function bandcode(s) {
            s = trim(s)
            if (s ~ /^2\.4/) return "2.4"
            if (s ~ /^5/)    return "5"
            if (s ~ /^6/)    return "6"
            return ""
        }
        # 表头：SSID,BSSID,Band,Channel,Radio,Signal,RssiEst,ChanUtil
        NR == 1 { next }
        {
            ssid = trim($1); bssid = trim($2); band = bandcode($3)
            chan = trim($4) + 0
            radio = trim($5)
            sig = trim($6) + 0
            rssi = trim($7)
            util = trim($8)
            if (band == "" || chan <= 0) next
            if (rssi == "") rssi = int(sig / 2 + 0.5) - 100
            printf "NB\t%s\t%s\t%s\t%d\t%d\t%d\t%s\t%s\n", ssid, bssid, band, chan, rssi, sig, util, radio
        }
    ' "$f"
}

# ---------------------------------------------------------------------------
# 后端 2：nmcli / iw 的原始输出（离线）
# ---------------------------------------------------------------------------
load_input() {
    local f="$1"
    if grep -q '^BSS ' "$f" 2>/dev/null; then
        parse_iw < "$f"
    else
        parse_nmcli < "$f"
    fi
}

# nmcli 的 -t 输出：字段用 : 分隔，值内的 : 被转义成 \:
parse_nmcli() {
    local line rest ssid bssid chan freq sig band rssi util radio
    local sep=$'\001'
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        case "$line" in '#'*) continue ;; esac
        line="${line//\\:/$sep}"
        # 第一列是 IN-USE 标记，解析周边 AP 时用不上
        IFS=':' read -r _ ssid bssid chan freq sig rest <<< "$line"
        ssid="${ssid//$sep/:}"; bssid="${bssid//$sep/:}"
        freq="${freq//[!0-9]/}"; sig="${sig//[!0-9]/}"
        [ -n "$freq" ] && [ -n "$sig" ] || continue
        band=$(band_of_freq "$freq")
        [ -n "$chan" ] || chan=$(chan_of_freq "$band" "$freq")
        rssi=$(awk -v s="$sig" 'BEGIN { printf "%d", int(s/2+0.5) - 100 }')
        util=''
        radio=''
        emit "$ssid" "$bssid" "$band" "$chan" "$rssi" "$sig" "$util" "$radio"
    done
}

# iw dev <if> scan 的原始输出：能拿到真实 dBm 和 BSS Load
parse_iw() {
    awk '
        function flush() {
            if (bssid == "" || freq <= 0) return
            band = (freq < 3000) ? "2.4" : (freq < 5925 ? "5" : "6")
            if (dschan > 0) chan = dschan
            else if (band == "2.4") chan = (freq == 2484) ? 14 : int((freq - 2412) / 5 + 1)
            else if (band == "5")  chan = int((freq - 5000) / 5)
            else                   chan = int((freq - 5950) / 5)
            sig = 2 * (rssi + 100)
            if (sig < 1) sig = 1
            if (sig > 100) sig = 100
            printf "NB\t%s\t%s\t%s\t%d\t%d\t%d\t%s\t%s\n", ssid, bssid, band, chan, rssi, sig, util, ""
        }
        /^BSS / {
            flush()
            bssid = $2; sub(/\(.*/, "", bssid)
            freq = 0; rssi = 0; ssid = ""; util = ""; dschan = 0
            next
        }
        /^[ \t]*freq:[ \t]*[0-9]/ {
            v = $0; sub(/.*freq:[ \t]*/, "", v); sub(/[ \t].*/, "", v); freq = v + 0; next
        }
        /^[ \t]*signal:[ \t]*-?[0-9]/ {
            v = $0; sub(/.*signal:[ \t]*/, "", v); sub(/[ \t].*/, "", v); rssi = int(v + 0); next
        }
        /^[ \t]*SSID:/ {
            v = $0; sub(/^[ \t]*SSID:[ \t]*/, "", v); sub(/[ \t\r]+$/, "", v); ssid = v; next
        }
        /DS Parameter set: channel/ {
            v = $0; sub(/.*channel[ \t]*/, "", v); dschan = v + 0; next
        }
        /channel utilis|channel utili[sz]ation/ {
            v = $0
            if (match(v, /[0-9]+\/[0-9]+/)) {
                piece = substr(v, RSTART, RLENGTH)
                split(piece, a, "/")
                if (a[2] + 0 > 0) util = int(a[1] * 100 / a[2] + 0.5)
            }
            next
        }
        END { flush() }
    '
}

# ---------------------------------------------------------------------------
# 后端 3：nmcli 实时扫描（免 root）
# ---------------------------------------------------------------------------
nmcli_ready() {
    command -v nmcli >/dev/null 2>&1 || return 1
    nmcli -t -f DEVICE,TYPE device status 2>/dev/null | grep -q ':wifi$' || return 1
    return 0
}

scan_nmcli() {
    local raw='' mode
    for mode in yes auto; do
        raw=$(nmcli -t -f IN-USE,SSID,BSSID,CHAN,FREQ,SIGNAL dev wifi list --rescan "$mode" 2>/dev/null) && [ -n "$raw" ] && break
        raw=''
    done
    [ -n "$raw" ] || return 1
    printf '%s\n' "$raw" | parse_nmcli
}

# ---------------------------------------------------------------------------
# 后端 4：iw 实时扫描（需 CAP_NET_ADMIN）
# ---------------------------------------------------------------------------
scan_iw() {
    local ifc="$1"
    command -v iw >/dev/null 2>&1 || return 1
    local out
    if ! out=$(iw dev "$ifc" scan 2>&1); then
        case "$out" in
            *"Operation not permitted"*|*"Permission denied"*)
                gray "  iw 扫描需要 root 权限，已跳过（可用 sudo 重跑）" ;;
            *) gray "  iw 扫描失败：$(printf '%s' "$out" | head -1)" ;;
        esac
        return 1
    fi
    [ -n "$out" ] || return 1
    printf '%s\n' "$out" | parse_iw
}

# ---------------------------------------------------------------------------
# 当前连接（用于推断目标 SSID 与真实 dBm）
# ---------------------------------------------------------------------------
CUR_SSID=''; CUR_BSSID=''; CUR_RSSI=''; CUR_SIGNAL=''; CUR_BAND=''; CUR_CHAN=''

current_from_nmcli() {
    local raw line rest ssid bssid chan freq sig sep=$'\001'
    raw=$(nmcli -t -f IN-USE,SSID,BSSID,CHAN,FREQ,SIGNAL dev wifi list 2>/dev/null) || return 1
    while IFS= read -r line; do
        case "$line" in
            '*:'*) ;;
            *) continue ;;
        esac
        line="${line//\\:/$sep}"
        # 第一列是 IN-USE 标记，已由上面的 case 判定过，这里丢弃
        IFS=':' read -r _ ssid bssid chan freq sig rest <<< "$line"
        ssid="${ssid//$sep/:}"; bssid="${bssid//$sep/:}"
        freq="${freq//[!0-9]/}"
        [ -n "$freq" ] || continue
        CUR_SSID="$ssid"; CUR_BSSID="$bssid"; CUR_BAND=$(band_of_freq "$freq")
        CUR_CHAN="${chan:-$(chan_of_freq "$CUR_BAND" "$freq")}"
        CUR_SIGNAL="${sig//[!0-9]/}"
        CUR_RSSI=$(awk -v s="$CUR_SIGNAL" 'BEGIN { printf "%d", int(s/2+0.5) - 100 }')
        return 0
    done <<< "$raw"
    return 1
}

current_from_iw() {
    local ifc="$1" link
    command -v iw >/dev/null 2>&1 || return 1
    link=$(iw dev "$ifc" link 2>/dev/null) || return 1
    case "$link" in
        *"Not connected"*) return 1 ;;
    esac
    CUR_SSID=$(printf '%s\n' "$link" | sed -n 's/^[[:space:]]*SSID:[[:space:]]*//p' | head -1)
    CUR_BSSID=$(printf '%s\n' "$link" | sed -n 's/^Connected to \([0-9a-fA-F:]\{17\}\).*/\1/p' | head -1)
    local freq rssi
    freq=$(printf '%s\n' "$link" | sed -n 's/^[[:space:]]*freq:[[:space:]]*\([0-9]*\).*/\1/p' | head -1)
    rssi=$(printf '%s\n' "$link" | sed -n 's/^[[:space:]]*signal:[[:space:]]*\(-\{0,1\}[0-9]*\).*/\1/p' | head -1)
    [ -n "$freq" ] || return 1
    CUR_BAND=$(band_of_freq "$freq")
    CUR_CHAN=$(chan_of_freq "$CUR_BAND" "$freq")
    CUR_RSSI="${rssi:-0}"
    CUR_SIGNAL=$(awk -v r="$CUR_RSSI" 'BEGIN { s = 2*(r+100); if (s<1) s=1; if (s>100) s=100; printf "%d", s }')
    return 0
}

# ---------------------------------------------------------------------------
# 采集
# ---------------------------------------------------------------------------
SOURCE=''
IFC=''

collect() {
    if [ -n "$CSV_FILE" ]; then
        SOURCE="CSV ($CSV_FILE)"
        load_csv "$CSV_FILE" >> "$TMPDIR_RUN/raw.tsv" || die "解析 CSV 失败"
        return 0
    fi

    if [ -n "$INPUT_FILE" ]; then
        SOURCE="离线抓取 ($INPUT_FILE)"
        load_input "$INPUT_FILE" > "$TMPDIR_RUN/raw.tsv" || die "解析 --input 失败"
        return 0
    fi

    local ifc=''
    if ifc=$(detect_iface); then IFC="$ifc"; fi

    local got=0 r
    if nmcli_ready; then
        SOURCE="nmcli${IFC:+ ($IFC)}"
        current_from_nmcli >/dev/null 2>&1 || true
        for ((r = 0; r < SCAN_ROUNDS; r++)); do
            scan_nmcli >> "$TMPDIR_RUN/raw.tsv" 2>/dev/null && got=1
            [ "$r" -lt $((SCAN_ROUNDS - 1)) ] && sleep "$(awk -v ms="$GAP_MS" 'BEGIN{printf "%.3f", ms/1000}')"
        done
    elif [ -n "$IFC" ] && command -v iw >/dev/null 2>&1; then
        SOURCE="iw ($IFC)"
        current_from_iw "$IFC" >/dev/null 2>&1 || true
        for ((r = 0; r < SCAN_ROUNDS; r++)); do
            scan_iw "$IFC" >> "$TMPDIR_RUN/raw.tsv" 2>/dev/null && got=1
            [ "$r" -lt $((SCAN_ROUNDS - 1)) ] && sleep "$(awk -v ms="$GAP_MS" 'BEGIN{printf "%.3f", ms/1000}')"
        done
    fi

    if [ "$got" -eq 0 ]; then
        [ -s "$TMPDIR_RUN/raw.tsv" ] || {
            red "错误：没有拿到任何扫描结果。"
            echo
            if [ -z "$IFC" ]; then
                echo "  未检测到无线接口。常见原因："
                echo "    · 正在 WSL2 / 容器 / 虚拟机里运行 —— 这类环境没有无线设备，物理上无法扫描"
                echo "    · 无线网卡驱动未加载（试试 ls /sys/class/net、rfkill list）"
                echo
                echo "  可行的替代做法："
                echo "    · 用 --csv examples/scan-sample.csv 验证分析逻辑"
                echo "    · 在真机 Linux 上抓一份 iw/nmcli 输出，再用 --input 分析"
            else
                echo "  检测到接口 $IFC，但没有扫描到任何 AP。"
                echo "    · iw 后端需要 root：sudo $PROG ..."
                echo "    · NetworkManager 未运行时 nmcli 不可用，可加 sudo 走 iw"
            fi
            exit 1
        }
    fi
}

# ---------------------------------------------------------------------------
# 合并去重：同一 BSSID 保留信号更强的一次
# ---------------------------------------------------------------------------
dedupe() {
    awk -F'\t' '
        {
            b = $3
            if (!(b in best) || $7 + 0 > best[b]) { best[b] = $7 + 0; line[b] = $0 }
        }
        END { for (b in line) print line[b] }
    ' | sort -t $'\t' -k2,2 -k3,3
}

# ---------------------------------------------------------------------------
# 输出辅助
# ---------------------------------------------------------------------------
banddisp() {
    case "$1" in
        2.4) printf '2.4 GHz' ;;
        5)   printf '5 GHz' ;;
        6)   printf '6 GHz' ;;
        *)   printf '%s' "$1" ;;
    esac
}

print_neighbors() {
    local band="$1" target="$2"
    awk -F'\t' -v band="$band" -v target="$target" '
        $1 != "NB" { next }
        $4 != band { next }
        $2 == target { next }
        {
            n++
            ssid[n] = $2; bssid[n] = $3; chan[n] = $5
            sig[n] = $7; rssi[n] = $6; util[n] = ($8 == "" ? "-" : $8)
        }
        END {
            printf "----- 同波段邻居（%d 个）-----\n", n
            if (n == 0) { print "  未发现同波段的其他 AP。"; exit }
            printf "  %-22s %-18s %5s %7s %7s %6s\n", "SSID", "BSSID", "Chan", "Signal", "dBm", "Util"
            for (i = 1; i <= n; i++) {
                s = ssid[i]; if (s == "") s = "(hidden)"
                printf "  %-22s %-18s %5d %6d%% %7d %6s\n", s, bssid[i], chan[i], sig[i], rssi[i], util[i]
            }
        }
    ' "$TMPDIR_RUN/records.tsv"
}

# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------
collect
dedupe < "$TMPDIR_RUN/raw.tsv" > "$RECORDS"

total_bssid=$(awk -F'\t' '$1=="NB"' "$RECORDS" | wc -l | tr -d ' ')
total_ssid=$(awk -F'\t' '$1=="NB" { print $2 }' "$RECORDS" | sort -u | wc -l | tr -d ' ')

if [ "$total_bssid" -eq 0 ]; then
    red "错误：扫描结果里没有任何 AP。"
    exit 1
fi

# ---- 1. 确定目标 SSID ----
SSID_FROM='命令行 --ssid 指定'
TARGET="${TARGET_SSID:-}"
if [ -z "$TARGET" ]; then
    if [ -n "$CUR_SSID" ]; then
        TARGET="$CUR_SSID"
        SSID_FROM='默认取当前接入的 SSID'
    else
        red "警告：当前没有无线连接，无法推断目标 SSID，请用 --ssid 指定要分析的网络名。"
        exit 2
    fi
fi

echo
cyan "目标 SSID : $TARGET   （$SSID_FROM）"
gray      "数据来源  : $SOURCE"
if [ -n "$CUR_SSID" ] && [ -n "$CUR_BAND" ]; then
    gray "当前连接  : $CUR_SSID @ $(banddisp "$CUR_BAND") ch${CUR_CHAN:-?}   ${CUR_RSSI} dBm"
fi

# ---- 2. 定位目标 SSID 的所有 BSSID ----
if ! awk -F'\t' -v t="$TARGET" '$1=="NB" && $2==t {found=1} END{exit !found}' "$RECORDS"; then
    echo
    red "警告：当前环境未扫描到SSID: $TARGET, 请输入正确的SSID，或重试。"
    gray "      本次扫描返回 $total_bssid 个 BSSID / $total_ssid 个 SSID。"
    gray "      若确认该网络就在附近，可加 --scan-rounds 5 或手动触发一次扫描后重试。"
    exit 2
fi

# ---- 3. 选定要分析的波段 ----
bands=$(awk -F'\t' -v t="$TARGET" -v f="$BAND_FILTER" \
        '$1=="NB" && $2==t && (f=="" || $4==f) { print $4 }' "$RECORDS" | sort -u)

if [ -z "$bands" ]; then
    echo
    red "警告：SSID $TARGET 未在 ${BAND_FILTER} GHz 波段扫描到。"
    exit 2
fi

nBands=$(printf '%s\n' "$bands" | wc -l | tr -d ' ')
idx=0
stale=0
SUMMARY="$TMPDIR_RUN/summary.tsv"
: > "$SUMMARY"

for band in $bands; do
    idx=$((idx + 1))

    # 参考 AP：优先当前连接的那个 BSSID，否则取信号最强者
    ref=$(awk -F'\t' -v t="$TARGET" -v b="$band" -v cb="$CUR_BSSID" '
        $1=="NB" && $2==t && $4==b {
            if (cb != "" && $3==cb) { pref = $0; prefhit = 1; }
            if (!seen || $7+0 > bestsig) { seen=1; bestsig=$7+0; fallback=$0 }
        }
        END { if (prefhit) print pref; else if (seen) print fallback }
    ' "$RECORDS")

    ref_bssid=$(printf '%s' "$ref"  | cut -f3)
    ref_chan=$(printf '%s'  "$ref"  | cut -f5)
    ref_rssi=$(printf '%s'  "$ref"  | cut -f6)
    ref_sig=$(printf '%s'   "$ref"  | cut -f7)
    ref_radio=$(printf '%s' "$ref"  | cut -f9)

    # 已连接的那个用真实 dBm（iw 后端能拿到）
    if [ -n "$CUR_BSSID" ] && [ "$ref_bssid" = "$CUR_BSSID" ] && [ -n "$CUR_RSSI" ]; then
        ref_rssi="$CUR_RSSI"
        [ -n "$CUR_SIGNAL" ] && ref_sig="$CUR_SIGNAL"
    fi

    {
        printf 'OWN\t%s\t%s\t%s\t%s\t%s\t%s\t\t%s\n' \
            "$TARGET" "$ref_bssid" "$band" "$ref_chan" "$ref_rssi" "$ref_sig" "${ref_radio:-}"
        # 排除同一 SSID 的其它 BSSID：mesh / 双频同名属于同一网络，不能互相当干扰
        awk -F'\t' -v b="$band" -v t="$TARGET" '$1=="NB" && $4==b && $2!=t' "$RECORDS"
    } > "$TMPDIR_RUN/band.tsv"

    nbs=$(awk -F'\t' -v t="$TARGET" -v b="$band" '$1=="NB" && $4==b && $2!=t' "$RECORDS" | wc -l | tr -d ' ')

    echo
    cyan "========== [$idx/$nBands] $TARGET @ $(banddisp "$band") =========="
    echo "  参考 AP   : $ref_bssid"
    echo "  当前信道  : ch$ref_chan   协议 ${ref_radio:--}   信号 ${ref_sig}% (${ref_rssi} dBm)"
    echo "  分析带宽  : $CHANNEL_WIDTH MHz   (邻居按 $NEIGHBOR_WIDTH MHz 计)"
    echo
    print_neighbors "$band" "$TARGET"
    echo

    out=$(awk -v width="$CHANNEL_WIDTH" -v nbw="$NEIGHBOR_WIDTH" -v top="$TOP" \
              -v thr="$STAY_THRESHOLD" -v dfsPen="$DFS_PENALTY" -v allowDfs="$INCLUDE_DFS" \
              -f "$AWK_SCORE" "$TMPDIR_RUN/band.tsv")

    case "$out" in
        '@NOCAND@'*)
            yellow "  没有可用的候选信道（$(banddisp "$band")，$CHANNEL_WIDTH MHz）。"
            printf '%s\t%s\t-\t-\t%s\t%s\t%s\n' "$(banddisp "$band")" "ch$ref_chan" "无候选" "-" "-" >> "$SUMMARY"
            continue
            ;;
        '@ERR@'*)
            red "  内部错误：$(printf '%s' "$out" | sed 's/^@ERR@ //')"
            continue
            ;;
    esac

    printf '%s\n' "$out" | grep -v '^@SUM@'

    sum=$(printf '%s\n' "$out" | grep '^@SUM@' | head -1)
    [ -n "$sum" ] && printf '%s\n' "$sum" | cut -f2- >> "$SUMMARY"

    # 同波段无邻居、但别的波段有 AP → 疑似扫描缓存陈旧（netsh 时代的坑，Linux 上同样会遇到）
    if [ "$nbs" -eq 0 ] && [ "$total_bssid" -gt 0 ]; then
        stale=$((stale + 1))
        yellow "  注意：同波段无邻居但其它波段有 AP，本次扫描可能不完整，建议重扫后再定。"
    fi
done

# ---- 4. 汇总 ----
if [ -s "$SUMMARY" ]; then
    echo
    green '========== 汇总 =========='
    awk -F'\t' '{ printf "  %-8s 当前 %-6s → 建议 %-6s [%s]   干扰分 %s → %s\n", $1, $2, $3, $4, $5, $6 }' "$SUMMARY"
fi

# ---- 5. 说明 ----
if [ "$QUIET" -eq 0 ]; then
    echo
    gray '========== 说明 =========='
    gray '  · 干扰分 = Σ(邻居功率×频谱重叠度×负载)/本机功率，1.0 ≈ 干扰与自身信号等强'
    gray '  · 多频 SSID 会按波段分别给建议；同一 SSID 的其它 BSSID 不计入干扰'
    gray '  · iw 后端读到的是真实 dBm；nmcli 只给百分比，按 quality/2-100 估算（强信号端偏差可达 10dB）'
    gray '  · 信道利用率（BSS Load）只有 iw 在网卡支持时才提供，nmcli 一律为 -'
    gray '  · 信道可用性受地区法规与固件限制，最终以路由器可选列表为准'
    if [ "$CHANNEL_WIDTH" -eq 20 ]; then
        gray '  · 邻居多为 80MHz 时，建议加 --width 80 --neighbor-width 80 复核'
    fi
    if [ "$stale" -gt 0 ]; then
        gray '  · 检测到部分波段扫描不完整，结论仅供参考'
    fi
fi
