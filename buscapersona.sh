#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
#  buscapersona.sh v2.0 — Búsqueda OSINT intensiva de personas en internet
#  "de forma intensa" — multi-motor, multi-plataforma, multi-técnica
# =============================================================================
#  Uso: ./buscapersona.sh -n "Nombre Apellido" [opciones]
#  Requisitos: curl, jq, python3, pandoc (opcional para HTML)
# =============================================================================

VERSION="2.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── Colores ─────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; MAGENTA='\033[0;35m'; BOLD='\033[1m'
NC='\033[0m'; DIM='\033[2m'; UNDER='\033[4m'

# ─── Config ──────────────────────────────────────────────────────────────────
NAME=""; OUTDIR=""; TIMEOUT=12; VERBOSE=false; SOCIAL=false
WEB=false; USERNAME=""; EMAIL=""; PHONE=""; THREADS=10
USE_TOR=false; PROXY=""; HTML_REPORT=false; DORKS=false; ALL=false
DELAY_MIN=0.5; DELAY_MAX=2.0
RESULTS_DIR=""

# ─── Helpers ─────────────────────────────────────────────────────────────────
info()  { echo -e "${CYAN}[*]${NC} $*"; }
ok()    { echo -e "${GREEN}[✓]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
err()   { echo -e "${RED}[✗]${NC} $*" >&2; }
dim()   { echo -e "${DIM}$*${NC}"; }
hr()    { printf '%*s\n' "${COLUMNS:-80}" '' | tr ' ' '─'; }

rand_delay() {
    python3 -c "import random,time; time.sleep(round(random.uniform($DELAY_MIN, $DELAY_MAX), 2))"
}

curl_wrap() {
    local url="$1"; shift
    local agent="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36"
    local proxy_args=()
    if [[ -n "$PROXY" ]]; then
        proxy_args=(--proxy "$PROXY")
    elif [[ "$USE_TOR" == true ]]; then
        proxy_args=(--proxy socks5h://127.0.0.1:9050)
    fi
    # Retry logic: up to 2 retries with backoff
    local attempt=0 max_retry=2
    while [[ $attempt -le $max_retry ]]; do
        if timeout "$((TIMEOUT+2))" curl -s -L --max-time "$TIMEOUT" \
            -H "User-Agent: $agent" \
            -H "Accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8" \
            -H "Accept-Language: en-US,en;q=0.5" \
            "${proxy_args[@]}" \
            "$url" 2>/dev/null; then
            return 0
        fi
        attempt=$((attempt + 1))
        [[ $attempt -le $max_retry ]] && sleep $((attempt * 2))
    done
    return 1
}

urlencode() { python3 -c "import urllib.parse; print(urllib.parse.quote('''$1'''))"; }

log_result() {
    local section="$1" source="$2" url="$3" found="$4" detail="${5:-}"
    local icon
    [[ "$found" == "true" ]] && icon="${GREEN}✓${NC}" || icon="${DIM}−${NC}"
    echo -e "  ${icon} ${BOLD}$section${NC} → $source ${DIM}$url${NC}"
    [[ -n "$detail" && "$found" == "true" ]] && echo -e "      ${DIM}$detail${NC}"

    if [[ -n "$RESULTS_DIR" ]]; then
        local f="${RESULTS_DIR}/resultados.txt"
        { echo "[${section}] ${source}: $([ "$found" == "true" ] && echo 'OK' || echo '--')";
          echo "  URL: $url";
          [[ -n "$detail" && "$found" == "true" ]] && echo "  $detail";
          echo ""; } >> "$f"
    fi
}

usage() {
    cat <<EOF
${BOLD}uso:${NC} $(basename "$0") ${CYAN}-n${NC} "${GREEN}\"Nombre Apellido\"${NC}" [opciones]

${BOLD}Búsqueda OSINT intensiva${NC} de una persona en internet.

${BOLD}Obligatorio (al menos uno):${NC}
  ${CYAN}-n, --name "${GREEN}Nombre Apellido${NC}"     Nombre a buscar
  ${CYAN}-u, --username "${GREEN}user${NC}"            Nombre de usuario
  ${CYAN}-e, --email "${GREEN}correo@ej.com${NC}"      Email
  ${CYAN}-p, --phone "${GREEN}+521234${NC}"             Teléfono

${BOLD}Modos:${NC}
  ${CYAN}--all${NC}               Activar TODOS los módulos intensivos
  ${CYAN}--dorks${NC}             Google Dorks OSINT
  ${CYAN}--social-only${NC}       Solo redes sociales
  ${CYAN}--web-only${NC}          Solo búsqueda web

${BOLD}Opciones avanzadas:${NC}
  ${CYAN}--tor${NC}               Enrutar tráfico por Tor (socks5 en :9050)
  ${CYAN}--proxy${NC} URL         Proxy HTTP/SOCKS personalizado
  ${CYAN}--html${NC}              Generar reporte HTML (requiere pandoc)
  ${CYAN}-o DIR${NC}              Guardar reportes en DIR
  ${CYAN}-t seg${NC}              Timeout por petición (def: 12)
  ${CYAN}--threads N${NC}         Hilos concurrentes (def: 10)
  ${CYAN}--delay min,max${NC}     Delay aleatorio entre peticiones (def: 0.5,2.0)
  ${CYAN}-v${NC}                  Modo verbose

${BOLD}Ejemplos:${NC}
  ./buscapersona.sh -n "Juan Pérez" --all
  ./buscapersona.sh -n "María García" --tor --html -o ~/investigacion
  ./buscapersona.sh -u "juanperez80" --dorks --threads 20
  ./buscapersona.sh -n "Carlos López" -e "carlos@x.com" -p "+525512345678" --all
EOF
    exit 0
}

# ─── Parse args ──────────────────────────────────────────────────────────────
[[ $# -eq 0 ]] && usage
while [[ $# -gt 0 ]]; do
    case "$1" in
        -n|--name)      NAME="$2"; shift 2 ;;
        -u|--username)  USERNAME="$2"; shift 2 ;;
        -e|--email)     EMAIL="$2"; shift 2 ;;
        -p|--phone)     PHONE="$2"; shift 2 ;;
        -o|--output)    OUTDIR="$2"; shift 2 ;;
        -t|--timeout)   TIMEOUT="$2"; shift 2 ;;
        --threads)      THREADS="$2"; shift 2 ;;
        --delay)        DELAY_MIN="${2%%,*}"; DELAY_MAX="${2##*,}"; shift 2 ;;
        --social-only)  SOCIAL=true; shift ;;
        --web-only)     WEB=true; shift ;;
        --tor)          USE_TOR=true; shift ;;
        --proxy)        PROXY="$2"; shift 2 ;;
        --html)         HTML_REPORT=true; shift ;;
        --dorks)        DORKS=true; shift ;;
        --all)          ALL=true; shift ;;
        -v|--verbose)   VERBOSE=true; shift ;;
        -h|--help)      usage ;;
        *)  err "Argumento desconocido: $1"; usage ;;
    esac
done

for cmd in curl jq python3; do
    command -v "$cmd" &>/dev/null || { err "Falta $cmd"; exit 1; }
done

if [[ -z "$NAME" && -z "$USERNAME" && -z "$EMAIL" && -z "$PHONE" ]]; then
    err "Provee al menos -n, -u, -e, o -p"; usage
fi

# Setup output dir
if [[ -n "$OUTDIR" ]]; then
    RESULTS_DIR="$OUTDIR"
    mkdir -p "$RESULTS_DIR"
    # Init results file
    : > "${RESULTS_DIR}/resultados.txt"
    { echo "buscapersona.sh v${VERSION}"; echo "Fecha: $(date '+%Y-%m-%d %H:%M:%S')"; echo ""; } >> "${RESULTS_DIR}/resultados.txt"
fi

if [[ "$USE_TOR" == true && -z "$PROXY" ]]; then
    info "Verificando Tor..."
    if timeout 7 curl -s --max-time 5 --proxy socks5h://127.0.0.1:9050 https://check.torproject.org/api 2>/dev/null | jq -r '.IsTor' 2>/dev/null | grep -q true; then
        ok "Tor conectado"
    else
        warn "Tor no detectado en :9050 — continuando sin Tor"
        USE_TOR=false
    fi
fi

# ─── Banner ──────────────────────────────────────────────────────────────────
banner() {
    echo -e "${MAGENTA}${BOLD}"
    echo '╔══════════════════════════════════════════════════════════════╗'
    echo '║                   buscapersona.sh  v2.0                    ║'
    echo '║              Búsqueda OSINT Intensiva                      ║'
    echo '╚══════════════════════════════════════════════════════════════╝'
    echo -e "${NC}"
    if [[ "$USE_TOR" == true ]]; then echo -e "  ${DIM}🔒 Tor activo${NC}"; fi
    if [[ -n "$PROXY" ]]; then echo -e "  ${DIM}🔒 Proxy: $PROXY${NC}"; fi
    echo ""
}

# ─── Check internet ──────────────────────────────────────────────────────────
check_internet() {
    info "Verificando conexión..."
    local targets=("https://www.google.com" "https://duckduckgo.com" "https://www.bing.com")
    for t in "${targets[@]}"; do
        if timeout 7 curl -s --max-time 5 "$t" >/dev/null 2>&1; then
            ok "Internet OK ($t)"
            return 0
        fi
    done
    warn "Sin internet — limitado a métodos offline"
    return 1
}

# ═════════════════════════════════════════════════════════════════════════════
#  MÓDULO 1: DuckDuckGo API (no bloquea como Google)
# ═════════════════════════════════════════════════════════════════════════════
duckduckgo_api() {
    local query="$1"
    local encoded; encoded=$(urlencode "$query")
    local api_url="https://api.duckduckgo.com/?q=${encoded}&format=json&no_html=1&skip_disambig=1"
    rand_delay
    local data; data=$(curl_wrap "$api_url") || return 1
    if [[ -z "$data" ]]; then return 1; fi

    # Abstract
    local abstract; abstract=$(echo "$data" | jq -r '.AbstractText // empty' 2>/dev/null)
    if [[ -n "$abstract" ]]; then
        echo -e "    ${DIM}Abstract: ${abstract:0:200}${NC}"
        log_result "DDG_API" "Abstract" "https://duckduckgo.com/?q=${encoded}" "true" "${abstract:0:200}"
    fi
    # Related topics
    local topics; topics=$(echo "$data" | jq -r '.RelatedTopics[]? | select(.Text != null) | .Text' 2>/dev/null | head -8)
    if [[ -n "$topics" ]]; then
        echo "$topics" | while IFS= read -r line; do
            echo -e "    ${DIM}→ ${line:0:120}${NC}"
            log_result "DDG_API" "Related" "" "true" "${line:0:120}"
        done
    fi
    # External links
    local results; results=$(echo "$data" | jq -r '.Results[]? | .FirstURL // empty' 2>/dev/null | head -10)
    if [[ -n "$results" ]]; then
        echo "$results" | while IFS= read -r url; do
            echo -e "    ${CYAN}↗${NC} ${DIM}$url${NC}"
            log_result "DDG_API" "Result" "$url" "true"
        done
    fi
    if [[ -z "$abstract" && -z "$topics" && -z "$results" ]]; then
        dim "    DDG API: sin resultados relevantes"
        log_result "DDG_API" "DuckDuckGo" "$api_url" "false"
    fi
}

# ═════════════════════════════════════════════════════════════════════════════
#  MÓDULO 2: Bing Web Search API (scrape)
# ═════════════════════════════════════════════════════════════════════════════
bing_search() {
    local query="$1" pages="${2:-1}"
    local encoded; encoded=$(urlencode "$query")
    echo -e "\n${BOLD}${CYAN}🌐  BING SEARCH (${pages} páginas)${NC}"
    hr

    local first=1
    for ((p=1; p<=pages; p++)); do
        rand_delay
        local url="https://www.bing.com/search?q=${encoded}&first=${first}"
        info "Bing página $p..."
        local html; html=$(curl_wrap "$url") || { warn "Bing página $p falló"; continue; }
        # Extract results
        echo "$html" | grep -oP '<li class="b_algo">.*?</li>' 2>/dev/null | head -10 | while IFS= read -r item; do
            local link; link=$(echo "$item" | grep -oP '(?<=<a href=")[^"]+(?=")')
            local title; title=$(echo "$item" | grep -oP '(?<=<h2>).*?(?=</h2>)' | sed 's/<[^>]*>//g')
            [[ -n "$link" ]] && echo -e "    ${CYAN}↗${NC} ${DIM}$title${NC}" && echo -e "      ${DIM}$link${NC}" && \
                log_result "Bing" "Bing" "$link" "true" "$title"
        done
        first=$((first + 10))
    done
}

# ═════════════════════════════════════════════════════════════════════════════
#  MÓDULO 3: DuckDuckGo Lite (más permisivo que el API)
# ═════════════════════════════════════════════════════════════════════════════
duckduckgo_lite() {
    local query="$1"
    local encoded; encoded=$(urlencode "$query")
    echo -e "\n${BOLD}${CYAN}🦆  DUCKDUCKGO LITE${NC}"
    hr
    rand_delay
    local url="https://lite.duckduckgo.com/lite/?q=${encoded}"
    local html; html=$(curl_wrap "$url") || { warn "DuckDuckGo Lite falló"; return 1; }
    local results; results=$(echo "$html" | grep -oP '(?<=<a href=")[^"]+(?=" class="result-link")' 2>/dev/null | head -15)
    if [[ -n "$results" ]]; then
        echo "$results" | while IFS= read -r link; do
            echo -e "    ${CYAN}↗${NC} ${DIM}$link${NC}"
            log_result "DDG_Lite" "DuckDuckGo" "$link" "true"
        done
    else
        dim "    Sin resultados"
        log_result "DDG_Lite" "DuckDuckGo" "$url" "false"
    fi
}

# ═════════════════════════════════════════════════════════════════════════════
#  MÓDULO 4: Google Dorks OSINT (si --dorks o --all)
# ═════════════════════════════════════════════════════════════════════════════
google_dorks() {
    local query="$1"
    echo -e "\n${BOLD}${RED}🔎  GOOGLE DORKS OSINT${NC}"
    hr
    # Dorks organizados por categoría
    local -a dorks=()
    dorks+=("${query} site:linkedin.com/in OR site:facebook.com OR site:twitter.com")
    dorks+=("${query} site:instagram.com OR site:tiktok.com OR site:youtube.com")
    dorks+=("${query} site:github.com OR site:gitlab.com OR site:bitbucket.org")
    dorks+=("${query} site:reddit.com OR site:quora.com OR site:stackoverflow.com")
    dorks+=("${query} site:pastebin.com OR site:gist.github.com OR site:hastebin.com")
    dorks+=("${query} site:medium.com OR site:dev.to OR site:hashnode.com")
    dorks+=("${query} site:docs.google.com OR site:drive.google.com OR site:dropbox.com")
    dorks+=("\"${query}\" curriculum OR cv OR resume filetype:pdf")
    dorks+=("\"${query}\" email OR contacto OR contact")
    dorks+=("\"${query}\" \"telefono\" OR \"phone\" OR \"celular\"")
    dorks+=("\"${query}\" \"direccion\" OR \"address\" OR \"domicilio\"")
    dorks+=("\"${query}\" site:archive.org OR site:web.archive.org")
    dorks+=("\"${query}\" site:wikipedia.org")
    dorks+=("\"${query}\" \"@\" -site:twitter.com -site:facebook.com")

    local total=${#dorks[@]} current=0
    for dork in "${dorks[@]}"; do
        current=$((current+1))
        local encoded; encoded=$(urlencode "$dork")
        local url="https://www.google.com/search?q=${encoded}"
        dim "  Dork [$current/$total]: ${DIM}$dork${NC}"
        rand_delay
        local html; html=$(curl_wrap "$url") || { dim "    (bloqueado)"; continue; }
        local links; links=$(echo "$html" | grep -oP '(?<=<a href="/url\?q=)[^"&]+' 2>/dev/null | head -5)
        if [[ -n "$links" ]]; then
            echo "$links" | while IFS= read -r link; do
                echo -e "    ${CYAN}↗${NC} ${DIM}$link${NC}"
                log_result "Dork" "Google" "$link" "true" "$dork"
            done
        else
            dim "    (sin resultados o bloqueado)"
        fi
    done
}

# ═════════════════════════════════════════════════════════════════════════════
#  MÓDULO 5: Búsqueda en redes sociales (name search)
# ═════════════════════════════════════════════════════════════════════════════
search_social || true() {
    echo -e "\n${BOLD}${MAGENTA}👤  REDES SOCIALES${NC}"
    hr
    local -A sites
    local encoded; encoded=$(urlencode "$NAME")
    sites=(
        ["LinkedIn"]="https://www.linkedin.com/search/results/all/?keywords=${encoded}"
        ["Twitter/X"]="https://twitter.com/search?q=${encoded}&src=typed_query&f=user"
        ["Facebook"]="https://www.facebook.com/search/people/?q=${encoded}"
        ["Instagram"]="https://www.instagram.com/web/search/topsearch/?query=${encoded}"
        ["TikTok"]="https://www.tiktok.com/search/user?q=${encoded}"
        ["Reddit"]="https://www.reddit.com/search/?q=${encoded}&type=user"
        ["YouTube"]="https://www.youtube.com/results?search_query=${encoded}"
        ["GitHub"]="https://github.com/search?q=${encoded}&type=users&s=followers&o=desc"
        ["Pinterest"]="https://www.pinterest.com/search/users/?q=${encoded}"
        ["Telegram"]="https://t.me/s?q=${encoded}"
        ["Behance"]="https://www.behance.net/search/projects?search=${encoded}"
        ["Dribbble"]="https://dribbble.com/search/users?q=${encoded}"
        ["Medium"]="https://medium.com/search?q=${encoded}"
        ["Discord"]="https://discord.com/search?q=${encoded}"
        ["Twitch"]="https://www.twitch.tv/search?term=${encoded}"
        ["VK"]="https://vk.com/search?c%5Bq%5D=${encoded}&c%5Btype%5D=people"
    )
    local count=0
    for platform in "${!sites[@]}"; do
        local url="${sites[$platform]}"
        [[ $VERBOSE == true ]] && info "Buscando en ${BOLD}$platform${NC}..."
        rand_delay
        local code; code=$(timeout "$((TIMEOUT+2))" curl -s -o /dev/null -w "%{http_code}" --max-time "$TIMEOUT" \
            -H "User-Agent: Mozilla/5.0" \
            $( [[ -n "$PROXY" ]] && echo "--proxy $PROXY" || true ) \
            $( [[ "$USE_TOR" == true ]] && echo "--proxy socks5h://127.0.0.1:9050" || true ) \
            -L "$url" 2>/dev/null || echo "000")
        if [[ "$code" == "200" || "$code" == "301" || "$code" == "302" ]]; then
            echo -e "  ${GREEN}✓${NC} ${BOLD}$platform${NC} ${DIM}$url${NC}"
            log_result "Social" "$platform" "$url" "true" "HTTP $code"
            count=$((count+1))
        elif [[ $VERBOSE == true ]]; then
            dim "  − $platform (HTTP $code)"
        fi
    done
    ok "Encontradas $count redes con posible presencia"
}

# ═════════════════════════════════════════════════════════════════════════════
#  MÓDULO 6: Búsqueda por username (40+ plataformas)
# ═════════════════════════════════════════════════════════════════════════════
search_username() {
    local uname="$1"
    echo -e "\n${BOLD}${GREEN}🔍  USERNAME: ${BOLD}$uname${NC} (40+ plataformas)${NC}"
    hr

    declare -A platforms
    platforms=(
        ["Twitter/X"]="https://twitter.com/${uname}"
        ["Instagram"]="https://www.instagram.com/${uname}"
        ["GitHub"]="https://github.com/${uname}"
        ["Reddit"]="https://www.reddit.com/user/${uname}"
        ["TikTok"]="https://www.tiktok.com/@${uname}"
        ["YouTube"]="https://www.youtube.com/@${uname}"
        ["Facebook"]="https://www.facebook.com/${uname}"
        ["LinkedIn"]="https://www.linkedin.com/in/${uname}"
        ["Pinterest"]="https://www.pinterest.com/${uname}"
        ["Twitch"]="https://www.twitch.tv/${uname}"
        ["Medium"]="https://medium.com/@${uname}"
        ["Dev.to"]="https://dev.to/${uname}"
        ["Keybase"]="https://keybase.io/${uname}"
        ["Patreon"]="https://www.patreon.com/${uname}"
        ["ProductHunt"]="https://www.producthunt.com/@${uname}"
        ["Behance"]="https://www.behance.net/${uname}"
        ["Dribbble"]="https://dribbble.com/${uname}"
        ["Flickr"]="https://www.flickr.com/people/${uname}"
        ["VK"]="https://vk.com/${uname}"
        ["Steam"]="https://steamcommunity.com/id/${uname}"
        ["Spotify"]="https://open.spotify.com/user/${uname}"
        ["Telegram"]="https://t.me/${uname}"
        ["Pastebin"]="https://pastebin.com/u/${uname}"
        ["HackerNews"]="https://news.ycombinator.com/user?id=${uname}"
        ["StackOverflow"]="https://stackoverflow.com/users/?search=${uname}"
        ["GitLab"]="https://gitlab.com/${uname}"
        ["BitBucket"]="https://bitbucket.org/${uname}"
        ["WordPress"]="https://${uname}.wordpress.com"
        ["Tumblr"]="https://${uname}.tumblr.com"
        ["About.me"]="https://about.me/${uname}"
        ["Imgur"]="https://imgur.com/user/${uname}"
        ["SlideShare"]="https://slideshare.net/${uname}"
        ["Gravatar"]="https://gravatar.com/${uname}"
        ["Linktree"]="https://linktr.ee/${uname}"
        ["BuyMeACoffee"]="https://buymeacoffee.com/${uname}"
        ["Kofi"]="https://ko-fi.com/${uname}"
        ["Replit"]="https://replit.com/@${uname}"
        ["CodePen"]="https://codepen.io/${uname}"
        ["HackTheBox"]="https://app.hackthebox.com/profile/${uname}"
        ["TryHackMe"]="https://tryhackme.com/p/${uname}"
        ["Mastodon.social"]="https://mastodon.social/@${uname}"
        ["Snapchat"]="https://www.snapchat.com/add/${uname}"
        ["WhatsApp"]="https://wa.me/${uname}"
        ["Signal"]="https://signal.me/#p/${uname}"
    )

    local found=0 total=${#platforms[@]} current=0
    for platform in "${!platforms[@]}"; do
        current=$((current+1))
        local url="${platforms[$platform]}"
        local agent="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36"
        local proxy_flag=""
        [[ -n "$PROXY" ]] && proxy_flag="--proxy $PROXY"
        [[ "$USE_TOR" == true ]] && proxy_flag="--proxy socks5h://127.0.0.1:9050"
        rand_delay
        local code
        code=$(timeout "$((TIMEOUT+2))" curl -s -o /dev/null -w "%{http_code}" --max-time "$TIMEOUT" \
            -H "User-Agent: $agent" -L $proxy_flag "$url" 2>/dev/null || echo "000")
        if [[ "$code" == "200" || "$code" == "301" || "$code" == "302" ]]; then
            echo -e "  ${GREEN}✓${NC} ${BOLD}$platform${NC} ${DIM}$url${NC}"
            log_result "Username" "$platform" "$url" "true" "HTTP $code"
            found=$((found+1))
        elif [[ $VERBOSE == true ]]; then
            dim "  − $platform (HTTP $code)"
        fi
    done
    if [[ $found -gt 0 ]]; then
        ok "Encontradas ${found}/${total} cuentas para '${uname}'"
    else
        warn "No se encontraron cuentas para '${uname}'"
    fi
}

# ═════════════════════════════════════════════════════════════════════════════
#  MÓDULO 7: Búsqueda de email (con scraping de páginas)
# ═════════════════════════════════════════════════════════════════════════════
search_email() {
    local email="$1"
    local domain="${email#*@}"
    local encoded; encoded=$(urlencode "$email")
    echo -e "\n${BOLD}${YELLOW}📧  EMAIL: ${BOLD}$email${NC}"
    hr

    # 1. Gravatar
    local hash; hash=$(echo -n "$email" | tr '[:upper:]' '[:lower:]' | md5sum | cut -d' ' -f1)
    local grav_url="https://www.gravatar.com/avatar/${hash}?d=404&s=200"
    local gcode; gcode=$(timeout 7 curl -s -o /dev/null -w "%{http_code}" --max-time 5 \
        $( [[ -n "$PROXY" ]] && echo "--proxy $PROXY" || true ) \
        $( [[ "$USE_TOR" == true ]] && echo "--proxy socks5h://127.0.0.1:9050" || true ) \
        "$grav_url" 2>/dev/null || echo "000")
    if [[ "$gcode" == "200" ]]; then
        ok "Gravatar: https://www.gravatar.com/${hash}"
        log_result "Email" "Gravatar" "https://www.gravatar.com/${hash}" "true"
    fi

    # 2. Have I Been Pwned (domain breaches)
    info "Breaches públicos para dominio $domain..."
    rand_delay
    local breaches; breaches=$(curl_wrap "https://haveibeenpwned.com/api/v3/breaches?domain=${domain}" 2>/dev/null) || true
    if echo "$breaches" | jq -e '. | length > 0' >/dev/null 2>&1; then
        echo "$breaches" | jq -r '.[] | "    ${RED}⚠${NC} \(.Name) — \(.BreachDate) — \(.Description[:80])..."' 2>/dev/null
        log_result "Email" "HIBP" "https://haveibeenpwned.com/" "true" "Breaches encontrados"
    else
        dim "    Sin breaches públicos conocidos"
        log_result "Email" "HIBP" "https://haveibeenpwned.com/" "false"
    fi

    # 3. Scrape Google for email
    info "Buscando email en web..."
    rand_delay
    local gg_results; gg_results=$(curl_wrap "https://www.google.com/search?q=%22${encoded}%22" 2>/dev/null || true)
    local links; links=$(echo "$gg_results" | grep -oP '(?<=<a href="/url\?q=)[^"&]+' 2>/dev/null | head -10)
    if [[ -n "$links" ]]; then
        echo "$links" | while IFS= read -r l; do
            echo -e "    ${CYAN}↗${NC} ${DIM}$l${NC}"
            log_result "Email" "Google" "$l" "true"
        done
    fi

    # 4. Extraer correos relacionados (nombre -> emails posibles)
    if [[ -n "$NAME" ]]; then
        local name_clean; name_clean=$(echo "$NAME" | tr '[:upper:]' '[:lower:]' | sed 's/ //g')
        info "Posibles emails generados:"
        for dom in gmail.com yahoo.com hotmail.com outlook.com protonmail.com "${domain}"; do
            echo -e "    ${DIM}${name_clean}@${dom}${NC}"
            log_result "Email" "Generado" "" "true" "${name_clean}@${dom}"
        done
    fi
}

# ═════════════════════════════════════════════════════════════════════════════
#  MÓDULO 8: Búsqueda por teléfono
# ═════════════════════════════════════════════════════════════════════════════
search_phone() {
    local phone="$1"
    local digits; digits=$(echo "$phone" | sed 's/[^0-9]//g')
    local encoded; encoded=$(urlencode "$phone")
    echo -e "\n${BOLD}${RED}📞  TELÉFONO: ${BOLD}$phone${NC}"
    hr

    # 1. Google para el número
    info "Buscando en Google..."
    rand_delay
    local gres; gres=$(curl_wrap "https://www.google.com/search?q=%22${encoded}%22" 2>/dev/null || true)
    local links; links=$(echo "$gres" | grep -oP '(?<=<a href="/url\?q=)[^"&]+' 2>/dev/null | head -12)
    if [[ -n "$links" ]]; then
        echo "$links" | while IFS= read -r l; do
            echo -e "    ${CYAN}↗${NC} ${DIM}$l${NC}"
            log_result "Phone" "Google" "$l" "true"
        done
    fi

    # 2. WhatsApp
    local wa_url="https://wa.me/${digits}"
    local wcode; wcode=$(timeout 7 curl -s -o /dev/null -w "%{http_code}" --max-time 5 \
        $( [[ -n "$PROXY" ]] && echo "--proxy $PROXY" || true ) \
        $( [[ "$USE_TOR" == true ]] && echo "--proxy socks5h://127.0.0.1:9050" || true ) \
        -L "https://api.whatsapp.com/send?phone=${digits}" 2>/dev/null || echo "000")
    if [[ "$wcode" != "404" && "$wcode" != "000" ]]; then
        ok "Posible WhatsApp: ${wa_url}"
        log_result "Phone" "WhatsApp" "$wa_url" "true" "HTTP $wcode"
    fi

    # 3. Telegram
    local tg_url="https://t.me/+${digits}"
    local tcode; tcode=$(timeout 7 curl -s -o /dev/null -w "%{http_code}" --max-time 5 \
        $( [[ -n "$PROXY" ]] && echo "--proxy $PROXY" || true ) \
        $( [[ "$USE_TOR" == true ]] && echo "--proxy socks5h://127.0.0.1:9050" || true ) \
        -L "$tg_url" 2>/dev/null || echo "000")
    if [[ "$tcode" == "200" || "$tcode" == "302" ]]; then
        ok "Teléfono en Telegram: ${tg_url}"
        log_result "Phone" "Telegram" "$tg_url" "true"
    fi

    # 4. Reverse phone lookups via search
    info "Buscando en directorios telefónicos..."
    local rev_sites=(
        "https://www.google.com/search?q=%22${encoded}%22+%22phone%22+%22address%22"
        "https://www.google.com/search?q=%22${encoded}%22+%22spam%22+OR+%22caller%22"
        "https://lite.duckduckgo.com/lite/?q=%22${phone// /}%22+telephone"
    )
    for site in "${rev_sites[@]}"; do
        rand_delay
        curl_wrap "$site" 2>/dev/null | grep -oP '(?<=<a href=")[^"]+(?=" class="result-link")|(?<=<a href="/url\?q=)[^"&]+' 2>/dev/null | head -5 || true
    done
}

# ═════════════════════════════════════════════════════════════════════════════
#  MÓDULO 9: Noticias
# ═════════════════════════════════════════════════════════════════════════════
search_news() {
    local query="$1"
    local encoded; encoded=$(urlencode "$query")
    echo -e "\n${BOLD}${CYAN}📰  NOTICIAS${NC}"
    hr

    # Google News
    info "Google News..."
    rand_delay
    local html; html=$(curl_wrap "https://news.google.com/search?q=${encoded}&hl=en-US&gl=US&ceid=US:en" 2>/dev/null || true)
    # Google News uses different selectors, try to extract article URLs
    local articles; articles=$(echo "$html" | grep -oP 'href="\./articles/[^"]+' 2>/dev/null | head -10)
    if [[ -n "$articles" ]]; then
        echo "$articles" | while IFS= read -r a; do
            local full="https://news.google.com${a#href=\"}"
            echo -e "    ${CYAN}↗${NC} ${DIM}$full${NC}"
            log_result "News" "GoogleNews" "$full" "true"
        done
    else
        dim "    Sin resultados en Google News"
    fi

    # DuckDuckGo News
    info "DuckDuckGo News..."
    rand_delay
    local ddgn; ddgn=$(curl_wrap "https://lite.duckduckgo.com/lite/?q=${encoded}+%28news%29" 2>/dev/null || true)
    local ddgn_l; ddgn_l=$(echo "$ddgn" | grep -oP '(?<=<a href=")[^"]+(?=" class="result-link")' 2>/dev/null | head -10)
    if [[ -n "$ddgn_l" ]]; then
        echo "$ddgn_l" | while IFS= read -r l; do
            echo -e "    ${CYAN}↗${NC} ${DIM}$l${NC}"
            log_result "News" "DDG" "$l" "true"
        done
    fi
}

# ═════════════════════════════════════════════════════════════════════════════
#  MÓDULO 10: Imágenes (incluye reverse image search)
# ═════════════════════════════════════════════════════════════════════════════
search_images() {
    local query="$1"
    local encoded; encoded=$(urlencode "$query")
    echo -e "\n${BOLD}${GREEN}🖼️  IMÁGENES${NC}"
    hr

    # Google Images
    info "Google Images..."
    rand_delay
    local img_html; img_html=$(curl_wrap "https://www.google.com/search?tbm=isch&q=${encoded}" 2>/dev/null || true)
    local urls; urls=$(echo "$img_html" | grep -oP 'src="https?://[^"]+' 2>/dev/null | head -10 || true)
    if [[ -n "$urls" ]]; then
        echo "$urls" | while IFS= read -r u; do
            u="${u#src=\"}"
            echo -e "    ${DIM}$u${NC}"
            log_result "Images" "GoogleImages" "$u" "true"
        done
    else
        dim "    No se pudieron extraer URLs de imágenes"
    fi

    # DuckDuckGo Images
    info "DuckDuckGo Images..."
    rand_delay
    local ddi; ddi=$(curl_wrap "https://lite.duckduckgo.com/lite/?q=${encoded}+image" 2>/dev/null || true)
    local ddi_l; ddi_l=$(echo "$ddi" | grep -oP '(?<=<a href=")[^"]+(?=" class="result-link")' 2>/dev/null | head -10)
    if [[ -n "$ddi_l" ]]; then
        echo "$ddi_l" | while IFS= read -r l; do
            echo -e "    ${CYAN}↗${NC} ${DIM}$l${NC}"
            log_result "Images" "DDG" "$l" "true"
        done
    fi

    # Reverse image search hint
    echo -e "\n    ${DIM}Para búsqueda inversa de imágenes, usa:$NC"
    echo -e "    ${DIM}  https://images.google.com/searchbyimage?image_url=URL${NC}"
    echo -e "    ${DIM}  https://tineye.com/search?url=URL${NC}"
    echo -e "    ${DIM}  https://yandex.com/images/search?url=URL&rpt=imageview${NC}"
}

# ═════════════════════════════════════════════════════════════════════════════
#  MÓDULO 11: Documentos
# ═════════════════════════════════════════════════════════════════════════════
search_docs() {
    local query="$1"
    local encoded; encoded=$(urlencode "\"$query\"")
    echo -e "\n${BOLD}${YELLOW}📄  DOCUMENTOS${NC}"
    hr

    local -a types=("pdf" "doc" "docx" "xls" "xlsx" "ppt" "pptx" "txt" "csv" "odt")
    for type in "${types[@]}"; do
        info "Buscando .${type}..."
        rand_delay
        local url="https://www.google.com/search?q=${encoded}+filetype%3A${type}"
        local html; html=$(curl_wrap "$url" 2>/dev/null || true)
        local links; links=$(echo "$html" | grep -oP '(?<=<a href="/url\?q=)[^"&]+' 2>/dev/null | head -3)
        if [[ -n "$links" ]]; then
            echo "$links" | while IFS= read -r l; do
                echo -e "    ${CYAN}↗${NC} ${DIM}$l${NC}"
                log_result "Docs" ".${type}" "$l" "true"
            done
        else
            dim "    (sin resultados .${type})"
        fi
    done
}

# ═════════════════════════════════════════════════════════════════════════════
#  MÓDULO 12: Deep Web / Pastebin / Foros
# ═════════════════════════════════════════════════════════════════════════════
deep_search() {
    local query="$1"
    local encoded; encoded=$(urlencode "\"$query\"")
    echo -e "\n${BOLD}${RED}🔥  BÚSQUEDA PROFUNDA${NC}"
    hr

    # Pastebin
    info "Pastebin..."
    rand_delay
    curl_wrap "https://www.google.com/search?q=site%3Apastebin.com+${encoded}" 2>/dev/null \
        | grep -oP '(?<=<a href="/url\?q=)[^"&]+' 2>/dev/null | head -10 \
        | while IFS= read -r l; do echo -e "    ${CYAN}↗${NC} ${DIM}$l${NC}"; log_result "Deep" "Pastebin" "$l" "true"; done || true

    # Archive.org
    info "Archive.org (Wayback Machine)..."
    local arch_url="https://web.archive.org/web/*/${encoded}"
    echo -e "    ${DIM}$arch_url${NC}"
    log_result "Deep" "Archive" "$arch_url" "true"

    # Hastebin
    info "Hastebin..."
    rand_delay
    curl_wrap "https://www.google.com/search?q=site%3Ahastebin.com+${encoded}" 2>/dev/null \
        | grep -oP '(?<=<a href="/url\?q=)[^"&]+' 2>/dev/null | head -5 \
        | while IFS= read -r l; do echo -e "    ${CYAN}↗${NC} ${DIM}$l${NC}"; log_result "Deep" "Hastebin" "$l" "true"; done || true

    # DocumentCloud
    info "DocumentCloud..."
    rand_delay
    curl_wrap "https://www.google.com/search?q=site%3A.documentcloud.org+${encoded}" 2>/dev/null \
        | grep -oP '(?<=<a href="/url\?q=)[^"&]+' 2>/dev/null | head -5 \
        | while IFS= read -r l; do echo -e "    ${CYAN}↗${NC} ${DIM}$l${NC}"; log_result "Deep" "DocCloud" "$l" "true"; done || true

    # Google Groups / Foros
    info "Foros públicos..."
    rand_delay
    curl_wrap "https://www.google.com/search?q=site%3Agroups.google.com+${encoded}+OR+site%3Aquora.com+${encoded}+OR+site%3Astackexchange.com+${encoded}" 2>/dev/null \
        | grep -oP '(?<=<a href="/url\?q=)[^"&]+' 2>/dev/null | head -15 \
        | while IFS= read -r l; do echo -e "    ${CYAN}↗${NC} ${DIM}$l${NC}"; log_result "Deep" "Forums" "$l" "true"; done || true
}

# ═════════════════════════════════════════════════════════════════════════════
#  MÓDULO 13: Búsqueda de dominios
# ═════════════════════════════════════════════════════════════════════════════
search_domains() {
    local name="$1"
    local clean; clean=$(echo "$name" | tr '[:upper:]' '[:lower:]' | sed 's/ //g; s/[^a-z0-9]//g')
    echo -e "\n${BOLD}${MAGENTA}🌍  DOMINIOS${NC}"
    hr

    local tlds=("com" "net" "org" "io" "me" "co" "dev" "app" "info")
    for tld in "${tlds[@]}"; do
        local domain="${clean}.${tld}"
        rand_delay
        local rdap_url="https://rdap.verisign.com/com/v1/domain/${domain}"
        local resp; resp=$(timeout 10 curl -s --max-time 8 "$rdap_url" 2>/dev/null || echo "{}")
        if echo "$resp" | jq -r '.handle' 2>/dev/null | grep -q .; then
            echo -e "  ${GREEN}✓${NC} ${BOLD}$domain${NC} ${DIM}(registrado)${NC}"
            log_result "Domain" "$domain" "https://${domain}" "true"
        else
            dim "  − $domain (disponible)"
        fi
    done
}

# ═════════════════════════════════════════════════════════════════════════════
#  MÓDULO 14: Extracción de emails desde resultados web
# ═════════════════════════════════════════════════════════════════════════════
extract_emails() {
    local query="$1"
    echo -e "\n${BOLD}${YELLOW}📨  EXTRACCIÓN DE EMAILS${NC}"
    hr
    info "Rastreando web en busca de patrones de email..."
    local encoded; encoded=$(urlencode "\"$query\" email OR contacto OR contact")
    rand_delay
    local html; html=$(curl_wrap "https://lite.duckduckgo.com/lite/?q=${encoded}" 2>/dev/null || true)
    local urls; urls=$(echo "$html" | grep -oP '(?<=<a href=")[^"]+(?=" class="result-link")' 2>/dev/null | head -10)
    if [[ -n "$urls" ]]; then
        echo "$urls" | while IFS= read -r url; do
            rand_delay
            local page; page=$(curl_wrap "$url" 2>/dev/null || true)
            local emails; emails=$(echo "$page" | grep -oP '[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}' 2>/dev/null | sort -u | head -5)
            if [[ -n "$emails" ]]; then
                echo -e "  ${GREEN}✓${NC} ${BOLD}$url${NC}"
                echo "$emails" | while IFS= read -r em; do
                    echo -e "    ${DIM}$em${NC}"
                    log_result "EmailExtract" "$url" "" "true" "$em"
                done
            fi
        done
    fi
}

# ═════════════════════════════════════════════════════════════════════════════
#  Generar reporte HTML (si --html)
# ═════════════════════════════════════════════════════════════════════════════
generate_html() {
    [[ -z "$RESULTS_DIR" || "$HTML_REPORT" != true ]] && return
    local txt="${RESULTS_DIR}/resultados.txt"
    local html="${RESULTS_DIR}/reporte.html"
    if command -v pandoc &>/dev/null; then
        (
            echo "# buscapersona.sh v${VERSION}"
            echo "**Fecha:** $(date '+%Y-%m-%d %H:%M:%S')"
            echo ""
            echo "## Datos de búsqueda"
            [[ -n "$NAME" ]] && echo "* Nombre: $NAME"
            [[ -n "$USERNAME" ]] && echo "* Usuario: $USERNAME"
            [[ -n "$EMAIL" ]] && echo "* Email: $EMAIL"
            [[ -n "$PHONE" ]] && echo "* Teléfono: $PHONE"
            echo ""
            echo "<pre>"
            cat "$txt"
            echo "</pre>"
        ) > "${RESULTS_DIR}/reporte.md"
        pandoc "${RESULTS_DIR}/reporte.md" -o "$html" --self-contained --metadata title="Reporte OSINT" 2>/dev/null && \
            ok "Reporte HTML: $html" || warn "No se pudo generar HTML (pandoc error)"
    else
        # Fallback: HTML manual
        {
            echo "<!DOCTYPE html><html><head><meta charset='utf-8'>"
            echo "<title>Reporte OSINT - buscapersona.sh</title>"
            echo "<style>body{font-family:sans-serif;max-width:900px;margin:2em auto;background:#1a1a2e;color:#e0e0e0;}"
            echo "pre{background:#16213e;padding:1em;border-radius:8px;overflow-x:auto;}"
            echo "h1{color:#e94560;} h2{color:#0f3460;} .ok{color:#4ecca3;} .no{color:#666;}</style></head><body>"
            echo "<h1>🔍 Reporte OSINT — buscapersona.sh v${VERSION}</h1>"
            echo "<p><strong>Fecha:</strong> $(date '+%Y-%m-%d %H:%M:%S')</p>"
            echo "<h2>Datos buscados</h2><ul>"
            [[ -n "$NAME" ]] && echo "<li><strong>Nombre:</strong> $NAME</li>"
            [[ -n "$USERNAME" ]] && echo "<li><strong>Usuario:</strong> $USERNAME</li>"
            [[ -n "$EMAIL" ]] && echo "<li><strong>Email:</strong> $EMAIL</li>"
            [[ -n "$PHONE" ]] && echo "<li><strong>Teléfono:</strong> $PHONE</li>"
            echo "</ul><h2>Resultados</h2><pre>"
            cat "$txt"
            echo "</pre></body></html>"
        } > "$html"
        ok "Reporte HTML: $html (sin pandoc)"
    fi
}

# ═════════════════════════════════════════════════════════════════════════════
#  Resumen final
# ═════════════════════════════════════════════════════════════════════════════
generate_report() {
    echo -e "\n${BOLD}${GREEN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${GREEN}  ✅ BÚSQUEDA COMPLETADA${NC}"
    echo -e "${BOLD}${GREEN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "\n  ${BOLD}Resumen:${NC}"
    [[ -n "$NAME" ]]     && echo -e "    ${CYAN}Nombre:${NC}     $NAME"
    [[ -n "$USERNAME" ]] && echo -e "    ${CYAN}Usuario:${NC}    $USERNAME"
    [[ -n "$EMAIL" ]]    && echo -e "    ${CYAN}Email:${NC}      $EMAIL"
    [[ -n "$PHONE" ]]    && echo -e "    ${CYAN}Teléfono:${NC}   $PHONE"
    [[ -n "$RESULTS_DIR" ]] && echo -e "\n    ${GREEN}Reportes:${NC}"
    [[ -n "$RESULTS_DIR" ]] && echo -e "      • ${RESULTS_DIR}/resultados.txt"
    [[ -n "$RESULTS_DIR" ]] && [[ "$HTML_REPORT" == true ]] && echo -e "      • ${RESULTS_DIR}/reporte.html"

    # Final summary to results file
    if [[ -n "$RESULTS_DIR" ]]; then
        echo "--- FIN DEL REPORTE ---" >> "${RESULTS_DIR}/resultados.txt"
        echo "Generado: $(date '+%Y-%m-%d %H:%M:%S')" >> "${RESULTS_DIR}/resultados.txt"
    fi

    echo -e "\n${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${DIM}  ⚠ Solo para uso educativo o con autorización explícita.${NC}"
    echo -e "${DIM}  Respeta privacidad y leyes aplicables.${NC}"
    echo -e "${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

# ═════════════════════════════════════════════════════════════════════════════
#  MAIN
# ═════════════════════════════════════════════════════════════════════════════
main() {
    banner
    check_internet || true

    if [[ "$ALL" == true ]]; then
        DORKS=true
        SOCIAL=true
        WEB=true
        HTML_REPORT=true
    fi

    # ── Búsqueda por nombre ──
    if [[ -n "$NAME" ]]; then
        [[ "$SOCIAL" != true && "$WEB" != true ]] && WEB=true  # default si no se especifica modo
        if [[ "$WEB" == true ]]; then
            duckduckgo_api "$NAME" || true
            duckduckgo_lite "$NAME" || true
            bing_search "$NAME" 2 || true
        fi
        if [[ "$SOCIAL" == true ]]; then
            search_social || true
        fi
        if [[ "$ALL" == true || "$DORKS" == true ]]; then
            google_dorks "$NAME" || true
        fi
        search_news "$NAME" || true
        search_images "$NAME" || true
        search_docs "$NAME" || true
        deep_search "$NAME" || true
        search_domains "$NAME" || true
        extract_emails "$NAME" || true
    fi

    # ── Búsqueda por username ──
    if [[ -n "$USERNAME" ]]; then
        search_username "$USERNAME" || true
    fi

    # ── Búsqueda por email ──
    if [[ -n "$EMAIL" ]]; then
        search_email "$EMAIL" || true
    fi

    # ── Búsqueda por teléfono ──
    if [[ -n "$PHONE" ]]; then
        search_phone "$PHONE" || true
    fi

    # ── Reporte ──
    generate_html || true
    generate_report || true
}

main
