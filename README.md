# server-bootstrap.sh

> **[English version below ↓](#english)**

---

# 🇷🇺 Русский

## Содержание

- [Описание](#описание)
- [Требования](#требования)
- [Быстрый старт](#быстрый-старт)
- [Режимы работы](#режимы-работы)
- [Аргументы CLI](#аргументы-cli)
- [Примеры запуска](#примеры-запуска)
- [Что делает каждый режим](#что-делает-каждый-режим)
- [Настройка sysctl](#настройка-sysctl)
- [Структура файлов](#структура-файлов)
- [Безопасность и идемпотентность](#безопасность-и-идемпотентность)
- [Компоненты](#компоненты)
- [Логирование](#логирование)
- [Dry-run режим](#dry-run-режим)
- [Откат изменений](#откат-изменений)
- [Устранение проблем](#устранение-проблем)
- [TODO / Планы](#todo--планы)

---

## Описание

`server-bootstrap.sh` — production-ready bash-скрипт для первичной настройки серверов и нод на **Debian 12+** и **Ubuntu 22.04+**. Разработан для автоматизации развёртывания инфраструктуры с несколькими предустановленными режимами: обычная нода, gate-нода, BS/роутер, базовая подготовка сервера и пошаговый кастомный режим.

**Ключевые принципы:**

- **Идемпотентность** — повторный запуск не дублирует строки в конфигах и не ломает уже работающие сервисы
- **Безопасность** — перед каждым изменением критичных файлов создаётся резервная копия
- **Dry-run** — режим предпросмотра без применения изменений
- **Интерактивный и неинтерактивный** — работает как с меню, так и через аргументы командной строки
- **Полное логирование** — все действия записываются в `/var/log/server-bootstrap.log`

---

## Требования

| Параметр | Значение |
|----------|----------|
| ОС | Debian 12+ или Ubuntu 22.04+ |
| Права | `root` (или `sudo`) |
| Bash | 4.0+ |
| Интернет | Требуется для установки пакетов и компонентов |
| Архитектура | `x86_64`, `aarch64` |

> ⚠️ **OpenVZ / LXC**: скрипт обнаружит контейнерную виртуализацию и предупредит. Docker, iptables/NAT и некоторые sysctl-параметры могут не работать в таком окружении.

---

## Быстрый старт

```bash
# Скачать и запустить интерактивное меню
curl -O https://github.com/catoo-hub/server-bootstrap/server-bootstrap.sh
chmod +x server-bootstrap.sh
sudo bash server-bootstrap.sh
```

Или напрямую:

```bash
sudo bash server-bootstrap.sh --mode node --non-interactive
```

> 💡 **Про запуск через curl:**
> ```bash
> # ✅ Правильно — process substitution, stdin остаётся терминалом
> bash <(curl -Ls https://github.com/catoo-hub/server-bootstrap/server-bootstrap.sh)
>
> # ✅ Правильно — неинтерактивный (работает и через пайп)
> bash <(curl -Ls https://github.com/catoo-hub/server-bootstrap/server-bootstrap.sh) --mode node --non-interactive
>
> # ❌ Неправильно — curl занимает stdin, интерактивные read сломаются
> curl -Ls https://github.com/catoo-hub/server-bootstrap/server-bootstrap.sh | bash
> ```
> Скрипт автоматически определяет pipe-режим (`[[ ! -t 0 ]]`) и форсирует `--non-interactive`.
> Если при этом не указан `--mode` — скрипт завершится с ошибкой и подскажет правильную команду.



---

## Режимы работы

| Режим | Описание | Команда |
|-------|----------|---------|
| `base` | Базовая подготовка сервера | `--mode base` |
| `node` | Обычная нода | `--mode node` |
| `gate` | Gate-нода | `--mode gate` |
| `bs` | BS/Роутер режим | `--mode bs` |
| `custom` | Пошаговый выбор компонентов | `--mode custom` |

---

## Аргументы CLI

```
Флаг                        Описание
────────────────────────────────────────────────────────────
--mode <mode>               Режим: base | node | gate | bs | custom
--gate-address <ip>         IP-адрес gate-ноды (обязателен для режима bs)
--dry-run                   Режим симуляции — изменения не применяются
--verbose, -v               Подробный вывод (debug-уровень)
--skip-selfsteal            Пропустить установку selfsteal
--skip-update               Пропустить apt update/upgrade
--non-interactive, -y       Неинтерактивный режим (использовать значения по умолчанию)
--status                    Показать статус системы и выйти
--version                   Показать версию скрипта
--help, -h                  Показать справку
```

---

## Примеры запуска

### Интерактивный режим (с меню)

```bash
sudo bash server-bootstrap.sh
```

Запустится цветное интерактивное меню с выбором режима, возможностью включить dry-run и verbose прямо в интерфейсе.

### Базовая настройка сервера

```bash
sudo bash server-bootstrap.sh --mode base --non-interactive
```

### Установка обычной ноды

```bash
sudo bash server-bootstrap.sh --mode node --non-interactive
```

### Gate-нода без selfsteal

```bash
sudo bash server-bootstrap.sh --mode gate --skip-selfsteal --non-interactive
```

### BS/Роутер с указанием gate

```bash
sudo bash server-bootstrap.sh --mode bs --gate-address 185.100.200.5 --non-interactive
```

### Пошаговый выбор компонентов

```bash
sudo bash server-bootstrap.sh --mode custom
```

### Dry-run с подробным логом (ничего не меняет)

```bash
sudo bash server-bootstrap.sh --mode node --dry-run --verbose
```

### Только проверка статуса системы

```bash
sudo bash server-bootstrap.sh --status
```

### Без обновления пакетов (быстро)

```bash
sudo bash server-bootstrap.sh --mode base --skip-update --non-interactive
```

---

## Что делает каждый режим

### `base` — Базовая подготовка

| Шаг | Действие |
|-----|----------|
| 1 | `apt update && apt upgrade` |
| 2 | Установка базовых пакетов: `curl wget git unzip tar jq vim nano htop net-tools dnsutils iproute2 ufw fail2ban socat tcpdump mtr ca-certificates` и др. |
| 3 | Настройка часового пояса (timezone) |
| 4 | Безопасное усиление SSH (без блокировки доступа) |
| 5 | Применение сетевых sysctl (BBR, TCP буферы, fq) |
| 6 | Опциональное создание swap-файла |
| 7 | Настройка UFW с разрешением SSH-порта |
| 8 | Настройка Fail2Ban с jail для sshd |

### `node` — Обычная нода

Всё из `base`, плюс:

| Шаг | Действие |
|-----|----------|
| 1 | UFW: открыть 443/tcp, 80/tcp, 8443/tcp |
| 2 | Установка `mobile443-filter` (режим `install.sh`) |
| 3 | Установка `remnanode` |
| 4 | Установка `selfsteal` (с вопросом или флагом) |

### `gate` — Gate-нода

Всё из `base`, плюс:

| Шаг | Действие |
|-----|----------|
| 1 | UFW: открыть 443/tcp, 80/tcp, 8443/tcp |
| 2 | Установка `mobile443-filter` (режим `install_block_only.sh`) |
| 3 | Установка `remnanode` |
| 4 | Установка `selfsteal` (с вопросом или флагом) |

**Отличие от `node`**: используется `block-only` режим mobile443-filter — трафик с мобильных операторов блокируется, а не перенаправляется.

### `bs` — BS/Роутер режим

Всё из `base`, плюс:

| Шаг | Действие |
|-----|----------|
| 1 | Дополнительные router sysctl: блокировка ICMP ping, отключение IPv6, включение ip_forward |
| 2 | UFW: открыть 443/tcp |
| 3 | Настройка HAProxy: TCP proxy с `send-proxy-v2` на указанный gate |
| 4 | Установка `mobile443-filter` (режим `install.sh`) |
| ✗ | remnanode — **не устанавливается** |
| ✗ | selfsteal — **не устанавливается** |

### `custom` — Пошаговый выбор

Интерактивный режим с вопросом по каждому компоненту:

- Базовые пакеты
- Timezone
- SSH hardening
- Сетевые sysctl
- Router sysctl
- UFW
- Fail2Ban
- HAProxy
- mobile443-filter (с выбором режима)
- remnanode
- selfsteal
- Docker
- Swap

---

## Настройка sysctl

Скрипт управляет sysctl **идемпотентно**: не дописывает одно и то же повторно, а заменяет существующие значения или добавляет новые.

### Файлы sysctl

| Файл | Назначение |
|------|-----------|
| `/etc/sysctl.d/99-custom-network.conf` | Сетевые настройки (все режимы) |
| `/etc/sysctl.d/99-router.conf` | Роутер-специфичные настройки (только BS) |

### Применяемые параметры (все режимы node/gate/bs)

```ini
# TCP буферы приёма: min / default / max
net.ipv4.tcp_rmem = 4096 131072 16777216

# TCP буферы отправки: min / default / max
net.ipv4.tcp_wmem = 4096 65536 16777216

# Общий лимит памяти TCP-стека
net.ipv4.tcp_mem = 786432 1048576 1572864

# Масштабирование TCP-окна (для высокого BDP)
net.ipv4.tcp_window_scaling = 1

# Selective ACK
net.ipv4.tcp_sack = 1

# TCP timestamps
net.ipv4.tcp_timestamps = 1

# Fair Queuing — равномерное распределение пропускной способности
net.core.default_qdisc = fq

# BBR — алгоритм управления перегрузкой
net.ipv4.tcp_congestion_control = bbr
```

### Дополнительные параметры для BS/роутера

```ini
# Блокировка ICMP ping
net.ipv4.icmp_echo_ignore_all = 1

# Отключение IPv6
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1

# Пересылка IP-пакетов
net.ipv4.ip_forward = 1
```

---

## Структура файлов

```
/
├── var/
│   ├── log/
│   │   └── server-bootstrap.log          ← Лог всех действий
│   └── backups/
│       └── server-bootstrap/
│           ├── sshd_config.20240115_143022.bak
│           ├── haproxy.cfg.20240115_143022.bak
│           └── ...                        ← Резервные копии с timestamp
├── etc/
│   ├── server-bootstrap.conf             ← Конфиг с параметрами последнего запуска
│   ├── sysctl.d/
│   │   ├── 99-custom-network.conf        ← Сетевые sysctl
│   │   └── 99-router.conf               ← Router sysctl (только BS)
│   ├── fail2ban/
│   │   └── jail.local                   ← Fail2Ban конфиг
│   └── haproxy/
│       └── haproxy.cfg                  ← HAProxy конфиг (только BS)
```

---

## Безопасность и идемпотентность

### Backup перед изменением

Перед изменением любого конфигурационного файла создаётся резервная копия:

```
/var/backups/server-bootstrap/<имя_файла>.<timestamp>.bak
```

### SSH — не заблокирует доступ

- SSH-порт определяется автоматически из `/etc/ssh/sshd_config`
- UFW открывает SSH **до** включения файрвола
- `sshd -t` проверяет конфиг перед `reload`
- При ошибке — автоматический откат backup

### UFW — безопасное включение

```bash
ufw default deny incoming
ufw default allow outgoing
ufw allow <SSH_PORT>/tcp    # ← СНАЧАЛА разрешить SSH
# ... затем добавить остальные правила ...
ufw --force enable          # ← только потом включить
```

### HAProxy — проверка перед рестартом

```bash
haproxy -c -f /etc/haproxy/haproxy.cfg   # валидация
systemctl restart haproxy                  # только если OK
# При ошибке → автоматически восстанавливается backup
```

### sysctl — идемпотентность

Функция `_sysctl_set key value file`:
- Если параметр уже есть с нужным значением → не трогает
- Если есть с другим значением → заменяет через `sed`
- Если нет → добавляет в конец файла

---

## Компоненты

### Базовые пакеты

`curl` `wget` `git` `unzip` `tar` `jq` `vim` `nano` `htop` `net-tools` `dnsutils` `iproute2` `ufw` `fail2ban` `socat` `tcpdump` `mtr` `ca-certificates` `lsb-release` `gnupg2` `software-properties-common` `bc` `psmisc` `procps`

### mobile443-filter

| Режим | Скрипт |
|-------|--------|
| `node` / `bs` | `install.sh` |
| `gate` | `install_block_only.sh` |

Источник: `https://github.com/wh3r3ar3you/mobile443-filter`

### remnanode

Устанавливается командой:
```bash
bash <(curl -Ls https://github.com/DigneZzZ/remnawave-scripts/raw/main/remnanode.sh) @ install
```

Используется в режимах: `node`, `gate`. **Не устанавливается** в режиме `bs`.

### selfsteal

Устанавливается командой:
```bash
bash <(curl -Ls https://github.com/DigneZzZ/remnawave-scripts/raw/main/selfsteal.sh) @ install
```

Используется в режимах: `node`, `gate`. Можно пропустить через `--skip-selfsteal`.

### HAProxy (только BS)

TCP-прокси с `send-proxy-v2`. Конфигурация:

```haproxy
frontend ft_xray
    bind *:443
    default_backend bk_xray

backend bk_xray
    server xray <GATE_IP>:443 send-proxy-v2
```

### Docker (опционально, режим `custom`)

Устанавливается через официальный скрипт `get.docker.com`. Включает `docker-compose-plugin`.

---

## Логирование

Все действия пишутся в `/var/log/server-bootstrap.log` с timestamp:

```
2024-01-15 14:30:22  [INFO]  Detected OS : Debian GNU/Linux 12 (bookworm)
2024-01-15 14:30:22  [INFO]  Architecture: x86_64
2024-01-15 14:30:23  [ OK ]  Internet connectivity — OK
2024-01-15 14:30:24  [INFO]  Installing: htop net-tools socat
2024-01-15 14:30:31  [ OK ]  Packages updated
2024-01-15 14:30:31  [WARN]  jail.local already exists — not overwriting
2024-01-15 14:30:35  [ OK ]  UFW enabled with rules for mode 'node'
2024-01-15 14:30:40  [ERR ]  haproxy config validation FAILED — reverting backup
```

**Уровни логирования:**

| Уровень | Цвет | Значение |
|---------|------|----------|
| `[INFO]` | Зелёный | Информация о ходе выполнения |
| `[ OK ]` | Ярко-зелёный | Шаг выполнен успешно |
| `[WARN]` | Жёлтый | Предупреждение, выполнение продолжается |
| `[ERR ]` | Красный | Ошибка |
| `[DBG ]` | Серый | Debug (только при `--verbose`) |
| `[DRY ]` | Пурпурный | Симуляция (только при `--dry-run`) |

---

## Dry-run режим

Флаг `--dry-run` активирует режим симуляции: скрипт проходит все шаги, показывает что **было бы** сделано, но **не вносит никаких изменений**.

```bash
sudo bash server-bootstrap.sh --mode node --dry-run --verbose
```

Пример вывода:
```
  [DRY ]  Would run: apt-get update && apt-get upgrade -y
  [DRY ]  Would write sysctl to /etc/sysctl.d/99-custom-network.conf
  [DRY ]  Would configure UFW: allow SSH:22, mode-specific ports
  [DRY ]  Would install mobile443-filter from https://...
```

---

## Откат изменений

При сбое критичных операций происходит автоматический откат:

- **SSH**: если `sshd -t` не прошёл → восстанавливается backup `sshd_config`
- **HAProxy**: если `haproxy -c -f` не прошёл → восстанавливается backup `haproxy.cfg` + сервис не перезапускается

Ручной откат из backup:

```bash
ls /var/backups/server-bootstrap/
cp /var/backups/server-bootstrap/haproxy.cfg.20240115_143022.bak /etc/haproxy/haproxy.cfg
systemctl restart haproxy
```

---

## Устранение проблем

### Скрипт заблокировал SSH-доступ

Если это произошло, используйте консоль провайдера (VNC/KVM):

```bash
ufw disable
ufw allow 22/tcp
ufw enable
```

### sysctl BBR не применяется

```bash
# Проверить наличие модуля
modprobe tcp_bbr
lsmod | grep bbr

# Применить вручную
sysctl -p /etc/sysctl.d/99-custom-network.conf
sysctl net.ipv4.tcp_congestion_control
```

### HAProxy не запускается

```bash
# Проверить конфиг
haproxy -c -f /etc/haproxy/haproxy.cfg

# Смотреть логи
journalctl -u haproxy -n 50

# Восстановить backup
ls /var/backups/server-bootstrap/
```

### Fail2Ban не видит логи sshd

```bash
# На systemd-системах
grep 'backend' /etc/fail2ban/jail.local
# Убедиться что стоит: backend = systemd
fail2ban-client status sshd
```

### Скрипт упал на container-среде

В OpenVZ/LXC некоторые функции недоступны. Используйте флаги:
```bash
sudo bash server-bootstrap.sh --mode base --skip-update --non-interactive
```

---

## TODO / Планы

- [ ] nftables / iptables-legacy switcher
- [ ] Управление TLS-сертификатами (acme.sh / certbot)
- [ ] Функции uninstall/rollback для каждого компонента
- [ ] Пресеты провайдеров (Hetzner, Vultr, DigitalOcean)
- [ ] Поддержка dual-stack IPv6 в правилах UFW
- [ ] Автоматическое добавление SSH-ключей (с GitHub / по URL)
- [ ] Мониторинг: Prometheus node-exporter + Grafana Alloy
- [ ] Оптимизация BBR2 и TCP для специфичных нагрузок
- [ ] CI с shellcheck и bats-core
- [ ] Автоматическая проверка обновлений скрипта
- [ ] WireGuard peer helpers
- [ ] Rate limiting в UFW / nftables
- [ ] Помощники для обновления и проверки remnanode/selfsteal

---
---
---

# English

<a name="english"></a>

## Table of Contents

- [Description](#description)
- [Requirements](#requirements)
- [Quick Start](#quick-start)
- [Modes](#modes)
- [CLI Arguments](#cli-arguments)
- [Usage Examples](#usage-examples)
- [What Each Mode Does](#what-each-mode-does)
- [sysctl Configuration](#sysctl-configuration)
- [File Structure](#file-structure)
- [Safety & Idempotency](#safety--idempotency)
- [Components](#components)
- [Logging](#logging)
- [Dry-run Mode](#dry-run-mode)
- [Rollback](#rollback)
- [Troubleshooting](#troubleshooting)
- [TODO / Roadmap](#todo--roadmap)

---

## Description

`server-bootstrap.sh` is a production-ready Bash script for initial setup of servers and nodes running **Debian 12+** or **Ubuntu 22.04+**. It automates infrastructure deployment with several preset modes: regular node, gate node, BS/router, base server preparation, and a step-by-step custom mode.

**Core principles:**

- **Idempotent** — re-running the script does not duplicate config lines or break already-running services
- **Safe** — creates a timestamped backup before modifying any critical file
- **Dry-run** — preview mode that simulates all actions without applying changes
- **Interactive & non-interactive** — works both with a menu and via CLI arguments
- **Full logging** — every action is recorded to `/var/log/server-bootstrap.log`

---

## Requirements

| Parameter | Value |
|-----------|-------|
| OS | Debian 12+ or Ubuntu 22.04+ |
| Privileges | `root` (or `sudo`) |
| Bash | 4.0+ |
| Internet | Required for package and component installation |
| Architecture | `x86_64`, `aarch64` |

> ⚠️ **OpenVZ / LXC**: The script detects container-based virtualization and warns you. Docker, iptables/NAT, and some sysctl settings may not work in such environments.

---

## Quick Start

```bash
# Download and launch the interactive menu
curl -O https://github.com/catoo-hub/server-bootstrap/server-bootstrap.sh
chmod +x server-bootstrap.sh
sudo bash server-bootstrap.sh
```

Or directly:

```bash
sudo bash server-bootstrap.sh --mode node --non-interactive
```

> 💡 **About running via curl:**
> ```bash
> # ✅ Correct — process substitution keeps stdin as the terminal
> bash <(curl -Ls https://github.com/catoo-hub/server-bootstrap/server-bootstrap.sh)
>
> # ✅ Correct — non-interactive works with both pipe and process substitution
> bash <(curl -Ls https://github.com/catoo-hub/server-bootstrap/server-bootstrap.sh) --mode node --non-interactive
>
> # ❌ Wrong — curl consumes stdin, all interactive `read` calls break
> curl -Ls https://github.com/catoo-hub/server-bootstrap/server-bootstrap.sh | bash
> ```
> The script auto-detects pipe mode (`[[ ! -t 0 ]]`) and forces `--non-interactive`.
> If `--mode` is not provided in this case, the script exits with a clear error message.



---

## Modes

| Mode | Description | Flag |
|------|-------------|------|
| `base` | Base server preparation | `--mode base` |
| `node` | Regular node | `--mode node` |
| `gate` | Gate node | `--mode gate` |
| `bs` | BS / Router mode | `--mode bs` |
| `custom` | Step-by-step component selection | `--mode custom` |

---

## CLI Arguments

```
Flag                          Description
────────────────────────────────────────────────────────────────
--mode <mode>                 Mode: base | node | gate | bs | custom
--gate-address <ip>           Gate node IP address (required for bs mode)
--dry-run                     Simulation mode — no changes applied
--verbose, -v                 Verbose/debug output
--skip-selfsteal              Skip selfsteal installation
--skip-update                 Skip apt update/upgrade
--non-interactive, -y         Non-interactive mode (use defaults)
--status                      Show system status and exit
--version                     Print script version
--help, -h                    Show help
```

---

## Usage Examples

### Interactive mode (with menu)

```bash
sudo bash server-bootstrap.sh
```

Launches a coloured interactive menu with mode selection and the ability to toggle dry-run and verbose from within the interface.

### Base server preparation

```bash
sudo bash server-bootstrap.sh --mode base --non-interactive
```

### Regular node installation

```bash
sudo bash server-bootstrap.sh --mode node --non-interactive
```

### Gate node without selfsteal

```bash
sudo bash server-bootstrap.sh --mode gate --skip-selfsteal --non-interactive
```

### BS/Router with a specific gate address

```bash
sudo bash server-bootstrap.sh --mode bs --gate-address 185.100.200.5 --non-interactive
```

### Step-by-step component selection

```bash
sudo bash server-bootstrap.sh --mode custom
```

### Dry-run with verbose output (no changes made)

```bash
sudo bash server-bootstrap.sh --mode node --dry-run --verbose
```

### System status check only

```bash
sudo bash server-bootstrap.sh --status
```

### Skip package update (faster re-run)

```bash
sudo bash server-bootstrap.sh --mode base --skip-update --non-interactive
```

---

## What Each Mode Does

### `base` — Base Server Preparation

| Step | Action |
|------|--------|
| 1 | `apt update && apt upgrade` |
| 2 | Install base packages: `curl wget git unzip tar jq vim nano htop net-tools dnsutils iproute2 ufw fail2ban socat tcpdump mtr ca-certificates` etc. |
| 3 | Configure timezone |
| 4 | Safely harden SSH (without locking you out) |
| 5 | Apply network sysctl (BBR, TCP buffers, fq) |
| 6 | Optionally create a swap file |
| 7 | Configure UFW — allow SSH port |
| 8 | Configure Fail2Ban with sshd jail |

### `node` — Regular Node

Everything from `base`, plus:

| Step | Action |
|------|--------|
| 1 | UFW: open 443/tcp, 80/tcp, 8443/tcp |
| 2 | Install `mobile443-filter` (`install.sh` mode) |
| 3 | Install `remnanode` |
| 4 | Install `selfsteal` (asks or respects flag) |

### `gate` — Gate Node

Everything from `base`, plus:

| Step | Action |
|------|--------|
| 1 | UFW: open 443/tcp, 80/tcp, 8443/tcp |
| 2 | Install `mobile443-filter` (`install_block_only.sh` mode) |
| 3 | Install `remnanode` |
| 4 | Install `selfsteal` (asks or respects flag) |

**Difference from `node`**: uses the `block-only` mode of mobile443-filter — mobile operator traffic is blocked rather than redirected.

### `bs` — BS / Router Mode

Everything from `base`, plus:

| Step | Action |
|------|--------|
| 1 | Additional router sysctl: block ICMP ping, disable IPv6, enable ip_forward |
| 2 | UFW: open 443/tcp |
| 3 | Configure HAProxy: TCP proxy with `send-proxy-v2` to the specified gate |
| 4 | Install `mobile443-filter` (`install.sh` mode) |
| ✗ | remnanode — **not installed** |
| ✗ | selfsteal — **not installed** |

### `custom` — Step-by-step Selection

Interactive mode that asks about each component:

- Base packages
- Timezone
- SSH hardening
- Network sysctl
- Router sysctl
- UFW
- Fail2Ban
- HAProxy
- mobile443-filter (with mode selection)
- remnanode
- selfsteal
- Docker
- Swap

---

## sysctl Configuration

The script manages sysctl **idempotently**: it does not blindly append values on each run, but replaces existing ones or appends missing ones.

### sysctl Files

| File | Purpose |
|------|---------|
| `/etc/sysctl.d/99-custom-network.conf` | Network tuning (all modes) |
| `/etc/sysctl.d/99-router.conf` | Router-specific settings (BS mode only) |

### Applied Parameters (all node/gate/bs modes)

```ini
# TCP receive buffers: min / default / max
net.ipv4.tcp_rmem = 4096 131072 16777216

# TCP send buffers: min / default / max
net.ipv4.tcp_wmem = 4096 65536 16777216

# Total TCP stack memory limits
net.ipv4.tcp_mem = 786432 1048576 1572864

# TCP window scaling (for high BDP links)
net.ipv4.tcp_window_scaling = 1

# Selective Acknowledgments
net.ipv4.tcp_sack = 1

# TCP timestamps
net.ipv4.tcp_timestamps = 1

# Fair Queuing — even bandwidth/latency distribution
net.core.default_qdisc = fq

# BBR congestion control
net.ipv4.tcp_congestion_control = bbr
```

### Additional Parameters for BS/Router

```ini
# Block ICMP ping
net.ipv4.icmp_echo_ignore_all = 1

# Disable IPv6
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1

# Enable IP forwarding
net.ipv4.ip_forward = 1
```

---

## File Structure

```
/
├── var/
│   ├── log/
│   │   └── server-bootstrap.log          ← Full action log
│   └── backups/
│       └── server-bootstrap/
│           ├── sshd_config.20240115_143022.bak
│           ├── haproxy.cfg.20240115_143022.bak
│           └── ...                        ← Timestamped backups
├── etc/
│   ├── server-bootstrap.conf             ← Last run configuration
│   ├── sysctl.d/
│   │   ├── 99-custom-network.conf        ← Network sysctl
│   │   └── 99-router.conf               ← Router sysctl (BS only)
│   ├── fail2ban/
│   │   └── jail.local                   ← Fail2Ban config
│   └── haproxy/
│       └── haproxy.cfg                  ← HAProxy config (BS only)
```

---

## Safety & Idempotency

### Backup Before Every Change

Before modifying any configuration file, a backup is created:

```
/var/backups/server-bootstrap/<filename>.<timestamp>.bak
```

### SSH — Won't Lock You Out

- SSH port is detected automatically from `/etc/ssh/sshd_config`
- UFW opens SSH **before** enabling the firewall
- `sshd -t` validates the config before `reload`
- On failure — automatic backup restore

### UFW — Safe Activation Order

```bash
ufw default deny incoming
ufw default allow outgoing
ufw allow <SSH_PORT>/tcp    # ← allow SSH FIRST
# ... then add mode-specific rules ...
ufw --force enable          # ← enable AFTER rules are in place
```

### HAProxy — Validate Before Restart

```bash
haproxy -c -f /etc/haproxy/haproxy.cfg   # validate config
systemctl restart haproxy                  # only if validation passed
# On failure → backup is automatically restored
```

### sysctl — Idempotency

The `_sysctl_set key value file` function:
- If the key already has the correct value → does nothing
- If the key exists with a different value → replaces it via `sed`
- If the key is missing → appends it to the file

---

## Components

### Base Packages

`curl` `wget` `git` `unzip` `tar` `jq` `vim` `nano` `htop` `net-tools` `dnsutils` `iproute2` `ufw` `fail2ban` `socat` `tcpdump` `mtr` `ca-certificates` `lsb-release` `gnupg2` `software-properties-common` `bc` `psmisc` `procps`

### mobile443-filter

| Mode | Script |
|------|--------|
| `node` / `bs` | `install.sh` |
| `gate` | `install_block_only.sh` |

Source: `https://github.com/wh3r3ar3you/mobile443-filter`

### remnanode

Installed with:
```bash
bash <(curl -Ls https://github.com/DigneZzZ/remnawave-scripts/raw/main/remnanode.sh) @ install
```

Used in: `node`, `gate`. **Not installed** in `bs` mode.

### selfsteal

Installed with:
```bash
bash <(curl -Ls https://github.com/DigneZzZ/remnawave-scripts/raw/main/selfsteal.sh) @ install
```

Used in: `node`, `gate`. Can be skipped with `--skip-selfsteal`.

### HAProxy (BS mode only)

TCP proxy with `send-proxy-v2`. Configuration:

```haproxy
frontend ft_xray
    bind *:443
    default_backend bk_xray

backend bk_xray
    server xray <GATE_IP>:443 send-proxy-v2
```

### Docker (optional, `custom` mode)

Installed via the official `get.docker.com` script. Includes `docker-compose-plugin`.

---

## Logging

All actions are written to `/var/log/server-bootstrap.log` with timestamps:

```
2024-01-15 14:30:22  [INFO]  Detected OS : Debian GNU/Linux 12 (bookworm)
2024-01-15 14:30:22  [INFO]  Architecture: x86_64
2024-01-15 14:30:23  [ OK ]  Internet connectivity — OK
2024-01-15 14:30:24  [INFO]  Installing: htop net-tools socat
2024-01-15 14:30:31  [ OK ]  Packages updated
2024-01-15 14:30:31  [WARN]  jail.local already exists — not overwriting
2024-01-15 14:30:35  [ OK ]  UFW enabled with rules for mode 'node'
2024-01-15 14:30:40  [ERR ]  haproxy config validation FAILED — reverting backup
```

**Log levels:**

| Level | Colour | Meaning |
|-------|--------|---------|
| `[INFO]` | Green | Progress information |
| `[ OK ]` | Bright green | Step completed successfully |
| `[WARN]` | Yellow | Warning, execution continues |
| `[ERR ]` | Red | Error |
| `[DBG ]` | Gray | Debug output (`--verbose` only) |
| `[DRY ]` | Magenta | Simulation (`--dry-run` only) |

---

## Dry-run Mode

The `--dry-run` flag activates simulation mode: the script walks through all steps and shows what **would** be done, but **makes no changes**.

```bash
sudo bash server-bootstrap.sh --mode node --dry-run --verbose
```

Example output:
```
  [DRY ]  Would run: apt-get update && apt-get upgrade -y
  [DRY ]  Would write sysctl to /etc/sysctl.d/99-custom-network.conf
  [DRY ]  Would configure UFW: allow SSH:22, mode-specific ports
  [DRY ]  Would install mobile443-filter from https://...
```

---

## Rollback

Critical operations include automatic rollback on failure:

- **SSH**: if `sshd -t` fails → `sshd_config` backup is restored
- **HAProxy**: if `haproxy -c -f` fails → `haproxy.cfg` backup is restored and the service is not restarted

Manual rollback from backup:

```bash
ls /var/backups/server-bootstrap/
cp /var/backups/server-bootstrap/haproxy.cfg.20240115_143022.bak /etc/haproxy/haproxy.cfg
systemctl restart haproxy
```

---

## Troubleshooting

### SSH access was blocked

If this happens, use your provider's console (VNC/KVM):

```bash
ufw disable
ufw allow 22/tcp
ufw enable
```

### BBR sysctl is not applied

```bash
# Check if the module is loaded
modprobe tcp_bbr
lsmod | grep bbr

# Apply manually
sysctl -p /etc/sysctl.d/99-custom-network.conf
sysctl net.ipv4.tcp_congestion_control
```

### HAProxy won't start

```bash
# Check config
haproxy -c -f /etc/haproxy/haproxy.cfg

# View logs
journalctl -u haproxy -n 50

# Restore backup
ls /var/backups/server-bootstrap/
```

### Fail2Ban doesn't see sshd logs

```bash
# On systemd systems
grep 'backend' /etc/fail2ban/jail.local
# Should be: backend = systemd
fail2ban-client status sshd
```

### Script fails in container environment

In OpenVZ/LXC some features are unavailable. Use limiting flags:
```bash
sudo bash server-bootstrap.sh --mode base --skip-update --non-interactive
```

---

## TODO / Roadmap

- [ ] nftables / iptables-legacy switcher
- [ ] TLS certificate management (acme.sh / certbot)
- [ ] Per-component uninstall/rollback functions
- [ ] Provider presets (Hetzner, Vultr, DigitalOcean network quirks)
- [ ] IPv6 dual-stack support in UFW rules
- [ ] Automatic SSH key injection (from GitHub / URL)
- [ ] Monitoring stack: Prometheus node-exporter + Grafana Alloy
- [ ] BBR2 / TCP tuning for specific workloads
- [ ] CI with shellcheck and bats-core
- [ ] Automatic script update check
- [ ] WireGuard peer setup helpers
- [ ] Rate limiting rules in UFW / nftables
- [ ] remnanode / selfsteal update and status helpers

---

*server-bootstrap.sh · v1.0.0 · Debian 12+ / Ubuntu 22.04+ · MIT License*
