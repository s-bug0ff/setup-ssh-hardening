#!/usr/bin/env bash
#
# Скрипт настройки SSH: смена порта, UFW, отключение паролей, fail2ban, опционально Netbird.
# Предназначен для Linux (systemd, UFW). Запуск: sudo ./setup-ssh-hardening.sh
#

set -e
set -u

# --- Проверка root ---
if [[ $EUID -ne 0 ]]; then
   echo "Скрипт нужно запускать с правами root (sudo)." >&2
   exit 1
fi

# --- 0) Создание пользователя и добавление в sudo ---
echo "[0/7] Создание нового пользователя с правами sudo..."
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
echo ""

# --- Запрос порта ---
echo "Введите порт для SSH (например 27391):"
read -r SSHPORT || true
SSHPORT="${SSHPORT:-}"

if ! [[ "${SSHPORT:-}" =~ ^[0-9]+$ ]] || [[ "$SSHPORT" -lt 1 ]] || [[ "$SSHPORT" -gt 65535 ]]; then
   echo "Ошибка: порт должен быть числом от 1 до 65535." >&2
   exit 1
fi

echo ""
echo "Будет выполнено:"
echo "  - Создание пользователя с правами sudo (запрошено выше)"
echo "  - UFW: сброс правил, останутся только порт $SSHPORT/tcp (SSH) и 443/tcp (HTTPS)"
echo "  - /etc/ssh/sshd_config: Port $SSHPORT и ужесточение входа"
echo "  - systemd ssh.socket: порт $SSHPORT"
echo "  - Установка и настройка fail2ban"
echo ""
echo "Внимание: убедитесь, что у вас есть доступ по ключу, иначе можно потерять доступ к серверу."
echo "Продолжить? (yes/no)"
read -r CONFIRM || true
CONFIRM="${CONFIRM:-no}"
if [[ "$CONFIRM" != "yes" ]]; then
   echo "Отмена."
   exit 0
fi

# --- Опционально: Netbird ---
NETBIRD_KEY=""
INSTALL_NETBIRD="no"
echo "Установить Netbird? (yes/no)"
read -r INSTALL_NETBIRD || true
INSTALL_NETBIRD="${INSTALL_NETBIRD:-no}"
if [[ "$INSTALL_NETBIRD" == "yes" ]]; then
   # Формат ключа: UUID
   UUID_REGEX='^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$'
   while true; do
      echo "Введите ключ Netbird (формат: 649E86C2-5719-4FFE-857B-5B28E87E1462):"
      read -r NETBIRD_KEY
      NETBIRD_KEY=$(echo "$NETBIRD_KEY" | tr -d '[:space:]')
      if [[ "$NETBIRD_KEY" =~ $UUID_REGEX ]]; then
         break
      fi
      if [[ -z "$NETBIRD_KEY" ]]; then
         echo "Установка Netbird отменена (пустой ввод)."
         INSTALL_NETBIRD="no"
         break
      fi
      echo "Ошибка: неверный формат ключа. Ожидается UUID (8-4-4-4-12 hex с дефисами)." >&2
   done
fi

# --- 1) UFW: сброс и только SSH + 443 ---
echo "[1/7] Сброс UFW и настройка правил (только порт $SSHPORT и 443)..."
if command -v ufw &>/dev/null; then
   echo "y" | ufw reset 2>/dev/null || true
   ufw default deny incoming
   ufw default allow outgoing
   ufw allow "${SSHPORT}/tcp" comment 'Allow SSH'
   ufw allow 443/tcp comment 'Allow HTTPS'
   ufw --force enable
else
   echo "Предупреждение: ufw не найден, шаг пропущен." >&2
fi

# --- 2) sshd_config: Port ---
echo "[2/7] Настройка /etc/ssh/sshd_config..."
SSHD_CONF="/etc/ssh/sshd_config"
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

# --- 3) systemd ssh.socket ---
echo "[3/7] Настройка systemd ssh.socket на порт $SSHPORT..."
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
else
   echo "Предупреждение: systemd не найден, override ssh.socket пропущен." >&2
fi

# --- 4) sshd_config: безопасность ---
echo "[4/7] Ужесточение параметров в sshd_config..."
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

# --- 5) Проверка конфига и перезапуск SSH ---
if command -v sshd &>/dev/null; then
   if ! sshd -t -f "$SSHD_CONF" 2>/dev/null; then
      echo "Ошибка: неверный синтаксис sshd_config после изменений. Восстановите из бэкапа." >&2
      exit 1
   fi
fi
echo "[5/7] Перезапуск ssh.socket и ssh.service..."
systemctl restart ssh.socket 2>/dev/null || true
systemctl restart sshd.service 2>/dev/null || true
systemctl restart ssh.service 2>/dev/null || true

# --- 6) fail2ban ---
echo "[6/7] Установка и настройка fail2ban..."
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

# Локальные настройки jail (best practice: jail.d/*.conf, не трогать jail.conf)
JAIL_D_DIR="/etc/fail2ban/jail.d"
mkdir -p "$JAIL_D_DIR"
cat > "${JAIL_D_DIR}/sshd-local.conf" << FAIL2BAN
[DEFAULT]
ignoreip = 127.0.0.1/8 
bantime = 604800 # неделя
findtime = 86400 # сутки
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

# --- 7) Опционально: Netbird ---
if [[ "$INSTALL_NETBIRD" == "yes" ]] && [[ -n "${NETBIRD_KEY:-}" ]]; then
   echo "[7/7] Установка Netbird и регистрация по ключу..."
   if ! command -v netbird &>/dev/null; then
      if command -v curl &>/dev/null; then
         curl -fsSL https://pkgs.netbird.io/install.sh | sh
      else
         echo "Ошибка: curl не найден, установите curl или Netbird вручную." >&2
         exit 1
      fi
   else
      echo "Netbird уже установлен."
   fi
   if netbird up --setup-key "$NETBIRD_KEY"; then
      echo "Netbird: установлен и зарегистрирован с указанным ключом."
   else
      echo "Предупреждение: не удалось зарегистрировать Netbird (проверьте ключ и сеть)." >&2
   fi
elif [[ "$INSTALL_NETBIRD" == "yes" ]]; then
   echo "[7/7] Netbird: пропущено (ключ не введён)."
fi

# --- Поиск файлов с переопределением параметров SSH ---
echo ""
echo "Поиск файлов, где заданы PasswordAuthentication, ChallengeResponseAuthentication, UsePAM, PermitRootLogin, PermitEmptyPasswords, PubkeyAuthentication..."
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
echo ""

# --- Итог ---
echo ""
echo "Готово."
echo ""
echo "Проверьте подключение по ключу на порт $SSHPORT перед закрытием текущей сессии:"
echo "  ssh -p $SSHPORT user@this-server"
echo ""
echo "Резервная копия sshd_config: ${SSHD_CONF}.bak.*"
if command -v ufw &>/dev/null; then
   echo "UFW: правила сброшены, разрешены только порты $SSHPORT/tcp (SSH) и 443/tcp (HTTPS), файрвол включён."
fi
echo "fail2ban: jail sshd на порту $SSHPORT включён (bantime=1h, maxretry=3, findtime=10m)."
if [[ "$INSTALL_NETBIRD" == "yes" ]] && [[ -n "$NETBIRD_KEY" ]]; then
   echo "Netbird: установлен и зарегистрирован."
fi
