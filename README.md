# setup-ssh-hardening

Скрипт автоматической настройки и усиления безопасности SSH на Linux-сервере: смена порта, UFW, отключение входа по паролю, fail2ban и опциональная установка Netbird.

## Что делает скрипт

- **UFW** — сброс правил; разрешены только выбранный порт SSH (TCP) и 443 (HTTPS)
- **sshd_config** — смена порта SSH и ужесточение: отключение паролей, PAM, входа root
- **systemd** — настройка `ssh.socket` на новый порт
- **fail2ban** — установка и настройка jail для SSH (bantime 24h, maxretry 3, findtime 10m)
- **Netbird** (опционально) — установка и регистрация по setup-ключу

Поддерживаются дистрибутивы с **systemd**, **UFW** и пакетными менеджерами: **apt** (Debian/Ubuntu), **dnf** / **yum** (RHEL/Fedora и др.).

## Требования

- Запуск с правами root: `sudo`
- **Обязательно** настроенный вход по SSH-ключу до запуска, иначе возможна потеря доступа к серверу

## Быстрый запуск

Запуск одной командой (скрипт скачивается и выполняется):

```bash
sudo bash <(curl -sL https://raw.githubusercontent.com/s-bug0ff/setup-ssh-hardening/main/setup-ssh-hardening.sh)
```

При проблемах с IPv6 можно принудительно использовать IPv4:

```bash
sudo bash <(curl -sL --ipv4 https://raw.githubusercontent.com/s-bug0ff/setup-ssh-hardening/main/setup-ssh-hardening.sh)
```

Во время работы скрипт запросит:

1. Порт для SSH (например, `27391`)
2. Подтверждение продолжения (`yes` / `no`)
3. Установку Netbird — да/нет и при необходимости ключ (UUID)

## Установка вручную

```bash
git clone https://github.com/s-bug0ff/setup-ssh-hardening.git
cd setup-ssh-hardening
sudo ./setup-ssh-hardening.sh
```

## Предупреждение

Перед запуском убедитесь, что вход по **SSH-ключу** уже работает. После применения настроек вход по паролю и под root будут отключены. Проверьте подключение на новый порт в отдельной сессии перед закрытием текущей.
