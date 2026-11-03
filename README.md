# Login-Provider anbinden: GitHub oder SAP IAS

Dieses Dokument beschreibt, was auf Provider-Seite (GitHub bzw. SAP) und im
Docker-Setup zu tun ist, damit **Caddy + oauth2-proxy** die Anmeldung für
`demo.hapetech.de` übernehmen und der dahinterliegende Rust-App-Server nur
noch fertig authentisierte Requests mit User-Headern bekommt.

## Überblick

```
Browser --https--> Caddy (TLS, Let's Encrypt)
                      │
                      ├─ /oauth2/*  ───────────► oauth2-proxy ──► GitHub bzw. SAP IAS
                      │
                      └─ alles andere:
                           forward_auth gegen oauth2-proxy
                           ├─ nicht eingeloggt (401) → Redirect auf /oauth2/sign_in
                           └─ eingeloggt            → reverse_proxy auf APP_UPSTREAM
                                                      mit Headern X-Auth-Request-*
```

Es ist immer **genau ein** Provider aktiv. Der Wechsel zwischen GitHub und
SAP betrifft nur den Service `oauth2-proxy` in der `docker-compose.yml` und die
`.env`. Caddy, `Caddyfile` und App-Server bleiben unverändert.

**Wichtig bei beiden Providern:** Die Redirect-/Callback-URL lautet immer
exakt

```
https://demo.hapetech.de/oauth2/callback
```

Der Pfad `/oauth2/callback` muss dabei sein, die Domain allein reicht nicht.

---

## 1. Gemeinsame Vorbereitung (für beide Provider)

1. DNS: `demo.hapetech.de` zeigt per A-/AAAA-Record auf den Linux-Server,
   Ports 80 und 443 sind von außen erreichbar. Caddy holt sich damit
   automatisch ein Let's-Encrypt-Zertifikat. Das Strato-Zertifikat wird
   nicht benötigt.
2. `.env` aus der Vorlage anlegen:
   ```bash
   cp .env.example .env
   ```
3. In der `.env` die gemeinsamen Werte setzen:

   | Variable | Bedeutung |
   |---|---|
   | `DOMAIN` | `demo.hapetech.de` |
   | `ACME_EMAIL` | **Echte** E-Mail-Adresse. Ist sie leer, bricht Caddy mit *"wrong argument count ... after 'email'"* ab. Alternativ die Zeile `email {$ACME_EMAIL}` im `Caddyfile` entfernen. |
   | `COOKIE_SECRET` | Muss nach Base64-Dekodierung **exakt 16, 24 oder 32 Byte** lang sein (siehe unten). |
   | `APP_UPSTREAM` | Ziel des App-Servers, z. B. `http://app-server:8080`. |

4. Cookie-Secret erzeugen (32 Byte, URL-safe Base64):
   ```bash
   openssl rand -base64 32 | tr -- '+/' '-_'
   ```
   Prüfen, dass das Ergebnis 32 Byte ergibt:
   ```bash
   echo -n "DEIN_WERT" | tr -- '-_' '+/' | base64 -d | wc -c
   ```
   Fehlermeldung bei falscher Länge: *"cookie_secret must be 16, 24, or 32 bytes ... but is 18 bytes"*.

---

## 2. Variante A: GitHub

### 2.1 Auf GitHub

1. **Settings → Developer settings → OAuth Apps → New OAuth App**
   (für eine Organisation: Org-Settings → Developer settings).
2. Eintragen:
   - **Homepage URL:** `https://demo.hapetech.de`
   - **Authorization callback URL:** `https://demo.hapetech.de/oauth2/callback`
3. App anlegen, **Client ID** notieren und ein **Client Secret** generieren.

### 2.2 In der `.env`

```bash
GITHUB_CLIENT_ID=...
GITHUB_CLIENT_SECRET='...'

# Optional: Zugriff einschränken. Alle leer = jeder GitHub-Account darf rein.
GITHUB_ORG=
GITHUB_TEAM=
GITHUB_USERS=            # kommagetrennt, z.B. peter,kollege
```

### 2.3 Service `oauth2-proxy` in der `docker-compose.yml`

```yaml
  oauth2-proxy:
    image: quay.io/oauth2-proxy/oauth2-proxy:v7.6.0
    restart: unless-stopped
    environment:
      OAUTH2_PROXY_PROVIDER: github
      OAUTH2_PROXY_CLIENT_ID: ${GITHUB_CLIENT_ID}
      OAUTH2_PROXY_CLIENT_SECRET: ${GITHUB_CLIENT_SECRET}
      OAUTH2_PROXY_COOKIE_SECRET: ${COOKIE_SECRET}
      OAUTH2_PROXY_COOKIE_SECURE: "true"
      OAUTH2_PROXY_COOKIE_DOMAINS: ${DOMAIN}
      OAUTH2_PROXY_WHITELIST_DOMAINS: ${DOMAIN}
      OAUTH2_PROXY_REDIRECT_URL: "https://${DOMAIN}/oauth2/callback"
      OAUTH2_PROXY_EMAIL_DOMAINS: "*"
      OAUTH2_PROXY_HTTP_ADDRESS: "0.0.0.0:4180"
      OAUTH2_PROXY_REVERSE_PROXY: "true"
      OAUTH2_PROXY_SET_XAUTHREQUEST: "true"
      OAUTH2_PROXY_PASS_USER_HEADERS: "true"
      OAUTH2_PROXY_SKIP_PROVIDER_BUTTON: "true"
      OAUTH2_PROXY_GITHUB_ORG: ${GITHUB_ORG:-}
      OAUTH2_PROXY_GITHUB_TEAM: ${GITHUB_TEAM:-}
      OAUTH2_PROXY_GITHUB_USERS: ${GITHUB_USERS:-}
    networks:
      - webnet
```

---

## 3. Variante B: SAP Identity Authentication Service (IAS) per OIDC

Der Login läuft über **SAP Cloud Identity Services (Identity Authentication)**
als OpenID-Connect-Provider. Die "SAP ID Service" / Universal ID
(`accounts.sap.com`) ist **nicht** dafür geeignet: Dort kann man keine eigenen
OAuth-Clients registrieren. Es muss ein IAS-Tenant sein, auf den du
Admin-Zugriff hast. Jeder BTP-Account bringt einen Default-Tenant mit.

### 3.1 Zur Admin-Konsole kommen

Die App wird **nicht im BTP Cockpit** angelegt, sondern in der separaten
IAS-Admin-Konsole:

1. BTP Cockpit → Subaccount → **Security → Trust Configuration**.
2. Dort steht dein Identity Provider mit einer URL der Form
   `https://<tenant>.accounts.ondemand.com`.
3. `/admin` anhängen: `https://<tenant>.accounts.ondemand.com/admin`.

Falls noch keine Subscription existiert: Cockpit → Subaccount →
**Entitlements** prüfen (Service "Identity Authentication") und unter
**Services → Instances and Subscriptions** eine Subscription anlegen.

Hinweis: Ein **Trial**-Account läuft ab. Für einen dauerhaft genutzten
Login ist ein Free-Tier- oder lizenzierter Account besser.

### 3.2 OIDC-Anwendung in der Admin-Konsole anlegen

1. **Applications & Resources → Applications → Create**.
2. Name vergeben (z. B. `demo-hapetech`), Protokoll **OpenID Connect**, speichern.
3. Die Anwendung öffnen → Bereich **Trust** (je nach Version "Single Sign-On")
   → **OpenID Connect Configuration** → Feld **Redirect URIs**:
   ```
   https://demo.hapetech.de/oauth2/callback
   ```
   Speichern. IAS vergleicht die URI **exakt**. Die bloße Domain
   `https://demo.hapetech.de/` führt zum Fehler *"redirect_uri muss mit der
   Konfiguration ... übereinstimmen"*.
4. **Client Authentication → Secrets**: Client Secret hinzufügen. Es wird nur
   einmal angezeigt, also sofort kopieren. Die **Client ID** steht im selben
   Bereich bzw. in den OIDC-Details.
5. **Subject Name Identifier / Attributes:** festlegen, welches Attribut als
   Benutzerkennung nach außen geht (meist E-Mail oder Login-Name). Das landet
   später im Header `X-Auth-Request-User`.
6. Optional **Application Access / Authorization**: einschränken, wer sich
   anmelden darf. Das ersetzt die GitHub-Optionen `ORG`/`TEAM`/`USERS`.

### 3.3 In der `.env`

```bash
SAP_IAS_TENANT=mein-tenant            # nur der Tenant-Name, ohne .accounts.ondemand.com
SAP_IAS_CLIENT_ID=...
SAP_IAS_CLIENT_SECRET='...'           # unbedingt in EINFACHEN Anführungszeichen
```

Das Secret enthält oft Sonderzeichen. In einfachen Anführungszeichen wird es
wörtlich übernommen. In doppelten oder ohne Anführungszeichen würde `$`
interpretiert und `#` als Kommentar gewertet, das Secret wäre dann
stillschweigend verfälscht. Kontrolle:

```bash
docker compose config | grep CLIENT_SECRET
```

(`docker compose config` zeigt `$` als `$$` an. Das ist nur die Darstellung.)

### 3.4 Service `oauth2-proxy` in der `docker-compose.yml`

Ersetzt den GitHub-Block aus 2.3. Die `GITHUB_*`-Variablen entfallen.

```yaml
  oauth2-proxy:
    image: quay.io/oauth2-proxy/oauth2-proxy:v7.6.0
    restart: unless-stopped
    environment:
      OAUTH2_PROXY_PROVIDER: oidc
      OAUTH2_PROXY_OIDC_ISSUER_URL: https://${SAP_IAS_TENANT}.accounts.ondemand.com
      OAUTH2_PROXY_CLIENT_ID: ${SAP_IAS_CLIENT_ID}
      OAUTH2_PROXY_CLIENT_SECRET: ${SAP_IAS_CLIENT_SECRET}
      OAUTH2_PROXY_SCOPE: "openid email profile"
      OAUTH2_PROXY_OIDC_EMAIL_CLAIM: email
      OAUTH2_PROXY_COOKIE_SECRET: ${COOKIE_SECRET}
      OAUTH2_PROXY_COOKIE_SECURE: "true"
      OAUTH2_PROXY_COOKIE_DOMAINS: ${DOMAIN}
      OAUTH2_PROXY_WHITELIST_DOMAINS: ${DOMAIN}
      OAUTH2_PROXY_REDIRECT_URL: "https://${DOMAIN}/oauth2/callback"
      OAUTH2_PROXY_EMAIL_DOMAINS: "*"
      OAUTH2_PROXY_HTTP_ADDRESS: "0.0.0.0:4180"
      OAUTH2_PROXY_REVERSE_PROXY: "true"
      OAUTH2_PROXY_SET_XAUTHREQUEST: "true"
      OAUTH2_PROXY_PASS_USER_HEADERS: "true"
      OAUTH2_PROXY_SKIP_PROVIDER_BUTTON: "true"
    networks:
      - webnet
```

oauth2-proxy findet die Endpunkte selbst über die OIDC-Discovery unter
`https://<tenant>.accounts.ondemand.com/.well-known/openid-configuration`.

Falls in IAS nicht die E-Mail, sondern der Login-Name als Subject-Identifier
konfiguriert ist, zusätzlich `OAUTH2_PROXY_USER_ID_CLAIM` auf das passende
Claim setzen (z. B. `sub` oder `preferred_username`).

---

## 4. Starten und Änderungen übernehmen

```bash
docker compose up -d
```

Nach Änderungen an der `.env` oder am Service `oauth2-proxy` genügt
`docker compose restart` **nicht**, weil dabei die Umgebungsvariablen nicht
neu eingelesen werden. Stattdessen:

```bash
docker compose up -d --force-recreate oauth2-proxy
```

Änderungen an `APP_UPSTREAM` betreffen Caddy:

```bash
docker compose up -d --force-recreate caddy
```

Zertifikat prüfen:

```bash
docker compose logs caddy | grep -i certificate
```

---

## 5. Was der App-Server sieht

Nach erfolgreicher Anmeldung kommen bei jedem Request u. a. diese Header an:

| Header | Inhalt |
|---|---|
| `X-Auth-Request-User` | Benutzerkennung (GitHub-Login bzw. IAS-Subject) |
| `X-Auth-Request-Email` | E-Mail-Adresse, falls vom Provider geliefert |
| `X-Auth-Request-Preferred-Username` | Bevorzugter Benutzername |
| `X-Auth-Request-Groups` | Gruppen/Orgs, falls vom Provider geliefert |

Zum Testen eignet sich das Projekt `header-echo`, das alle empfangenen Header
als Text ausgibt.

**Sicherheitshinweis:** Diese Header sind nur vertrauenswürdig, wenn der
App-Server **ausschließlich über Caddy** erreichbar ist. Kein `ports:`-Mapping
nach außen. Läuft der Server auf einem anderen Host, per Firewall nur den
Docker-Host zulassen. Sonst kann jeder die Header selbst setzen und sich als
anderer User ausgeben.

---

## 6. App-Server in Docker einbinden

**Option 1: Fertiges Host-Binary mounten** (Service `app-server` mit
`Dockerfile.rust-runtime`). Umgestellt wird über `APP_BIN_DIR`, `APP_BINARY`,
`APP_PORT` in der `.env`, danach:
```bash
docker compose up -d --build app-server
```

**Option 2: Aus Quellcode bauen** (Multi-Stage-Dockerfile, Stage `run`):
```yaml
  app-server:
    build:
      context: ./servers/mein-projekt
      dockerfile: Dockerfile           # bzw. Dockerfile.workspace bei Cargo-Workspaces
      target: run
      args:
        BIN_NAME: mein-server
        # CARGO_BUILD_ARGS: "-p mein-crate"   # nur bei Namenskollision im Workspace
    image: mein-server:latest
    restart: unless-stopped
    expose:
      - "${APP_PORT}"
    environment:
      PORT: ${APP_PORT}
    networks:
      - webnet
```
Build-Args werden nur beim Bauen ausgewertet. Nach einer Änderung von
`BIN_NAME` ist `docker compose up -d --build app-server` nötig.

In beiden Fällen gilt: `APP_UPSTREAM=http://app-server:<APP_PORT>`.

---

## 7. Fehlerbilder und Lösungen

| Meldung / Symptom | Ursache | Lösung |
|---|---|---|
| `cookie_secret must be 16, 24, or 32 bytes ... but is 18 bytes` | Cookie-Secret hat falsche Länge | Mit `openssl rand -base64 32 \| tr -- '+/' '-_'` neu erzeugen |
| Caddy: `wrong argument count or unexpected line ending after 'email'` | `ACME_EMAIL` ist leer | E-Mail eintragen oder Zeile im `Caddyfile` entfernen |
| SAP: *"redirect_uri muss mit der Konfiguration übereinstimmen"* | In IAS steht nur die Domain statt der Callback-URL | `https://demo.hapetech.de/oauth2/callback` eintragen |
| Login schlägt mit SAP fehl, Secret "falsch" | Sonderzeichen im Secret durch Quoting verfälscht | In `.env` in einfache Anführungszeichen setzen |
| Edge: "Nicht sicher", obwohl Zertifikat gültig | Alte Browser-Ausnahme "Inhalte trotz Zertifikatsfehler erlauben" | Websiteeinstellungen → Berechtigungen zurücksetzen bzw. in `edge://settings/content/all` den Eintrag löschen |
| Änderung in `.env` wirkt nicht | `docker compose restart` liest die `.env` nicht neu ein | `docker compose up -d --force-recreate <service>` |
