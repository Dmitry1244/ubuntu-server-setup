#!/bin/bash
set -e

# === Framework ===
DRY_RUN=false
LOGFILE="setup.log"
ROLLBACK_DIR="rollback"
mkdir -p "$ROLLBACK_DIR"

log_step() { echo -e "\n[STEP] $1" | tee -a "$LOGFILE"; }
log_info() { echo "[INFO] $1" | tee -a "$LOGFILE"; }
log_error() { echo "[ERROR] $1" | tee -a "$LOGFILE"; }

run_cmd() {
  if $DRY_RUN; then
    log_info "DRY-RUN: $1"
  else
    log_info "EXEC: $1"
    eval "$1" >>"$LOGFILE" 2>&1 || {
      log_error "Команда не выполнена: $1"
      exit 1
    }
  fi
}

backup_file() {
  if [ -f "$1" ]; then
    local backup="$ROLLBACK_DIR/$(basename $1).$(date +%s).bak"
    cp "$1" "$backup"
    log_info "Backup $1 -> $backup"
  fi
}

# === Modules as functions ===
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
