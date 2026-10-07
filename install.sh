#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════
#  Remnawave Installer — интерактивная установка Remnawave «под ключ»
#
#  Панель · страница подписок · ноды (VLESS Reality) · Caddy + SSL
#
#    bash <(curl -fsSL https://raw.githubusercontent.com/h1gurodev/remnawave-installer/main/install.sh)
#
#  Аргументы не нужны — скрипт сам спросит, что и куда ставить.
#  Неофициальный проект, с командой Remnawave не связан.
# ══════════════════════════════════════════════════════════════════════

if [ -z "${BASH_VERSION:-}" ]; then
  echo "Запусти через bash:  bash install.sh" >&2
  exit 1
fi
if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 2) )); then
  echo "Нужен bash 4.2 или новее" >&2
  exit 1
fi

shopt -s extglob
set -o pipefail

RWI_VERSION="1.0.0"
RWI_RAW="https://raw.githubusercontent.com/h1gurodev/remnawave-installer/main/install.sh"

PANEL_DIR=${RWI_PANEL_DIR:-/opt/remnawave}
SUB_DIR=$PANEL_DIR/subscription
CADDY_DIR=$PANEL_DIR/caddy
NODE_DIR=${RWI_NODE_DIR:-/opt/remnanode}
BACKUP_DIR=${RWI_BACKUP_DIR:-/root/remnawave-backups}
CRED_FILE=${RWI_CRED_FILE:-/root/remnawave-credentials.txt}
LOG_FILE=${RWI_LOG_FILE:-/var/log/remnawave-installer.log}

PANEL_API_LOCAL="http://127.0.0.1:3000"
UPSTREAM_COMPOSE="https://raw.githubusercontent.com/remnawave/backend/refs/heads/main/docker-compose-prod.yml"
UPSTREAM_ENV="https://raw.githubusercontent.com/remnawave/backend/refs/heads/main/.env.sample"

ANIM=1
[[ -n ${RWI_NO_ANIM:-} ]] && ANIM=0
COLS=80
SPIN_PID=""
STATUS_FILE=""
STEP=0
STEPS=0
STEPTAG=""
SKIPPED=()
USED_DOMAINS=()
PAL=()

# ═════════════════════════════ терминал ═════════════════════════════

_fix_locale() {
  local cur="${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" l
  [[ ${cur,,} == *utf?(-)8* ]] && return 0
  l=$(locale -a 2>/dev/null | grep -iE '^(c|en_us)\.utf-?8$' | head -n1)
  [[ -n $l ]] && export LC_ALL=$l
  return 0
}

_init_term() {
  local sz
  if sz=$( { stty size </dev/tty; } 2>/dev/null ); then COLS=${sz##* }; fi
  [[ $COLS =~ ^[0-9]+$ ]] && (( COLS >= 20 )) || COLS=80

  COLOR=1
  [[ -n ${NO_COLOR:-} || ${TERM:-dumb} == dumb ]] && COLOR=0
  TRUECOLOR=0
  [[ ${COLORTERM:-} == @(truecolor|24bit) || ${RWI_TRUECOLOR:-} == 1 ]] && TRUECOLOR=1

  if (( COLOR )); then
    N=$'\e[0m' BLD=$'\e[1m' DIM=$'\e[2m'
    if (( TRUECOLOR )); then
      CY=$'\e[38;2;0;229;255m'  VI=$'\e[38;2;150;120;255m' PK=$'\e[38;2;255;79;216m'
      GR=$'\e[38;2;46;230;140m' YE=$'\e[38;2;255;200;60m'  RD=$'\e[38;2;255;84;104m'
      MU=$'\e[38;2;128;138;160m' WH=$'\e[38;2;240;244;255m'
      SEL=$'\e[1;38;2;255;255;255;48;2;110;80;255m'
    else
      CY=$'\e[38;5;51m' VI=$'\e[38;5;141m' PK=$'\e[38;5;205m'
      GR=$'\e[38;5;48m' YE=$'\e[38;5;221m' RD=$'\e[38;5;203m'
      MU=$'\e[38;5;245m' WH=$'\e[38;5;231m'
      SEL=$'\e[1;97;48;5;99m'
    fi
  else
    N='' BLD='' DIM='' CY='' VI='' PK='' GR='' YE='' RD='' MU='' WH='' SEL=''
    ANIM=0
  fi
}

_sleep() { (( ANIM )) && sleep "$1"; return 0; }
_hide()  { (( COLOR )) && printf '\e[?25l'; return 0; }
_show()  { (( COLOR )) && printf '\e[?25h'; return 0; }

_tty_raw_on()  { _STTY=$( { stty -g </dev/tty; } 2>/dev/null ); { stty -echo </dev/tty; } 2>/dev/null; return 0; }
_tty_raw_off() { [[ -n ${_STTY:-} ]] && { stty "$_STTY" </dev/tty; } 2>/dev/null; _STTY=""; return 0; }

# видимая длина строки (без ANSI-кодов) → REPLY
_vlen() { local s=${1//$'\e'\[*([0-9;])m/}; REPLY=${#s}; }

# ═══════════════════════════ цвет и градиент ════════════════════════

GRAD256=(51 45 39 33 63 99 135 171 207 213)

# grad <0..1000> → REPLY = escape-код цвета (бирюзовый → фиолетовый → розовый)
grad() {
  (( COLOR )) || { REPLY=''; return; }
  local t=$1 r g b u
  (( t < 0 )) && t=0
  (( t > 1000 )) && t=1000
  if (( TRUECOLOR )); then
    if (( t < 500 )); then
      u=$(( t * 2 ))
      r=$(( 124 * u / 1000 )); g=$(( 229 - 137 * u / 1000 )); b=255
    else
      u=$(( (t - 500) * 2 ))
      r=$(( 124 + 131 * u / 1000 )); g=$(( 92 - 13 * u / 1000 )); b=$(( 255 - 39 * u / 1000 ))
    fi
    REPLY=$'\e[38;2;'"${r};${g};${b}m"
  else
    REPLY=$'\e[38;5;'"${GRAD256[t * 9 / 1000]}m"
  fi
}

# _pal <ширина> [сдвиг] → PAL[x] — цвет для каждой колонки
_pal() {
  local w=$1 sh=${2:-0} x t d
  PAL=()
  d=$(( w > 1 ? w - 1 : 1 ))
  for (( x = 0; x < w; x++ )); do
    t=$(( (x * 1000 / d + sh) % 2000 ))
    (( t > 1000 )) && t=$(( 2000 - t ))
    grad "$t"
    PAL[x]=$REPLY
  done
}

# gtext "строка" [сдвиг] → REPLY = строка с градиентом
gtext() {
  local s=$1 out='' x ch
  (( COLOR )) || { REPLY=$s; return; }
  _pal "${#s}" "${2:-0}"
  for (( x = 0; x < ${#s}; x++ )); do
    ch=${s:x:1}
    if [[ $ch == ' ' ]]; then out+=' '; else out+="${PAL[x]}$ch"; fi
  done
  REPLY="$out$N"
}

# ═════════════════════════════ вывод ════════════════════════════════

say()  { printf '  %s\n' "$*"; }
info() { printf '  %s●%s %s\n' "$CY" "$N" "$*"; }
ok()   { printf '  %s✔%s %s\n' "$GR" "$N" "$*"; }
warn() { printf '  %s▲%s %s\n' "$YE" "$N" "$*"; }
err()  { printf '  %s✖%s %s\n' "$RD" "$N" "$*"; }
hint() { printf '    %s%s%s\n' "$MU" "$*" "$N"; }

die() {
  _spin_kill
  _tty_raw_off
  printf '\n'
  err "$*"
  printf '\n'
  exit 1
}

center() {
  local pad
  _vlen "$1"
  pad=$(( (COLS - REPLY) / 2 ))
  (( pad < 2 )) && pad=2
  printf '%*s%s\n' "$pad" '' "$1"
}

typeout() {
  local s=$1 d=${2:-0.01} i
  if (( ! ANIM )); then printf '%s' "$s"; return; fi
  for (( i = 0; i < ${#s}; i++ )); do
    printf '%s' "${s:i:1}"
    sleep "$d"
  done
}

section() {
  local t=" $1 " w rule
  w=$(( COLS > 76 ? 72 : COLS - 4 ))
  _vlen "$t"
  printf -v rule '%*s' $(( w - REPLY - 3 > 2 ? w - REPLY - 3 : 2 )) ''
  rule=${rule// /━}
  gtext "━━━$t$rule"
  printf '\n  %s\n' "$REPLY"
}

# kv "Ключ" "значение" → REPLY (выровненная строка для box)
kv() {
  local p
  printf -v p '%*s' $(( 12 - ${#1} > 1 ? 12 - ${#1} : 1 )) ''
  REPLY="${MU}$1${N}${p}$2"
}

# box "Заголовок" "строка" ...
box() {
  local title=$1 w=0 l tw inner rule pad
  shift
  _vlen "$title"; tw=$REPLY
  for l in "$@"; do _vlen "$l"; (( REPLY > w )) && w=$REPLY; done
  (( w < tw + 4 )) && w=$(( tw + 4 ))
  inner=$(( w + 2 ))
  printf -v rule '%*s' $(( inner - tw - 3 )) ''
  rule=${rule// /─}
  gtext "╭─ $title $rule╮"
  printf '  %s\n' "$REPLY"
  for l in "$@"; do
    _vlen "$l"
    printf -v pad '%*s' $(( w - REPLY )) ''
    printf '  %s│%s %s%s%s %s│%s\n' "$CY" "$N" "$l" "$N" "$pad" "$PK" "$N"
  done
  printf -v rule '%*s' "$inner" ''
  rule=${rule// /─}
  gtext "╰$rule╯"
  printf '  %s\n' "$REPLY"
}

# ═════════════════════════════ анимации ═════════════════════════════

_banner_big() {
  local -a gR=("██████╗ " "██╔══██╗" "██████╔╝" "██╔══██╗" "██║  ██║" "╚═╝  ╚═╝")
  local -a gE=("███████╗" "██╔════╝" "█████╗  " "██╔══╝  " "███████╗" "╚══════╝")
  local -a gM=("███╗   ███╗" "████╗ ████║" "██╔████╔██║" "██║╚██╔╝██║" "██║ ╚═╝ ██║" "╚═╝     ╚═╝")
  local -a gN=("███╗   ██╗" "████╗  ██║" "██╔██╗ ██║" "██║╚██╗██║" "██║ ╚████║" "╚═╝  ╚═══╝")
  local -a gA=(" █████╗ " "██╔══██╗" "███████║" "██╔══██║" "██║  ██║" "╚═╝  ╚═╝")
  local -a gW=("██╗    ██╗" "██║    ██║" "██║ █╗ ██║" "██║███╗██║" "╚███╔███╔╝" " ╚══╝╚══╝ ")
  local -a gV=("██╗   ██╗" "██║   ██║" "██║   ██║" "╚██╗ ██╔╝" " ╚████╔╝ " "  ╚═══╝  ")
  local r
  BANNER=()
  for r in 0 1 2 3 4 5; do
    BANNER+=("${gR[r]}${gE[r]}${gM[r]}${gN[r]}${gA[r]}${gW[r]}${gA[r]}${gV[r]}${gE[r]}")
  done
}

_banner_small() {
  BANNER=(
    "┏━┓┏━╸┏┳┓┏┓╻┏━┓╻ ╻┏━┓╻ ╻┏━╸"
    "┣┳┛┣╸ ┃┃┃┃┗┫┣━┫┃╻┃┣━┫┃┏┛┣╸ "
    "╹┗╸┗━╸╹ ╹╹ ╹╹ ╹┗┻┛╹ ╹┗┛ ┗━╸"
  )
}

_banner_line() {
  local sp=$1 line=$2 out='' x ch
  for (( x = 0; x < ${#line}; x++ )); do
    ch=${line:x:1}
    if [[ $ch == ' ' ]]; then out+=' '; else out+="${PAL[x]}$ch"; fi
  done
  printf '\r%s%s%s\e[K\n' "$sp" "$out" "$N"
}

# баннер: построчное появление, затем градиент «переливается» один круг
show_banner() {
  local w sp f i nl
  _banner_big
  (( COLS < ${#BANNER[0]} + 4 )) && _banner_small
  w=${#BANNER[0]}
  nl=${#BANNER[@]}
  printf -v sp '%*s' $(( (COLS - w) / 2 > 1 ? (COLS - w) / 2 : 1 )) ''
  _hide
  _pal "$w" 0
  for (( i = 0; i < nl; i++ )); do
    _banner_line "$sp" "${BANNER[i]}"
    _sleep 0.035
  done
  if (( ANIM )); then
    for (( f = 1; f <= 20; f++ )); do
      printf '\e[%dA' "$nl"
      _pal "$w" $(( f * 100 ))
      for (( i = 0; i < nl; i++ )); do _banner_line "$sp" "${BANNER[i]}"; done
      sleep 0.025
    done
  fi
  _show
}

WAVE_CH=(▁ ▂ ▃ ▄ ▅ ▆ ▇ █)
WAVE_P=(0 1 2 3 4 5 6 7 7 6 5 4 3 2 1 0)

# wave <кадров> <ширина> — волна-эквалайзер (Remna*wave*)
wave() {
  local frames=${1:-24} w=${2:-48} f x lvl out sp
  (( w < 8 )) && w=8
  printf -v sp '%*s' $(( (COLS - w) / 2 > 1 ? (COLS - w) / 2 : 1 )) ''
  _pal "$w" 0
  if (( ! COLOR )); then printf '\n'; return; fi
  (( ANIM )) || frames=1
  _hide
  for (( f = 0; f < frames; f++ )); do
    out=''
    for (( x = 0; x < w; x++ )); do
      lvl=${WAVE_P[((x - f) % 16 + 16) % 16]}
      out+="${PAL[x]}${WAVE_CH[lvl]}"
    done
    printf '\r%s%s%s' "$sp" "$out" "$N"
    _sleep 0.04
  done
  printf '\n'
  _show
}

intro() {
  local sub w
  (( COLOR )) && printf '\e[2J\e[H'
  printf '\n'
  show_banner
  printf '\n'
  sub="панель · страница подписок · ноды · SSL — всё одной командой"
  _vlen "$sub"
  printf '%*s%s' $(( (COLS - REPLY) / 2 > 2 ? (COLS - REPLY) / 2 : 2 )) '' "$WH"
  typeout "$sub" 0.008
  printf '%s\n' "$N"
  center "${MU}Remnawave Installer v${RWI_VERSION} · неофициальный${N}"
  printf '\n'
  w=$(( COLS > 66 ? 58 : COLS - 8 ))
  wave 26 "$w"
}

# ═══════════════════════════ спиннер и шаги ═════════════════════════

status() { [[ -n $STATUS_FILE ]] && printf '%s' "$*" >"$STATUS_FILE"; return 0; }

_spinner() {
  trap 'exit 0' TERM
  local i=0 st t0=$SECONDS t max line
  local -a F=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
  _vlen "$STEPTAG"
  max=$(( COLS - REPLY - ${#SPIN_TITLE} - 18 ))
  while :; do
    st=''
    [[ -s $STATUS_FILE ]] && IFS= read -r st <"$STATUS_FILE"
    if (( max < 6 )); then st=''; elif (( ${#st} > max )); then st="${st:0:max-1}…"; fi
    t=$(( (i * 40) % 2000 )); (( t > 1000 )) && t=$(( 2000 - t ))
    grad "$t"
    line="  ${STEPTAG}${REPLY}${F[i % 10]}${N} ${SPIN_TITLE}"
    [[ -n $st ]] && line+=" ${MU}· ${st}${N}"
    line+=" ${DIM}$(( SECONDS - t0 ))s${N}"
    printf '\r\e[2K%s' "$line"
    sleep 0.08
    i=$(( i + 1 ))
  done
}

spin_start() {
  SPIN_TITLE=$1
  SPIN_T0=$SECONDS
  : >"$STATUS_FILE"
  if (( COLOR )); then
    _hide
    _spinner &
    SPIN_PID=$!
  else
    printf '  %s… %s\n' "$STEPTAG" "$SPIN_TITLE"
  fi
}

_spin_kill() {
  if [[ -n ${SPIN_PID:-} ]]; then
    kill "$SPIN_PID" 2>/dev/null
    wait "$SPIN_PID" 2>/dev/null
    SPIN_PID=""
    (( COLOR )) && printf '\r\e[2K'
  fi
  return 0
}

spin_stop() {
  local rc=$1 dt=$(( SECONDS - SPIN_T0 ))
  _spin_kill
  if (( rc == 0 )); then
    printf '  %s%s✔%s %s %s%ss%s\n' "$STEPTAG" "$GR" "$N" "$SPIN_TITLE" "$DIM" "$dt" "$N"
  else
    printf '  %s%s✖%s %s\n' "$STEPTAG" "$RD" "$N" "$SPIN_TITLE"
  fi
  _show
}

# spin_run "Заголовок" функция [аргументы] — со спиннером, вывод — в лог
spin_run() {
  local title=$1 rc
  shift
  printf '\n──── %s · %s\n' "$(date '+%F %T')" "$title" >>"$LOG_FILE"
  spin_start "$title"
  "$@" >>"$LOG_FILE" 2>&1 </dev/null
  rc=$?
  spin_stop "$rc"
  return "$rc"
}

_steptag() {
  local cells=10 f i s=''
  if (( STEPS <= 0 )); then STEPTAG=''; return; fi
  f=$(( STEP * cells / STEPS ))
  _pal "$cells" 0
  for (( i = 0; i < cells; i++ )); do
    if (( i < f )); then s+="${PAL[i]}▰"; else s+="${MU}▱"; fi
  done
  printf -v STEPTAG '%s%s %s%02d/%02d%s  ' "$s" "$N" "$MU" "$STEP" "$STEPS" "$N"
}

# step "Заголовок" функция [аргументы] — шаг установки с повтором при ошибке
step() {
  local title=$1
  shift
  STEP=$(( STEP + 1 ))
  _steptag
  while :; do
    spin_run "$title" "$@" && return 0
    _step_failed "$title" "$1" || return 1
  done
}

_step_failed() {
  local title=$1 fn=$2 l c
  local -a tl=() opts=()
  while IFS= read -r l; do
    l=${l//$'\t'/  }
    l=${l//$'\r'/}
    l=${l//$'\e'\[*([0-9;])[A-Za-z]/}
    (( ${#l} > COLS - 10 )) && l="${l:0:COLS-11}…"
    tl+=("${MU}${l}")
  done < <(tail -n 14 "$LOG_FILE")
  printf '\n'
  box "Что пошло не так: $title" "${tl[@]}"
  hint "Полный лог: $LOG_FILE"
  opts=("Повторить|запустить этот шаг ещё раз")
  [[ $fn == pull_* ]] && opts+=("Через зеркало|включить зеркало Docker Hub и повторить")
  opts+=("Пропустить|идти дальше без этого шага" "Выйти|остановить установку")
  menu c "Что делаем?" "${opts[@]}"
  case ${opts[c]%%|*} in
    "Повторить") return 0 ;;
    "Через зеркало") spin_run "Включаю зеркала Docker Hub" docker_enable_mirror; return 0 ;;
    "Пропустить") SKIPPED+=("$title"); return 1 ;;
    *) die "Установка остановлена. Лог: $LOG_FILE" ;;
  esac
}

# run_plan "Заголовок|функция аргументы" ...
run_plan() {
  local s
  STEP=0
  STEPS=$#
  for s in "$@"; do
    # shellcheck disable=SC2086
    step "${s%%|*}" ${s#*|}
  done
  STEPTAG=''
}

# ═══════════════════════════ ввод: меню, да/нет, поля ═══════════════

readkey() {
  local k k2='' c
  IFS= read -rsn1 k </dev/tty || die "Нет ввода с терминала"
  case $k in
    $'\e')
      # стрелки приходят как ESC [ A / ESC O A; на медленном SSH — иногда по частям
      IFS= read -rsn1 -t 0.15 c </dev/tty && k2=$c
      [[ $k2 == @('['|O) ]] && IFS= read -rsn1 -t 0.15 c </dev/tty && k2+=$c
      case $k2 in
        '[A'|'OA') KEY=up ;;
        '[B'|'OB') KEY=down ;;
        '[C'|'OC') KEY=right ;;
        '[D'|'OD') KEY=left ;;
        *) KEY=esc ;;
      esac ;;
    '') KEY=enter ;;
    $'\t') KEY=tab ;;
    ' ') KEY=space ;;
    *) KEY=$k ;;
  esac
}

_menu_draw() {
  local i d pad avail
  for (( i = 0; i < _mn; i++ )); do
    printf -v pad '%*s' $(( _mlw - ${#_mlab[i]} )) ''
    d=${_mdes[i]}
    avail=$(( COLS - _mlw - 10 ))
    if (( avail < 8 )); then d=''; elif (( ${#d} > avail )); then d="${d:0:avail-1}…"; fi
    if (( i == _msel )); then
      gtext "❯ ${_mlab[i]}"
      printf '\r\e[2K  %s%s%s%s  %s%s%s\n' "$BLD" "$REPLY" "$N" "$pad" "$WH" "$d" "$N"
    else
      printf '\r\e[2K    %s%s  %s%s%s\n' "${_mlab[i]}" "$pad" "$MU" "$d" "$N"
    fi
  done
}

# menu VAR "Вопрос" "Пункт|пояснение" ...   (MENU_DEFAULT — пункт по умолчанию)
menu() {
  local _mv=$1 _mq=$2 _mx _mn _msel=${MENU_DEFAULT:-0} _mlw=0 _mkh=''
  local -a _mlab=() _mdes=()
  shift 2
  MENU_DEFAULT=0
  for _mx in "$@"; do
    _mlab+=("${_mx%%|*}")
    if [[ $_mx == *'|'* ]]; then _mdes+=("${_mx#*|}"); else _mdes+=(''); fi
  done
  _mn=${#_mlab[@]}
  (( _msel >= _mn )) && _msel=0
  for _mx in "${_mlab[@]}"; do (( ${#_mx} > _mlw )) && _mlw=${#_mx}; done
  (( ${#_mq} + 24 < COLS )) && _mkh="  ${MU}↑↓ · Enter${N}"
  printf '\n  %s◆%s %s%s%s%s\n' "$VI" "$N" "$BLD" "$_mq" "$N" "$_mkh"
  _hide
  _tty_raw_on
  _menu_draw
  while :; do
    readkey
    case $KEY in
      up|k|w) _msel=$(( (_msel - 1 + _mn) % _mn )) ;;
      down|j|s|tab) _msel=$(( (_msel + 1) % _mn )) ;;
      [1-9])
        if (( KEY <= _mn )); then
          _msel=$(( KEY - 1 ))
          printf '\e[%dA' "$_mn"; _menu_draw
          break
        fi
        continue ;;
      enter|space) break ;;
      *) continue ;;
    esac
    printf '\e[%dA' "$_mn"
    _menu_draw
  done
  _tty_raw_off
  printf '\e[%dA\e[J' $(( _mn + 1 ))
  gtext "${_mlab[_msel]}"
  printf '  %s✔%s %s %s›%s %s\n' "$GR" "$N" "$_mq" "$MU" "$N" "$REPLY"
  _show
  MENU_LABEL=${_mlab[_msel]}
  printf -v "$_mv" '%s' "$_msel"
}

_confirm_draw() {
  local y n
  if (( COLOR )); then
    if (( _cv )); then y="${SEL} Да ${N}"; n="${MU} Нет ${N}"; else y="${MU} Да ${N}"; n="${SEL} Нет ${N}"; fi
  else
    if (( _cv )); then y="[Да]"; n=" Нет "; else y=" Да "; n="[Нет]"; fi
  fi
  printf '\r\e[2K  %s?%s %s%s%s   %s %s' "$CY" "$N" "$BLD" "$_cq" "$N" "$y" "$n"
}

# confirm "Вопрос" [y|n] → код 0 = да
confirm() {
  local _cq=$1 _cv=1 _ca
  [[ ${2:-y} == n ]] && _cv=0
  printf '\n'
  _hide
  _tty_raw_on
  while :; do
    _confirm_draw
    readkey
    case $KEY in
      left|right|tab|space|h|l) _cv=$(( 1 - _cv )) ;;
      y|Y|д|Д) _cv=1; break ;;
      n|N|н|Н) _cv=0; break ;;
      enter) break ;;
    esac
  done
  _tty_raw_off
  _ca="Нет"; (( _cv )) && _ca="Да"
  printf '\r\e[2K  %s✔%s %s %s›%s %s%s%s\n' "$GR" "$N" "$_cq" "$MU" "$N" "$CY" "$_ca" "$N"
  _show
  (( _cv ))
}

# ask VAR "Вопрос" [по умолчанию] [валидатор] [подсказка]
# Валидатор: код 0 — ок (может напечатать нормализованное значение), иначе — текст ошибки.
ask() {
  local _av=$1 _aq=$2 _adef=${3:-} _afn=${4:-} _ahint=${5:-} _aval _amsg _alines=1 _ashown
  printf '\n  %s?%s %s%s%s\n' "$CY" "$N" "$BLD" "$_aq" "$N"
  [[ -n $_ahint ]] && { hint "$_ahint"; _alines=2; }
  while :; do
    _aval=''
    _show
    IFS= read -e -r -i "$_adef" -p $'    \001'"$PK"$'\002❯\001'"$N"$'\002 ' _aval </dev/tty || die "Ввод прерван"
    _alines=$(( _alines + 1 + (6 + ${#_aval}) / COLS ))
    _aval=${_aval##+([[:space:]])}
    _aval=${_aval%%+([[:space:]])}
    [[ -z $_aval ]] && _aval=$_adef
    if [[ -n $_afn ]]; then
      if _amsg=$("$_afn" "$_aval"); then
        [[ -n $_amsg ]] && _aval=$_amsg
      else
        printf '    %s✖ %s%s\n' "$RD" "${_amsg:-неверное значение}" "$N"
        _alines=$(( _alines + 1 ))
        continue
      fi
    fi
    break
  done
  printf '\e[%dA\e[J' "$_alines"
  _ashown=$_aval
  (( ${#_ashown} > 46 )) && _ashown="${_ashown:0:22}…${_ashown: -10}"
  [[ -z $_ashown ]] && _ashown="${MU}—"
  printf '  %s✔%s %s %s›%s %s%s%s\n' "$GR" "$N" "$_aq" "$MU" "$N" "$CY" "$_ashown" "$N"
  printf -v "$_av" '%s' "$_aval"
}

# ask_secret VAR "Вопрос" [валидатор] [подсказка] [что показать, если пусто]
ask_secret() {
  local _av=$1 _aq=$2 _afn=${3:-} _ahint=${4:-} _aempty=${5:-—} _aval _amsg _alines=1 _ashown
  printf '\n  %s?%s %s%s%s\n' "$CY" "$N" "$BLD" "$_aq" "$N"
  [[ -n $_ahint ]] && { hint "$_ahint"; _alines=2; }
  while :; do
    _aval=''
    _show
    printf '    %s❯%s ' "$PK" "$N"
    IFS= read -rs _aval </dev/tty || die "Ввод прерван"
    printf '\n'
    _alines=$(( _alines + 1 ))
    _aval=${_aval##+([[:space:]])}
    _aval=${_aval%%+([[:space:]])}
    if [[ -n $_afn ]]; then
      if ! _amsg=$("$_afn" "$_aval"); then
        printf '    %s✖ %s%s\n' "$RD" "${_amsg:-неверное значение}" "$N"
        _alines=$(( _alines + 1 ))
        continue
      fi
    fi
    break
  done
  printf '\e[%dA\e[J' "$_alines"
  if [[ -z $_aval ]]; then _ashown=$_aempty; else _ashown="•••••••• ${MU}(${#_aval} симв.)"; fi
  printf '  %s✔%s %s %s›%s %s%s%s\n' "$GR" "$N" "$_aq" "$MU" "$N" "$CY" "$_ashown" "$N"
  printf -v "$_av" '%s' "$_aval"
}

# ═════════════════════════════ валидаторы ═══════════════════════════

v_domain() {
  local d=${1,,} u
  d=${d#http://}; d=${d#https://}; d=${d%%/*}; d=${d%%:*}; d=${d%.}
  [[ -z $d ]] && { echo "введи домен"; return 1; }
  [[ $d =~ ^[0-9.]+$ ]] && { echo "нужен домен, а не IP-адрес"; return 1; }
  [[ $d =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9-]{2,63}$ ]] || { echo "не похоже на домен, пример: panel.example.com"; return 1; }
  for u in "${USED_DOMAINS[@]}"; do
    [[ $d == "$u" ]] && { echo "этот домен уже занят под другое — нужен отдельный поддомен"; return 1; }
  done
  echo "$d"
}

v_port() {
  [[ $1 =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 )) || { echo "порт — число от 1 до 65535"; return 1; }
}

v_port_free() {
  v_port "$1" || return 1
  if port_busy "$1" && ! port_ours "$1"; then
    echo "порт $1 уже занят ($(port_owner "$1" || true))"
    return 1
  fi
}

v_port_aio() {
  v_port "$1" || return 1
  case $1 in
    80|443) echo "порт $1 нужен панели (Caddy) — выбери другой, например 8443"; return 1 ;;
    3000|3001|3010|6767) echo "порт $1 занят сервисами панели"; return 1 ;;
  esac
  [[ $1 == "$NODE_PORT" ]] && { echo "порт $1 — это API ноды, нужен другой"; return 1; }
  v_port_free "$1"
}

v_node_port() {
  v_port_free "$1" || return 1
  [[ -n ${REALITY_PORT:-} && $1 == "$REALITY_PORT" ]] && { echo "совпадает с портом VPN"; return 1; }
  return 0
}

v_reality_port() {
  v_port_free "$1" || return 1
  [[ -n ${NODE_PORT:-} && $1 == "$NODE_PORT" ]] && { echo "порт $1 уже отдан под API ноды"; return 1; }
  return 0
}

v_url() {
  local u=${1%/}
  [[ -z $u ]] && { echo "введи адрес панели"; return 1; }
  [[ $u == http?(s)://* ]] || u="https://$u"
  [[ $u =~ ^https?://[A-Za-z0-9.-]+(:[0-9]+)?$ ]] || { echo "пример: https://panel.example.com"; return 1; }
  echo "$u"
}

v_user() {
  [[ $1 =~ ^[A-Za-z0-9_-]{3,34}$ ]] || { echo "3–34 символа: латиница, цифры, _ и -"; return 1; }
}

v_pass() {
  [[ -z $1 ]] && return 0
  (( ${#1} >= 24 )) && [[ $1 =~ [[:upper:]] && $1 =~ [[:lower:]] && $1 =~ [[:digit:]] ]] && return 0
  echo "нужно минимум 24 символа, заглавные, строчные буквы и цифры (или просто Enter)"
  return 1
}

v_nonempty() { [[ -n $1 ]] || { echo "не может быть пустым"; return 1; }; }

v_cc() {
  local c=${1^^}
  [[ $c =~ ^[[:upper:]]{2}$ ]] || { echo "две латинские буквы, например DE, NL, FI"; return 1; }
  echo "$c"
}

v_node_name() {
  (( ${#1} >= 3 && ${#1} <= 30 )) || { echo "от 3 до 30 символов"; return 1; }
}

v_tg_token() {
  [[ $1 =~ ^[0-9]{5,}:[A-Za-z0-9_-]{30,}$ ]] || { echo "токен вида 123456789:AA… — его выдаёт @BotFather"; return 1; }
}

v_tg_chat() {
  [[ $1 =~ ^-?[0-9]+(:[0-9]+)?$ ]] || { echo "ID чата — число, например -1001234567890 (можно :ID_топика)"; return 1; }
}

v_secret_key() {
  local s=$1
  s=${s#SECRET_KEY=}
  s=${s#\"}; s=${s%\"}; s=${s#\'}; s=${s%\'}
  [[ -z $s ]] && { echo "вставь SECRET_KEY из панели"; return 1; }
  [[ $s =~ [[:space:]] ]] && { echo "в ключе не должно быть пробелов — скопируй целиком одной строкой"; return 1; }
  (( ${#s} >= 40 )) || { echo "слишком короткий — скопируй ключ полностью"; return 1; }
  echo "$s"
}

# ═══════════════════════════ система и сеть ═════════════════════════

has() { command -v "$1" >/dev/null 2>&1; }

pkg_install() {
  if has apt-get; then
    DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 install -y -q "$@"
  elif has dnf; then
    dnf install -y -q "$@"
  elif has yum; then
    yum install -y -q "$@"
  else
    echo "Не знаю, как ставить пакеты на этой системе"
    return 1
  fi
}

install_base() {
  local need=0 c
  for c in curl jq openssl ss tar gzip awk; do has "$c" || need=1; done
  [[ -e /etc/ssl/certs/ca-certificates.crt || -e /etc/pki/tls/certs/ca-bundle.crt ]] || need=1
  (( need )) || return 0
  if has apt-get; then
    status "apt update"
    DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 update -q || return 1
    status "curl, jq, openssl, iproute2"
    pkg_install curl ca-certificates openssl jq iproute2 tar gzip gawk
  else
    status "curl, jq, openssl, iproute"
    pkg_install curl ca-certificates openssl jq iproute tar gzip gawk
  fi
}

detect_ip() {
  local ip u
  for u in https://api.ipify.org https://ipv4.icanhazip.com https://ifconfig.me/ip https://checkip.amazonaws.com; do
    ip=$(curl -4 -fsS -m 5 "$u" 2>/dev/null | tr -d '[:space:]')
    [[ $ip =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] && { echo "$ip"; return 0; }
  done
  ip -4 route get 1.1.1.1 2>/dev/null | grep -oE 'src [0-9.]+' | awk '{print $2}'
}

detect_country() {
  local c
  c=$(curl -fsS -m 5 https://ipinfo.io/country 2>/dev/null | tr -d '[:space:]')
  [[ $c =~ ^[[:upper:]]{2}$ ]] || c=$(curl -fsS -m 5 "http://ip-api.com/line/?fields=countryCode" 2>/dev/null | tr -d '[:space:]')
  [[ $c =~ ^[[:upper:]]{2}$ ]] || c=XX
  echo "$c"
}

# флаг-эмодзи по коду страны
flag() {
  local cc=${1^^} a b h1 h2 loc="${LC_ALL:-${LC_CTYPE:-${LANG:-}}}"
  [[ ${loc,,} == *utf?(-)8* ]] || return 0
  [[ $cc =~ ^[[:upper:]]{2}$ && $cc != XX ]] || return 0
  printf -v a '%d' "'${cc:0:1}"
  printf -v b '%d' "'${cc:1:1}"
  printf -v h1 '%08X' $(( 0x1F1E6 + a - 65 ))
  printf -v h2 '%08X' $(( 0x1F1E6 + b - 65 ))
  # shellcheck disable=SC2059
  printf "\\U$h1\\U$h2"
}

resolve_a() {
  local d=$1 r
  r=$(curl -fsS -m 6 -H 'accept: application/dns-json' "https://cloudflare-dns.com/dns-query?name=${d}&type=A" 2>/dev/null | grep -oE '"data":"[0-9.]+"' | cut -d'"' -f4)
  [[ -z $r ]] && r=$(curl -fsS -m 6 "https://dns.google/resolve?name=${d}&type=A" 2>/dev/null | grep -oE '"data":"[0-9.]+"' | cut -d'"' -f4)
  [[ -z $r ]] && r=$(getent ahostsv4 "$d" 2>/dev/null | awk '{print $1}')
  [[ -n $r ]] && printf '%s\n' $r | sort -u
  return 0
}

port_busy() {
  ss -ltn 2>/dev/null | awk -v p="$1" 'NR > 1 { n = split($4, a, ":"); if (a[n] == p) f = 1 } END { exit !f }'
}

port_owner() {
  ss -ltnp 2>/dev/null | awk -v p="$1" 'NR > 1 { n = split($4, a, ":"); if (a[n] == p) { print; exit } }' \
    | grep -oE 'users:\(\("[^"]+' | head -n1 | sed 's/.*("//'
}

# порт держит наша же старая установка (при переустановке)
port_ours() {
  (( ${REINSTALL:-0} || ${REINSTALL_NODE:-0} )) || return 1
  local o
  o=$(port_owner "$1")
  [[ -z $o || $o == @(docker-proxy|xray|rw-core|caddy|node|remnanode) ]]
}

port_guard() {
  local p o
  for p in "$@"; do
    port_busy "$p" || continue
    port_ours "$p" && continue
    o=$(port_owner "$p")
    printf '\n'
    warn "Порт $p занят: ${o:-неизвестный процесс}"
    case $o in
      nginx|apache2|httpd|caddy|haproxy|lighttpd|angie)
        if confirm "Остановить и отключить $o?" y; then
          systemctl disable --now "$o" >/dev/null 2>&1 || systemctl stop "$o" >/dev/null 2>&1
          sleep 1
          port_busy "$p" && die "Порт $p всё ещё занят — освободи его и запусти установщик снова"
          ok "$o остановлен и убран из автозапуска"
          continue
        fi ;;
      docker-proxy)
        hint "Его держит контейнер: $(docker ps --filter "publish=$p" --format '{{.Names}}' 2>/dev/null | paste -sd, -)" ;;
    esac
    confirm "Продолжить всё равно? (Caddy не сможет запуститься)" n || die "Освободи порт $p и запусти установщик снова"
  done
}

check_dns() {
  local d=$1 ips c
  while :; do
    ips=$(resolve_a "$d" | paste -sd' ' -)
    if [[ -n $PUBLIC_IP && " $ips " == *" $PUBLIC_IP "* ]]; then
      ok "$d → $PUBLIC_IP"
      return 0
    fi
    if [[ -z $ips ]]; then
      warn "$d пока никуда не указывает"
    else
      warn "$d → $ips, а у этого сервера $PUBLIC_IP"
    fi
    hint "Нужна A-запись: $d → ${PUBLIC_IP:-IP сервера} (в Cloudflare — серое облако «DNS only»)"
    menu c "Как быть?" \
      "Проверить ещё раз|DNS уже поправил" \
      "Продолжить так|SSL-сертификат может не выпуститься" \
      "Другой домен|ввести заново"
    case $c in
      0) continue ;;
      1) return 0 ;;
      *) return 1 ;;
    esac
  done
}

ask_domain() {
  local _dv=$1 _dq=$2 _dh=$3 _dd
  while :; do
    ask _dd "$_dq" "" v_domain "$_dh"
    check_dns "$_dd" && break
  done
  USED_DOMAINS+=("$_dd")
  printf -v "$_dv" '%s' "$_dd"
}

# Reality нужен от сайта TLS 1.3 и h2 в ALPN — сам HTTP-ответ не важен
check_sni_tls() {
  local out
  out=$(timeout 10 openssl s_client -connect "$1:443" -servername "$1" -tls1_3 -alpn h2 </dev/null 2>&1)
  echo "$out" | grep -E 'Protocol|ALPN|Verify return' | head -n 5
  grep -q 'TLSv1\.3' <<<"$out" && grep -q 'ALPN protocol: h2' <<<"$out"
}

ufw_active() { has ufw && ufw status 2>/dev/null | grep -q '^Status: active'; }

fw_setup() {
  local r
  for r in "${FW_RULES[@]}"; do
    echo "ufw $r"
    # shellcheck disable=SC2086
    ufw $r || return 1
  done
}

gen_pass() {
  local n=${1:-28} p
  while :; do
    p=$(openssl rand -base64 96 | tr -dc 'A-Za-z0-9' | head -c "$n")
    [[ ${#p} -ge $n && $p =~ [[:upper:]] && $p =~ [[:lower:]] && $p =~ [[:digit:]] ]] && { printf '%s' "$p"; return; }
  done
}

env_get() { grep -E "^$1=" "$2" 2>/dev/null | tail -n1 | cut -d= -f2- | tr -d '"'; }

env_set() {
  local f=$1 k=$2 v=$3
  if grep -q "^${k}=" "$f" 2>/dev/null; then
    awk -v k="$k" -v v="$v" 'BEGIN { n = length(k) + 1 } substr($0, 1, n) == k "=" { print k "=" v; next } { print }' "$f" >"$f.awk" \
      && mv -f "$f.awk" "$f"
  else
    [[ -s $f && -n $(tail -c1 "$f") ]] && printf '\n' >>"$f"
    printf '%s=%s\n' "$k" "$v" >>"$f"
  fi
}

_ctr_exists()  { has docker && docker inspect "$1" >/dev/null 2>&1; }
_ctr_running() { [[ $(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null) == true ]]; }

panel_installed() { [[ -f $PANEL_DIR/docker-compose.yml ]] || _ctr_exists remnawave; }
node_installed()  { [[ -f $NODE_DIR/docker-compose.yml ]] || _ctr_exists remnanode; }
sub_installed()   { [[ -f $SUB_DIR/docker-compose.yml ]] || _ctr_exists remnawave-subscription-page; }

compose_dirs() {
  local d
  COMPOSE_DIRS=()
  for d in "$PANEL_DIR" "$SUB_DIR" "$CADDY_DIR" "$NODE_DIR"; do
    [[ -f $d/docker-compose.yml ]] && COMPOSE_DIRS+=("$d")
  done
}

# ═══════════════════════════════ Docker ═════════════════════════════

ensure_docker() {
  local i arch
  if ! has docker; then
    status "ставлю Docker с get.docker.com"
    if ! { curl -fsSL -m 60 https://get.docker.com -o /tmp/rwi-get-docker.sh && sh /tmp/rwi-get-docker.sh; }; then
      echo "get.docker.com не сработал — ставлю docker.io из репозитория дистрибутива"
      status "docker.io из репозитория"
      pkg_install docker.io || return 1
    fi
    rm -f /tmp/rwi-get-docker.sh
  fi
  has systemctl && systemctl enable --now docker >/dev/null 2>&1
  if ! docker compose version >/dev/null 2>&1; then
    status "плагин docker compose"
    if ! { pkg_install docker-compose-plugin || pkg_install docker-compose-v2; }; then
      arch=$(uname -m)
      [[ $arch == @(aarch64|arm64) ]] && arch=aarch64 || arch=x86_64
      mkdir -p /usr/local/lib/docker/cli-plugins
      curl -fsSL -m 180 "https://github.com/docker/compose/releases/latest/download/docker-compose-linux-$arch" \
        -o /usr/local/lib/docker/cli-plugins/docker-compose || return 1
      chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
    fi
  fi
  status "жду docker daemon"
  for i in $(seq 1 20); do docker info >/dev/null 2>&1 && break; sleep 1; done
  docker info >/dev/null 2>&1 || return 1
  docker version --format 'Docker {{.Server.Version}}'
  docker compose version
}

docker_enable_mirror() {
  local f=/etc/docker/daemon.json
  mkdir -p /etc/docker
  if [[ -s $f ]]; then
    jq '."registry-mirrors" = (((."registry-mirrors" // []) + ["https://mirror.gcr.io", "https://dockerhub.timeweb.cloud"]) | unique)' "$f" >"$f.tmp" \
      && mv -f "$f.tmp" "$f" || return 1
  else
    printf '{\n  "registry-mirrors": ["https://mirror.gcr.io", "https://dockerhub.timeweb.cloud"]\n}\n' >"$f"
  fi
  systemctl restart docker || service docker restart
  sleep 3
  docker info >/dev/null 2>&1
}

compose_images() { grep -oE 'image:[[:space:]]*[^[:space:]]+' "$1/docker-compose.yml" | awk '{print $2}' | paste -sd' ' -; }

pull_images() {
  local d
  for d in "$@"; do
    [[ -f $d/docker-compose.yml ]] || continue
    status "$(compose_images "$d")"
    (cd "$d" && docker compose pull -q) || return 1
  done
}

caddy_validate() {
  docker run --rm -v "$1/Caddyfile:/etc/caddy/Caddyfile:ro" caddy:2 \
    caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
}

# ═════════════════════════════ API панели ═══════════════════════════

API_BASE=""
API_AUTH=""
API_CODE=""
API_BODY=""

# api МЕТОД /путь [json] → API_CODE, API_BODY
api() {
  local m=$1 p=$2 d=${3:-} out
  local -a a=(-sS -m 30 -X "$m" -H 'Content-Type: application/json' -H 'Accept: application/json' -w $'\n%{http_code}')
  [[ $API_BASE == http://* ]] && a+=(-H 'X-Forwarded-For: 127.0.0.1' -H 'X-Forwarded-Proto: https')
  # админский JWT панель v3 принимает только «от дашборда»; для API-токенов заголовок ни на что не влияет
  [[ -n $API_AUTH ]] && a+=(-H "Authorization: Bearer $API_AUTH" -H 'X-Remnawave-Client-Type: browser')
  [[ -n $d ]] && a+=(--data-binary "$d")
  if ! out=$(curl "${a[@]}" "$API_BASE$p" 2>&1); then
    API_CODE=000
    API_BODY=$out
    echo "API $m $p → нет ответа: ${out:0:300}"
    return 1
  fi
  API_CODE=${out##*$'\n'}
  API_BODY=${out%$'\n'*}
  if [[ $API_CODE != 2* ]]; then
    echo "API $m $p → HTTP $API_CODE: ${API_BODY:0:600}"
    return 1
  fi
}

jget() { jq -r "$1 // empty" <<<"$API_BODY" 2>/dev/null; }

wait_panel() {
  local deadline=$(( SECONDS + 300 )) code st
  status "старт бэкенда и миграции БД"
  while (( SECONDS < deadline )); do
    code=$(curl -s -o /dev/null -m 4 -w '%{http_code}' -H 'X-Forwarded-For: 127.0.0.1' -H 'X-Forwarded-Proto: https' \
      "$PANEL_API_LOCAL/api/auth/status" 2>/dev/null)
    [[ $code == 200 ]] && return 0
    st=$(docker inspect -f '{{.State.Status}}' remnawave 2>/dev/null)
    [[ $st == restarting ]] && status "контейнер перезапускается…"
    sleep 3
  done
  (cd "$PANEL_DIR" && docker compose logs --tail 80 remnawave)
  return 1
}

panel_admin() {
  API_BASE=$PANEL_API_LOCAL
  API_AUTH=""
  api GET /api/auth/status || return 1
  if [[ $(jget '.response.isRegisterAllowed') == true ]]; then
    status "регистрирую суперадмина"
    api POST /api/auth/register "$(jq -nc --arg u "$ADMIN_USER" --arg p "$ADMIN_PASS" '{username: $u, password: $p}')" || return 1
  else
    status "админ уже есть — вхожу"
    api POST /api/auth/login "$(jq -nc --arg u "$ADMIN_USER" --arg p "$ADMIN_PASS" '{username: $u, password: $p}')" || {
      echo "В базе уже есть администратор, и логин/пароль к нему не подошли"
      return 1
    }
  fi
  API_AUTH=$(jget '.response.accessToken')
  [[ -n $API_AUTH ]]
}

panel_tokens() {
  status "токен для страницы подписок"
  api POST /api/tokens '{"name":"subscription-page","expiresInDays":3650}' || return 1
  SUB_API_TOKEN=$(jget '.response.token')
  status "токен для подключения нод"
  api POST /api/tokens '{"name":"remna-installer","expiresInDays":3650}' || return 1
  NODES_API_TOKEN=$(jget '.response.token')
  [[ -n $SUB_API_TOKEN && -n $NODES_API_TOKEN ]]
}

api_profile() {
  local suf clean cfg
  status "ключи x25519"
  api GET /api/system/tools/x25519/generate || return 1
  REALITY_PRIV=$(jget '.response.keypairs[0].privateKey')
  REALITY_PUB=$(jget '.response.keypairs[0].publicKey')
  [[ -n $REALITY_PRIV ]] || { echo "Панель не вернула ключи x25519"; return 1; }
  REALITY_SID=$(openssl rand -hex 8)
  suf=$(openssl rand -hex 2 | tr 'a-f' 'A-F')
  INBOUND_TAG="VLESS_REALITY_${suf}"
  clean=$(printf '%s' "$NODE_NAME" | tr -cd 'A-Za-z0-9_ -' | cut -c1-16)
  clean=${clean%% }
  PROFILE_NAME="Reality-${clean:-node}-${suf}"
  status "профиль $PROFILE_NAME"
  cfg=$(jq -nc \
    --arg tag "$INBOUND_TAG" --argjson port "$REALITY_PORT" --arg target "$REALITY_TARGET" \
    --arg sni "$REALITY_SNI" --arg pk "$REALITY_PRIV" --arg sid "$REALITY_SID" --argjson bt "${BLOCK_TORRENT:-1}" '
    {
      log: {loglevel: "warning"},
      inbounds: [{
        tag: $tag, listen: "0.0.0.0", port: $port, protocol: "vless",
        settings: {clients: [], decryption: "none"},
        sniffing: {enabled: true, destOverride: ["http", "tls", "quic"]},
        streamSettings: {
          network: "raw", security: "reality",
          realitySettings: {show: false, xver: 0, target: $target, serverNames: [$sni], privateKey: $pk, shortIds: [$sid]}
        }
      }],
      outbounds: [{protocol: "freedom", tag: "DIRECT"}, {protocol: "blackhole", tag: "BLOCK"}],
      routing: {rules: ([{ip: ["geoip:private"], outboundTag: "BLOCK"}]
        + (if $bt == 1 then [{protocol: ["bittorrent"], outboundTag: "BLOCK"}] else [] end))}
    }')
  api POST /api/config-profiles "$(jq -nc --arg n "$PROFILE_NAME" --argjson c "$cfg" '{name: $n, config: $c}')" || return 1
  PROFILE_UUID=$(jget '.response.uuid')
  INBOUND_UUID=$(jq -r --arg t "$INBOUND_TAG" '.response.inbounds[]? | select(.tag == $t) | .uuid' <<<"$API_BODY" | head -n1)
  [[ -n $PROFILE_UUID && -n $INBOUND_UUID ]]
}

api_node() {
  local body inb
  status "нода $NODE_NAME"
  body=$(jq -nc --arg name "$NODE_NAME" --arg addr "$NODE_ADDR" --argjson port "$NODE_PORT" --arg cc "$COUNTRY" \
    --arg pu "$PROFILE_UUID" --arg iu "$INBOUND_UUID" \
    '{name: $name, address: $addr, port: $port, countryCode: $cc, isTrafficTrackingActive: false,
      configProfile: {activeConfigProfileUuid: $pu, activeInbounds: [$iu]}}')
  api POST /api/nodes "$body" || return 1
  NODE_UUID=$(jget '.response.uuid')

  status "SECRET_KEY"
  api GET /api/keygen || return 1
  NODE_SECRET=$(jget '.response.secretKey')
  [[ -n $NODE_SECRET ]] || { echo "Панель не отдала SECRET_KEY"; return 1; }

  status "хост для подписки"
  HOST_REMARK="$(flag "$COUNTRY") $NODE_NAME"
  HOST_REMARK=${HOST_REMARK# }
  body=$(jq -nc --arg pu "$PROFILE_UUID" --arg iu "$INBOUND_UUID" --arg remark "$HOST_REMARK" \
    --arg addr "$HOST_ADDR" --argjson port "$REALITY_PORT" --arg sni "$REALITY_SNI" \
    '{inbound: {configProfileUuid: $pu, configProfileInboundUuid: $iu}, remark: $remark,
      address: $addr, port: $port, sni: $sni, fingerprint: "firefox"}')
  api POST /api/hosts "$body" || return 1

  status "сквад"
  api GET /api/internal-squads || return 1
  if [[ -z ${SQUAD_UUID:-} ]]; then
    SQUAD_UUID=$(jq -r '.response.internalSquads | ((map(select(.name == "Default-Squad")) + .)[0].uuid) // empty' <<<"$API_BODY")
    SQUAD_NAME=$(jq -r --arg s "$SQUAD_UUID" '.response.internalSquads[]? | select(.uuid == $s) | .name' <<<"$API_BODY")
  fi
  if [[ -z $SQUAD_UUID ]]; then
    api POST /api/internal-squads "$(jq -nc --arg i "$INBOUND_UUID" '{name: "Default-Squad", inbounds: [$i]}')" || return 1
    SQUAD_UUID=$(jget '.response.uuid')
    SQUAD_NAME="Default-Squad"
    return 0
  fi
  inb=$(jq -c --arg s "$SQUAD_UUID" --arg iu "$INBOUND_UUID" \
    '[.response.internalSquads[]? | select(.uuid == $s) | .inbounds[]?.uuid] + [$iu] | unique' <<<"$API_BODY")
  api PATCH /api/internal-squads "$(jq -nc --arg u "$SQUAD_UUID" --argjson i "$inb" '{uuid: $u, inbounds: $i}')"
}

wait_node() {
  local deadline=$(( SECONDS + 180 )) msg
  NODE_OK=0
  while (( SECONDS < deadline )); do
    if api GET "/api/nodes/$NODE_UUID" >/dev/null; then
      if [[ $(jget '.response.isConnected') == true ]]; then
        NODE_OK=1
        return 0
      fi
      msg=$(jget '.response.lastStatusMessage' | head -n1)
      status "${msg:-панель подключается к ноде}"
    fi
    sleep 4
  done
  echo "Нода не подключилась за 3 минуты. Логи ноды:"
  docker logs --tail 40 remnanode 2>&1
  return 1
}

api_test_user() {
  local exp name
  exp=$(date -u -d '+30 days' '+%Y-%m-%dT%H:%M:%S.000Z' 2>/dev/null) || exp=$(date -u -v+30d '+%Y-%m-%dT%H:%M:%S.000Z')
  name="test-$(openssl rand -hex 3)"
  api POST /api/users "$(jq -nc --arg u "$name" --arg e "$exp" --arg s "$SQUAD_UUID" \
    '{username: $u, expireAt: $e, trafficLimitBytes: 0, trafficLimitStrategy: "NO_RESET", activeInternalSquads: [$s],
      description: "Тестовый пользователь от установщика"}')" || return 1
  TEST_USER=$name
  TEST_SUB_URL=$(jget '.response.subscriptionUrl')
  [[ -n $TEST_SUB_URL ]]
}

check_panel_access() {
  API_BASE=$PANEL_URL
  API_AUTH=$PANEL_TOKEN
  api GET /api/config-profiles && return 0
  case $API_CODE in
    000) CHECK_ERR="Панель не отвечает по адресу $PANEL_URL" ;;
    401|403) CHECK_ERR="Токен не подошёл (HTTP $API_CODE)" ;;
    404) CHECK_ERR="По этому адресу не Remnawave (HTTP 404)" ;;
    *) CHECK_ERR="Панель ответила HTTP $API_CODE" ;;
  esac
  return 1
}

choose_squad() {
  local -a names=() uuids=() o=()
  local i c
  SQUAD_UUID=""
  SQUAD_NAME=""
  api GET /api/internal-squads >/dev/null 2>&1 || return 0
  mapfile -t names < <(jq -r '.response.internalSquads[]?.name' <<<"$API_BODY")
  mapfile -t uuids < <(jq -r '.response.internalSquads[]?.uuid' <<<"$API_BODY")
  (( ${#uuids[@]} )) || return 0
  if (( ${#uuids[@]} == 1 )); then
    SQUAD_UUID=${uuids[0]}
    SQUAD_NAME=${names[0]}
    return 0
  fi
  for i in "${!names[@]}"; do o+=("${names[i]}|"); done
  menu c "В какой сквад добавить ноду?" "${o[@]}"
  SQUAD_UUID=${uuids[c]}
  SQUAD_NAME=${names[c]}
}

# ═══════════════════════════ файлы конфигурации ═════════════════════

embedded_compose() {
  cat <<'EOF'
x-common: &common
  ulimits:
    nofile:
      soft: 1048576
      hard: 1048576
  restart: always
  networks:
    - remnawave-network

x-logging: &logging
  logging:
    driver: json-file
    options:
      max-size: 100m
      max-file: 5

x-env: &env
  env_file: .env

services:
  remnawave:
    image: remnawave/backend:3
    container_name: remnawave
    hostname: remnawave
    <<: [*common, *logging, *env]
    volumes:
      - valkey-socket:/var/run/valkey
    ports:
      - 127.0.0.1:3000:${APP_PORT:-3000}
      - 127.0.0.1:3001:${METRICS_PORT:-3001}
    healthcheck:
      test: ['CMD-SHELL', 'curl -f http://localhost:${METRICS_PORT:-3001}/health']
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 30s
    depends_on:
      remnawave-db:
        condition: service_healthy
      remnawave-redis:
        condition: service_healthy

  remnawave-db:
    image: postgres:18.4
    container_name: remnawave-db
    hostname: remnawave-db
    shm_size: 512mb
    <<: [*common, *logging, *env]
    environment:
      - POSTGRES_USER=${POSTGRES_USER}
      - POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
      - POSTGRES_DB=${POSTGRES_DB}
      - TZ=UTC
    ports:
      - 127.0.0.1:6767:5432
    volumes:
      - remnawave-db-data:/var/lib/postgresql
    healthcheck:
      test: ['CMD-SHELL', 'pg_isready -U $${POSTGRES_USER} -d $${POSTGRES_DB}']
      interval: 3s
      timeout: 10s
      retries: 3

  remnawave-redis:
    image: valkey/valkey:9-alpine
    container_name: remnawave-redis
    hostname: remnawave-redis
    <<: [*common, *logging]
    volumes:
      - valkey-socket:/var/run/valkey
    command: >
      valkey-server
      --save ""
      --appendonly no
      --maxmemory-policy noeviction
      --loglevel warning
      --unixsocket /var/run/valkey/valkey.sock
      --unixsocketperm 777
      --port 0
    healthcheck:
      test: ['CMD', 'valkey-cli', '-s', '/var/run/valkey/valkey.sock', 'ping']
      interval: 3s
      timeout: 3s
      retries: 3

networks:
  remnawave-network:
    name: remnawave-network
    driver: bridge
    external: false

volumes:
  remnawave-db-data:
    name: remnawave-db-data
    driver: local
    external: false
  valkey-socket:
    name: valkey-socket
    driver: local
    external: false
EOF
}

embedded_env() {
  cat <<'EOF'
APP_PORT=3000
METRICS_PORT=3001
API_INSTANCES=1
DATABASE_URL="postgresql://postgres:postgres@remnawave-db:5432/postgres"
REDIS_SOCKET=/var/run/valkey/valkey.sock
APP_SECRET=change_me
IS_TELEGRAM_NOTIFICATIONS_ENABLED=false
TELEGRAM_BOT_TOKEN=change_me
TELEGRAM_NOTIFY_USERS=change_me
TELEGRAM_NOTIFY_NODES=change_me
TELEGRAM_NOTIFY_CRM=change_me
TELEGRAM_NOTIFY_SERVICE=change_me
TELEGRAM_NOTIFY_TBLOCKER=change_me
PANEL_DOMAIN=panel.domain.com
FRONT_END_DOMAIN=*
SUB_PUBLIC_DOMAIN=panel.domain.com/api/sub
METRICS_USER=admin
METRICS_PASS=admin
WEBHOOK_ENABLED=false
WEBHOOK_URL=https://your-webhook-url.com/endpoint
WEBHOOK_SECRET_HEADER=change_me
BANDWIDTH_USAGE_NOTIFICATIONS_ENABLED=false
BANDWIDTH_USAGE_NOTIFICATIONS_THRESHOLD=[60, 80]
NOT_CONNECTED_USERS_NOTIFICATIONS_ENABLED=false
NOT_CONNECTED_USERS_NOTIFICATIONS_AFTER_HOURS=[6, 24, 48]
EXPIRATION_NOTIFICATIONS_ENABLED=false
EXPIRATION_NOTIFICATIONS=[-72, -48, -24, 24]
SHORT_UUID_METHOD=nanoid
SHORT_UUID_LENGTH=16
SERVICE_SNI_VERIFICATION=true
POSTGRES_USER=postgres
POSTGRES_PASSWORD=postgres
POSTGRES_DB=postgres
EOF
}

write_panel_files() {
  local f pg k
  mkdir -p "$PANEL_DIR"
  status "docker-compose.yml"
  if curl -fsSL -m 20 "$UPSTREAM_COMPOSE" -o "$PANEL_DIR/docker-compose.yml.tmp" 2>/dev/null \
    && grep -q 'remnawave/backend' "$PANEL_DIR/docker-compose.yml.tmp"; then
    echo "compose: свежий из репозитория Remnawave"
  else
    echo "compose: встроенный"
    embedded_compose >"$PANEL_DIR/docker-compose.yml.tmp"
  fi
  mv -f "$PANEL_DIR/docker-compose.yml.tmp" "$PANEL_DIR/docker-compose.yml"

  status ".env"
  f=$PANEL_DIR/.env.tmp
  if curl -fsSL -m 20 "$UPSTREAM_ENV" -o "$f" 2>/dev/null && grep -q '^APP_SECRET=' "$f"; then
    echo ".env: свежий шаблон из репозитория Remnawave"
  else
    echo ".env: встроенный шаблон"
    embedded_env >"$f"
  fi
  pg=$(openssl rand -hex 24)
  env_set "$f" APP_SECRET "$(openssl rand -hex 64)"
  env_set "$f" METRICS_PASS "$(openssl rand -hex 32)"
  env_set "$f" WEBHOOK_SECRET_HEADER "$(openssl rand -hex 32)"
  env_set "$f" POSTGRES_PASSWORD "$pg"
  env_set "$f" DATABASE_URL "\"postgresql://postgres:${pg}@remnawave-db:5432/postgres\""
  env_set "$f" FRONT_END_DOMAIN "$PANEL_DOMAIN"
  env_set "$f" PANEL_DOMAIN "$PANEL_DOMAIN"
  env_set "$f" SUB_PUBLIC_DOMAIN "$SUB_DOMAIN"
  if (( ${TG_ON:-0} )); then
    env_set "$f" IS_TELEGRAM_NOTIFICATIONS_ENABLED true
    env_set "$f" TELEGRAM_BOT_TOKEN "$TG_TOKEN"
    for k in TELEGRAM_NOTIFY_USERS TELEGRAM_NOTIFY_NODES TELEGRAM_NOTIFY_CRM TELEGRAM_NOTIFY_SERVICE TELEGRAM_NOTIFY_TBLOCKER; do
      env_set "$f" "$k" "$TG_CHAT"
    done
  fi
  mv -f "$f" "$PANEL_DIR/.env"
  chmod 600 "$PANEL_DIR/.env"
}

write_sub_files() {
  mkdir -p "$SUB_DIR"
  cat >"$SUB_DIR/docker-compose.yml" <<'EOF'
services:
  remnawave-subscription-page:
    image: remnawave/subscription-page:latest
    container_name: remnawave-subscription-page
    hostname: remnawave-subscription-page
    restart: always
    env_file:
      - .env
    ports:
      - '127.0.0.1:3010:3010'
    networks:
      - remnawave-network
    logging:
      driver: json-file
      options:
        max-size: 20m
        max-file: '3'

networks:
  remnawave-network:
    name: remnawave-network
    external: true
EOF
  printf 'APP_PORT=3010\nREMNAWAVE_PANEL_URL=%s\nREMNAWAVE_API_TOKEN=%s\nCUSTOM_SUB_PREFIX=\nTRUST_PROXY=1\n' \
    "$1" "${SUB_API_TOKEN:-}" >"$SUB_DIR/.env"
  chmod 600 "$SUB_DIR/.env"
}

write_stub_site() {
  local dir=$1 name tag lead year
  local -a names=("Northwind Studio" "Lumen Labs" "Brightline Digital" "Atlas Works" "Polar Systems" "Kestrel Media" "Mosaic Cloud" "Cedar Engineering")
  local -a tags=("We build calm, reliable software." "Infrastructure that simply works." "Digital products, done right." "Engineering for the long run.")
  name=${names[RANDOM % ${#names[@]}]}
  tag=${tags[RANDOM % ${#tags[@]}]}
  lead="Independent team crafting web platforms, APIs and cloud infrastructure for growing companies."
  year=$(date +%Y)
  mkdir -p "$dir"
  cat >"$dir/index.html" <<EOF
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>$name</title>
<style>
:root{--bg:#0b0d12;--fg:#e8ebf1;--mu:#8b93a7;--ac:#7b8cff;--bd:#1d2230}
*{box-sizing:border-box;margin:0;padding:0}
body{font:16px/1.6 system-ui,-apple-system,"Segoe UI",Roboto,sans-serif;background:var(--bg);color:var(--fg);min-height:100vh;display:flex;flex-direction:column}
header,main,footer{width:min(960px,92vw);margin:0 auto}
header{display:flex;justify-content:space-between;align-items:center;padding:28px 0}
.logo{font-weight:700;letter-spacing:.3px}
.logo span{color:var(--ac)}
nav a{color:var(--mu);text-decoration:none;margin-left:22px;font-size:14px}
nav a:hover{color:var(--fg)}
main{flex:1;padding:72px 0 56px}
h1{font-size:clamp(32px,5vw,52px);line-height:1.15;max-width:720px}
.lead{color:var(--mu);font-size:18px;max-width:600px;margin-top:20px}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(220px,1fr));gap:18px;margin-top:64px}
.card{border:1px solid var(--bd);border-radius:14px;padding:22px;background:#10131b}
.card h3{font-size:16px;margin-bottom:6px}
.card p{color:var(--mu);font-size:14px}
footer{padding:28px 0;color:var(--mu);font-size:13px;border-top:1px solid var(--bd)}
</style>
</head>
<body>
<header><div class="logo">${name%% *}<span>.</span></div><nav><a href="#services">Services</a><a href="#about">About</a><a href="#contact">Contact</a></nav></header>
<main>
<h1>$tag</h1>
<p class="lead">$lead</p>
<div class="grid" id="services">
<div class="card"><h3>Infrastructure</h3><p>Resilient hosting, delivery and observability for modern web products.</p></div>
<div class="card"><h3>Engineering</h3><p>Backend systems, APIs and automation built to last.</p></div>
<div class="card"><h3>Support</h3><p>Monitoring and maintenance around the clock.</p></div>
</div>
</main>
<footer id="contact">© $year $name. All rights reserved.</footer>
</body>
</html>
EOF
}

write_panel_caddy() {
  mkdir -p "$CADDY_DIR/site"
  cat >"$CADDY_DIR/docker-compose.yml" <<'EOF'
services:
  remnawave-caddy:
    image: caddy:2
    container_name: remnawave-caddy
    hostname: remnawave-caddy
    restart: always
    ports:
      - '0.0.0.0:80:80'
      - '0.0.0.0:443:443'
    networks:
      - remnawave-network
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - ./site:/srv/site:ro
      - remnawave-caddy-data:/data
      - remnawave-caddy-config:/config
    logging:
      driver: json-file
      options:
        max-size: 20m
        max-file: '3'

networks:
  remnawave-network:
    name: remnawave-network
    external: true

volumes:
  remnawave-caddy-data:
    name: remnawave-caddy-data
  remnawave-caddy-config:
    name: remnawave-caddy-config
EOF

  {
    printf '# Сгенерировано Remnawave Installer · %s\n\n' "$(date '+%F %T')"
    if [[ -n ${PANEL_DOMAIN:-} ]]; then
      if (( ${PANEL_GATE:-0} )); then
        cat <<EOF
https://$PANEL_DOMAIN {
	encode zstd gzip

	# Вход только по секретной ссылке https://$PANEL_DOMAIN/?auth=$GATE_KEY
	@unlock query auth=$GATE_KEY
	handle @unlock {
		header Set-Cookie "rw_gate=$GATE_KEY; Path=/; Max-Age=31536000; HttpOnly; Secure; SameSite=Lax"
		redir * / 302
	}

	@allowed header Cookie *rw_gate=$GATE_KEY*
	handle @allowed {
		reverse_proxy remnawave:3000
	}

	# API по токену (страница подписок, ноды, боты) — токен проверяет сама панель
	@api {
		path /api/*
		header Authorization "Bearer *"
	}
	handle @api {
		reverse_proxy remnawave:3000
	}

	# всем остальным — молча рвём соединение
	handle {
		abort
	}
}

EOF
      else
        cat <<EOF
https://$PANEL_DOMAIN {
	encode zstd gzip
	reverse_proxy remnawave:3000
}

EOF
      fi
    fi
    if [[ -n ${SUB_DOMAIN:-} ]]; then
      cat <<EOF
https://$SUB_DOMAIN {
	encode zstd gzip
	reverse_proxy remnawave-subscription-page:3010
}

EOF
    fi
    if (( ${STEAL:-0} )) && [[ -n ${STEAL_DOMAIN:-} ]]; then
      cat <<EOF
https://$STEAL_DOMAIN {
	root * /srv/site
	file_server
}
EOF
    fi
  } >"$CADDY_DIR/Caddyfile"
  if (( ${STEAL:-0} )); then write_stub_site "$CADDY_DIR/site"; fi
  return 0
}

write_node_files() {
  mkdir -p "$NODE_DIR"
  {
    cat <<'EOF'
services:
  remnanode:
    image: remnawave/node:latest
    container_name: remnanode
    hostname: remnanode
    network_mode: host
    restart: always
    cap_add:
      - NET_ADMIN
    ulimits:
      nofile:
        soft: 1048576
        hard: 1048576
    env_file:
      - .env
    logging:
      driver: json-file
      options:
        max-size: 50m
        max-file: '3'
EOF
    if (( ${STEAL:-0} && ! ${WITH_PANEL:-0} )); then
      cat <<'EOF'

  remnanode-caddy:
    image: caddy:2
    container_name: remnanode-caddy
    hostname: remnanode-caddy
    network_mode: host
    restart: always
    volumes:
      - ./caddy/Caddyfile:/etc/caddy/Caddyfile:ro
      - ./caddy/site:/srv/site:ro
      - remnanode-caddy-data:/data
      - remnanode-caddy-config:/config
    logging:
      driver: json-file
      options:
        max-size: 20m
        max-file: '3'

volumes:
  remnanode-caddy-data:
    name: remnanode-caddy-data
  remnanode-caddy-config:
    name: remnanode-caddy-config
EOF
    fi
  } >"$NODE_DIR/docker-compose.yml"
  printf 'NODE_PORT=%s\nSECRET_KEY=%s\n' "$NODE_PORT" "${NODE_SECRET:-}" >"$NODE_DIR/.env"
  chmod 600 "$NODE_DIR/.env"

  if (( ${STEAL:-0} && ! ${WITH_PANEL:-0} )); then
    mkdir -p "$NODE_DIR/caddy"
    cat >"$NODE_DIR/caddy/Caddyfile" <<EOF
# Сайт-заглушка для Reality (self-steal). Сгенерировано Remnawave Installer · $(date '+%F %T')
# Xray слушает :$REALITY_PORT и всех «чужих» отправляет сюда, на 127.0.0.1:9443.
{
	https_port 9443
	default_bind 127.0.0.1
	auto_https disable_redirects
}

http://$STEAL_DOMAIN {
	bind 0.0.0.0
	redir https://{host}{uri} permanent
}

https://$STEAL_DOMAIN {
	root * /srv/site
	file_server
}
EOF
    write_stub_site "$NODE_DIR/caddy/site"
  fi
  return 0
}

write_sub_standalone() {
  docker network inspect remnawave-network >/dev/null 2>&1 || docker network create remnawave-network || return 1
  SUB_API_TOKEN=$PANEL_TOKEN
  write_sub_files "$PANEL_URL" || return 1
  PANEL_DOMAIN="" STEAL=0
  write_panel_caddy
}

# ═════════════════════════ запуск компонентов ═══════════════════════

start_panel() { (cd "$PANEL_DIR" && docker compose up -d --remove-orphans); }

start_sub() {
  env_set "$SUB_DIR/.env" REMNAWAVE_API_TOKEN "$SUB_API_TOKEN"
  (cd "$SUB_DIR" && docker compose up -d --remove-orphans)
}

start_caddy() {
  status "проверяю Caddyfile"
  caddy_validate "$CADDY_DIR" || return 1
  status "запускаю"
  (cd "$CADDY_DIR" && docker compose up -d --remove-orphans) || return 1
  sleep 3
  _ctr_running remnawave-caddy || { docker logs --tail 30 remnawave-caddy 2>&1; return 1; }
}

start_node_caddy() {
  status "проверяю Caddyfile"
  caddy_validate "$NODE_DIR/caddy" || return 1
  (cd "$NODE_DIR" && docker compose up -d remnanode-caddy) || return 1
  sleep 3
  _ctr_running remnanode-caddy || { docker logs --tail 30 remnanode-caddy 2>&1; return 1; }
}

start_node() {
  [[ -n ${NODE_SECRET:-} ]] || { echo "Нет SECRET_KEY для ноды"; return 1; }
  printf 'NODE_PORT=%s\nSECRET_KEY=%s\n' "$NODE_PORT" "$NODE_SECRET" >"$NODE_DIR/.env"
  chmod 600 "$NODE_DIR/.env"
  (cd "$NODE_DIR" && docker compose up -d remnanode) || return 1
  sleep 3
  _ctr_running remnanode || { docker logs --tail 30 remnanode 2>&1; return 1; }
}

pick_node_addr() {
  NODE_ADDR=$(docker network inspect remnawave-network -f '{{range .IPAM.Config}}{{.Gateway}} {{end}}' 2>/dev/null | awk '{print $1}')
  [[ $NODE_ADDR =~ ^[0-9.]+$ ]] || NODE_ADDR=$PUBLIC_IP
  echo "Адрес ноды для панели: $NODE_ADDR"
}

api_node_local() { pick_node_addr; api_node; }

# wait_certs <host:port> домен... — ждём валидный сертификат (Let's Encrypt через Caddy)
wait_certs() {
  local hp=$1 d deadline
  shift
  deadline=$(( SECONDS + 180 ))
  for d in "$@"; do
    status "$d"
    until timeout 8 openssl s_client -connect "$hp" -servername "$d" -verify_return_error -verify_hostname "$d" </dev/null >/dev/null 2>&1; do
      if (( SECONDS > deadline )); then
        echo "Нет валидного сертификата для $d. Проверь A-запись и что порты 80/443 открыты у хостера."
        docker logs --tail 40 remnawave-caddy 2>&1 || docker logs --tail 40 remnanode-caddy 2>&1
        return 1
      fi
      sleep 4
    done
    echo "SSL ок: $d"
  done
}

wait_certs_panel() {
  local -a d=("$PANEL_DOMAIN" "$SUB_DOMAIN")
  (( ${STEAL:-0} )) && d+=("$STEAL_DOMAIN")
  wait_certs 127.0.0.1:443 "${d[@]}"
}

teardown_panel() {
  local d
  [[ -f $CADDY_DIR/docker-compose.yml ]] && (cd "$CADDY_DIR" && docker compose down --remove-orphans)
  [[ -f $SUB_DIR/docker-compose.yml ]] && (cd "$SUB_DIR" && docker compose down --remove-orphans)
  [[ -f $PANEL_DIR/docker-compose.yml ]] && (cd "$PANEL_DIR" && docker compose down -v --remove-orphans)
  for d in remnawave remnawave-db remnawave-redis remnawave-subscription-page remnawave-caddy; do
    docker rm -f "$d" >/dev/null 2>&1
  done
  docker volume rm remnawave-db-data valkey-socket >/dev/null 2>&1
  return 0
}

teardown_node() {
  [[ -f $NODE_DIR/docker-compose.yml ]] && (cd "$NODE_DIR" && docker compose down --remove-orphans)
  docker rm -f remnanode remnanode-caddy >/dev/null 2>&1
  return 0
}

teardown_sub() {
  [[ -f $CADDY_DIR/docker-compose.yml ]] && (cd "$CADDY_DIR" && docker compose down --remove-orphans)
  [[ -f $SUB_DIR/docker-compose.yml ]] && (cd "$SUB_DIR" && docker compose down --remove-orphans)
  docker rm -f remnawave-subscription-page remnawave-caddy >/dev/null 2>&1
  return 0
}

install_cli() {
  mkdir -p /usr/local/share/remna
  cat >/usr/local/bin/remna <<EOF
#!/usr/bin/env bash
# remna — меню Remnawave Installer: статус, логи, обновление, бэкап, новые ноды
url="$RWI_RAW"
dir=/usr/local/share/remna
tmp=\$(mktemp)
if curl -fsSL --max-time 15 "\$url" -o "\$tmp" 2>/dev/null && bash -n "\$tmp" 2>/dev/null; then
  install -m 0755 "\$tmp" "\$dir/install.sh"
fi
rm -f "\$tmp"
[ -f "\$dir/install.sh" ] || { echo "Не удалось скачать установщик: \$url" >&2; exit 1; }
exec bash "\$dir/install.sh" "\$@"
EOF
  chmod 755 /usr/local/bin/remna
  if curl -fsSL -m 20 "$RWI_RAW" -o /usr/local/share/remna/install.sh.tmp 2>/dev/null; then
    install -m 0755 /usr/local/share/remna/install.sh.tmp /usr/local/share/remna/install.sh
    rm -f /usr/local/share/remna/install.sh.tmp
  fi
  return 0
}

save_creds() {
  {
    printf '\n# ── %s · %s ──\n' "$MODE_TITLE" "$(date '+%F %T')"
    printf '%s\n' "$@"
  } >>"$CRED_FILE"
  chmod 600 "$CRED_FILE"
}

# ═════════════════════════ бэкап и управление ═══════════════════════

do_backup() {
  local ts tmp u db f
  ts=$(date +%Y%m%d-%H%M%S)
  mkdir -p "$BACKUP_DIR"
  chmod 700 "$BACKUP_DIR"
  tmp=$(mktemp -d)
  if _ctr_running remnawave-db; then
    u=$(env_get POSTGRES_USER "$PANEL_DIR/.env"); u=${u:-postgres}
    db=$(env_get POSTGRES_DB "$PANEL_DIR/.env"); db=${db:-postgres}
    status "дамп базы"
    docker exec remnawave-db pg_dump -U "$u" -d "$db" --clean --if-exists | gzip >"$tmp/db.sql.gz" || { rm -rf "$tmp"; return 1; }
  fi
  status "конфиги"
  for f in "$PANEL_DIR/.env" "$PANEL_DIR/docker-compose.yml" "$SUB_DIR/.env" "$SUB_DIR/docker-compose.yml" \
           "$CADDY_DIR/Caddyfile" "$CADDY_DIR/docker-compose.yml" "$NODE_DIR/.env" "$NODE_DIR/docker-compose.yml" \
           "$NODE_DIR/caddy/Caddyfile" "$CRED_FILE"; do
    [[ -f $f ]] || continue
    mkdir -p "$tmp/files$(dirname "$f")"
    cp -p "$f" "$tmp/files$f"
  done
  BACKUP_PATH="$BACKUP_DIR/remnawave-$ts.tar.gz"
  tar -czf "$BACKUP_PATH" -C "$tmp" . || { rm -rf "$tmp"; return 1; }
  chmod 600 "$BACKUP_PATH"
  rm -rf "$tmp"
  echo "Бэкап: $BACKUP_PATH"
}

do_update() {
  local d
  compose_dirs
  for d in "${COMPOSE_DIRS[@]}"; do
    status "$(basename "$d"): pull"
    (cd "$d" && docker compose pull -q) || return 1
    status "$(basename "$d"): перезапуск"
    (cd "$d" && docker compose up -d --remove-orphans) || return 1
  done
  docker image prune -f >/dev/null 2>&1
  return 0
}

do_restart() {
  local d
  compose_dirs
  for d in "${COMPOSE_DIRS[@]}"; do
    status "$(basename "$d")"
    (cd "$d" && docker compose restart) || return 1
  done
}

show_status() {
  local -a L=()
  local n st c
  for n in remnawave remnawave-db remnawave-redis remnawave-subscription-page remnawave-caddy remnanode remnanode-caddy; do
    st=$(docker inspect -f '{{.State.Status}}{{if .State.Health}} · {{.State.Health.Status}}{{end}}' "$n" 2>/dev/null) || continue
    case $st in
      running*healthy|running) c=$GR ;;
      running*) c=$YE ;;
      *) c=$RD ;;
    esac
    printf -v REPLY '%s%-29s%s %s● %s%s' "$WH" "$n" "$N" "$c" "$st" "$N"
    L+=("$REPLY")
  done
  printf '\n'
  if (( ${#L[@]} )); then
    box "Контейнеры" "${L[@]}"
  else
    warn "Компоненты Remnawave на этом сервере не найдены"
  fi
}

show_logs() {
  local -a names=() o=()
  local i n
  mapfile -t names < <(docker ps -a --format '{{.Names}}' 2>/dev/null | grep -E '^(remnawave|remnanode)' | sort)
  (( ${#names[@]} )) || { warn "Контейнеров нет"; return; }
  for n in "${names[@]}"; do o+=("$n|"); done
  o+=("Назад|")
  menu i "Чьи логи смотрим?" "${o[@]}"
  (( i == ${#names[@]} )) && return
  hint "Ctrl+C — вернуться в меню"
  printf '\n'
  trap ':' INT
  docker logs --tail 150 -f "${names[i]}"
  trap on_int INT
  printf '\n'
}

show_creds() {
  printf '\n'
  if [[ -s $CRED_FILE ]]; then
    local l
    while IFS= read -r l; do
      if [[ $l == \#* ]]; then printf '  %s%s%s\n' "$VI" "$l" "$N"
      elif [[ $l == *=* ]]; then printf '  %s%s%s=%s\n' "$MU" "${l%%=*}" "$N" "${l#*=}"
      else printf '  %s\n' "$l"; fi
    done <"$CRED_FILE"
  else
    warn "Файла $CRED_FILE нет — установщик на этом сервере ещё ничего не ставил"
  fi
}

do_uninstall() {
  local -a o=() k=()
  local c what
  panel_installed && { o+=("Панель|панель, база, страница подписок, Caddy"); k+=(panel); }
  if ! panel_installed && sub_installed; then o+=("Страница подписок|страница подписок и Caddy"); k+=(sub); fi
  node_installed && { o+=("Нода|remnanode и сайт-заглушка"); k+=(node); }
  (( ${#k[@]} )) || { warn "Удалять нечего"; return; }
  o+=("Отмена|")
  MENU_DEFAULT=${#k[@]}
  menu c "Что удаляем?" "${o[@]}"
  (( c == ${#k[@]} )) && return
  what=${k[c]}
  STEP=0 STEPS=0
  if [[ $what == panel ]]; then
    warn "Вместе с панелью удалится база со всеми пользователями"
    if confirm "Сначала сделать бэкап?" y; then
      step "Делаю бэкап" do_backup && ok "Бэкап: $BACKUP_PATH"
    fi
  fi
  confirm "Точно удалить «${o[c]%%|*}»?" n || return
  case $what in
    panel) step "Удаляю панель" _uninstall_panel ;;
    sub)   step "Удаляю страницу подписок" _uninstall_sub ;;
    node)  step "Удаляю ноду" _uninstall_node ;;
  esac
}

_uninstall_panel() {
  teardown_panel
  docker volume rm remnawave-caddy-data remnawave-caddy-config >/dev/null 2>&1
  docker network rm remnawave-network >/dev/null 2>&1
  rm -rf "$PANEL_DIR"
  return 0
}

_uninstall_sub() {
  teardown_sub
  docker volume rm remnawave-caddy-data remnawave-caddy-config >/dev/null 2>&1
  docker network rm remnawave-network >/dev/null 2>&1
  rm -rf "$SUB_DIR" "$CADDY_DIR"
  rmdir "$PANEL_DIR" 2>/dev/null
  return 0
}

_uninstall_node() {
  [[ -f $NODE_DIR/docker-compose.yml ]] && (cd "$NODE_DIR" && docker compose down -v --remove-orphans)
  docker rm -f remnanode remnanode-caddy >/dev/null 2>&1
  rm -rf "$NODE_DIR"
  return 0
}

flow_manage() {
  local c
  if ! has docker; then warn "Docker не установлен — управлять нечем"; return 0; fi
  while :; do
    show_status
    menu c "Управление" \
      "Обновить|скачать свежие образы и перезапустить" \
      "Перезапустить|рестарт всех компонентов" \
      "Логи|смотреть логи контейнера" \
      "Бэкап|дамп базы и конфиги → $BACKUP_DIR" \
      "Данные доступа|ссылки, логины, токены" \
      "Удалить|снести компоненты с сервера" \
      "Назад|в главное меню"
    STEP=0 STEPS=0
    case $c in
      0) step "Обновляю компоненты" do_update ;;
      1) step "Перезапускаю" do_restart ;;
      2) show_logs ;;
      3) step "Делаю бэкап" do_backup && ok "Бэкап: $BACKUP_PATH" ;;
      4) show_creds ;;
      5) do_uninstall ;;
      *) return 0 ;;
    esac
  done
}

# ═══════════════════════════════ вопросы ════════════════════════════

ask_admin() {
  ask ADMIN_USER "Логин администратора" "admin" v_user
  ask_secret ADMIN_PASS "Пароль администратора" v_pass "Enter — сгенерирую надёжный (24+ символа: A-Z, a-z, 0-9)" "${MU}сгенерирую"
  if [[ -z $ADMIN_PASS ]]; then
    ADMIN_PASS=$(gen_pass 28)
    ADMIN_PASS_GEN=1
  fi
}

ask_panel_extras() {
  section "Защита и уведомления"
  PANEL_GATE=0
  TG_ON=0
  if confirm "Спрятать панель за секретной ссылкой?" y; then
    PANEL_GATE=1
    GATE_KEY=$(openssl rand -hex 16)
    hint "Без ключа в ссылке домен панели молча рвёт соединение — сканеры её не найдут"
  fi
  if confirm "Уведомления в Telegram?" n; then
    ask TG_TOKEN "Токен бота" "" v_tg_token "Создай бота у @BotFather и вставь его токен"
    ask TG_CHAT "ID чата для уведомлений" "" v_tg_chat "Свой ID покажет @userinfobot; для группы — добавь туда бота"
    TG_ON=1
  fi
}

ask_node_identity() {
  local cc def
  cc=$(detect_country)
  ask COUNTRY "Страна ноды" "$cc" v_cc "Код из двух букв (DE, NL, FI…). По IP похоже на: $cc"
  def="$COUNTRY $(hostname -s 2>/dev/null)"
  def=${def:0:30}
  (( ${#def} < 3 )) && def="Node $COUNTRY"
  ask NODE_NAME "Имя ноды в панели" "$def" v_node_name
}

# ask_reality <порт по умолчанию> <aio|node>
ask_reality() {
  local defport=$1 mode=$2 m s fn=v_reality_port
  [[ $mode == aio ]] && fn=v_port_aio
  section "VPN: VLESS + Reality"
  if [[ $mode == aio ]]; then
    ask REALITY_PORT "Порт для VPN-подключений" "$defport" "$fn" "443 занят панелью, поэтому по умолчанию 8443"
  else
    ask REALITY_PORT "Порт для VPN-подключений" "$defport" "$fn" "443 — лучший вариант для маскировки"
  fi
  STEAL=0
  while :; do
    menu m "Под что маскируем трафик?" \
      "Свой сайт-заглушка|self-steal: ещё один домен на этот сервер — надёжнее всего" \
      "Чужой сайт|маскировка под крупный сайт, домен не нужен"
    if (( m == 0 )); then
      if [[ $mode == node ]] && port_busy 80 && ! port_ours 80; then
        warn "Для заглушки нужен свободный порт 80 (выпуск SSL), а его держит $(port_owner 80)"
        continue
      fi
      STEAL=1
      ask_domain STEAL_DOMAIN "Домен для сайта-заглушки" "Например cdn.example.com — A-запись на $PUBLIC_IP, поставлю на него сайт с SSL"
      REALITY_SNI=$STEAL_DOMAIN
      if [[ $mode == aio ]]; then REALITY_TARGET="127.0.0.1:443"; else REALITY_TARGET="127.0.0.1:9443"; fi
      break
    fi
    menu s "Под какой сайт?" \
      "www.samsung.com|" "www.nvidia.com|" "www.microsoft.com|" "dl.google.com|" "Свой вариант|введу домен сам"
    if (( s == 4 )); then
      ask REALITY_SNI "Домен сайта для маскировки" "" v_domain "Сайт должен поддерживать TLS 1.3 и HTTP/2"
    else
      REALITY_SNI=$MENU_LABEL
    fi
    if spin_run "Проверяю $REALITY_SNI (TLS 1.3 + HTTP/2)" check_sni_tls "$REALITY_SNI"; then
      REALITY_TARGET="$REALITY_SNI:443"
      break
    fi
    warn "$REALITY_SNI не ответил по TLS 1.3/HTTP2 с этого сервера — Reality может не заработать"
    if confirm "Всё равно использовать?" n; then
      REALITY_TARGET="$REALITY_SNI:443"
      break
    fi
  done
  if confirm "Блокировать торренты на ноде?" y; then BLOCK_TORRENT=1; else BLOCK_TORRENT=0; fi
}

# ═══════════════════════════ сценарии установки ═════════════════════

flow_panel() {
  local with_node=$1 c
  local -a L=() P=()
  WITH_PANEL=1 WITH_NODE=$with_node REINSTALL=0 REINSTALL_NODE=0 STEAL=0 TEST_USER_ON=0
  PANEL_GATE=0 TG_ON=0 ADMIN_PASS_GEN=0 NODE_OK=0 SQUAD_UUID="" TEST_SUB_URL="" BACKUP_PATH=""
  USED_DOMAINS=()
  if (( with_node )); then MODE_TITLE="Всё на одном сервере"; else MODE_TITLE="Панель + подписки"; fi
  section "$MODE_TITLE"

  if panel_installed; then
    MENU_DEFAULT=1
    menu c "Панель уже установлена — что делаем?" \
      "Переустановить начисто|бэкап базы → удалить старую → поставить заново" \
      "Назад|в главное меню (обновление — в «Управлении»)"
    (( c == 0 )) || return 1
    REINSTALL=1
  fi
  if (( with_node )) && node_installed; then
    confirm "На сервере уже есть нода — переустановить её?" y || return 1
    REINSTALL_NODE=1
  fi

  section "Домены"
  hint "A-записи обоих доменов должны смотреть на $PUBLIC_IP"
  hint "Cloudflare — только «DNS only» (серое облако), иначе SSL не выпустится"
  ask_domain PANEL_DOMAIN "Домен панели" "например: panel.example.com"
  ask_domain SUB_DOMAIN "Домен страницы подписок" "отдельный поддомен, например: sub.example.com"

  section "Администратор"
  ask_admin

  if (( with_node )); then
    section "VPN-нода на этом же сервере"
    NODE_PORT=2222
    while port_busy "$NODE_PORT" && ! port_ours "$NODE_PORT"; do NODE_PORT=$(( NODE_PORT + 1 )); done
    ask_node_identity
    ask_reality 8443 aio
    HOST_ADDR=$PUBLIC_IP
  fi

  ask_panel_extras
  if (( with_node )); then
    confirm "Создать тестового пользователя для проверки?" y && TEST_USER_ON=1
  fi

  section "Проверим"
  kv "Режим" "$MODE_TITLE"; L+=("$REPLY")
  kv "Панель" "https://$PANEL_DOMAIN"; L+=("$REPLY")
  kv "Подписки" "https://$SUB_DOMAIN"; L+=("$REPLY")
  kv "Админ" "$ADMIN_USER"; L+=("$REPLY")
  if (( PANEL_GATE )); then kv "Защита" "секретная ссылка"; else kv "Защита" "нет"; fi; L+=("$REPLY")
  if (( TG_ON )); then kv "Telegram" "вкл → $TG_CHAT"; else kv "Telegram" "выкл"; fi; L+=("$REPLY")
  if (( with_node )); then
    kv "Нода" "$NODE_NAME · $COUNTRY"; L+=("$REPLY")
    kv "VPN" "VLESS Reality · порт $REALITY_PORT · fp firefox"; L+=("$REPLY")
    if (( STEAL )); then kv "Маскировка" "свой сайт $STEAL_DOMAIN"; else kv "Маскировка" "$REALITY_SNI"; fi; L+=("$REPLY")
    if (( BLOCK_TORRENT )); then kv "Торренты" "блокируются"; else kv "Торренты" "разрешены"; fi; L+=("$REPLY")
  fi
  (( REINSTALL )) && { kv "Внимание" "${YE}старая панель будет удалена (бэкап сделаю)${N}"; L+=("$REPLY"); }
  box "$MODE_TITLE" "${L[@]}"
  confirm "Всё верно — ставим?" y || return 1

  port_guard 80 443
  if ufw_active; then
    FW_RULES=("allow 80/tcp" "allow 443/tcp")
    (( with_node )) && FW_RULES+=("allow $REALITY_PORT/tcp" "allow from 172.16.0.0/12 to any port $NODE_PORT proto tcp")
  fi

  section "Установка"
  P=("Docker и compose|ensure_docker")
  (( REINSTALL )) && P+=("Бэкап старой панели|do_backup" "Удаляю старую панель|teardown_panel")
  (( REINSTALL_NODE )) && P+=("Удаляю старую ноду|teardown_node")
  P+=("Готовлю конфиги панели|write_panel_files"
      "Конфиги страницы подписок|write_sub_files http://remnawave:3000"
      "Конфиг Caddy (HTTPS)|write_panel_caddy")
  (( with_node )) && P+=("Конфиг ноды|write_node_files")
  if (( with_node )); then
    P+=("Скачиваю образы|pull_images $PANEL_DIR $SUB_DIR $CADDY_DIR $NODE_DIR")
  else
    P+=("Скачиваю образы|pull_images $PANEL_DIR $SUB_DIR $CADDY_DIR")
  fi
  P+=("Запускаю базу и панель|start_panel"
      "Жду, пока панель поднимется|wait_panel"
      "Создаю администратора|panel_admin"
      "Выпускаю API-токены|panel_tokens"
      "Запускаю страницу подписок|start_sub"
      "Запускаю Caddy|start_caddy")
  ufw_active && P+=("Открываю порты в ufw|fw_setup")
  if (( with_node )); then
    P+=("Профиль Xray: VLESS Reality|api_profile"
        "Нода, хост и сквад в панели|api_node_local"
        "Запускаю ноду|start_node"
        "Жду, пока нода подключится|wait_node")
  fi
  (( TEST_USER_ON )) && P+=("Тестовый пользователь|api_test_user")
  P+=("SSL-сертификаты|wait_certs_panel" "Команда remna|install_cli")
  run_plan "${P[@]}"

  PANEL_LINK="https://$PANEL_DOMAIN"
  (( PANEL_GATE )) && PANEL_LINK="https://$PANEL_DOMAIN/?auth=$GATE_KEY"
  local -a C=("PANEL_URL=$PANEL_LINK" "ADMIN_USER=$ADMIN_USER" "ADMIN_PASS=$ADMIN_PASS" "SUB_DOMAIN=https://$SUB_DOMAIN"
              "NODES_API_TOKEN=${NODES_API_TOKEN:-}" "SUB_PAGE_API_TOKEN=${SUB_API_TOKEN:-}")
  if (( with_node )); then
    C+=("NODE=$NODE_NAME ($COUNTRY) · VLESS Reality :$REALITY_PORT · SNI $REALITY_SNI · fp firefox"
        "REALITY_PUBLIC_KEY=${REALITY_PUB:-}" "REALITY_SHORT_ID=${REALITY_SID:-}")
  fi
  [[ -n $TEST_SUB_URL ]] && C+=("TEST_USER=$TEST_USER" "TEST_SUB_URL=$TEST_SUB_URL")
  [[ -n $BACKUP_PATH ]] && C+=("OLD_PANEL_BACKUP=$BACKUP_PATH")
  save_creds "${C[@]}"
  final_panel
  return 0
}

flow_node() {
  local c
  local -a L=() P=()
  WITH_PANEL=0 WITH_NODE=1 REINSTALL=0 REINSTALL_NODE=0 STEAL=0 NODE_AUTO=0 NODE_OK=0
  SQUAD_UUID="" SQUAD_NAME="" PANEL_IP="" NODE_SECRET="" REALITY_PORT=""
  USED_DOMAINS=()
  MODE_TITLE="Нода"
  section "Нода Remnawave"

  if node_installed; then
    MENU_DEFAULT=1
    menu c "Нода уже установлена — что делаем?" \
      "Переустановить|снести старую ноду и поставить заново" \
      "Назад|в главное меню"
    (( c == 0 )) || return 1
    REINSTALL_NODE=1
  fi

  menu c "Как подключаем к панели?" \
    "Автоматически|по API-токену — сам создам ноду, профиль Reality и хост" \
    "Вручную|вставлю SECRET_KEY из панели"
  if (( c == 0 )); then
    NODE_AUTO=1
    while :; do
      ask PANEL_URL "Адрес панели" "" v_url "например: https://panel.example.com"
      ask_secret PANEL_TOKEN "API-токен панели" v_nonempty \
        "NODES_API_TOKEN из $CRED_FILE на сервере панели, или: Настройки → API-токены"
      printf '\n'
      spin_run "Проверяю доступ к панели" check_panel_access && break
      err "$CHECK_ERR"
      confirm "Ввести заново?" y || return 1
    done
    choose_squad
    local ph=${PANEL_URL#*://}
    PANEL_IP=$(resolve_a "${ph%%:*}" | head -n1)
    ask_node_identity
    ask NODE_PORT "Порт API ноды (для связи с панелью)" "2222" v_node_port "Наружу его видит только панель"
    ask_reality 443 node
  else
    ask NODE_SECRET "SECRET_KEY ноды" "" v_secret_key "Панель → Ноды → «+» → скопируй значение SECRET_KEY и вставь сюда"
    ask NODE_PORT "NODE_PORT (как указал в панели)" "2222" v_node_port
    if confirm "Поставить сайт-заглушку для Reality (self-steal)?" y; then
      if port_busy 80 && ! port_ours 80; then
        warn "Порт 80 занят ($(port_owner 80)) — без него SSL для заглушки не выпустить, пропускаю"
      else
        STEAL=1
        REALITY_PORT=443
        ask_domain STEAL_DOMAIN "Домен для заглушки" "A-запись на $PUBLIC_IP"
        REALITY_SNI=$STEAL_DOMAIN
      fi
    fi
  fi

  section "Проверим"
  kv "Режим" "Нода · $( (( NODE_AUTO )) && echo 'авто через API' || echo 'вручную')"; L+=("$REPLY")
  kv "IP" "$PUBLIC_IP"; L+=("$REPLY")
  kv "API ноды" "порт $NODE_PORT"; L+=("$REPLY")
  if (( NODE_AUTO )); then
    kv "Панель" "$PANEL_URL"; L+=("$REPLY")
    kv "Нода" "$NODE_NAME · $COUNTRY"; L+=("$REPLY")
    [[ -n $SQUAD_NAME ]] && { kv "Сквад" "$SQUAD_NAME"; L+=("$REPLY"); }
    kv "VPN" "VLESS Reality · порт $REALITY_PORT · fp firefox"; L+=("$REPLY")
    if (( STEAL )); then kv "Маскировка" "свой сайт $STEAL_DOMAIN"; else kv "Маскировка" "$REALITY_SNI"; fi; L+=("$REPLY")
    if (( BLOCK_TORRENT )); then kv "Торренты" "блокируются"; else kv "Торренты" "разрешены"; fi; L+=("$REPLY")
  elif (( STEAL )); then
    kv "Заглушка" "$STEAL_DOMAIN → 127.0.0.1:9443"; L+=("$REPLY")
  fi
  box "Нода" "${L[@]}"
  confirm "Всё верно — ставим?" y || return 1

  (( STEAL )) && port_guard 80
  if ufw_active; then
    FW_RULES=()
    [[ -n $REALITY_PORT ]] && FW_RULES+=("allow $REALITY_PORT/tcp")
    (( STEAL )) && FW_RULES+=("allow 80/tcp")
    if [[ -n $PANEL_IP ]]; then
      FW_RULES+=("allow from $PANEL_IP to any port $NODE_PORT proto tcp")
    else
      FW_RULES+=("allow $NODE_PORT/tcp")
    fi
  fi

  NODE_ADDR=$PUBLIC_IP
  HOST_ADDR=$PUBLIC_IP
  section "Установка"
  P=("Docker и compose|ensure_docker")
  (( REINSTALL_NODE )) && P+=("Удаляю старую ноду|teardown_node")
  P+=("Готовлю конфиги ноды|write_node_files" "Скачиваю образы|pull_images $NODE_DIR")
  (( STEAL )) && P+=("Сайт-заглушка (Caddy)|start_node_caddy")
  (( NODE_AUTO )) && P+=("Профиль Xray: VLESS Reality|api_profile" "Нода, хост и сквад в панели|api_node")
  P+=("Запускаю ноду|start_node")
  ufw_active && P+=("Открываю порты в ufw|fw_setup")
  (( NODE_AUTO )) && P+=("Жду, пока нода подключится|wait_node")
  (( STEAL )) && P+=("SSL для заглушки|wait_certs 127.0.0.1:9443 $STEAL_DOMAIN")
  P+=("Команда remna|install_cli")
  run_plan "${P[@]}"

  local -a C=("NODE_IP=$PUBLIC_IP" "NODE_PORT=$NODE_PORT")
  (( NODE_AUTO )) && C+=("PANEL=$PANEL_URL" "NODE=$NODE_NAME ($COUNTRY) · VLESS Reality :$REALITY_PORT · SNI $REALITY_SNI · fp firefox"
                        "REALITY_PUBLIC_KEY=${REALITY_PUB:-}" "REALITY_SHORT_ID=${REALITY_SID:-}")
  (( STEAL )) && C+=("STEAL_SITE=https://$STEAL_DOMAIN (Caddy на 127.0.0.1:9443)")
  save_creds "${C[@]}"
  final_node
  return 0
}

flow_sub() {
  local c
  local -a L=() P=()
  WITH_PANEL=0 WITH_NODE=0 REINSTALL=0 REINSTALL_NODE=0 STEAL=0
  USED_DOMAINS=()
  MODE_TITLE="Страница подписок"
  section "Страница подписок отдельно"

  if panel_installed; then
    warn "На этом сервере стоит панель — страница подписок уже идёт вместе с ней"
    return 1
  fi
  if sub_installed; then
    MENU_DEFAULT=1
    menu c "Страница подписок уже установлена — что делаем?" \
      "Переустановить|снести и поставить заново" \
      "Назад|в главное меню"
    (( c == 0 )) || return 1
    REINSTALL=1
  fi

  ask_domain SUB_DOMAIN "Домен страницы подписок" "например: sub.example.com — A-запись на $PUBLIC_IP"
  while :; do
    ask PANEL_URL "Адрес панели" "" v_url "например: https://panel.example.com"
    ask_secret PANEL_TOKEN "API-токен панели" v_nonempty "Панель → Настройки → API-токены (или NODES_API_TOKEN из $CRED_FILE)"
    printf '\n'
    spin_run "Проверяю доступ к панели" check_panel_access && break
    err "$CHECK_ERR"
    confirm "Ввести заново?" y || return 1
  done

  section "Проверим"
  kv "Подписки" "https://$SUB_DOMAIN"; L+=("$REPLY")
  kv "Панель" "$PANEL_URL"; L+=("$REPLY")
  box "Страница подписок" "${L[@]}"
  confirm "Всё верно — ставим?" y || return 1

  port_guard 80 443
  ufw_active && FW_RULES=("allow 80/tcp" "allow 443/tcp")

  section "Установка"
  P=("Docker и compose|ensure_docker")
  (( REINSTALL )) && P+=("Удаляю старую установку|teardown_sub")
  P+=("Готовлю конфиги|write_sub_standalone"
      "Скачиваю образы|pull_images $SUB_DIR $CADDY_DIR"
      "Запускаю страницу подписок|start_sub"
      "Запускаю Caddy|start_caddy")
  ufw_active && P+=("Открываю порты в ufw|fw_setup")
  P+=("SSL-сертификат|wait_certs 127.0.0.1:443 $SUB_DOMAIN" "Команда remna|install_cli")
  run_plan "${P[@]}"

  save_creds "SUB_DOMAIN=https://$SUB_DOMAIN" "PANEL=$PANEL_URL"
  final_sub
  return 0
}

# ═══════════════════════════════ финал ══════════════════════════════

_final_header() {
  local title=$1 w
  printf '\n'
  w=$(( COLS > 66 ? 58 : COLS - 8 ))
  wave 34 "$w"
  printf '\n'
  gtext "✦  $title  ✦"
  center "${BLD}${REPLY}"
  printf '\n'
}

_skipped_note() {
  (( ${#SKIPPED[@]} )) || return 0
  printf '\n'
  warn "Пропущены шаги: $(IFS=','; echo "${SKIPPED[*]}" | sed 's/,/, /g')"
  hint "Подробности в $LOG_FILE"
}

final_panel() {
  local -a L=()
  if (( ${#SKIPPED[@]} )); then _final_header "Установка завершена с пропусками"; else _final_header "Готово — Remnawave работает"; fi
  kv "Панель" "${BLD}${PANEL_LINK}${N}"; L+=("$REPLY")
  kv "Логин" "$ADMIN_USER"; L+=("$REPLY")
  kv "Пароль" "$ADMIN_PASS"; L+=("$REPLY")
  kv "Подписки" "https://$SUB_DOMAIN"; L+=("$REPLY")
  if (( WITH_NODE )); then
    if (( NODE_OK )); then kv "Нода" "${GR}●${N} $NODE_NAME · Reality :$REALITY_PORT"; else kv "Нода" "${YE}●${N} $NODE_NAME — проверь в панели"; fi
    L+=("$REPLY")
    kv "Маскировка" "$REALITY_SNI · fp firefox"; L+=("$REPLY")
  fi
  [[ -n ${TEST_USER:-} && -n $TEST_SUB_URL ]] && { kv "Тест-юзер" "$TEST_USER"; L+=("$REPLY"); }
  box "Remnawave" "${L[@]}"
  if (( PANEL_GATE )); then
    printf '\n'
    warn "Сохрани ссылку панели целиком — без ?auth=… домен не откроется"
  fi
  if [[ -n $TEST_SUB_URL ]]; then
    printf '\n'
    info "Подписка тестового юзера — вставь в Happ / v2rayTun / Hiddify:"
    printf '    %s%s%s\n' "$CY" "$TEST_SUB_URL" "$N"
  fi
  if [[ -n ${NODES_API_TOKEN:-} ]]; then
    printf '\n'
    info "Новую ноду на другом сервере — тем же скриптом: «Нода» → «Автоматически»."
    hint "Понадобятся адрес https://$PANEL_DOMAIN и токен NODES_API_TOKEN:"
    printf '    %s%s%s\n' "$MU" "$NODES_API_TOKEN" "$N"
  fi
  printf '\n'
  ok "Всё сохранено в ${BLD}$CRED_FILE${N}"
  ok "Меню управления: ${BLD}remna${N}"
  _skipped_note
  printf '\n'
}

final_node() {
  local -a L=()
  if (( NODE_AUTO )); then
    if (( NODE_OK )); then _final_header "Нода подключена"; else _final_header "Нода установлена"; fi
    kv "Нода" "$NODE_NAME · $COUNTRY"; L+=("$REPLY")
    kv "Адрес" "$PUBLIC_IP:$REALITY_PORT"; L+=("$REPLY")
    kv "Маскировка" "$REALITY_SNI · fp firefox"; L+=("$REPLY")
    if (( NODE_OK )); then kv "Статус" "${GR}● на связи с панелью${N}"; else kv "Статус" "${YE}● панель пока не достучалась${N}"; fi
    L+=("$REPLY")
    [[ -n $SQUAD_NAME ]] && { kv "Сквад" "$SQUAD_NAME"; L+=("$REPLY"); }
    box "Нода" "${L[@]}"
    (( NODE_OK )) || hint "Проверь, что порт $NODE_PORT открыт для IP панели у хостера, и посмотри «remna → Логи → remnanode»"
  else
    _final_header "Нода запущена"
    kv "IP" "$PUBLIC_IP"; L+=("$REPLY")
    kv "NODE_PORT" "$NODE_PORT"; L+=("$REPLY")
    (( STEAL )) && { kv "Заглушка" "https://$STEAL_DOMAIN"; L+=("$REPLY"); }
    box "Нода" "${L[@]}"
    printf '\n'
    info "Что сделать в панели:"
    hint "1. Ноды → твоя нода: адрес $PUBLIC_IP, порт $NODE_PORT → выбери конфиг-профиль"
    if (( STEAL )); then
      hint "2. В профиле inbound VLESS Reality: port 443, target 127.0.0.1:9443,"
      hint "   serverNames [\"$STEAL_DOMAIN\"], xver 0"
      hint "3. Хост: адрес $PUBLIC_IP, порт 443, SNI $STEAL_DOMAIN, fingerprint firefox"
    else
      hint "2. Хост: адрес $PUBLIC_IP, порт как в inbound, fingerprint firefox"
    fi
  fi
  printf '\n'
  ok "Данные — в ${BLD}$CRED_FILE${N}, меню управления: ${BLD}remna${N}"
  _skipped_note
  printf '\n'
}

final_sub() {
  local -a L=()
  _final_header "Страница подписок работает"
  kv "Подписки" "https://$SUB_DOMAIN"; L+=("$REPLY")
  kv "Панель" "$PANEL_URL"; L+=("$REPLY")
  box "Страница подписок" "${L[@]}"
  printf '\n'
  warn "Последний шаг — на сервере ПАНЕЛИ:"
  hint "в /opt/remnawave/.env поставь  SUB_PUBLIC_DOMAIN=$SUB_DOMAIN"
  hint "и перезапусти:  cd /opt/remnawave && docker compose up -d"
  printf '\n'
  ok "Меню управления: ${BLD}remna${N}"
  _skipped_note
  printf '\n'
}

# ════════════════════════════════ main ══════════════════════════════

cleanup() {
  _spin_kill
  _tty_raw_off
  (( ${COLOR:-0} )) && printf '\e[?25h\e[0m'
  [[ -n ${STATUS_FILE:-} ]] && rm -f "$STATUS_FILE"
  return 0
}

on_int() {
  _spin_kill
  _tty_raw_off
  printf '\n\n'
  warn "Прервано (Ctrl+C). Лог: $LOG_FILE"
  printf '\n'
  exit 130
}

preflight() {
  (( EUID == 0 )) || die "Нужен root. Запусти так:  sudo bash <(curl -fsSL $RWI_RAW)"
  OS_PRETTY=$( . /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-Linux}" )
  OS_ID=$( . /etc/os-release 2>/dev/null; echo "${ID:-} ${ID_LIKE:-}" )
  ARCH=$(uname -m)
  [[ $ARCH == @(x86_64|amd64|aarch64|arm64) ]] || die "Архитектура $ARCH не поддерживается (нужна x86_64 или arm64)"
  mkdir -p "$(dirname "$LOG_FILE")"
  touch "$LOG_FILE" && chmod 600 "$LOG_FILE"
  printf '\n════ Remnawave Installer %s · %s ════\n' "$RWI_VERSION" "$(date '+%F %T')" >>"$LOG_FILE"

  STEP=0 STEPS=0
  step "Проверяю систему и базовые пакеты" install_base || die "Без curl/jq/openssl дальше никак. Лог: $LOG_FILE"
  PUBLIC_IP=$(detect_ip)
}

sysinfo() {
  local -a L=()
  local cpu ram ramm disk dv found=()
  cpu=$(nproc 2>/dev/null || echo '?')
  ramm=$(awk '/MemTotal/ {print int($2 / 1024)}' /proc/meminfo 2>/dev/null)
  ram=$(awk '/MemTotal/ {printf "%.1f", $2 / 1048576}' /proc/meminfo 2>/dev/null)
  disk=$(df -h / 2>/dev/null | awk 'NR == 2 {print $4}')
  if dv=$(docker version --format '{{.Server.Version}}' 2>/dev/null) && [[ -n $dv ]]; then
    dv="${GR}✔${N} $dv"
  else
    dv="${MU}нет — поставлю сам${N}"
  fi
  panel_installed && found+=("панель")
  sub_installed && ! panel_installed && found+=("подписки")
  node_installed && found+=("нода")
  case $OS_ID in
    *debian*|*ubuntu*) ;;
    *) OS_PRETTY+=" ${YE}(не тестировалось)${N}" ;;
  esac
  kv "Система" "$OS_PRETTY · $ARCH"; L+=("$REPLY")
  kv "IP" "${PUBLIC_IP:-${RD}не определён${N}}"; L+=("$REPLY")
  kv "Ресурсы" "$cpu vCPU · ${ram:-?} ГБ RAM · ${disk:-?} свободно"; L+=("$REPLY")
  kv "Docker" "$dv"; L+=("$REPLY")
  if (( ${#found[@]} )); then kv "Найдено" "${CY}$(IFS=','; echo "${found[*]}" | sed 's/,/ · /g')${N}"; else kv "Найдено" "${MU}чистый сервер${N}"; fi
  L+=("$REPLY")
  printf '\n'
  box "Сервер" "${L[@]}"
  [[ -n ${ramm:-} ]] && (( ramm < 900 )) && warn "Памяти меньше 1 ГБ — панели будет тесно (для ноды хватит)"
  return 0
}

main_menu() {
  local c
  while :; do
    MENU_DEFAULT=0
    { panel_installed || node_installed || sub_installed; } && MENU_DEFAULT=4
    menu c "Что делаем?" \
      "Всё на один сервер|панель + страница подписок + VPN-нода" \
      "Панель + подписки|без ноды — ноды подключишь потом" \
      "Нода|VPN-сервер для уже установленной панели" \
      "Страница подписок|отдельно, на свой сервер" \
      "Управление|статус, логи, обновление, бэкап, удаление" \
      "Выход|"
    case $c in
      0) flow_panel 1 && return 0 ;;
      1) flow_panel 0 && return 0 ;;
      2) flow_node && return 0 ;;
      3) flow_sub && return 0 ;;
      4) flow_manage ;;
      *) printf '\n'; gtext "До связи ✦"; printf '  %s\n\n' "$REPLY"; return 0 ;;
    esac
  done
}

usage() {
  cat <<EOF
Remnawave Installer v$RWI_VERSION — интерактивная установка Remnawave

  bash <(curl -fsSL $RWI_RAW)

Без аргументов — интерактивное меню. Для крона и скриптов:
  remna backup     бэкап базы и конфигов в $BACKUP_DIR
  remna update     обновить все компоненты
  remna status     состояние контейнеров
EOF
}

main() {
  _fix_locale
  case ${1:-} in
    -h|--help|help) _init_term; usage; return 0 ;;
    -v|--version) echo "$RWI_VERSION"; return 0 ;;
    backup|update|status)
      _init_term
      ANIM=0
      (( EUID == 0 )) || die "Нужен root"
      STATUS_FILE=$(mktemp /tmp/rwi.XXXXXX)
      trap cleanup EXIT
      mkdir -p "$(dirname "$LOG_FILE")"; touch "$LOG_FILE"
      STEP=0 STEPS=0
      case $1 in
        backup) spin_run "Бэкап" do_backup && ok "Бэкап: $BACKUP_PATH" ;;
        update) spin_run "Обновление" do_update ;;
        status) show_status ;;
      esac
      return $?
      ;;
  esac

  if ! { : </dev/tty; } 2>/dev/null; then
    echo "Нужен интерактивный терминал. Запусти так:  bash <(curl -fsSL $RWI_RAW)" >&2
    exit 1
  fi
  _init_term
  STATUS_FILE=$(mktemp /tmp/rwi.XXXXXX)
  trap cleanup EXIT
  trap on_int INT TERM

  intro
  preflight
  sysinfo
  main_menu
}

[[ ${RWI_SOURCED:-} == 1 ]] || main "$@"
