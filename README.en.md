<div align="center">

# xui-reality-selfsteal-443-installer

**VPN server installer for 3x-ui / Xray: VLESS Reality (self-steal) on 443, VLESS XHTTP, Hysteria2**

[![Русский](https://img.shields.io/badge/%D0%A0%D1%83%D1%81%D1%81%D0%BA%D0%B8%D0%B9-555555?style=for-the-badge)](README.md)
[![English](https://img.shields.io/badge/English-2ea44f?style=for-the-badge)](README.en.md)

</div>

---

The script installs the 3x-ui panel on a VPS and sets up VLESS Reality on 443/tcp. From the outside, the server looks like an ordinary website on your domain. VLESS XHTTP and Hysteria2 can be added as well. All protocols reach the client through a single subscription link. The script also takes care of the Let's Encrypt certificate, nginx, routing and ufw. You can install from scratch or move an `x-ui.db` database from another server.

> The script's prompts and messages are in Russian.

## Requirements

- Ubuntu, root or sudo access.
- A domain or subdomain with an A record pointing to the server's IP.
- Free ports 80/tcp and 443/tcp.
- The script configures ufw itself. With a different firewall, open 80/tcp, 443/tcp, SSH and the Hysteria2 UDP port there.

## Installation

```bash
wget -O install.sh https://raw.githubusercontent.com/yakoqqx/xui-reality-selfsteal-443-installer/main/install.sh
sudo bash install.sh
```

Answer the questions again:

```bash
sudo bash install.sh --reconfigure
```

Check the server without changing anything:

```bash
sudo bash install.sh --check
```

Remove what the script installed, fully or in parts:

```bash
sudo bash install.sh --uninstall
```

| Item | What is removed |
|---|---|
| 1 | 3x-ui: the x-ui service, `/usr/local/x-ui`, `/etc/x-ui`, `/var/log/x-ui`, fail2ban jail `3x-ipl`. The database is copied to `/root/x-ui.db.<date>` first. |
| 2 | nginx configs created by the script: site, anti-scan, port 80. |
| 3 | Certificate `/etc/ssl/<folder>`, the domain in acme.sh, `cert-renew.sh` and the cron job. acme.sh itself is removed only if it holds no other domains. |
| 4 | ufw rules added by the script. The SSH rule stays. |
| 5 | Everything above, plus the decoy site, answers file, log and `/root/nginx-*.tgz` archives. |

The nginx and fail2ban packages are removed only if you confirm a separate question. curl, openssl, python3, sqlite3, cron and `/etc/nginx/snippets/xui-panel*.conf` files are not removed.

To reinstall 3x-ui, remove item 1 and run `sudo bash install.sh`.

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
                            /<XHTTP path>           Xray XHTTP 127.0.0.1:8081 (optional)
                            /<subscription path>    subscription 127.0.0.1:2096
                            /<panel path>           3x-ui panel 127.0.0.1:2053
<port>/udp     → Hysteria2 (optional)
```

Only 80/tcp, 443/tcp, SSH and the Hysteria2 UDP port are open from the outside. All links use the domain, not the IP.

## What gets configured

| Component | Settings |
|---|---|
| Certificate | Let's Encrypt via acme.sh, ECDSA, HTTP-01 challenge through nginx (webroot `/var/www/acme`). Renewed by `/usr/local/sbin/cert-renew.sh`: cron runs it daily, and the certificate is renewed when less than 30 days are left. |
| nginx | Listens on `127.0.0.1:7443`, TLS 1.3 and h2. Connections without SNI or with a foreign SNI are rejected (`ssl_reject_handshake`). XHTTP (`grpc_pass`), the subscription and the panel (`proxy_pass`, WebSocket) live on secret paths, everything else is the decoy site. On 80/tcp the domain is redirected to https, other requests get 444. |
| 3x-ui | The panel listens on `127.0.0.1:2053` and is reachable only through nginx. The version tested with the script is installed. If a newer one is out, you can pick it during installation. |
| 3x-ui ads | Always off: nginx returns an empty list for `/<panel path>/sponsors` and 404 for `/<panel path>/sponsors/`. |
| VLESS Reality | 443/tcp, `xtls-rprx-vision`, fingerprint `firefox`, target `127.0.0.1:7443`, SNI is the domain, xver 0. |
| VLESS XHTTP | Optional. `127.0.0.1:8081`, `stream-one` mode. In the subscription: `<domain>:443`, TLS, ALPN `h2`, fingerprint `firefox`. |
| Hysteria2 | Optional. UDP, domain certificate, ALPN `h3`, Salamander. Default port 443/udp. |
| Sniffing | On Reality, XHTTP and Hysteria2: `http`, `tls`, `quic`, `routeOnly`. The domain found in traffic is used for routing only, the destination address is not replaced. |
| Routing | → blocked: private IPs (`geoip:private`), Russian IPs (`ext:geoip_RU.dat:ru`), BitTorrent, domains from `ext:geosite_RU.dat:ru-available-only-inside`, the `.ru`, `.su`, `.рф` zones, ads (`category-ads-all`); UDP/443 for Reality and XHTTP. Your own rules are kept, the script only adds what is missing. |
| Subscription | `127.0.0.1:2096`, link format `https://<domain>/<subscription path>/`. |
| ufw | SSH (the port is taken from the running sshd or ssh.socket), 80/tcp, 443/tcp, the Hysteria2 UDP port. |

Your own directives for the panel, such as `sub_filter` for a favicon, go into `/etc/nginx/snippets/xui-panel*.conf`. The script includes these files and never changes them.

Your own decoy site: on the first install the script pauses so you can put `index.html` and `favicon.ico`, `.svg` or `.png` into `/var/www/<domain>/`. Without them, a 403 page is installed.

## Fresh install

The script asks for:

1. the domain and an email for Let's Encrypt;
2. the path to `x-ui.db` — leave empty;
3. the 3x-ui version, if a newer one than the tested version is out;
4. whether to add VLESS XHTTP;
5. secret paths for XHTTP, the subscription and the panel;
6. panel username and password;
7. whether to add Hysteria2 and on which port;
8. the first client's name.

Only the domain and email are required, everything else is generated if left empty.

A secret path is one or more parts separated by `/`, made of letters, digits, `-` and `_`. Paths must not match or be nested in each other.

The Hysteria2 port is 443 by default, `r` picks a random one in 20000–60000. Not allowed: 51820, 1194, 500, 4500, 1723; 1–1023 except 443; 7443, 8081, 2053, 2096, 62789; the SSH port; UDP ports in use.

## Moving x-ui.db

1. On the old server run:
   ```bash
   sqlite3 /etc/x-ui/x-ui.db "PRAGMA wal_checkpoint(TRUNCATE);"
   ```
   and copy `/etc/x-ui/x-ui.db` to the new server.
2. Point the domain's A record to the new IP.
3. Run the script and enter the path to the file.

Clients, the panel username and password, and secret paths are taken from the database. During the move:

- Reality is moved to 443, target `127.0.0.1:7443`, SNI is the domain; non-zero `limitFallback*` are removed. x25519 keys and shortIds are kept if Reality was already set up the same way, otherwise new ones are issued. If several Reality inbounds are enabled, the script stops and lists them.
- Other inbounds on public TCP ports are disabled.
- If the database has no XHTTP or Hysteria2, the script offers to add them. For Hysteria2 it asks whether to keep the current port.
- Hosts get the domain as the address, port 443 (Reality, XHTTP) and the Hysteria2 port. Hosts with another domain are left as they are.
- `externalProxy` is removed: links are built from Hosts.
- Tags in routing rules, `subURI` and ufw rules are updated.
- You can set a new panel username and password or keep the old ones.
- 2FA is disabled.

A database from a newer 3x-ui version than the installed one is not moved: the script stops before any change and lists the unknown migrations and tables.

## Checks

At the end of installation and with `--check`, the script verifies that:

- only Xray listens on 443/tcp, nginx on `127.0.0.1:7443` and 80/tcp, Hysteria2 on its UDP port;
- in `config.json` Reality is on 443 with target `127.0.0.1:7443`, has no non-zero `limitFallback`, inbounds have sniffing, and the blocking and UDP/443 rules are in place;
- there are no connections to `127.0.0.1:443`;
- `127.0.0.1:7443` answers with TLS 1.3 and h2 using the domain certificate and rejects connections without SNI;
- public 443 rejects connections without SNI or with a foreign SNI and serves the certificate for the domain;
- the site, panel and subscription open through 443, and the subscription contains all protocols;
- nginx intercepts the 3x-ui ad request;
- on 80/tcp, requests by IP or with a foreign Host are closed without a response, the domain gets a 301 to https, `/.well-known/acme-challenge/` is served;
- acme.sh works through webroot, `cert-renew.sh` is in root's cron;
- the Xray log has no warning about Reality not being on 443;
- ufw rules.

If a path in the answers file differs from the 3x-ui database, `--check` shows a warning and checks against the database.

At the end of installation, the panel address, username, password and subscription link are printed.

## Re-running

Each step compares the current state with the desired one and fixes only the differences. On a configured server a re-run changes nothing, and an interrupted installation continues where it stopped.

## Files on the server

| Path | Purpose |
|---|---|
| `/root/.xui-reality-selfsteal-443-installer.conf` | answers, panel username and password (0600) |
| `/root/xui-reality-selfsteal-443-installer.log` | log (0600) |
| `/etc/nginx/sites-available/<domain>` | site |
| `/etc/nginx/conf.d/00-reject-unknown-sni.conf` | anti-scan for 127.0.0.1:7443 |
| `/etc/nginx/conf.d/00-http-reject.conf` | anti-scan for 80/tcp |
| `/etc/nginx/conf.d/10-http-<domain>.conf` | port 80 for the domain |
| `/var/www/acme/` | HTTP-01 challenge directory |
| `/var/www/<domain>/` | decoy site |
| `/etc/ssl/<domain>/` | certificate |
| `/usr/local/sbin/cert-renew.sh` | certificate renewal |

## Credits

[3x-ui](https://github.com/MHSanaei/3x-ui) · [Xray-core](https://github.com/XTLS/Xray-core) · [acme.sh](https://github.com/acmesh-official/acme.sh) · [nginx](https://nginx.org/)
