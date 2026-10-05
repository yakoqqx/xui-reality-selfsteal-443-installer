<div align="center">

# xui-reality-selfsteal-443-installer

**VPN server installer for 3x-ui / Xray: VLESS Reality (self-steal) on 443, VLESS XHTTP, Hysteria2**

[![Русский](https://img.shields.io/badge/%D0%A0%D1%83%D1%81%D1%81%D0%BA%D0%B8%D0%B9-555555?style=for-the-badge)](README.md)
[![English](https://img.shields.io/badge/English-2ea44f?style=for-the-badge)](README.en.md)

</div>

---

The script deploys the 3x-ui panel on a VPS, VLESS Reality on 443/tcp disguised as its own website, VLESS XHTTP, optionally Hysteria2, and outputs a single subscription link for all protocols. It issues a Let's Encrypt certificate and configures nginx, routing and ufw. Supports a fresh install and importing `x-ui.db` from another server.

> The script's prompts and messages are in Russian.

## Requirements

- Ubuntu, root or sudo.
- A domain or subdomain with an A record pointing to the server's IP.
- Free ports 80/tcp and 443/tcp.
- ufw is configured automatically. With another firewall, open: 80/tcp, 443/tcp, SSH, the Hysteria2 UDP port.

## Installation

```bash
wget -O install.sh https://raw.githubusercontent.com/yakoqqx/xui-reality-selfsteal-443-installer/main/install.sh
sudo bash install.sh
```

Answer the questions again:

```bash
sudo bash install.sh --reconfigure
```

Check without changing the server, exit code 0 — no errors, 1 — errors found:

```bash
sudo bash install.sh --check
```

## Layout

```
80/tcp         → nginx
                   IP, foreign Host → 444
                   domain → /.well-known/acme-challenge/  /var/www/acme
                            other paths                   301 https://<domain>
443/tcp        → Xray VLESS Reality (SNI = domain, target = 127.0.0.1:7443)
                   Reality client → tunnel
                   other connections → nginx 127.0.0.1:7443
127.0.0.1:7443 → nginx
                   foreign / empty SNI, IP → ssl_reject_handshake
                   domain → /                       decoy website
                            /<XHTTP path>           Xray XHTTP 127.0.0.1:8081
                            /<subscription path>    subscription 127.0.0.1:2096
                            /<panel path>           3x-ui panel 127.0.0.1:2053
<port>/udp     → Hysteria2 (optional)
```

Ports open from outside: 80/tcp, 443/tcp, SSH, the Hysteria2 UDP port. All addresses in the links use the domain.

## Components

| Component | Settings |
|---|---|
| Certificate | Let's Encrypt, acme.sh, ECDSA, HTTP-01 through nginx (webroot `/var/www/acme`). Renewal: `/usr/local/sbin/cert-renew.sh` from root's cron, daily, when fewer than 30 days remain. |
| nginx | `127.0.0.1:7443`, TLS 1.3 + h2. Default server: `ssl_reject_handshake on`. Decoy website, XHTTP (`grpc_pass`), subscription and panel (`proxy_pass`, WebSocket) on secret paths. 80/tcp: 301 to https for the domain, 444 for other requests. |
| 3x-ui | Panel on `127.0.0.1:2053`, accessed through nginx. |
| VLESS Reality | 443/tcp, `xtls-rprx-vision`, fingerprint `firefox`, target `127.0.0.1:7443`, SNI is the domain, xver 0. |
| VLESS XHTTP | `127.0.0.1:8081`, `stream-one`, security none. Host `<domain>:443`, TLS, ALPN `h2`, fingerprint `firefox`. |
| Hysteria2 | UDP, TLS with the domain certificate, ALPN `h3`, Salamander. Default port 443/udp. |
| Routing | `geoip:ru` → blocked; UDP/443 → blocked for Reality and XHTTP. Tags from `config.json`. |
| Subscription | `127.0.0.1:2096`, `subURI` = `https://<domain>/<subscription path>/`. |
| ufw | SSH, 80/tcp, 443/tcp, the Hysteria2 UDP port. |

Custom decoy page: on first install the script pauses; you can put `index.html` and `favicon.ico` / `.svg` / `.png` into `/var/www/<domain>/`. Otherwise a 403 page is installed.

## Installation modes

### Fresh install

The script asks for:

1. domain, email for Let's Encrypt;
2. path to `x-ui.db` — leave empty;
3. secret paths for XHTTP, the subscription, the panel;
4. panel username and password;
5. Hysteria2: yes/no, port;
6. the first client's name.

Domain and email are required; everything else is generated if left empty.

Hysteria2 port: 443 by default, `r` picks a random port in 20000–60000. Not accepted: 51820, 1194, 500, 4500, 1723; 1–1023 except 443; 7443, 8081, 2053, 2096, 62789; SSH; UDP ports in use.

### Importing x-ui.db

1. On the source server:
   ```bash
   sqlite3 /etc/x-ui/x-ui.db "PRAGMA wal_checkpoint(TRUNCATE);"
   ```
   copy `/etc/x-ui/x-ui.db` to the new server.
2. Point the domain's A record to the new IP.
3. Run the script and enter the path to the file.

Clients, panel username and password, and secret paths are taken from the database. Changes:

- Reality: port 443, target `127.0.0.1:7443`, SNI is the domain, new x25519 keys and shortIds, `limitFallback*` removed. Several enabled Reality inbounds — the script stops and lists them.
- Other inbounds on public TCP ports are disabled.
- Hysteria2: asks whether to keep the current port; if absent, asks whether to add it.
- Hosts: address is the domain, ports are 443 (Reality, XHTTP) and the Hysteria2 port. Hosts with another domain are not changed.
- Tags in routing rules, `subURI` and ufw rules are updated.
- Panel username and password: asks whether to set new ones; otherwise the existing ones are kept.
- 2FA is disabled.

## Checks

After installation:

- only Xray listens on 443/tcp, nginx on `127.0.0.1:7443` and 80/tcp, Hysteria2 on its UDP port;
- `config.json`: Reality on 443, target `127.0.0.1:7443`, no `limitFallback`; the UDP/443 rule covers the Reality and XHTTP tags;
- no connections to `127.0.0.1:443`;
- `127.0.0.1:7443`: TLS 1.3, h2, domain certificate, rejection without SNI;
- public 443: no SNI and a foreign SNI are rejected, the domain gets the certificate;
- the site, panel and subscription respond through 443, the subscription contains all protocols;
- 80/tcp: by IP and with a foreign Host the connection is closed without a response, the domain gets a 301 to https, `/.well-known/acme-challenge/` is served;
- acme.sh is in webroot mode, `cert-renew.sh` is in root's cron;
- no warning in the Xray log about Reality not on 443;
- ufw rules.

Output: panel address, username, password, subscription link.

## Re-running

Each step compares the current state with the target state and changes only what differs. On a configured server a run changes nothing; an interrupted installation is completed.

## Files on the server

| Path | Purpose |
|---|---|
| `/root/.xui-reality-selfsteal-443-installer.conf` | answers, panel username and password (0600) |
| `/root/xui-reality-selfsteal-443-installer.log` | log (0600) |
| `/etc/nginx/sites-available/<domain>` | site |
| `/etc/nginx/conf.d/00-reject-unknown-sni.conf` | anti-scan 127.0.0.1:7443 |
| `/etc/nginx/conf.d/00-http-reject.conf` | anti-scan 80/tcp |
| `/etc/nginx/conf.d/10-http-<domain>.conf` | port 80 of the domain |
| `/var/www/acme/` | HTTP-01 challenge directory |
| `/var/www/<domain>/` | decoy page |
| `/etc/ssl/<domain>/` | certificate |
| `/usr/local/sbin/cert-renew.sh` | certificate renewal |

## Credits

[3x-ui](https://github.com/MHSanaei/3x-ui) · [Xray-core](https://github.com/XTLS/Xray-core) · [acme.sh](https://github.com/acmesh-official/acme.sh) · [nginx](https://nginx.org/)
