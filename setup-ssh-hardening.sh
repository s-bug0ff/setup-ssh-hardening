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

# --- Проверка интерактивного терминала (иначе read не работает, скрипт сразу выходит) ---
if [[ ! -t 0 ]]; then
   echo "Скрипт нужно запускать в интерактивном терминале (не через pipe/cron)." >&2
   echo "Выполните: curl -sL -o /tmp/setup-ssh-hardening.sh https://raw.githubusercontent.com/s-bug0ff/setup-ssh-hardening/main/setup-ssh-hardening.sh" >&2
   echo "Затем: sudo bash /tmp/setup-ssh-hardening.sh" >&2
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

   # Удаляем все строки с Port (в том числе закомментированные), затем добавляем свою
   sed -i '/^[[:space:]]*#\{0,1\}[[:space:]]*Port[[:space:]]/d' "$SSHD_CONF"
   echo "Port $SSHPORT" >> "$SSHD_CONF"

   # Override ssh.socket: явно IPv4 и IPv6, иначе на новых Ubuntu сокет может слушать только IPv6 → Connection refused по IPv4
   SOCKET_OVERRIDE_DIR="/etc/systemd/system/ssh.socket.d"
   SOCKET_OVERRIDE="${SOCKET_OVERRIDE_DIR}/override.conf"
   if [[ -d /etc/systemd/system ]]; then
      mkdir -p "$SOCKET_OVERRIDE_DIR"
      cat > "$SOCKET_OVERRIDE" << EOF
[Socket]
ListenStream=
ListenStream=0.0.0.0:${SSHPORT}
ListenStream=[::]:${SSHPORT}
EOF
      systemctl daemon-reload
   fi

   set_sshd_param() {
      local key="$1"
      local value="$2"
      # Удаляем все строки с этим параметром (в том числе закомментированные)
      sed -i '/^[[:space:]]*#\{0,1\}[[:space:]]*'"${key}"'[[:space:]]/d' "$SSHD_CONF"
      echo "${key} ${value}" >> "$SSHD_CONF"
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
      # PYTHONWARNINGS=ignore подавляет SyntaxWarning из тестов fail2ban (пакет Ubuntu)
      DEBIAN_FRONTEND=noninteractive PYTHONWARNINGS=ignore apt-get install -y -qq fail2ban
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

# --- 8) Откат изменений ---
do_rollback() {
   echo ""
   echo "[8] Откат изменений (sshd_config, systemd, UFW; опционально — fail2ban, Netbird)..."
   echo "Будет восстановлен sshd_config из бэкапа, убран override ssh.socket, UFW — разрешены только 22 и 443."
   echo "Откат fail2ban и Netbird — по вашему выбору."
   echo "Продолжить? (yes/no)"
   read -r CONFIRM || true
   CONFIRM="${CONFIRM:-no}"
   if [[ "$CONFIRM" != "yes" ]]; then
      echo "Откат отменён."
      return 0
   fi

   # 1) Восстановление sshd_config из последнего бэкапа
   SSHD_BAK=$(ls -t "${SSHD_CONF}.bak."* 2>/dev/null | head -1)
   if [[ -n "$SSHD_BAK" ]] && [[ -f "$SSHD_BAK" ]]; then
      cp -a "$SSHD_BAK" "$SSHD_CONF"
      echo "  sshd_config восстановлен из $SSHD_BAK"
   else
      echo "  Предупреждение: бэкап sshd_config не найден (${SSHD_CONF}.bak.*), шаг пропущен." >&2
   fi

   # 2) Удаление override systemd для ssh.socket
   SOCKET_OVERRIDE_DIR="/etc/systemd/system/ssh.socket.d"
   if [[ -d "$SOCKET_OVERRIDE_DIR" ]]; then
      rm -rf "$SOCKET_OVERRIDE_DIR"
      systemctl daemon-reload
      echo "  Удалён $SOCKET_OVERRIDE_DIR"
   fi

   # 3) Перезапуск SSH (порт снова из sshd_config, обычно 22)
   if command -v sshd &>/dev/null; then
      sshd -t -f "$SSHD_CONF" 2>/dev/null || true
   fi
   systemctl restart ssh.socket 2>/dev/null || true
   systemctl restart sshd.service 2>/dev/null || true
   systemctl restart ssh.service 2>/dev/null || true
   echo "  SSH перезапущен (порт по умолчанию из конфига)"

   # 4) Опционально: удаление настроек fail2ban для sshd (jail)
   echo ""
   read -r -p "Удалить настройки fail2ban для sshd (jail sshd-local.conf)? (yes/no): " ROLLBACK_FAIL2BAN
   ROLLBACK_FAIL2BAN="${ROLLBACK_FAIL2BAN:-no}"
   if [[ "$ROLLBACK_FAIL2BAN" == "yes" ]]; then
      JAIL_LOCAL="/etc/fail2ban/jail.d/sshd-local.conf"
      if [[ -f "$JAIL_LOCAL" ]]; then
         rm -f "$JAIL_LOCAL"
         if systemctl is-active --quiet fail2ban 2>/dev/null; then
            systemctl restart fail2ban
         fi
         echo "  Удалён $JAIL_LOCAL, fail2ban перезапущен"
      else
         echo "  Файл $JAIL_LOCAL не найден"
      fi
   else
      echo "  fail2ban: без изменений"
   fi

   # 5) Опционально: остановить и удалить Netbird
   echo ""
   read -r -p "Остановить и удалить Netbird? (yes/no): " ROLLBACK_NETBIRD
   ROLLBACK_NETBIRD="${ROLLBACK_NETBIRD:-no}"
   if [[ "$ROLLBACK_NETBIRD" == "yes" ]]; then
      if command -v netbird &>/dev/null; then
         netbird down 2>/dev/null || true
         echo "  Netbird остановлен"
      fi
      if command -v apt-get &>/dev/null; then
         apt-get remove -y netbird 2>/dev/null && echo "  Пакет netbird удалён" || true
      elif command -v dnf &>/dev/null; then
         dnf remove -y netbird 2>/dev/null && echo "  Пакет netbird удалён" || true
      elif command -v yum &>/dev/null; then
         yum remove -y netbird 2>/dev/null && echo "  Пакет netbird удалён" || true
      else
         echo "  Удалите Netbird вручную, если установлен через скрипт"
      fi
   else
      echo "  Netbird: без изменений"
   fi

   # 6) UFW: сброс и только 22 (SSH) + 443 (HTTPS)
   if command -v ufw &>/dev/null; then
      echo "y" | ufw reset 2>/dev/null || true
      ufw default deny incoming
      ufw default allow outgoing
      ufw allow 22/tcp comment 'Allow SSH'
      ufw allow 443/tcp comment 'Allow HTTPS'
      ufw --force enable
      echo "  UFW: разрешены только порты 22 и 443"
   fi

   echo ""
   echo "Откат выполнен. Подключайтесь по умолчанию: ssh user@<IP> (порт 22)."
   echo "Созданные скриптом пользователи не удаляются. Удалить вручную: sudo userdel -r USERNAME"
}

# --- Полный сценарий (всё по порядку) ---
run_full_flow() {
   echo ""
   echo "=== Выполнение полного сценария ==="
   do_create_user

   echo ""
   echo "--- Важно: скопируйте SSH-ключ новому пользователю ДО продолжения ---"
   echo "Из другого терминала выполните (порт 22 пока ещё действует):"
   echo "  ssh-copy-id -p 22 $NEWUSER@<IP_ЭТОГО_СЕРВЕРА>"
   echo "Проверьте вход: ssh -p 22 $NEWUSER@<IP_СЕРВЕРА>"
   echo "После проверки вернитесь сюда и продолжите."
   echo ""
   read -r -p "Ключ скопирован и вход по ключу проверен? Введите yes для продолжения: " CONFIRM_KEY
   CONFIRM_KEY="${CONFIRM_KEY:-no}"
   if [[ "$CONFIRM_KEY" != "yes" ]]; then
      echo "Отмена. Сначала скопируйте ключ и проверьте вход."
      exit 0
   fi

   echo ""
   ask_port
   echo ""
   echo "Будет выполнено: смена порта SSH на $SSHPORT, UFW, отключение входа по паролю, fail2ban, опционально Netbird."
   echo ""
   echo "!!! Иначе будет 'Connection refused' при подключении !!!"
   echo "После выполнения скрипта ОБЯЗАТЕЛЬНО откройте в панели хостинга (Hetzner Cloud / DigitalOcean / Selectel / и т.д.) входящий TCP-порт $SSHPORT (Firewall / Security groups / Сеть)."
   echo ""
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

   # Сначала UFW (открываем новый порт), потом смена порта и перезапуск sshd
   do_ufw
   echo ""
   echo "Сейчас будет перезапущен SSH. Сессия может оборваться — подключайтесь заново: ssh -p $SSHPORT $NEWUSER@<IP>"
   do_ssh_policies
   do_fail2ban

   if [[ "$INSTALL_NETBIRD" == "yes" ]]; then
      do_netbird
   fi

   do_check_override

   echo ""
   echo "Готово."
   echo ""
   echo "=============================================="
   echo "  ЧТО СДЕЛАТЬ СЕЙЧАС (иначе Connection refused):"
   echo "=============================================="
   echo "  1. Панель хостинга → Firewall / Security groups → добавить входящее правило: TCP порт $SSHPORT"
   echo "  2. Подключение: ssh -p $SSHPORT $NEWUSER@<IP_СЕРВЕРА> -i <путь_к_ключу>"
   echo "=============================================="
   echo ""
   echo "fail2ban: 3 неудачные попытки = бан на неделю; свой IP можно добавить в ignoreip в /etc/fail2ban/jail.d/sshd-local.conf"
   echo "Резервная копия sshd_config: ${SSHD_CONF}.bak.*"
   return 0
}

# --- Главный цикл меню ---
while true; do
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
echo "  8) Откатить изменения (sshd, systemd, fail2ban, UFW)"
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
   continue
fi

# Пункт "8" — откат изменений
if [[ " $CHOICE " == *" 8 "* ]]; then
   do_rollback
   continue
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
# Пункт 8 обрабатывается выше (continue)

echo ""
echo "Готово."
if [[ "${NEED_PORT:-0}" -eq 1 ]] && [[ -n "${SSHPORT:-}" ]]; then
   echo ""
   echo "Напоминание: откройте TCP-порт $SSHPORT в панели хостинга (Firewall / Security groups), иначе при подключении будет Connection refused."
   echo "  ssh -p $SSHPORT user@<IP> -i <ключ>"
fi
done
