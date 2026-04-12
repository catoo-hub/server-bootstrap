#!/usr/bin/env bash
# ==============================================================================
#  server-bootstrap.sh — Production-ready server/node setup script
#
#  Author:  Kitsura VPN
#  Version: 1.0.0 V2 - MAY INCORRUPT
# ==============================================================================

###############################################################################
#  Настройки и глобальные переменные
###############################################################################
set -euo pipefail
IFS=$'\n\t'

# Цвета и символы для красивого CLI (по мотивам шаблона gist):contentReference[oaicite:4]{index=4}
RESET="$(tput sgr0)"
BOLD="$(tput bold)"
RED="$(tput setaf 1)"
GREEN="$(tput setaf 2)"
YELLOW="$(tput setaf 3)"
BLUE="$(tput setaf 4)"
CYAN="$(tput setaf 6)"
MAGENTA="$(tput setaf 5)"
SYMBOL_TICK="✔"
SYMBOL_CROSS="✖"
SYMBOL_WARN="⚠"
SYMBOL_INFO="ℹ"

# Путь к файлу лога
LOG_FILE="/var/log/server-bootstrap.log"

# Опции запуска
DRY_RUN=0
VERBOSE=0
MODE=""
SKIP_SELFSTEAL=0
GATE_ADDRESS=""

###############################################################################
#  Функции логирования
###############################################################################
log_debug() {
  [[ "${VERBOSE}" -eq 1 ]] && echo -e "${CYAN}[DEBUG] $*${RESET}" | tee -a "${LOG_FILE}"
}

log_info() {
  echo -e "${BLUE}${SYMBOL_INFO} $*${RESET}" | tee -a "${LOG_FILE}"
}

log_ok() {
  echo -e "${GREEN}${SYMBOL_TICK} $*${RESET}" | tee -a "${LOG_FILE}"
}

log_warn() {
  echo -e "${YELLOW}${SYMBOL_WARN} $*${RESET}" | tee -a "${LOG_FILE}"
}

log_error() {
  echo -e "${RED}${BOLD}${SYMBOL_CROSS} $*${RESET}" | tee -a "${LOG_FILE}" >&2
}

###############################################################################
#  Трап для перехвата ошибок и выхода
###############################################################################
trap 'log_error "Произошла критическая ошибка на строке ${LINENO}. Просмотрите лог ${LOG_FILE}." ; exit 1' ERR

###############################################################################
#  Вспомогательные функции
###############################################################################
# Проверка запуска от root
check_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    log_error "Скрипт должен быть запущен с root‑правами."
    exit 1
  fi
}

# Проверка ОС/версии/архитектуры/виртуализации
detect_system() {
  OS_NAME="$(. /etc/os-release && echo "$NAME")"
  OS_VERSION_ID="$(. /etc/os-release && echo "$VERSION_ID")"
  ARCH="$(uname -m)"
  VIRT="$(systemd-detect-virt || true)"
  log_info "ОС: ${OS_NAME} ${OS_VERSION_ID}, архитектура: ${ARCH}, виртуализация: ${VIRT}"
  if [[ "${VIRT}" =~ "openvz" || "${VIRT}" =~ "lxc" ]]; then
    log_warn "Обнаружена контейнерная виртуализация (${VIRT}). Некоторые функции могут быть недоступны."
  fi
}

# Выполнение команд с учётом dry-run
run_cmd() {
  local cmd="$*"
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log_info "[DRY‑RUN] ${cmd}"
  else
    log_debug "Выполняется: ${cmd}"
    eval "${cmd}"
  fi
}

# Создание бэкапа файла
backup_file() {
  local file="$1"
  [[ -f "${file}" ]] || return 0
  local ts
  ts="$(date +%Y%m%d%H%M%S)"
  cp -p "${file}" "${file}.bak.${ts}"
  log_info "Сделан бэкап ${file} → ${file}.bak.${ts}"
}

# Запрос подтверждения
ask_confirm() {
  local prompt="$1"
  read -r -p "${prompt} [y/N]: " ans
  [[ "${ans:-}" =~ ^([yY][eE]?[sS]?|[yY])$ ]]
}

###############################################################################
#  Idempotent изменение sysctl
###############################################################################
# Применяет или обновляет параметр в конфигурационном файле
set_sysctl_param() {
  local file="$1"
  local key="$2"
  local value="$3"
  if grep -qE "^[#\s]*${key}\s*=" "${file}"; then
    # заменить существующее значение
    run_cmd "sed -ri 's#^[#\\s]*${key}\\s*=.*#${key} = ${value}#' ${file}"
    log_info "Обновлено ${key} в ${file}"
  else
    # добавить параметр
    run_cmd "echo '${key} = ${value}' >> ${file}"
    log_info "Добавлено ${key} в ${file}"
  fi
}

# Настройка сетевых sysctl (одинаковая для node/gate/bs)
configure_network_sysctl() {
  local sysctl_file="/etc/sysctl.d/99-custom-network.conf"
  backup_file "${sysctl_file}"
  run_cmd "touch ${sysctl_file}"
  # Основные настройки (автотюнинг буферов, BBR и прочее)
  set_sysctl_param "${sysctl_file}" "net.ipv4.tcp_rmem" "4096 131072 16777216"
  set_sysctl_param "${sysctl_file}" "net.ipv4.tcp_wmem" "4096 65536 16777216"
  set_sysctl_param "${sysctl_file}" "net.ipv4.tcp_mem" "786432 1048576 1572864"
  set_sysctl_param "${sysctl_file}" "net.ipv4.tcp_window_scaling" "1"
  set_sysctl_param "${sysctl_file}" "net.ipv4.tcp_sack" "1"
  set_sysctl_param "${sysctl_file}" "net.ipv4.tcp_timestamps" "1"
  set_sysctl_param "${sysctl_file}" "net.core.default_qdisc" "fq"
  set_sysctl_param "${sysctl_file}" "net.ipv4.tcp_congestion_control" "bbr"
}

# Дополнительные sysctl для режима bs/роутер
configure_router_sysctl() {
  local sysctl_file="/etc/sysctl.d/99-custom-network.conf"
  set_sysctl_param "${sysctl_file}" "net.ipv4.icmp_echo_ignore_all" "1"
  set_sysctl_param "${sysctl_file}" "net.ipv6.conf.all.disable_ipv6" "1"
  set_sysctl_param "${sysctl_file}" "net.ipv6.conf.default.disable_ipv6" "1"
  set_sysctl_param "${sysctl_file}" "net.ipv6.conf.lo.disable_ipv6" "1"
}

# Применить изменения sysctl
apply_sysctl() {
  log_info "Применяем sysctl…"
  run_cmd "sysctl --system"
}

###############################################################################
#  Настройка UFW и Fail2Ban
###############################################################################
setup_ufw() {
  log_info "Устанавливаем UFW…"
  run_cmd "apt-get update -qq"
  run_cmd "apt-get install -y ufw"

  # Проверяем текущий порт SSH
  local ssh_port
  ssh_port="$(awk '/^Port /{print $2}' /etc/ssh/sshd_config | tail -n1)"
  ssh_port="${ssh_port:-22}"

  # Разрешаем SSH до активации, чтобы не потерять соединение:contentReference[oaicite:5]{index=5}
  run_cmd "ufw allow ${ssh_port}/tcp"

  # Дополнительные правила
  if [[ "${MODE}" == "bs" ]]; then
    run_cmd "ufw allow 443/tcp"
  elif [[ "${MODE}" == "gate" ]]; then
    run_cmd "ufw allow 443/tcp"
  fi

  # Настройки по умолчанию
  run_cmd "ufw default deny incoming"
  run_cmd "ufw default allow outgoing"

  # Включаем UFW
  if ! ufw status | grep -q "Status: active"; then
    run_cmd "ufw --force enable"
    log_ok "UFW активирован"
  else
    log_info "UFW уже активен"
  fi
}

setup_fail2ban() {
  log_info "Устанавливаем Fail2Ban…"
  run_cmd "apt-get install -y fail2ban"

  local jail_local="/etc/fail2ban/jail.local"
  backup_file "${jail_local}"
  cat > "${jail_local}" <<'EOF'
[DEFAULT]
bantime  = 10m
findtime = 10m
maxretry = 5
backend = systemd

[sshd]
enabled = true
port    = ssh
EOF
  log_ok "Fail2Ban настроен"
  run_cmd "systemctl restart fail2ban"
  run_cmd "systemctl enable fail2ban"
}

###############################################################################
#  Установка мобильного фильтра mobile443-filter
###############################################################################
install_mobile443_filter() {
  local mode="$1"  # node/gate/bs
  log_info "Установка mobile443-filter (${mode})…"
  local url=""
  case "${mode}" in
    node) url="https://raw.githubusercontent.com/wh3r3ar3you/mobile443-filter/refs/heads/main/install.sh" ;;
    gate) url="https://raw.githubusercontent.com/wh3r3ar3you/mobile443-filter/refs/heads/main/install_block_only.sh" ;;
    bs)   url="https://raw.githubusercontent.com/wh3r3ar3you/mobile443-filter/refs/heads/main/install.sh" ;;
  esac
  if ! command -v curl &>/dev/null; then
    log_error "curl не установлен. Установите его вручную."
    return
  fi
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log_info "[DRY‑RUN] скачал бы ${url}"
  else
    bash <(curl -Ls "${url}") || log_error "Не удалось установить mobile443-filter"
  fi
}

###############################################################################
#  Установка remnanode
###############################################################################
install_remnanode() {
  log_info "Установка remnanode…"
  if ! command -v curl &>/dev/null; then
    log_error "curl не установлен, remnanode не будет установлен"
    return
  fi
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log_info "[DRY‑RUN] запуск установки remnanode"
  else
    bash <(curl -Ls https://github.com/DigneZzZ/remnawave-scripts/raw/main/remnanode.sh) @ install || \
      log_error "Установка remnanode завершилась ошибкой"
  fi
}

###############################################################################
#  Установка selfsteal
###############################################################################
install_selfsteal() {
  if [[ "${SKIP_SELFSTEAL}" -eq 1 ]]; then
    log_info "Установка selfsteal пропущена (--skip-selfsteal)"
    return
  fi
  log_info "Установка selfsteal…"
  if ! command -v curl &>/dev/null; then
    log_error "curl не установлен, selfsteal не будет установлен"
    return
  fi
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log_info "[DRY‑RUN] запуск установки selfsteal"
  else
    bash <(curl -Ls https://github.com/DigneZzZ/remnawave-scripts/raw/main/selfsteal.sh) @ install || \
      log_error "Установка selfsteal завершилась ошибкой"
  fi
}

###############################################################################
#  Настройка haproxy для режима bs (роутер)
###############################################################################
setup_haproxy() {
  log_info "Установка и настройка HAProxy (режим bs)…"
  if [[ -z "${GATE_ADDRESS}" ]]; then
    read -r -p "Введите IP адрес gate для проксирования TCP 443: " GATE_ADDRESS
  fi
  # простая валидация IP
  if ! [[ "${GATE_ADDRESS}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    log_error "Неверный IP: ${GATE_ADDRESS}"
    return
  fi
  run_cmd "apt-get install -y haproxy"
  local haproxy_cfg="/etc/haproxy/haproxy.cfg"
  backup_file "${haproxy_cfg}"
  cat > "${haproxy_cfg}" <<EOF
global
    log /dev/log local0
    maxconn 50000

defaults
    mode tcp
    timeout connect 5s
    timeout client 50s
    timeout server 50s
    log global

frontend ft_xray
    bind *:443
    default_backend bk_xray

backend bk_xray
    server xray ${GATE_ADDRESS}:443 send-proxy-v2
EOF
  # Проверить конфиг перед перезапуском
  if haproxy -c -f "${haproxy_cfg}"; then
    run_cmd "systemctl restart haproxy"
    run_cmd "systemctl enable haproxy"
    log_ok "HAProxy настроен и запущен"
  else
    log_error "Конфигурация HAProxy содержит ошибки. Откатываемся."
    cp -p "${haproxy_cfg}.bak."* "${haproxy_cfg}"
  fi
}

###############################################################################
#  Базовая подготовка сервера (mode=base)
###############################################################################
mode_base() {
  log_info "Запуск базовой подготовки"
  run_cmd "apt-get update -y && apt-get upgrade -y"
  run_cmd "apt-get install -y curl wget git unzip tar jq vim nano htop net-tools dnsutils iproute2 ufw fail2ban socat tcpdump mtr ca-certificates"
  # настройка timezone в noninteractive режиме — например Europe/Helsinki
  run_cmd "timedatectl set-timezone Europe/Helsinki"
  # базовая настройка SSH: разрешить root login? (оставляем неизменным, делаем backup)
  backup_file "/etc/ssh/sshd_config"
  # пример: включим ClientAliveInterval, если его нет
  if ! grep -q "^ClientAliveInterval" /etc/ssh/sshd_config; then
    echo "ClientAliveInterval 300" >> /etc/ssh/sshd_config
  fi
  run_cmd "systemctl reload sshd"
  configure_network_sysctl
  apply_sysctl
  setup_ufw
  setup_fail2ban
  log_ok "Базовая подготовка завершена"
}

###############################################################################
#  Обычная нода (mode=node)
###############################################################################
mode_node() {
  mode_base
  install_mobile443_filter "node"
  install_remnanode
  install_selfsteal
  log_ok "Режим обычной ноды выполнен"
}

###############################################################################
#  Gate нода (mode=gate)
###############################################################################
mode_gate() {
  mode_base
  install_mobile443_filter "gate"
  install_remnanode
  install_selfsteal
  log_ok "Режим gate ноды выполнен"
}

###############################################################################
#  BS (роутер) режим (mode=bs)
###############################################################################
mode_bs() {
  mode_base
  configure_router_sysctl
  apply_sysctl
  setup_haproxy
  install_mobile443_filter "bs"
  # remnanode и selfsteal не устанавливаем в bs, как указано в ТЗ
  log_ok "Режим bs/роутер выполнен"
}

###############################################################################
#  Пользовательский режим (mode=custom)
###############################################################################
mode_custom() {
  log_info "Выбран пользовательский режим"
  # последовательное меню выбора компонентов
  select opt in "Сетевые sysctl" "UFW" "Fail2Ban" "mobile443-filter" "remnanode" "selfsteal" "HAProxy (bs mode)" "Выход"; do
    case ${REPLY} in
      1) configure_network_sysctl && apply_sysctl ;;
      2) setup_ufw ;;
      3) setup_fail2ban ;;
      4) read -r -p "Выберите режим mobile443 (node/gate/bs): " m; install_mobile443_filter "${m}" ;;
      5) install_remnanode ;;
      6) install_selfsteal ;;
      7) setup_haproxy ;;
      8) break ;;
      *) log_warn "Неверный выбор" ;;
    esac
  done
}

###############################################################################
#  Парсер аргументов
###############################################################################
usage() {
cat <<EOF
Использование: $0 [опции]

--mode <base|node|gate|bs|custom>   режим работы
--dry-run                           выводить команды, но не выполнять
--verbose                           подробный вывод
--skip-selfsteal                    пропустить установку selfsteal
--gate <IP>                         IP адрес gate для режима bs
--help                              показать справку

Пример неинтерактивного запуска:
  $0 --mode node --verbose

EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --mode) MODE="$2"; shift 2 ;;
      --dry-run) DRY_RUN=1; shift ;;
      --verbose) VERBOSE=1; shift ;;
      --skip-selfsteal) SKIP_SELFSTEAL=1; shift ;;
      --gate) GATE_ADDRESS="$2"; shift 2 ;;
      --help|-h) usage; exit 0 ;;
      *) log_error "Неизвестный параметр: $1"; usage; exit 1 ;;
    esac
  done
}

###############################################################################
#  Интерактивное меню
###############################################################################
interactive_menu() {
  PS3="Выберите режим (или 6 для выхода): "
  select MODE in "base" "node" "gate" "bs" "custom" "выход"; do
    case ${REPLY} in
      1|2|3|4|5)
        break ;;
      6)
        log_info "Выход."
        exit 0 ;;
      *)
        log_warn "Неверный выбор" ;;
    esac
  done
}

###############################################################################
#  Главная функция
###############################################################################
main() {
  check_root
  parse_args "$@"
  detect_system

  # Если режим не указан, спрашиваем интерактивно
  if [[ -z "${MODE}" ]]; then
    interactive_menu
  fi

  case "${MODE}" in
    base) mode_base ;;
    node) mode_node ;;
    gate) mode_gate ;;
    bs)   mode_bs ;;
    custom) mode_custom ;;
    *) log_error "Неизвестный режим: ${MODE}" ; usage ; exit 1 ;;
  esac

  log_ok "Все задачи в режиме ${MODE} завершены"
}

main "$@"
