# setup-server

Bash-скрипт автоматизированной настройки сервера Ubuntu 24.04.

## Что делает

**Фаза 1 — настройка сервера (root):**
- Обновление системы, установка временной зоны, hostname
- Создание пользователя с sudo, SSH-ключом и безопасным паролем
- Харденинг SSH (кастомный порт, отключение root и password auth)
- Настройка UFW (80, 443, SSH и дополнительные порты)
- Опционально: отключение systemd-resolved, удаление Zabbix Agent

**Фаза 2 — деплой сервисов (deploy user):**
- Установка Docker Engine
- Установка acme.sh, получение SSL-сертификата (Let's Encrypt, HTTP-01)
- Деплой Nginx (reverse proxy + заглушка)
- Настройка авторенью сертификата
- Health-check и сводный отчёт

## Требования

- Ubuntu 24.04
- Чистый сервер (или повторный запуск — идемпотентен для большинства шагов)
- Домен с A-записью, указывающей на IP сервера

## Быстрый старт

```bash
curl -fsSL https://raw.githubusercontent.com/k0sha/setup-server/main/setup-server.sh -o setup-server.sh
sudo bash setup-server.sh
```

Скрипт автоматически переместится в `/opt/setup-server/` и при первом запуске проверит наличие обновлений.

## Конфиг

При первом запуске скрипт запрашивает все параметры интерактивно и сохраняет их в `/opt/setup-server/setup-server.conf`.

При повторном запуске — показывает сохранённые значения и предлагает использовать их.

Можно заранее создать конфиг рядом со скриптом (скрипт переместит его вместе с собой):

```bash
cp setup-server.conf.example setup-server.conf
nano setup-server.conf
sudo bash setup-server.sh
```

Все поля конфига описаны в `setup-server.conf.example`.

## Повторный деплой (только фаза 2)

```bash
sudo bash /opt/setup-server/setup-server.sh --deploy
```

## Структура после деплоя

```
/opt/setup-server/
  setup-server.sh       # скрипт
  setup-server.log      # лог фазы 1
  deploy-info.txt       # итоговая сводка (без паролей и ключей)

/opt/nginx/
  nginx.conf
  docker-compose.yml
  fullchain.pem / privkey.key
  www/                  # заглушка (замени на свой сайт)
  nginx-logs/
```

## Обновление скрипта

При каждом первом запуске из штатного расположения скрипт проверяет наличие новой версии на GitHub и предлагает обновиться.

## Лицензия

MIT — см. [LICENSE](LICENSE).
