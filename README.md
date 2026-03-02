# setup-ssh-hardening

Скрипт настройки и усиления безопасности Linux-сервера: создание пользователя с sudo, смена порта SSH, UFW, вход только по ключу, отключение паролей и входа под root, fail2ban, опционально Netbird. Есть откат изменений и возврат в главное меню после каждого действия.

## Что делает скрипт

| Действие | Описание |
|----------|----------|
| **1. Пользователь** | Имя и пароль, `useradd`, добавление в группу `sudo` или `wheel`. |
| **2. Политики SSH** | Порт в `sshd_config`, override `ssh.socket` (явно IPv4 и IPv6), параметры: `PubkeyAuthentication yes`, `PasswordAuthentication no`, `ChallengeResponseAuthentication no`, `UsePAM no`, `PermitRootLogin no`, `PermitEmptyPasswords no`. Удаляются закомментированные и активные строки с этими параметрами. Бэкап конфига перед правками. |
| **3. UFW** | Сброс правил; разрешены только выбранный порт SSH (TCP) и 443 (HTTPS). |
| **4. fail2ban** | Установка и jail для SSH: `bantime = 604800` (неделя), `findtime = 86400` (сутки), `maxretry = 3`, `mode = aggressive`, `ignoreip = 127.0.0.1/8`. Файл: `/etc/fail2ban/jail.d/sshd-local.conf`. |
| **5. Netbird** | Опционально: установка и регистрация по setup-ключу (UUID). Пустой ввод — пропуск. |
| **6. Проверка** | Поиск файлов в `/etc/ssh`, где переопределены ключевые параметры SSH. |
| **7. Полный сценарий** | Пункты 1 → подтверждение ключа → порт → UFW → политики SSH → fail2ban → опционально Netbird → проверка. |
| **8. Откат** | Восстановление `sshd_config` из последнего бэкапа, удаление override `ssh.socket`, перезапуск SSH, UFW только 22 и 443. Опционально: удаление jail fail2ban для sshd и/или остановка и удаление Netbird. Созданные пользователи не удаляются. |

Поддерживаются дистрибутивы с **systemd**, **UFW** и пакетными менеджерами **apt** (Debian/Ubuntu), **dnf** / **yum** (RHEL/Fedora и др.).

## Меню

При запуске выводится меню. Можно ввести один номер, несколько через пробел (например `1 2 4`) или `7` для полного сценария. После выполнения скрипт снова показывает меню; выход — только по `0` или пустому вводу.

| № | Действие |
|---|----------|
| 1 | Создать пользователя (с паролем и sudo) |
| 2 | Настроить политики SSH (порт, ключ, отключение паролей/root) |
| 3 | Настроить UFW (только SSH + 443) |
| 4 | Установить и настроить fail2ban |
| 5 | Установить Netbird |
| 6 | Проверить переопределение параметров SSH в `/etc/ssh` |
| 7 | Выполнить всё по порядку (полный сценарий) |
| 8 | Откатить изменения (sshd, systemd, UFW; опционально fail2ban, Netbird) |
| 0 | Выход |

Для пунктов **2, 3, 4** перед выполнением запрашивается порт SSH.

## Требования

- Запуск с правами **root** (`sudo`).
- **Интерактивный терминал** (скрипт проверяет `-t 0`; при запуске из pipe/cron выведет сообщение и завершится).
- До отключения входа по паролю **обязательно** скопировать SSH-ключ новому пользователю (`ssh-copy-id -p PORT user@server`), иначе возможна потеря доступа.

## Быстрый запуск

Одной командой (скачивание в файл и запуск):

```bash
curl -sL -o /tmp/setup-ssh-hardening.sh https://raw.githubusercontent.com/s-bug0ff/setup-ssh-hardening/main/setup-ssh-hardening.sh && sudo bash /tmp/setup-ssh-hardening.sh
```

При проблемах с IPv6:

```bash
curl -sL --ipv4 -o /tmp/setup-ssh-hardening.sh https://raw.githubusercontent.com/s-bug0ff/setup-ssh-hardening/main/setup-ssh-hardening.sh && sudo bash /tmp/setup-ssh-hardening.sh
```

Если меню не появляется или скрипт сразу выходит — запускайте в интерактивном терминале по шагам:

```bash
curl -sL -o /tmp/setup-ssh-hardening.sh https://raw.githubusercontent.com/s-bug0ff/setup-ssh-hardening/main/setup-ssh-hardening.sh
ls -la /tmp/setup-ssh-hardening.sh
sudo bash /tmp/setup-ssh-hardening.sh
```

Если после `ls` размер файла 0 или файла нет — проверьте сеть и URL.

## Установка вручную

```bash
git clone https://github.com/s-bug0ff/setup-ssh-hardening.git
cd setup-ssh-hardening
sudo ./setup-ssh-hardening.sh
```

## Откат (пункт 8)

- Восстанавливается `/etc/ssh/sshd_config` из последнего бэкапа (`/etc/ssh/sshd_config.bak.*`).
- Удаляется `/etc/systemd/system/ssh.socket.d/`, перезапускается SSH (порт снова из конфига, обычно 22).
- UFW сбрасывается: разрешены только **22/tcp** и **443/tcp**.
- По запросу: удаление jail fail2ban для sshd (`/etc/fail2ban/jail.d/sshd-local.conf`) и/или остановка и удаление Netbird.
- Созданные скриптом пользователи **не удаляются** — при необходимости: `sudo userdel -r USERNAME`.

## Важно: порт в панели хостинга

После смены порта SSH скрипт открывает его только в **UFW на сервере**. Во входящих правилах **файрвола хостинга** (Hetzner Cloud, DigitalOcean, Selectel и т.п.) нужно вручную открыть выбранный **TCP-порт**, иначе при подключении будет **Connection refused**.

## Предупреждение

После применения настроек вход по паролю и под root отключены, разрешён только вход по ключу. До закрытия текущей сессии скопируйте новому пользователю SSH-ключ и проверьте подключение на новый порт:

```bash
ssh-copy-id -p PORT newuser@server
ssh -p PORT newuser@server
```

fail2ban: 3 неудачные попытки входа — бан на неделю. Свой IP можно добавить в `ignoreip` в `/etc/fail2ban/jail.d/sshd-local.conf`.
