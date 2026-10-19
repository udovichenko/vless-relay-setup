#!/usr/bin/env bash
# netprobe — диагностика блокировок на участке сети до VLESS-сервера.
#
# Запускается где угодно (ноутбук пользователя, relay, новая VDS) и проверяет
# один участок «отсюда → сервер» по слоям: базовая сеть → IP → TLS → объём →
# сам протокол VLESS/Reality. Первый проваленный слой подсказывает, что именно
# режут. Отчёт пишется в локальные файлы (txt + json), никуда не отправляется.
#
# Совместим с bash 3.2 (macOS) и Linux. Зависимости: curl, openssl, perl.
# Xray скачивается автоматически (с проверкой sha256) в ~/.cache/netprobe.
#
# Usage:
#   netprobe.sh 'vless://...'                   # проверить ссылку (VPN выключить!)
#   netprobe.sh --from-relay                    # на relay: участок relay → exit
#   netprobe.sh --host 203.0.113.10 --sni a.b   # без ключей: только слои 0–3

set -o pipefail

NETPROBE_VERSION="0.1.0"
XRAY_VERSION="26.3.27"

N_HANDSHAKES=30
LONG_TEST=0
MODE=""
LINK=""
TARGET_HOST=""
TARGET_PORT=443
TARGET_SNI=""
XRAY_BIN="${XRAY_BIN:-}"
OUT_DIR="."

usage() {
    cat <<'EOF'
netprobe — проверка блокировок на участке сети до VLESS-сервера

Использование:
  netprobe.sh 'vless://...'              проверить подключение по ссылке
  netprobe.sh --from-relay               на relay-сервере: участок relay → exit
  netprobe.sh --host IP[:PORT] [--sni ДОМЕН]
                                         без ключей: только IP/TLS/объём (слои 0–3),
                                         удобно для проверки новой VDS

Опции:
  -n N          число тестовых подключений в слое 4 (по умолчанию 30)
  --long        добавить тест долгого соединения (~2 мин)
  --xray PATH   использовать указанный бинарник xray вместо скачивания
  --out DIR     куда сохранить отчёт (по умолчанию текущая папка)
  -h, --help    эта справка

Перед запуском с компьютера ВЫКЛЮЧИТЕ VPN, иначе проверяется не ваш провайдер.
Ссылку берите в одинарные кавычки: в ней есть символы & и #.
EOF
}

# --- output -----------------------------------------------------------------

if [ -t 1 ]; then
    C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'; C_BLD=$'\033[1m'; C_DIM=$'\033[2m'; C_RST=$'\033[0m'
else
    C_RED=""; C_GRN=""; C_YEL=""; C_BLD=""; C_DIM=""; C_RST=""
fi

TXT=""
JSON_BODY=""
VERDICTS=()
VERDICT_LEVELS=()

# out COLOR TEXT — печать в терминал (с цветом) и в txt-отчёт (без цвета)
out() {
    local color="$1" text="$2"
    printf '%s%s%s\n' "$color" "$text" "$C_RST"
    [ -n "$TXT" ] && printf '%s\n' "$text" >> "$TXT"
    return 0
}
section() { out "$C_BLD" ""; out "$C_BLD" "== $1"; }
info()    { out "" "   $1"; }
ok()      { out "$C_GRN" "   [OK] $1"; }
warn()    { out "$C_YEL" "   [!!] $1"; }
bad()     { out "$C_RED" "   [XX] $1"; }

# verdict LEVEL TEXT — пункт итогового вывода (LEVEL: ok|warn|bad)
verdict() { VERDICT_LEVELS+=("$1"); VERDICTS+=("$2"); }

json_escape() {
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr -d '\000-\037'
}
# jnum KEY NUMBER / jstr KEY STRING — плоский json-отчёт с ключами вида "l1.tcp_ok"
jnum() { JSON_BODY="${JSON_BODY}  \"$1\": ${2:-null},"$'\n'; }
jstr() { JSON_BODY="${JSON_BODY}  \"$1\": \"$(json_escape "$2")\","$'\n'; }

die() { printf '%sОшибка: %s%s\n' "$C_RED" "$1" "$C_RST" >&2; exit 1; }

# --- helpers ----------------------------------------------------------------

# with_timeout SECONDS CMD... — переносимая замена timeout(1) (на macOS её нет)
with_timeout() {
    local secs="$1"; shift
    perl -e 'alarm shift @ARGV; exec @ARGV or exit 127' "$secs" "$@"
}

now_ms() { perl -MTime::HiRes=time -e 'printf "%d\n", time*1000'; }

urldecode() {
    local s="${1//+/ }"
    printf '%b' "${s//%/\\x}"
}

# query_param NAME QUERY — значение параметра из query-строки ссылки
query_param() {
    local name="$1" query="$2" pair
    local IFS='&'
    for pair in $query; do
        if [ "${pair%%=*}" = "$name" ]; then
            urldecode "${pair#*=}"
            return 0
        fi
    done
    return 1
}

is_ipv4() { [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; }

# resolve_system HOST — IPv4 через системный резолвер
resolve_system() {
    perl -MSocket -e '$a = inet_aton($ARGV[0]) or exit 1; print inet_ntoa($a)' "$1" 2>/dev/null
}

# resolve_doh HOST — IPv4-адреса через DNS-over-HTTPS (Cloudflare)
resolve_doh() {
    curl -s -m 6 -H 'accept: application/dns-json' \
        "https://cloudflare-dns.com/dns-query?name=$1&type=A" 2>/dev/null \
        | grep -oE '"data":"[0-9.]+"' | grep -oE '[0-9.]+' | sort -u
}

json_field() {
    printf '%s' "$2" | sed -n "s/.*\"$1\": *\"\([^\"]*\)\".*/\1/p" | head -1
}

median() { sort -n | awk '{a[NR]=$1} END {if (NR==0) print ""; else print a[int((NR+1)/2)]}'; }

sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
    else shasum -a 256 "$1" | awk '{print $1}'; fi
}

port_in_use() { with_timeout 1 bash -c "exec 3<>/dev/tcp/127.0.0.1/$1" 2>/dev/null; }

# tcp_try IP PORT — "ok MS" | "refused MS" | "timeout MS"
tcp_try() {
    local ip="$1" port="$2" t0 t1 rc
    t0=$(now_ms)
    with_timeout 4 bash -c "exec 3<>/dev/tcp/$ip/$port" 2>/dev/null
    rc=$?
    t1=$(now_ms)
    if [ $rc -eq 0 ]; then echo "ok $((t1 - t0))"
    elif [ $rc -eq 142 ]; then echo "timeout $((t1 - t0))"
    else echo "refused $((t1 - t0))"; fi
}

# tls_try IP PORT SNI — "ok MS" | "fail MS"
tls_try() {
    local ip="$1" port="$2" sni="$3" t0 t1 res
    local sni_args=()
    [ -n "$sni" ] && sni_args=(-servername "$sni")
    t0=$(now_ms)
    res=$(with_timeout 6 openssl s_client -connect "$ip:$port" "${sni_args[@]}" </dev/null 2>/dev/null)
    t1=$(now_ms)
    if printf '%s' "$res" | grep -q "Cipher"; then echo "ok $((t1 - t0))"; else echo "fail $((t1 - t0))"; fi
}

# --- xray -------------------------------------------------------------------

ensure_xray() {
    local os arch asset cache zip dgst want got
    if [ -n "$XRAY_BIN" ]; then
        [ -x "$XRAY_BIN" ] || die "xray не найден: $XRAY_BIN"
        return 0
    fi
    case "$(uname -s)-$(uname -m)" in
        Linux-x86_64)               asset="Xray-linux-64.zip" ;;
        Linux-aarch64|Linux-arm64)  asset="Xray-linux-arm64-v8a.zip" ;;
        Darwin-x86_64)              asset="Xray-macos-64.zip" ;;
        Darwin-arm64)               asset="Xray-macos-arm64-v8a.zip" ;;
        *) die "неподдерживаемая платформа $(uname -s)-$(uname -m), укажите --xray PATH" ;;
    esac
    cache="${XDG_CACHE_HOME:-$HOME/.cache}/netprobe/xray-$XRAY_VERSION"
    XRAY_BIN="$cache/xray"
    [ -x "$XRAY_BIN" ] && return 0

    info "Скачиваю xray $XRAY_VERSION ($asset)..."
    mkdir -p "$cache" || die "не могу создать $cache"
    zip="$cache/$asset"; dgst="$zip.dgst"
    local base="https://github.com/XTLS/Xray-core/releases/download/v$XRAY_VERSION"
    if ! curl -fsSL -m 120 -o "$zip" "$base/$asset" || ! curl -fsSL -m 30 -o "$dgst" "$base/$asset.dgst"; then
        for os in /usr/local/bin/xray /usr/bin/xray; do
            if [ -x "$os" ]; then warn "Скачать не удалось, использую системный $os"; XRAY_BIN="$os"; return 0; fi
        done
        die "не удалось скачать xray с GitHub. Скачайте вручную и передайте --xray PATH"
    fi
    want=$(grep -i 'SHA2-256' "$dgst" | head -1 | awk '{print $NF}')
    got=$(sha256_of "$zip")
    [ -n "$want" ] && [ "$want" = "$got" ] || { rm -f "$zip" "$dgst"; die "контрольная сумма xray не совпала"; }
    arch="$cache"
    if command -v unzip >/dev/null 2>&1; then unzip -o -q "$zip" xray -d "$arch"
    elif command -v bsdtar >/dev/null 2>&1; then (cd "$arch" && bsdtar -xf "$zip" xray)
    elif command -v python3 >/dev/null 2>&1; then python3 -c 'import sys,zipfile; zipfile.ZipFile(sys.argv[1]).extract("xray", sys.argv[2])' "$zip" "$arch"
    else die "нечем распаковать zip (нужен unzip, bsdtar или python3)"; fi
    chmod +x "$XRAY_BIN"
    rm -f "$zip" "$dgst"
    [ -x "$XRAY_BIN" ] || die "xray не распаковался"
}

# Разбор vless://UUID@HOST:PORT?params#name → глобальные L_*
parse_vless_link() {
    local link="$1" rest userhost hostport
    [[ "$link" == vless://* ]] || die "поддерживаются только ссылки vless://"
    rest="${link#vless://}"
    rest="${rest%%#*}"
    userhost="${rest%%\?*}"
    [[ "$userhost" == *@* ]] || die "не удалось разобрать ссылку (нет uuid@host)"
    L_QUERY=""
    [[ "$rest" == *\?* ]] && L_QUERY="${rest#*\?}"
    L_UUID="${userhost%%@*}"
    hostport="${userhost#*@}"
    if [[ "$hostport" == \[* ]]; then
        L_HOST="${hostport#\[}"; L_HOST="${L_HOST%%\]*}"
        L_PORT="${hostport##*\]:}"
    else
        L_HOST="${hostport%:*}"
        L_PORT="${hostport##*:}"
    fi
    [[ "$L_PORT" =~ ^[0-9]+$ ]] || L_PORT=443
    L_TYPE=$(query_param type "$L_QUERY") || L_TYPE="tcp"
    [ "$L_TYPE" = "raw" ] && L_TYPE="tcp"
    L_SECURITY=$(query_param security "$L_QUERY") || L_SECURITY="none"
    L_SNI=$(query_param sni "$L_QUERY") || L_SNI=""
    L_FP=$(query_param fp "$L_QUERY") || L_FP="chrome"
    L_PBK=$(query_param pbk "$L_QUERY") || L_PBK=""
    L_SID=$(query_param sid "$L_QUERY") || L_SID=""
    L_SPX=$(query_param spx "$L_QUERY") || L_SPX=""
    L_FLOW=$(query_param flow "$L_QUERY") || L_FLOW=""
    L_PATH=$(query_param path "$L_QUERY") || L_PATH="/"
    L_XHOST=$(query_param host "$L_QUERY") || L_XHOST=""
    L_MODE=$(query_param mode "$L_QUERY") || L_MODE="auto"
    L_EXTRA=$(query_param extra "$L_QUERY") || L_EXTRA=""
    L_SERVICE=$(query_param serviceName "$L_QUERY") || L_SERVICE=""
    L_ALPN=$(query_param alpn "$L_QUERY") || L_ALPN=""
    [ -n "$L_UUID" ] && [ -n "$L_HOST" ] || die "не удалось разобрать ссылку"
    [ "$L_SECURITY" != "reality" ] || [ -n "$L_PBK" ] || die "в reality-ссылке нет pbk (публичного ключа)"
    case "$L_TYPE" in tcp|xhttp|grpc|ws) ;; *) die "транспорт type=$L_TYPE пока не поддерживается" ;; esac
    case "$L_SECURITY" in reality|tls|none) ;; *) die "security=$L_SECURITY пока не поддерживается" ;; esac
}

# Конфиг xray-клиента из разобранной ссылки: socks на 127.0.0.1:$1
build_config_from_link() {
    local socks_port="$1" stream net sec
    local e_sni e_host
    e_sni=$(json_escape "$L_SNI"); e_host=$(json_escape "$L_XHOST")
    case "$L_TYPE" in
        tcp)   net='"network": "raw"' ;;
        xhttp) net="\"network\": \"xhttp\", \"xhttpSettings\": {\"path\": \"$(json_escape "$L_PATH")\", \"host\": \"$e_host\", \"mode\": \"$(json_escape "$L_MODE")\"${L_EXTRA:+, \"extra\": $L_EXTRA}}" ;;
        grpc)  net="\"network\": \"grpc\", \"grpcSettings\": {\"serviceName\": \"$(json_escape "$L_SERVICE")\"}" ;;
        ws)    net="\"network\": \"ws\", \"wsSettings\": {\"path\": \"$(json_escape "$L_PATH")\", \"headers\": {\"Host\": \"$e_host\"}}" ;;
    esac
    case "$L_SECURITY" in
        reality) sec="\"security\": \"reality\", \"realitySettings\": {\"serverName\": \"$e_sni\", \"fingerprint\": \"$(json_escape "$L_FP")\", \"publicKey\": \"$(json_escape "$L_PBK")\", \"shortId\": \"$(json_escape "$L_SID")\", \"spiderX\": \"$(json_escape "$L_SPX")\"}" ;;
        tls)     sec="\"security\": \"tls\", \"tlsSettings\": {\"serverName\": \"$e_sni\", \"fingerprint\": \"$(json_escape "$L_FP")\"${L_ALPN:+, \"alpn\": [\"${L_ALPN//,/\",\"}\"]}}" ;;
        none)    sec='"security": "none"' ;;
    esac
    stream="{$net, $sec}"
    cat <<EOF
{
  "log": {"loglevel": "warning"},
  "inbounds": [{"listen": "127.0.0.1", "port": $socks_port, "protocol": "socks", "settings": {"udp": false}}],
  "outbounds": [{
    "protocol": "vless",
    "settings": {"vnext": [{"address": "$(json_escape "$L_HOST")", "port": $L_PORT,
      "users": [{"id": "$(json_escape "$L_UUID")", "encryption": "none", "flow": "$(json_escape "$L_FLOW")"}]}]},
    "streamSettings": $stream
  }]
}
EOF
}

# На relay (3X-UI): берём outbound proxy-exit и то, на что он ссылается через dialerProxy
build_config_from_relay() {
    local socks_port="$1" cfg="/usr/local/x-ui/bin/config.json"
    command -v jq >/dev/null 2>&1 || die "для --from-relay нужен jq"
    [ -r "$cfg" ] || die "не найден $cfg — это точно relay с 3X-UI? (нужен root)"
    jq --argjson p "$socks_port" '
        (.outbounds[] | select(.tag == "proxy-exit")) as $px
        | ($px.streamSettings.sockopt.dialerProxy // "") as $dp
        | {log: {loglevel: "warning"},
           inbounds: [{listen: "127.0.0.1", port: $p, protocol: "socks", settings: {udp: false}}],
           outbounds: ([$px] + [.outbounds[] | select(.tag == $dp)])}' "$cfg"
}

relay_target_fields() {
    jq -r '.outbounds[] | select(.tag == "proxy-exit")
        | [.settings.vnext[0].address, .settings.vnext[0].port,
           (.streamSettings.realitySettings.serverName // ""),
           (.streamSettings.network // "raw"), (.streamSettings.security // "none"),
           (.settings.vnext[0].users[0].flow // ""),
           (.streamSettings.realitySettings.fingerprint // ""),
           (.streamSettings.sockopt.dialerProxy // "")] | @tsv' /usr/local/x-ui/bin/config.json
}

# --- layers -----------------------------------------------------------------

layer0_baseline() {
    local ipjson ya gg
    section "Слой 0. Базовая сеть"
    ipjson=$(curl -s -m 8 https://ipinfo.io/json 2>/dev/null)
    LOCAL_IP=$(json_field ip "$ipjson"); LOCAL_ORG=$(json_field org "$ipjson"); LOCAL_CC=$(json_field country "$ipjson")
    info "Ваш внешний IP: ${LOCAL_IP:-?}  ${LOCAL_ORG:-?}  (${LOCAL_CC:-?})"
    jstr "l0.ip" "$LOCAL_IP"; jstr "l0.org" "$LOCAL_ORG"; jstr "l0.country" "$LOCAL_CC"
    if [ -n "$LOCAL_CC" ] && [ "$LOCAL_CC" != "RU" ]; then
        warn "IP не российский. Если это ваш компьютер — выключите VPN/прокси и запустите заново."
        warn "Если вы проверяете с зарубежного сервера — всё в порядке."
    fi
    ya=$(curl -s -o /dev/null -m 8 -w '%{http_code}' https://ya.ru 2>/dev/null)
    gg=$(curl -s -o /dev/null -m 8 -w '%{http_code}' https://www.google.com/generate_204 2>/dev/null)
    jstr "l0.ya_ru" "$ya"; jstr "l0.google" "$gg"
    if [ "$ya" = "000" ] && [ "$gg" = "000" ]; then
        bad "Нет интернета (ни ya.ru, ни google.com не открываются)"
        verdict bad "Нет базового интернета — дальнейшие проверки бессмысленны"
        return 1
    fi
    ok "Интернет есть (ya.ru: $ya, google: $gg)"
    if [ -n "$TARGET_HOST" ] && ! is_ipv4 "$TARGET_HOST"; then
        local sys doh
        sys=$(resolve_system "$TARGET_HOST")
        doh=$(resolve_doh "$TARGET_HOST" | tr '\n' ' ')
        jstr "l0.dns_system" "$sys"; jstr "l0.dns_doh" "$doh"
        if [ -z "$sys" ]; then
            bad "Домен $TARGET_HOST не резолвится системным DNS (DoH: ${doh:-пусто})"
            verdict bad "DNS: домен сервера не резолвится у вашего провайдера"
        elif [ -n "$doh" ] && [[ " $doh " != *" $sys "* ]]; then
            warn "DNS расходится: системный → $sys, DoH → $doh (возможна подмена DNS)"
            verdict warn "DNS: системный резолвер отдаёт другой IP, чем DoH — возможна подмена"
        else
            ok "DNS: $TARGET_HOST → $sys"
        fi
        TARGET_IP="$sys"
    fi
    return 0
}

layer1_ip() {
    local ping_out loss rtt i r okc=0 refc=0 toc=0 times=""
    section "Слой 1. Доступность IP ($TARGET_IP:$TARGET_PORT)"
    ping_out=$(with_timeout 10 ping -c 4 "$TARGET_IP" 2>/dev/null)
    loss=$(printf '%s' "$ping_out" | grep -oE '[0-9.]+% packet loss' | grep -oE '^[0-9.]+')
    rtt=$(printf '%s' "$ping_out" | awk -F'/' '/min\/avg/ {print $5}')
    jstr "l1.ping_loss_pct" "${loss:-100}"; jstr "l1.ping_rtt_ms" "$rtt"
    if [ -n "$rtt" ]; then info "ping: потери ${loss}%, rtt ${rtt} мс"
    else info "ping: нет ответа (ICMP часто закрыт — само по себе не страшно)"; fi
    for i in 1 2 3 4 5 6 7 8 9 10; do
        r=$(tcp_try "$TARGET_IP" "$TARGET_PORT")
        case "${r%% *}" in
            ok) okc=$((okc + 1)); times="$times ${r#* }" ;;
            refused) refc=$((refc + 1)) ;;
            *) toc=$((toc + 1)) ;;
        esac
        sleep 0.3
    done
    local med
    med=$(printf '%s\n' $times | median)
    jnum "l1.tcp_ok" "$okc"; jnum "l1.tcp_refused" "$refc"; jnum "l1.tcp_timeout" "$toc"; jstr "l1.tcp_median_ms" "$med"
    if [ $okc -eq 10 ]; then ok "TCP-подключение к порту $TARGET_PORT: 10/10 (медиана ${med} мс)"
    elif [ $okc -eq 0 ] && [ $toc -gt 0 ]; then
        bad "TCP к порту $TARGET_PORT: 0/10, все по таймауту"
        if [ -n "$rtt" ]; then
            verdict bad "IP пингуется, но порт $TARGET_PORT не отвечает — блокировка порта/протокола по IP или сервис не запущен"
        else
            verdict bad "IP полностью недоступен (ни ping, ни TCP) — блокировка IP/подсети или сервер выключен. Сравните с другой сетью"
        fi
        return 1
    elif [ $okc -eq 0 ]; then
        bad "TCP к порту $TARGET_PORT: 0/10, соединение отклоняется (RST)"
        verdict bad "Порт $TARGET_PORT закрыт или сброс соединений — сервис не слушает порт либо RST-инъекция"
        return 1
    else
        warn "TCP к порту $TARGET_PORT: $okc/10 (таймаутов $toc, отказов $refc)"
        verdict warn "Нестабильный TCP до сервера ($okc/10) — потери на маршруте или частичная блокировка IP"
    fi
    return 0
}

layer2_tls() {
    local i r okc=0 times="" cert ctl_ok=0
    section "Слой 2. TLS-рукопожатие (SNI: ${TARGET_SNI:-нет})"
    for i in 1 2 3 4 5 6 7 8 9 10; do
        r=$(tls_try "$TARGET_IP" "$TARGET_PORT" "$TARGET_SNI")
        [ "${r%% *}" = "ok" ] && { okc=$((okc + 1)); times="$times ${r#* }"; }
        sleep 0.3
    done
    for i in 1 2 3; do
        r=$(tls_try 1.1.1.1 443 one.one.one.one)
        [ "${r%% *}" = "ok" ] && ctl_ok=$((ctl_ok + 1))
    done
    cert=$(with_timeout 6 openssl s_client -connect "$TARGET_IP:$TARGET_PORT" ${TARGET_SNI:+-servername "$TARGET_SNI"} </dev/null 2>/dev/null \
        | openssl x509 -noout -subject 2>/dev/null | sed 's/^subject= *//')
    jnum "l2.tls_ok" "$okc"; jnum "l2.control_ok" "$ctl_ok"; jstr "l2.cert_subject" "$cert"
    info "Сертификат сервера: ${cert:-не получен}"
    if [ $okc -eq 10 ]; then ok "TLS: 10/10 (медиана $(printf '%s\n' $times | median) мс); контроль 1.1.1.1: $ctl_ok/3"
    elif [ $okc -eq 0 ]; then
        bad "TLS: 0/10 при рабочем TCP; контроль 1.1.1.1: $ctl_ok/3"
        if [ $ctl_ok -gt 0 ]; then verdict bad "TCP проходит, а TLS к серверу рвётся — фильтрация по SNI/TLS на этом участке"
        else verdict bad "TLS не работает вообще (даже к 1.1.1.1) — проблема в вашей сети/провайдере"; fi
        return 1
    else
        warn "TLS: $okc/10; контроль 1.1.1.1: $ctl_ok/3"
        verdict warn "Часть TLS-рукопожатий не проходит ($okc/10) — выборочная фильтрация TLS"
    fi
    return 0
}

layer3_volume() {
    local res code size t
    section "Слой 3. Передача объёма (заморозка 16–20 КБ)"
    if [ -z "$TARGET_SNI" ]; then info "SNI неизвестен — пропускаю, объём проверится в слое 4"; return 0; fi
    res=$(curl -sk -o /dev/null -m 15 --resolve "$TARGET_SNI:$TARGET_PORT:$TARGET_IP" \
        -w '%{http_code} %{size_download} %{time_total}' "https://$TARGET_SNI:$TARGET_PORT/" 2>/dev/null)
    code=${res%% *}; size=$(echo "$res" | awk '{print $2}'); t=$(echo "$res" | awk '{print $3}')
    jstr "l3.http_code" "$code"; jnum "l3.bytes" "${size:-0}"; jstr "l3.time_s" "$t"
    if [ "$code" = "000" ] && [ "${size:-0}" -ge 8000 ] 2>/dev/null && [ "${size:-0}" -le 40000 ]; then
        bad "Загрузка сайта на сервере зависла после ${size} байт"
        verdict bad "Заморозка соединения после ~16–20 КБ — ТСПУ ограничивает трафик к этому IP/хостингу"
    elif [ "$code" = "000" ]; then
        warn "Сайт-прикрытие не ответил по HTTPS (получено ${size:-0} байт)"
    elif [ "${size:-0}" -lt 30000 ]; then
        info "Сайт-прикрытие ответил ($code, ${size} байт) — страница мала для проверки заморозки, проверю в слое 4"
    else
        ok "Сайт-прикрытие отдал ${size} байт за ${t} с — заморозки нет"
    fi
    return 0
}

layer4_protocol() {
    local socks_port cfg i res rc code app total okc=0 stall=0 reset=0 proxyerr=0 other=0 line="" times=""
    section "Слой 4. Протокол VLESS ($PROTO_DESC)"
    ensure_xray
    info "xray: $("$XRAY_BIN" version 2>/dev/null | head -1 | awk '{print $1, $2}')"
    socks_port=$((20000 + RANDOM % 20000))
    while port_in_use "$socks_port"; do socks_port=$((20000 + RANDOM % 20000)); done
    cfg="$WORK/c.json"
    if [ "$MODE" = "relay" ]; then build_config_from_relay "$socks_port" > "$cfg" || die "не удалось собрать конфиг"
    else build_config_from_link "$socks_port" > "$cfg"; fi
    if ! "$XRAY_BIN" run -test -c "$cfg" >"$WORK/test.log" 2>&1; then
        bad "xray не принял конфиг из ссылки:"; tail -3 "$WORK/test.log" | while read -r l; do info "$l"; done
        verdict bad "Ссылка некорректна или не поддерживается этой версией xray"
        return 1
    fi
    "$XRAY_BIN" run -c "$cfg" >"$WORK/xray.log" 2>&1 &
    XRAY_PID=$!
    for i in 1 2 3 4 5 6 7 8 9 10; do port_in_use "$socks_port" && break; sleep 0.5; done
    local px="--socks5-hostname 127.0.0.1:$socks_port"
    [ "$L_TYPE" = "xhttp" ] && info "Транспорт xhttp переиспользует соединения — процент ниже отражает общую стабильность"
    info "Делаю $N_HANDSHAKES подключений через туннель с паузами (это займёт ~$((N_HANDSHAKES * 13 / 10)) с)..."
    printf '   '
    for ((i = 1; i <= N_HANDSHAKES; i++)); do
        # shellcheck disable=SC2086
        res=$(curl $px -s -o /dev/null -m 6 -w '%{http_code} %{time_appconnect} %{time_total}' https://www.google.com/generate_204 2>/dev/null)
        rc=$?
        code=${res%% *}; app=$(echo "$res" | awk '{print $2}'); total=$(echo "$res" | awk '{print $3}')
        if [ "$code" = "204" ]; then
            okc=$((okc + 1)); line="$line."; printf '%s.%s' "$C_GRN" "$C_RST"
            times="$times $(awk -v t="$total" 'BEGIN{printf "%d", t*1000}')"
        else
            line="${line}X"; printf '%sX%s' "$C_RED" "$C_RST"
            if [ $rc -eq 28 ] && [ "$(awk -v a="${app:-0}" 'BEGIN{print (a==0)}')" = "1" ]; then stall=$((stall + 1))
            elif [ $rc -eq 97 ] || [ $rc -eq 7 ]; then proxyerr=$((proxyerr + 1))
            elif [ $rc -eq 35 ] || [ $rc -eq 56 ] || [ $rc -eq 52 ]; then reset=$((reset + 1))
            else other=$((other + 1)); fi
        fi
        sleep "0.$((3 + RANDOM % 7))"
    done
    printf '\n'
    [ -n "$TXT" ] && printf '   %s\n' "$line" >> "$TXT"
    local fail=$((N_HANDSHAKES - okc)) pct med
    pct=$((fail * 100 / N_HANDSHAKES))
    med=$(printf '%s\n' $times | median)
    jnum "l4.attempts" "$N_HANDSHAKES"; jnum "l4.ok" "$okc"; jnum "l4.stall" "$stall"; jnum "l4.reset" "$reset"
    jnum "l4.proxy_error" "$proxyerr"; jnum "l4.other" "$other"; jstr "l4.median_ms" "$med"; jstr "l4.pattern" "$line"
    info "Успешно $okc/$N_HANDSHAKES (медиана ${med:-?} мс). Сбои: зависание $stall, обрыв/RST $reset, мгновенный отказ $proxyerr, прочее $other"

    if [ $okc -eq 0 ]; then
        bad "Туннель не работает совсем"
        if [ $proxyerr -ge $((fail / 2)) ]; then verdict bad "Сервер сразу отвергает подключение — проверьте ссылку (uuid/ключ/sni); если ссылка верна — активная блокировка протокола"
        else verdict bad "Туннель не поднимается: все подключения зависают — протокол блокируется на этом участке"; fi
    elif [ $pct -le 3 ]; then ok "Туннель стабилен (сбоев ${pct}%)"; verdict ok "Протокол работает стабильно (сбоев ${pct}%)"
    elif [ $pct -le 15 ]; then
        warn "Деградация: ${pct}% подключений не прошли"
        if [ $stall -ge $((fail / 2)) ]; then verdict warn "Часть новых подключений зависает (${pct}%) — похоже на выборочный сброс хендшейков ТСПУ: «то работает, то нет»"
        else verdict warn "Часть подключений рвётся (${pct}%) — нестабильный участок"; fi
    else
        bad "Сильная деградация: ${pct}% подключений не прошли"
        verdict bad "Протокол сильно деградирует (${pct}% сбоев) — участок фактически непригоден"
    fi

    if [ $okc -gt 0 ]; then
        local d bytes spd
        info "Скачивание через туннель (3 × 4 МБ):"
        for d in 1 2 3; do
            # shellcheck disable=SC2086
            res=$(curl $px -s -o /dev/null -m 25 -w '%{http_code} %{size_download} %{speed_download}' "https://speed.cloudflare.com/__down?bytes=4000000" 2>/dev/null)
            bytes=$(echo "$res" | awk '{print $2}'); spd=$(echo "$res" | awk '{printf "%.1f", $3*8/1000000}')
            jstr "l4.download$d" "$res"
            if [ "${bytes:-0}" -ge 4000000 ] 2>/dev/null; then ok "  #$d: 4 МБ, ${spd} Мбит/с"
            elif [ "${bytes:-0}" -ge 8000 ] 2>/dev/null && [ "${bytes:-0}" -le 40000 ]; then
                bad "  #$d: зависло после ${bytes} байт"
                verdict bad "Заморозка после ~16–20 КБ внутри туннеля — ТСПУ режет объём к этому серверу"
            elif [ "${bytes:-0}" -eq 0 ] 2>/dev/null; then bad "  #$d: не стартовало — новое соединение зависло (тот же сбой, что выше)"
            else bad "  #$d: оборвалось на ${bytes} байт"; fi
        done
        head -c 2000000 /dev/urandom > "$WORK/up.bin"
        for d in 1 2; do
            # shellcheck disable=SC2086
            res=$(curl $px -s -o /dev/null -m 25 --data-binary @"$WORK/up.bin" -w '%{http_code} %{size_upload} %{speed_upload}' https://speed.cloudflare.com/__up 2>/dev/null)
            [ "${res%% *}" = "200" ] && break
        done
        jstr "l4.upload" "$res"
        if [ "${res%% *}" = "200" ]; then ok "  Отдача 2 МБ: $(echo "$res" | awk '{printf "%.1f", $3*8/1000000}') Мбит/с"
        else warn "  Отдача 2 МБ не удалась ($res)"; fi

        if [ $LONG_TEST -eq 1 ]; then
            info "Долгое соединение (~2 мин, медленная загрузка)..."
            # shellcheck disable=SC2086
            res=$(curl $px -s -o /dev/null -m 150 --limit-rate 25k -w '%{http_code} %{size_download} %{time_total}' "https://speed.cloudflare.com/__down?bytes=3000000" 2>/dev/null)
            jstr "l4.long" "$res"
            bytes=$(echo "$res" | awk '{print $2}')
            if [ "${bytes:-0}" -ge 3000000 ] 2>/dev/null; then ok "  Долгое соединение продержалось до конца"
            else
                bad "  Долгое соединение оборвалось через $(echo "$res" | awk '{print $3}') с (${bytes:-0} байт)"
                verdict warn "Долгие соединения обрываются — возможно ограничение по времени жизни сессии"
            fi
        fi
    fi
    kill "$XRAY_PID" 2>/dev/null; XRAY_PID=""
    return 0
}

# --- main -------------------------------------------------------------------

cleanup() {
    [ -n "${XRAY_PID:-}" ] && kill "$XRAY_PID" 2>/dev/null
    [ -n "${WORK:-}" ] && rm -rf "$WORK"
}

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            -h|--help) usage; exit 0 ;;
            -n) N_HANDSHAKES="$2"; shift ;;
            --long) LONG_TEST=1 ;;
            --xray) XRAY_BIN="$2"; shift ;;
            --out) OUT_DIR="$2"; shift ;;
            --from-relay) MODE="relay" ;;
            --host) MODE="host"; TARGET_HOST="${2%%:*}"; [[ "$2" == *:* ]] && TARGET_PORT="${2##*:}"; shift ;;
            --sni) TARGET_SNI="$2"; shift ;;
            vless://*) MODE="link"; LINK="$1" ;;
            *) usage; die "непонятный аргумент: $1" ;;
        esac
        shift
    done
    [ -n "$MODE" ] || { usage; exit 1; }
    [[ "$N_HANDSHAKES" =~ ^[0-9]+$ ]] && [ "$N_HANDSHAKES" -ge 5 ] || die "-n должно быть числом ≥ 5"
}

main() {
    local cmd ts
    parse_args "$@"
    for cmd in curl openssl perl; do command -v "$cmd" >/dev/null 2>&1 || die "не найден $cmd"; done

    WORK=$(mktemp -d "${TMPDIR:-/tmp}/netprobe.XXXXXX") || die "mktemp"
    chmod 700 "$WORK"
    trap cleanup EXIT
    trap 'exit 130' INT TERM

    case "$MODE" in
        link)
            parse_vless_link "$LINK"
            TARGET_HOST="$L_HOST"; TARGET_PORT="$L_PORT"; TARGET_SNI="$L_SNI"
            PROTO_DESC="$L_TYPE/$L_SECURITY${L_FLOW:+/$L_FLOW}, fp=$L_FP"
            ;;
        relay)
            local f
            f=$(relay_target_fields) || die "не удалось прочитать outbound proxy-exit"
            TARGET_HOST=$(echo "$f" | cut -f1); TARGET_PORT=$(echo "$f" | cut -f2); TARGET_SNI=$(echo "$f" | cut -f3)
            PROTO_DESC="$(echo "$f" | cut -f4)/$(echo "$f" | cut -f5)/$(echo "$f" | cut -f6), fp=$(echo "$f" | cut -f7)$( [ -n "$(echo "$f" | cut -f8)" ] && echo ", dialerProxy=$(echo "$f" | cut -f8)")"
            L_TYPE=$(echo "$f" | cut -f4)
            ;;
    esac
    TARGET_IP="$TARGET_HOST"

    ts=$(date +%Y%m%d-%H%M%S)
    mkdir -p "$OUT_DIR" || die "не могу создать $OUT_DIR"
    TXT="$OUT_DIR/netprobe-$ts.txt"
    : > "$TXT" || die "не могу писать в $OUT_DIR"
    local json_file="$OUT_DIR/netprobe-$ts.json"

    out "$C_BLD" "netprobe $NETPROBE_VERSION — $(date '+%Y-%m-%d %H:%M:%S %Z')"
    out "$C_DIM" "Цель: $TARGET_HOST:$TARGET_PORT  SNI: ${TARGET_SNI:-—}  режим: $MODE${PROTO_DESC:+  ($PROTO_DESC)}"
    jstr "version" "$NETPROBE_VERSION"; jstr "time" "$(date '+%Y-%m-%dT%H:%M:%S%z')"; jstr "mode" "$MODE"
    jstr "host" "$(hostname 2>/dev/null)"; jstr "os" "$(uname -sm)"
    jstr "target.host" "$TARGET_HOST"; jstr "target.port" "$TARGET_PORT"; jstr "target.sni" "$TARGET_SNI"
    jstr "target.proto" "${PROTO_DESC:-}"

    if layer0_baseline; then
        if ! is_ipv4 "$TARGET_IP"; then
            bad "Не удалось получить IPv4 для $TARGET_HOST"
        elif layer1_ip; then
            layer2_tls
            layer3_volume
            [ "$MODE" != "host" ] && layer4_protocol
        fi
    fi

    section "ИТОГ"
    if [ ${#VERDICTS[@]} -eq 0 ]; then
        ok "Явных признаков блокировки не найдено"
        VERDICTS+=("Явных признаков блокировки не найдено"); VERDICT_LEVELS+=("ok")
    else
        local i
        for ((i = 0; i < ${#VERDICTS[@]}; i++)); do
            case "${VERDICT_LEVELS[$i]}" in
                ok) ok "${VERDICTS[$i]}" ;; warn) warn "${VERDICTS[$i]}" ;; *) bad "${VERDICTS[$i]}" ;;
            esac
            jstr "verdict.$((i + 1))" "${VERDICT_LEVELS[$i]}: ${VERDICTS[$i]}"
        done
        if [ "$MODE" = "link" ] && [[ " ${VERDICT_LEVELS[*]} " == *" warn "* || " ${VERDICT_LEVELS[*]} " == *" bad "* ]]; then
            info ""
            info "Если это ссылка на relay, проверялась вся цепочка (вы → relay → exit)."
            info "Чтобы найти проблемный участок: проверьте прямую ссылку на exit с этой же"
            info "машины и запустите на relay: netprobe.sh --from-relay"
        fi
    fi
    printf '{\n%s  "end": true\n}\n' "$JSON_BODY" > "$json_file"
    out "" ""
    out "$C_DIM" "Отчёт: $TXT"
    out "$C_DIM" "       $json_file"
    out "$C_DIM" "Пришлите оба файла. Ключей и UUID в них нет."
}

main "$@"
