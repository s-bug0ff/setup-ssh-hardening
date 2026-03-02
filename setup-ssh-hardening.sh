#!/usr/bin/env bash
#
# Скрипт настройки SSH: смена порта, UFW, отключение паролей, fail2ban, опционально Netbird.
# Предназначен для Linux (systemd, UFW). Запуск: sudo ./setup-ssh-hardening.sh
#

set -e
set -u

SSHD_CONF="/etc/ssh/sshd_config"

# --- Проверка root ---
if [[ $EUID -ne 0 ]]; then
   echo "Скрипт нужно запускать с правами root (sudo)." >&2
   exit 1
fi

# --- Запрос порта SSH (для шагов 2, 3, 4) ---
ask_port() {
   echo "Введите порт для SSH (например 27391):"
   read -r SSHPORT || true
   SSHPORT="${SSHPORT:-}"
   if ! [[ "${SSHPORT:-}" =~ ^[0-9]+$ ]] || [[ "$SSHPORT" -lt 1 ]] || [[ "$SSHPORT" -gt 65535 ]]; then
      echo "Ошибка: порт должен быть числом от 1 до 65535." >&2
      exit 1
   fi
}

# --- 1) Создание пользователя и добавление в sudo ---
do_create_user() {
   echo ""
   echo "[1] Создание нового пользователя с правами sudo..."
   NEWUSER=""
   while true; do
      echo "Введите имя нового пользователя:"
      read -r NEWUSER
      NEWUSER=$(echo "$NEWUSER" | tr -d '[:space:]')
      if [[ -z "$NEWUSER" ]]; then
         echo "Ошибка: имя пользователя не может быть пустым." >&2
         continue
      fi
      if ! [[ "$NEWUSER" =~ ^[a-zA-Z0-9_.-]+$ ]]; then
         echo "Ошибка: имя может содержать только буквы, цифры, символы _ . -" >&2
         continue
      fi
      if id "$NEWUSER" &>/dev/null; then
         echo "Пользователь '$NEWUSER' уже существует. Введите другое имя или используйте существующего." >&2
         continue
      fi
      break
   done

   NEWPASS=""
   NEWPASS2=""
   while true; do
      echo "Введите пароль для пользователя $NEWUSER:"
      read -rs NEWPASS
      echo ""
      if [[ -z "$NEWPASS" ]]; then
         echo "Ошибка: пароль не может быть пустым." >&2
         continue
      fi
      echo "Повторите пароль:"
      read -rs NEWPASS2
      echo ""
      if [[ "$NEWPASS" != "$NEWPASS2" ]]; then
         echo "Ошибка: пароли не совпадают." >&2
         continue
      fi
      break
   done

   useradd -m -s /bin/bash "$NEWUSER"
   echo "${NEWUSER}:${NEWPASS}" | chpasswd

   if getent group sudo &>/dev/null; then
      usermod -aG sudo "$NEWUSER"
      echo "Пользователь $NEWUSER добавлен в группу sudo."
   elif getent group wheel &>/dev/null; then
      usermod -aG wheel "$NEWUSER"
      echo "Пользователь $NEWUSER добавлен в группу wheel (права sudo)."
   else
      echo "Предупреждение: группы sudo и wheel не найдены. Добавьте пользователя в группу администраторов вручную." >&2
   fi

   echo "Пользователь $NEWUSER создан. Не забудьте скопировать ему SSH-ключ (ssh-copy-id -p PORT $NEWUSER@server) до отключения входа по паролю."
}

# --- 2) Политики SSH: порт, sshd_config, systemd, перезапуск ---
do_ssh_policies() {
   echo ""
   echo "[2] Настройка политик SSH (порт $SSHPORT, sshd_config, systemd)..."
   if [[ ! -f "$SSHD_CONF" ]]; then
      echo "Ошибка: файл $SSHD_CONF не найден." >&2
      exit 1
   fi
   cp -a "$SSHD_CONF" "${SSHD_CONF}.bak.$(date +%Y%m%d%H%M%S)"

   if grep -qE '^[[:space:]]*Port[[:space:]]+' "$SSHD_CONF"; then
      sed -i "s/^[[:space:]]*Port[[:space:]]*.*/Port $SSHPORT/" "$SSHD_CONF"
   else
      echo "Port $SSHPORT" >> "$SSHD_CONF"
   fi

   SOCKET_OVERRIDE_DIR="/etc/systemd/system/ssh.socket.d"
   SOCKET_OVERRIDE="${SOCKET_OVERRIDE_DIR}/override.conf"
   if [[ -d /etc/systemd/system ]]; then
      mkdir -p "$SOCKET_OVERRIDE_DIR"
      cat > "$SOCKET_OVERRIDE" << EOF
[Socket]
ListenStream=
ListenStream=$SSHPORT
EOF
      systemctl daemon-reload
   fi

   set_sshd_param() {
      local key="$1"
      local value="$2"
      if grep -qE "^[[:space:]]*${key}[[:space:]]+" "$SSHD_CONF"; then
         sed -i "s/^[[:space:]]*${key}[[:space:]]*.*/${key} ${value}/" "$SSHD_CONF"
      else
         echo "${key} ${value}" >> "$SSHD_CONF"
      fi
   }
   set_sshd_param "PubkeyAuthentication" "yes"
   set_sshd_param "PasswordAuthentication" "no"
   set_sshd_param "ChallengeResponseAuthentication" "no"
   set_sshd_param "UsePAM" "no"
   set_sshd_param "PermitRootLogin" "no"
   set_sshd_param "PermitEmptyPasswords" "no"

   if command -v sshd &>/dev/null; then
      if ! sshd -t -f "$SSHD_CONF" 2>/dev/null; then
         echo "Ошибка: неверный синтаксис sshd_config после изменений. Восстановите из бэкапа." >&2
         exit 1
      fi
   fi
   systemctl restart ssh.socket 2>/dev/null || true
   systemctl restart sshd.service 2>/dev/null || true
   systemctl restart ssh.service 2>/dev/null || true
   echo "Политики SSH применены, сервис перезапущен."
}

# --- 3) UFW ---
do_ufw() {
   echo ""
   echo "[3] Настройка UFW (порт $SSHPORT и 443)..."
   if command -v ufw &>/dev/null; then
      echo "y" | ufw reset 2>/dev/null || true
      ufw default deny incoming
      ufw default allow outgoing
      ufw allow "${SSHPORT}/tcp" comment 'Allow SSH'
      ufw allow 443/tcp comment 'Allow HTTPS'
      ufw --force enable
      echo "UFW настроен."
   else
      echo "Предупреждение: ufw не найден." >&2
   fi
}

# --- 4) fail2ban ---
do_fail2ban() {
   echo ""
   echo "[4] Установка и настройка fail2ban..."
   if command -v apt-get &>/dev/null; then
      apt-get update -qq
      DEBIAN_FRONTEND=noninteractive apt-get install -y -qq fail2ban
   elif command -v dnf &>/dev/null; then
      dnf install -y fail2ban fail2ban-systemd
   elif command -v yum &>/dev/null; then
      yum install -y fail2ban fail2ban-systemd
   else
      echo "Менеджер пакетов не определён. Установите fail2ban вручную." >&2
      exit 1
   fi

   JAIL_D_DIR="/etc/fail2ban/jail.d"
   mkdir -p "$JAIL_D_DIR"
   cat > "${JAIL_D_DIR}/sshd-local.conf" << FAIL2BAN
[DEFAULT]
ignoreip = 127.0.0.1/8
bantime = 604800
findtime = 86400
maxretry = 3

[sshd]
enabled = true
mode    = aggressive
port    = $SSHPORT
filter  = sshd
logpath = %(sshd_log)s
backend = %(sshd_backend)s
FAIL2BAN

   systemctl enable fail2ban
   systemctl restart fail2ban
   echo "fail2ban установлен и настроен."
}

# --- 5) Netbird ---
do_netbird() {
   echo ""
   echo "[5] Установка Netbird..."
   NETBIRD_KEY=""
   UUID_REGEX='^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$'
   while true; do
      echo "Введите ключ Netbird (формат UUID) или пусто для пропуска:"
      read -r NETBIRD_KEY
      NETBIRD_KEY=$(echo "$NETBIRD_KEY" | tr -d '[:space:]')
      if [[ -z "$NETBIRD_KEY" ]]; then
         echo "Netbird пропущен."
         return 0
      fi
      if [[ "$NETBIRD_KEY" =~ $UUID_REGEX ]]; then
         break
      fi
      echo "Ошибка: неверный формат ключа (ожидается UUID)." >&2
   done

   if ! command -v netbird &>/dev/null; then
      if command -v curl &>/dev/null; then
         curl -fsSL https://pkgs.netbird.io/install.sh | sh
      else
         echo "Ошибка: curl не найден." >&2
         return 1
      fi
   fi
   if netbird up --setup-key "$NETBIRD_KEY"; then
      echo "Netbird установлен и зарегистрирован."
   else
      echo "Предупреждение: не удалось зарегистрировать Netbird." >&2
   fi
}

# --- 6) Проверка переопределения параметров SSH ---
do_check_override() {
   echo ""
   echo "[6] Поиск файлов с переопределением параметров SSH..."
   SSH_PARAMS="PasswordAuthentication|ChallengeResponseAuthentication|UsePAM|PermitRootLogin|PermitEmptyPasswords|PubkeyAuthentication"
   FOUND_FILES=""
   if [[ -d /etc/ssh ]]; then
      FOUND_FILES=$(grep -rEl "^[[:space:]]*(${SSH_PARAMS})[[:space:]]+" /etc/ssh 2>/dev/null || true)
   fi
   if [[ -n "$FOUND_FILES" ]]; then
      echo "Найдены файлы с переопределением этих параметров:"
      echo "$FOUND_FILES" | while read -r f; do
         [[ -n "$f" ]] && echo "  — $f"
      done
   else
      echo "Файлов с переопределением этих параметров не найдено."
   fi
}

# --- Полный сценарий (всё по порядку) ---
run_full_flow() {
   echo ""
   echo "=== Выполнение полного сценария ==="
   do_create_user

   echo ""
   ask_port
   echo ""
   echo "Будет выполнено: UFW, политики SSH (порт $SSHPORT), fail2ban, опционально Netbird."
   echo "Внимание: убедитесь, что у вас есть доступ по ключу."
   echo "Продолжить? (yes/no)"
   read -r CONFIRM || true
   CONFIRM="${CONFIRM:-no}"
   if [[ "$CONFIRM" != "yes" ]]; then
      echo "Отмена."
      exit 0
   fi

   echo "Установить Netbird? (yes/no)"
   read -r INSTALL_NETBIRD || true
   INSTALL_NETBIRD="${INSTALL_NETBIRD:-no}"

   do_ufw
   do_ssh_policies
   do_fail2ban

   if [[ "$INSTALL_NETBIRD" == "yes" ]]; then
      do_netbird
   fi

   do_check_override

   echo ""
   echo "Готово."
   echo "Проверьте подключение: ssh -p $SSHPORT user@this-server"
   echo "Резервная копия sshd_config: ${SSHD_CONF}.bak.*"
   exit 0
}

# --- Меню ---
echo ""
echo "=============================================="
echo "  Настройка безопасности сервера (SSH, UFW)"
echo "=============================================="
echo ""
echo "  1) Создать пользователя (с паролем и sudo)"
echo "  2) Настроить политики SSH (порт, ключ, отключение паролей/root)"
echo "  3) Настроить UFW (только SSH + 443)"
echo "  4) Установить и настроить fail2ban"
echo "  5) Установить Netbird"
echo "  6) Проверить переопределение параметров SSH"
echo "  7) Выполнить всё по порядку (полный сценарий)"
echo "  0) Выход"
echo ""
echo "Введите номер действия или несколько номеров через пробел (например: 1 2 4):"
read -r CHOICE || true
CHOICE=$(echo "${CHOICE:-0}" | tr ',' ' ' | xargs)

if [[ -z "$CHOICE" ]] || [[ "$CHOICE" == "0" ]]; then
   echo "Выход."
   exit 0
fi

# Пункт "7" — полный сценарий (если 7 среди выбранных)
if [[ " $CHOICE " == *" 7 "* ]]; then
   run_full_flow
fi

# Проверка: для 2, 3, 4 нужен порт
NEED_PORT=0
for n in 2 3 4; do
   if [[ " $CHOICE " == *" $n "* ]]; then
      NEED_PORT=1
      break
   fi
done
if [[ "$NEED_PORT" -eq 1 ]]; then
   ask_port
fi

# Выполнение выбранных действий по порядку
for n in 1 2 3 4 5 6; do
   if [[ " $CHOICE " != *" $n "* ]]; then
      continue
   fi
   case "$n" in
      1) do_create_user ;;
      2) do_ssh_policies ;;
      3) do_ufw ;;
      4) do_fail2ban ;;
      5) do_netbird ;;
      6) do_check_override ;;
   esac
done

echo ""
echo "Готово."
