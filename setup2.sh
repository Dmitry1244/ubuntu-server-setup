#!/bin/bash
set -e

# === Цвета ===
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# === Глобальные переменные ===
DRY_RUN=false
LOGFILE="setup.log"
ROLLBACK_DIR="rollback"
TOTAL_STEPS=0
FAILED_STEPS=0
FAILED_LIST=()

mkdir -p "$ROLLBACK_DIR"

# === Логирование ===
log_step() { TOTAL_STEPS=$((TOTAL_STEPS+1)); echo -e "\n${BLUE}[STEP]${NC} $1" | tee -a "$LOGFILE"; }
log_info() { echo -e "${GREEN}[INFO]${NC} $1" | tee -a "$LOGFILE"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" | tee -a "$LOGFILE"; }

# === Выполнение команд ===
run_cmd() {
  if $DRY_RUN; then
    log_info "DRY-RUN: $1"
  else
    log_info "EXEC: $1"
    bash -c "$1" 2>&1 | tee -a "$LOGFILE"
    local status=${PIPESTATUS[0]}
    if [ $status -ne 0 ]; then
      log_error "Команда завершилась с ошибкой: $1"
      FAILED_STEPS=$((FAILED_STEPS+1))
      FAILED_LIST+=("$1")
    fi
  fi
}

# === Backup/Restore ===
backup_file() {
  if [ -f "$1" ]; then
    local backup="$ROLLBACK_DIR/$(basename $1).$(date +%s).bak"
    cp "$1" "$backup"
    log_info "Backup $1 -> $backup"
  fi
}

restore_last_backup() {
  local file="$1"
  local last_backup=$(ls -t $ROLLBACK_DIR/$(basename $file).* 2>/dev/null | head -n1)
  if [ -n "$last_backup" ]; then
    cp "$last_backup" "$file"
    log_info "Восстановлен $file из $last_backup"
  else
    log_error "Нет backup для $file"
  fi
}

# === Модули ===
update_system() {
  log_step "Обновление системы"
  run_cmd "apt-get update -y"
  run_cmd "apt-get upgrade -y"
}

ssh_port() {
  log_step "Смена SSH порта на 20022"
  backup_file /etc/ssh/sshd_config
  run_cmd "sed -i 's/^#Port 22/Port 20022/' /etc/ssh/sshd_config"
  run_cmd "systemctl restart sshd"
}

ufw_setup() {
  log_step "Настройка UFW"
  run_cmd "ufw allow 8443/tcp"
  run_cmd "ufw allow 20022/tcp"
  run_cmd "ufw allow 1985/tcp"
  run_cmd "ufw --force enable"
}

disable_ping() {
  log_step "Запрет ICMP ping"
  run_cmd "echo 'net.ipv4.icmp_echo_ignore_all=1' >> /etc/sysctl.conf"
  run_cmd "sysctl -p"
}

fail2ban_setup() {
  log_step "Установка Fail2ban"
  run_cmd "apt-get install -y fail2ban"
  backup_file /etc/fail2ban/jail.local
  cat <<EOF > /etc/fail2ban/jail.local
[sshd]
enabled = true
port = 20022
logpath = /var/log/auth.log
maxretry = 5
EOF
  run_cmd "systemctl enable fail2ban"
  run_cmd "systemctl restart fail2ban"
}

sqlite_install() {
  log_step "Установка sqlite3"
  run_cmd "apt-get install -y sqlite3"
}

ntp_setup() {
  log_step "Установка и настройка NTP"
  run_cmd "apt-get install -y ntp"
  run_cmd "systemctl enable ntp"
  run_cmd "systemctl start ntp"
}

ntp_status() {
  log_step "Проверка состояния NTP"
  run_cmd "ntpq -p"
}

ssl_selfsigned() {
  log_step "Выпуск самоподписанного SSL сертификата"
  mkdir -p /etc/ssl/selfsigned
  run_cmd "openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout /etc/ssl/selfsigned/server.key \
    -out /etc/ssl/selfsigned/server.crt \
    -subj '/CN=$(hostname)'"
}

install_3xui() {
  log_step "Установка панели 3X-UI"
  run_cmd "bash <(curl -Ls https://raw.githubusercontent.com/MHSanaei/3x-ui/master/install.sh)"
}

# === Итоговая сводка ===
summary() {
  echo -e "\n${YELLOW}========== ИТОГОВАЯ СВОДКА ==========${NC}"
  echo -e "Всего шагов: $TOTAL_STEPS"
  if [ $FAILED_STEPS -eq 0 ]; then
    echo -e "${GREEN}Все шаги выполнены успешно ✅${NC}"
  else
    echo -e "${RED}Ошибок: $FAILED_STEPS ❌${NC}"
    echo "Проблемные команды:"
    for cmd in "${FAILED_LIST[@]}"; do
      echo -e "  - $cmd"
    done
    echo -e "Подробности см. в ${YELLOW}setup.log${NC}"
  fi
  echo -e "${YELLOW}=====================================${NC}\n"
}

# === Main ===
if [[ "$1" == "--dry-run" ]]; then
  DRY_RUN=true
  log_info "Запуск в режиме dry-run"
fi

update_system
ssh_port
ufw_setup
disable_ping
fail2ban_setup
sqlite_install
ntp_setup
ntp_status
ssl_selfsigned
install_3xui

summary
