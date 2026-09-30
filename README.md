<div align="center">

# xui-reality-selfsteal-443-installer

**Установщик VPN-сервера на 3x-ui / Xray: VLESS Reality (self-steal) на 443, VLESS XHTTP, Hysteria2**

[![Русский](https://img.shields.io/badge/%D0%A0%D1%83%D1%81%D1%81%D0%BA%D0%B8%D0%B9-2ea44f?style=for-the-badge)](README.md)
[![English](https://img.shields.io/badge/English-555555?style=for-the-badge)](README.en.md)

</div>

---

Скрипт разворачивает на VPS панель 3x-ui, VLESS Reality на 443/tcp с маскировкой под собственный сайт, VLESS XHTTP, опционально Hysteria2, и выдаёт одну ссылку подписки на все протоколы. Выпускает сертификат Let's Encrypt, настраивает nginx, маршрутизацию и ufw. Поддерживает установку с нуля и импорт `x-ui.db` с другого сервера.

## Требования

- Ubuntu, root или sudo.
- Домен или поддомен, A-запись указывает на IP сервера.
- Свободные порты 80/tcp (выпуск и продление сертификата) и 443/tcp.
- ufw настраивается автоматически. При другом файрволе открыть: 443/tcp, SSH, UDP-порт Hysteria2, 80/tcp на время выпуска сертификата.

## Установка

```bash
wget -O install.sh https://raw.githubusercontent.com/yakoqqx/xui-reality-selfsteal-443-installer/main/install.sh
sudo bash install.sh
```

Задать ответы заново:

```bash
sudo bash install.sh --reconfigure
```

## Схема

```
443/tcp        → Xray VLESS Reality (SNI = домен, target = 127.0.0.1:7443)
                   клиент Reality → туннель
                   остальные подключения → nginx 127.0.0.1:7443
127.0.0.1:7443 → nginx
                   чужой / пустой SNI, IP → ssl_reject_handshake
                   домен → /                  сайт-заглушка
                           /<путь XHTTP>      Xray XHTTP 127.0.0.1:8081
                           /<путь подписки>   подписка 127.0.0.1:2096
                           /<путь панели>     панель 3x-ui 127.0.0.1:2053
<порт>/udp     → Hysteria2 (опционально)
```

Открытые порты снаружи: 443/tcp, SSH, UDP-порт Hysteria2. Все адреса в ссылках — по домену.

## Компоненты

| Компонент | Настройки |
|---|---|
| Сертификат | Let's Encrypt, acme.sh, ECDSA, HTTP-01 на 80/tcp. Продление — `/usr/local/sbin/cert-renew.sh` из cron root, ежедневно, при сроке меньше 30 дней. |
| nginx | Только `127.0.0.1:7443`, TLS 1.3 + h2. Сервер по умолчанию — `ssl_reject_handshake on`. Сайт-заглушка, XHTTP (`grpc_pass`), подписка и панель (`proxy_pass`, WebSocket) по секретным путям. |
| 3x-ui | Панель на `127.0.0.1:2053`, доступ через nginx. |
| VLESS Reality | 443/tcp, `xtls-rprx-vision`, fingerprint `firefox`, target `127.0.0.1:7443`, SNI — домен, xver 0. |
| VLESS XHTTP | `127.0.0.1:8081`, `stream-one`, security none. Хост `<домен>:443`, TLS, fingerprint `firefox`. |
| Hysteria2 | UDP, TLS с сертификатом домена, ALPN `h3`, Salamander. Порт по умолчанию 443/udp. |
| Маршрутизация | `geoip:ru` → blocked; UDP/443 → blocked для Reality и XHTTP. Теги из `config.json`. |
| Подписка | `127.0.0.1:2096`, `subURI` = `https://<домен>/<путь подписки>/`. |
| ufw | SSH, 443/tcp, UDP-порт Hysteria2. |

Своя заглушка: при первой установке скрипт делает паузу, в `/var/www/<домен>/` можно положить `index.html` и `favicon.ico` / `.svg` / `.png`. Иначе ставится страница 403.

## Режимы установки

### Новая установка

Запрашивается:

1. домен, email для Let's Encrypt;
2. путь к `x-ui.db` — пусто;
3. секретные пути XHTTP, подписки, панели;
4. логин и пароль панели;
5. Hysteria2: да/нет, порт;
6. имя первого клиента.

Обязательны домен и email, остальное генерируется при пустом ответе.

Порт Hysteria2: 443 по умолчанию, `r` — случайный из 20000–60000. Не принимаются: 51820, 1194, 500, 4500, 1723; 1–1023, кроме 443; 7443, 8081, 2053, 2096, 62789; SSH; занятые UDP-порты.

### Импорт x-ui.db

1. На исходном сервере:
   ```bash
   sqlite3 /etc/x-ui/x-ui.db "PRAGMA wal_checkpoint(TRUNCATE);"
   ```
   скопировать `/etc/x-ui/x-ui.db` на новый сервер.
2. Перевести A-запись домена на новый IP.
3. Запустить скрипт, указать путь к файлу.

Из базы берутся клиенты, логин и пароль панели, секретные пути. Изменения:

- Reality: порт 443, target `127.0.0.1:7443`, SNI — домен, новые ключи x25519 и shortIds, `limitFallback*` удаляются. Несколько включённых Reality-инбаундов — остановка со списком.
- Прочие инбаунды на публичных TCP-портах выключаются.
- Hysteria2: запрос, оставить ли текущий порт; при отсутствии — запрос на добавление.
- Хосты: адрес — домен, порты — 443 (Reality, XHTTP) и порт Hysteria2. Хосты с другим доменом не меняются.
- Теги в правилах маршрутизации, `subURI`, правила ufw обновляются.
- Логин и пароль панели: запрос, задать ли новые; иначе остаются прежние.
- 2FA отключается.

## Проверки

После установки:

- 443/tcp слушает только Xray, nginx — только `127.0.0.1:7443`, Hysteria2 — свой UDP-порт;
- `config.json`: Reality на 443, target `127.0.0.1:7443`, нет `limitFallback`; правило UDP/443 — по тегам Reality и XHTTP;
- нет соединений на `127.0.0.1:443`;
- `127.0.0.1:7443`: TLS 1.3, h2, сертификат домена, без SNI — отказ;
- публичный 443: без SNI и с чужим SNI — отказ, с доменом — сертификат;
- сайт, панель и подписка отвечают через 443, в подписке есть все протоколы;
- в журнале Xray нет предупреждения о Reality не на 443;
- правила ufw.

Вывод: адрес панели, логин, пароль, ссылка подписки.

## Повторный запуск

Каждый шаг сравнивает текущее состояние с целевым и меняет только расхождения. На настроенном сервере запуск ничего не меняет; прерванная установка завершается.

## Файлы на сервере

| Путь | Назначение |
|---|---|
| `/root/.xui-reality-selfsteal-443-installer.conf` | ответы, логин и пароль панели (0600) |
| `/root/xui-reality-selfsteal-443-installer.log` | лог (0600) |
| `/etc/nginx/sites-available/<домен>` | сайт |
| `/etc/nginx/conf.d/00-reject-unknown-sni.conf` | сервер по умолчанию |
| `/var/www/<домен>/` | заглушка |
| `/etc/ssl/<домен>/` | сертификат |
| `/usr/local/sbin/cert-renew.sh` | продление сертификата |

## Благодарности

[3x-ui](https://github.com/MHSanaei/3x-ui) · [Xray-core](https://github.com/XTLS/Xray-core) · [acme.sh](https://github.com/acmesh-official/acme.sh) · [nginx](https://nginx.org/)
