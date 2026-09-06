#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# V2ray-Bot one-line installer (Ubuntu / Debian, run as root)
#
#   bash <(curl -fsSL https://bot.primelinelk.com/install.sh)
#
# Installs Go and nginx, builds the bot, asks for the Telegram bot token,
# the admin chat ID, lets you choose Turso or Firebase as the primary
# database, generates a random dashboard password, and starts everything
# as a systemd service.
#
# Every answer can also be supplied up-front as an environment variable for a
# fully unattended install:
#
#   PRIMARY_DATABASE=turso BOT_TOKEN=123:abc ADMIN_CHAT_IDS=5478442446 \
#   TURSO_DATABASE_URL=libsql://your-db.turso.io TURSO_AUTH_TOKEN=xxx \
#   DOMAIN=bot.example.com TLS_EMAIL=me@example.com bash install.sh
#
#   PRIMARY_DATABASE=firebase BOT_TOKEN=123:abc ADMIN_CHAT_IDS=5478442446 \
#   FIREBASE_PROJECT_ID=my-project FIREBASE_CREDENTIALS_JSON='{...}' \
#   DOMAIN=bot.example.com TLS_EMAIL=me@example.com bash install.sh
#
# To pull the newest commit onto an existing server, rebuild and restart
# (settings in .env, nginx and HTTPS are all left alone):
#
#   GITHUB_TOKEN=github_pat_xxx bash install.sh --update
#
# Flags:  --update    update an existing install to the newest commit
#         --dry-run   validate everything, change nothing
#         --no-tls    skip the Let's Encrypt certificate
#         --rotate-password  generate a new dashboard password on re-install
# ---------------------------------------------------------------------------
set -Eeuo pipefail

REPO_URL="${REPO_URL:-https://github.com/x-kevinbro/V2ray-Bot.git}"
BRANCH="${BRANCH:-main}"
INSTALL_DIR="${INSTALL_DIR:-/opt/v2raybot}"
SERVICE_NAME="${SERVICE_NAME:-v2raybot}"
DASHBOARD_PORT="${DASHBOARD_PORT:-8080}"
DASHBOARD_USERNAME="${DASHBOARD_USERNAME:-admin}"
GO_MIN="${GO_MIN:-1.25.0}"
GO_VERSION="${GO_VERSION:-1.25.0}"
BINARY_NAME="v2raybot"
DRY_RUN=0
UPDATE=0
NO_TLS=0
ROTATE_PASSWORD="${ROTATE_PASSWORD:-0}"

BOT_TOKEN="${BOT_TOKEN:-}"
ADMIN_CHAT_IDS="${ADMIN_CHAT_IDS:-}"
FIREBASE_PROJECT_ID="${FIREBASE_PROJECT_ID:-}"
FIREBASE_CREDENTIALS_FILE="${FIREBASE_CREDENTIALS_FILE:-}"
FIREBASE_CREDENTIALS_JSON="${FIREBASE_CREDENTIALS_JSON:-}"
PRIMARY_DATABASE="${PRIMARY_DATABASE:-}"
TURSO_DATABASE_URL="${TURSO_DATABASE_URL:-}"
TURSO_AUTH_TOKEN="${TURSO_AUTH_TOKEN:-}"
DOMAIN="${DOMAIN:-}"
TLS_EMAIL="${TLS_EMAIL:-}"
GITHUB_TOKEN="${GITHUB_TOKEN:-}"

BOLD=$'\033[1m'; RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; CYN=$'\033[36m'; OFF=$'\033[0m'
step() { printf '%s==>%s %s\n' "$CYN" "$OFF" "$*"; }
ok()   { printf '%s  ok%s %s\n' "$GRN" "$OFF" "$*"; }
warn() { printf '%s warn%s %s\n' "$YEL" "$OFF" "$*" >&2; }
die()  { printf '%s fail%s %s\n' "$RED" "$OFF" "$*" >&2; exit 1; }
run()  { if [ "$DRY_RUN" = 1 ]; then printf '   (dry-run) %s\n' "$*"; else "$@"; fi; }

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --update) UPDATE=1 ;;
    --no-tls) NO_TLS=1 ;;
    --rotate-password) ROTATE_PASSWORD=1 ;;
    --domain) DOMAIN="${2:-}"; shift ;;
    --email) TLS_EMAIL="${2:-}"; shift ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
  shift
done

[ "$(id -u)" = 0 ] || die "run this as root (use sudo)."
[ -r /etc/os-release ] || die "unsupported system: no /etc/os-release"
. /etc/os-release
case "${ID:-}${ID_LIKE:-}" in
  *debian*|*ubuntu*) : ;;
  *) warn "this installer targets Ubuntu/Debian; continuing anyway." ;;
esac

printf '\n%sV2ray-Bot installer%s  ->  %s\n\n' "$BOLD" "$OFF" "$INSTALL_DIR"
[ "$DRY_RUN" = 1 ] && warn "dry-run: nothing will be installed or changed."

INTERACTIVE=0
if [ -t 0 ]; then
  INTERACTIVE=1
elif { exec 0</dev/tty; } 2>/dev/null; then
  INTERACTIVE=1
fi
ask() { # ask <prompt> <varname>
  local prompt="$1" name="$2" reply=""
  [ "$INTERACTIVE" = 1 ] || die "$name was not provided and there is no terminal to ask on. Pass it as an environment variable."
  while [ -z "$reply" ]; do printf '%s' "$prompt"; IFS= read -r reply || true; done
  printf -v "$name" '%s' "$reply" 2>/dev/null || eval "$name=\$reply"
}

if [ "$UPDATE" = 1 ]; then
  [ -f "$INSTALL_DIR/.env" ] || die "no existing install at $INSTALL_DIR - run without --update first, or set INSTALL_DIR=/path"
  step "Update mode: reusing the settings already in $INSTALL_DIR/.env"
  [ -n "$BOT_TOKEN" ] || BOT_TOKEN="$(grep -m1 '^BOT_TOKEN=' "$INSTALL_DIR/.env" | cut -d= -f2-)"
  [ -n "$ADMIN_CHAT_IDS" ] || ADMIN_CHAT_IDS="$(grep -m1 '^ADMIN_CHAT_IDS=' "$INSTALL_DIR/.env" | cut -d= -f2-)"
  [ -n "$PRIMARY_DATABASE" ] || PRIMARY_DATABASE="$(grep -m1 '^PRIMARY_DATABASE=' "$INSTALL_DIR/.env" | cut -d= -f2- || true)"
  [ -n "$TURSO_DATABASE_URL" ] || TURSO_DATABASE_URL="$(grep -m1 '^TURSO_DATABASE_URL=' "$INSTALL_DIR/.env" | cut -d= -f2- || true)"
  [ -n "$TURSO_AUTH_TOKEN" ] || TURSO_AUTH_TOKEN="$(grep -m1 '^TURSO_AUTH_TOKEN=' "$INSTALL_DIR/.env" | cut -d= -f2- || true)"
  [ -n "$FIREBASE_PROJECT_ID" ] || FIREBASE_PROJECT_ID="$(grep -m1 '^FIREBASE_PROJECT_ID=' "$INSTALL_DIR/.env" | cut -d= -f2- || true)"
  [ -n "$FIREBASE_CREDENTIALS_FILE" ] || FIREBASE_CREDENTIALS_FILE="$(grep -m1 '^FIREBASE_CREDENTIALS_FILE=' "$INSTALL_DIR/.env" | cut -d= -f2- || true)"
  [ -n "$FIREBASE_CREDENTIALS_FILE" ] || FIREBASE_CREDENTIALS_FILE="$INSTALL_DIR/serviceAccountKey.json"
  case "$FIREBASE_CREDENTIALS_FILE" in /*) : ;; *) FIREBASE_CREDENTIALS_FILE="$INSTALL_DIR/${FIREBASE_CREDENTIALS_FILE#./}" ;; esac
  ok "dashboard password, nginx and HTTPS will be left untouched"
fi

# --- 1. base packages ------------------------------------------------------
step "Installing base packages"
export DEBIAN_FRONTEND=noninteractive
run apt-get update -qq
run apt-get install -y -qq git curl ca-certificates openssl python3 nginx >/dev/null
ok "git, curl, openssl, python3, nginx"

# --- 2. Go toolchain -------------------------------------------------------
version_ge() { [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" = "$2" ]; }
step "Checking Go toolchain (need >= $GO_MIN)"
GO_BIN="$(command -v go || true)"
GO_HAVE=""
[ -n "$GO_BIN" ] && GO_HAVE="$(go version 2>/dev/null | awk '{print $3}' | sed 's/^go//')"
if [ -n "$GO_HAVE" ] && version_ge "$GO_HAVE" "$GO_MIN"; then
  ok "go $GO_HAVE already installed"
else
  case "$(uname -m)" in
    x86_64|amd64) GOARCH=amd64 ;;
    aarch64|arm64) GOARCH=arm64 ;;
    *) die "unsupported CPU architecture: $(uname -m)" ;;
  esac
  step "Installing go $GO_VERSION ($GOARCH)"
  run curl -fsSL -o /tmp/go.tgz "https://go.dev/dl/go${GO_VERSION}.linux-${GOARCH}.tar.gz"
  run rm -rf /usr/local/go
  run tar -C /usr/local -xzf /tmp/go.tgz
  run rm -f /tmp/go.tgz
  run ln -sf /usr/local/go/bin/go /usr/local/bin/go
  export PATH="/usr/local/go/bin:$PATH"
  ok "go $GO_VERSION installed"
fi

# --- 3. collect the settings ----------------------------------------------
step "Bot settings"
if [ -z "$BOT_TOKEN" ]; then
  echo "   Get this from @BotFather -> your bot -> API token."
  ask "   Telegram bot token: " BOT_TOKEN
fi
BOT_TOKEN="$(printf '%s' "$BOT_TOKEN" | tr -d '[:space:]')"
case "$BOT_TOKEN" in
  *:*) : ;;
  *) die "that does not look like a bot token (expected digits:letters)." ;;
esac
BOT_NAME=""
BOT_NAME="$(curl -fsS --max-time 20 "https://api.telegram.org/bot${BOT_TOKEN}/getMe" 2>/dev/null \
    | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d["result"]["username"] if d.get("ok") else "")' 2>/dev/null || true)"
[ -n "$BOT_NAME" ] || die "Telegram rejected that token. Check it and run the installer again."
ok "token valid: @$BOT_NAME"

if [ -z "$ADMIN_CHAT_IDS" ]; then
  echo "   Your numeric Telegram ID (ask @userinfobot). Separate several with commas."
  ask "   Admin chat ID: " ADMIN_CHAT_IDS
fi
ADMIN_CHAT_IDS="$(printf '%s' "$ADMIN_CHAT_IDS" | tr -d '[:space:]')"
printf '%s' "$ADMIN_CHAT_IDS" | grep -Eq '^-?[0-9]+(,-?[0-9]+)*$' \
  || die "admin chat ID must be numeric, e.g. 5478442446 or 5478442446,123456789"
ok "admin id(s): $ADMIN_CHAT_IDS"

# --- 4. primary database ---------------------------------------------------
step "Primary database selection"
PRIMARY_DATABASE="$(printf '%s' "$PRIMARY_DATABASE" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
if [ -z "$PRIMARY_DATABASE" ]; then
  if [ "$INTERACTIVE" = 1 ]; then
    echo "   Choose the live database for the bot:"
    echo "     1) Turso (recommended, fewer free-quota issues)"
    echo "     2) Firebase / Firestore"
    while :; do
      printf '   Primary database [1]: '; IFS= read -r DB_CHOICE || true
      DB_CHOICE="${DB_CHOICE:-1}"
      case "$DB_CHOICE" in
        1|turso|Turso|TURSO) PRIMARY_DATABASE="turso"; break ;;
        2|firebase|Firebase|FIREBASE|firestore|Firestore|FIRESTORE) PRIMARY_DATABASE="firebase"; break ;;
        *) echo "   Please enter 1 for Turso or 2 for Firebase." ;;
      esac
    done
  else
    PRIMARY_DATABASE="turso"
  fi
fi
case "$PRIMARY_DATABASE" in
  turso|firebase|firestore) : ;;
  *) die "PRIMARY_DATABASE must be turso or firebase" ;;
esac
[ "$PRIMARY_DATABASE" = "firestore" ] && PRIMARY_DATABASE="firebase"
ok "primary database: $PRIMARY_DATABASE"

if [ "$PRIMARY_DATABASE" = "turso" ]; then
  step "Turso primary database"
  if [ -z "$TURSO_DATABASE_URL" ]; then
    echo "   Create a Turso database and paste its libsql:// URL."
    ask "   Turso database URL: " TURSO_DATABASE_URL
  fi
  TURSO_DATABASE_URL="$(printf '%s' "$TURSO_DATABASE_URL" | tr -d '[:space:]')"
  case "$TURSO_DATABASE_URL" in
    libsql://*|file://*|http://*|https://*|ws://*|wss://*) : ;;
    *) die "TURSO_DATABASE_URL must start with libsql://, file://, https://, http://, wss:// or ws://" ;;
  esac
  if [ -z "$TURSO_AUTH_TOKEN" ] && [ "${TURSO_DATABASE_URL#libsql://}" != "$TURSO_DATABASE_URL" ]; then
    echo "   Paste the auth token generated for that Turso database."
    ask "   Turso auth token: " TURSO_AUTH_TOKEN
  fi
  TURSO_AUTH_TOKEN="$(printf '%s' "$TURSO_AUTH_TOKEN" | tr -d '[:space:]')"
  ok "Turso primary database configured"
else
  step "Firebase primary database"
  echo "   Firebase/Firestore will be used as the live database."
  echo "   Turso settings are not required."
fi

step "Firebase setup"
TMP_KEY="$(mktemp /tmp/fbkey.XXXXXX.json)"
chmod 600 "$TMP_KEY"
cleanup() { rm -f "$TMP_KEY"; }
trap cleanup EXIT
FB_INFO=""
FB_PROJECT=""
FB_EMAIL=""
if [ -n "$FIREBASE_CREDENTIALS_JSON" ]; then
  printf '%s' "$FIREBASE_CREDENTIALS_JSON" > "$TMP_KEY"
elif [ -n "$FIREBASE_CREDENTIALS_FILE" ] && [ -r "$FIREBASE_CREDENTIALS_FILE" ]; then
  cat "$FIREBASE_CREDENTIALS_FILE" > "$TMP_KEY"
elif [ "$INTERACTIVE" = 1 ] && [ "$UPDATE" != 1 ]; then
  if [ "$PRIMARY_DATABASE" = "firebase" ]; then
    ADD_FIREBASE="y"
    echo "   Paste your Firebase service-account JSON for the primary database."
  else
    echo "   Firebase is optional when Turso is primary. It is only for backup/import from old projects."
    printf '   Add Firebase service-account JSON now? [y/N]: '; IFS= read -r ADD_FIREBASE || true
  fi
  case "$ADD_FIREBASE" in
    y|Y|yes|YES)
      cat <<'HOWTO'
   Paste the Firebase service-account JSON below, then press Enter and type END on its own line.
HOWTO
      : > "$TMP_KEY"
      while IFS= read -r line; do
        [ "$line" = "END" ] && break
        printf '%s
' "$line" >> "$TMP_KEY"
      done
      ;;
  esac
fi
if [ -s "$TMP_KEY" ]; then
  FB_INFO="$(python3 - "$TMP_KEY" <<'PY' || true
import json,sys
try:
    d=json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
if d.get('type')!='service_account': sys.exit(0)
if 'BEGIN PRIVATE KEY' not in d.get('private_key',''): sys.exit(0)
print(d.get('project_id',''), d.get('client_email',''))
PY
)"
  [ -n "$FB_INFO" ] || die "that is not a valid Firebase service-account JSON key."
  FB_PROJECT="$(printf '%s' "$FB_INFO" | awk '{print $1}')"
  FB_EMAIL="$(printf '%s' "$FB_INFO" | awk '{print $2}')"
  [ -n "$FIREBASE_PROJECT_ID" ] || FIREBASE_PROJECT_ID="$FB_PROJECT"
  ok "optional Firebase configured: $FIREBASE_PROJECT_ID ($FB_EMAIL)"
else
  if [ "$PRIMARY_DATABASE" = "firebase" ]; then
    die "Firebase primary requires FIREBASE_CREDENTIALS_JSON or FIREBASE_CREDENTIALS_FILE"
  fi
  ok "skipping Firebase; Turso will be used as the live database"
fi
if [ "$PRIMARY_DATABASE" = "firebase" ] && [ -z "$FIREBASE_PROJECT_ID" ]; then
  die "Firebase primary requires FIREBASE_PROJECT_ID"
fi
# --- 5. domain -------------------------------------------------------------
if [ -z "$DOMAIN" ] && [ "$INTERACTIVE" = 1 ] && [ "$UPDATE" != 1 ]; then
  echo "   Domain pointing at this server, e.g. bot.example.com"
  echo "   Leave empty to serve the dashboard on http://<server-ip> instead."
  printf '   Dashboard domain (optional): '; IFS= read -r DOMAIN || true
  DOMAIN="$(printf '%s' "$DOMAIN" | tr -d '[:space:]')"
fi
if [ -n "$DOMAIN" ] && [ "$NO_TLS" = 0 ] && [ -z "$TLS_EMAIL" ] && [ "$INTERACTIVE" = 1 ]; then
  echo "   Email for the free Let's Encrypt certificate (renewal warnings)."
  echo "   Leave empty to stay on plain HTTP."
  printf '   Email (optional): '; IFS= read -r TLS_EMAIL || true
  TLS_EMAIL="$(printf '%s' "$TLS_EMAIL" | tr -d '[:space:]')"
fi

# --- 6. source code --------------------------------------------------------
step "Fetching the source"
CLONE_URL="$REPO_URL"
if [ -n "$GITHUB_TOKEN" ]; then
  CLONE_URL="$(printf '%s' "$REPO_URL" | sed "s#https://#https://x-access-token:${GITHUB_TOKEN}@#")"
fi
if [ "$DRY_RUN" = 1 ]; then
  printf '   (dry-run) git clone %s %s\n' "$REPO_URL" "$INSTALL_DIR"
elif [ -d "$INSTALL_DIR/.git" ]; then
  git -C "$INSTALL_DIR" remote set-url origin "$CLONE_URL"
  git -C "$INSTALL_DIR" fetch --depth 1 origin "$BRANCH" \
    || die "cannot reach the repository. Private repo? Re-run with GITHUB_TOKEN=<your token>"
  git -C "$INSTALL_DIR" reset --hard "origin/$BRANCH"
  git -C "$INSTALL_DIR" remote set-url origin "$REPO_URL"
  ok "updated existing checkout"
else
  mkdir -p "$INSTALL_DIR"
  git clone --depth 1 --branch "$BRANCH" "$CLONE_URL" "$INSTALL_DIR" \
    || die "cannot clone the repository. Private repo? Re-run with GITHUB_TOKEN=<your token>"
  git -C "$INSTALL_DIR" remote set-url origin "$REPO_URL"
  ok "cloned into $INSTALL_DIR"
fi

# --- 7. build --------------------------------------------------------------
step "Building (this takes a minute on a small VPS)"
if [ "$DRY_RUN" = 1 ]; then
  printf '   (dry-run) go build -o %s/%s\n' "$INSTALL_DIR" "$BINARY_NAME"
else
  MODFLAG=""
  [ -d "$INSTALL_DIR/vendor" ] && MODFLAG="-mod=vendor"
  BUILDTAGS=""
  [ "$PRIMARY_DATABASE" = "firebase" ] && BUILDTAGS="-tags firestorelegacy"
  ( cd "$INSTALL_DIR" && GOCACHE=/root/.cache/go-build go build $MODFLAG $BUILDTAGS -o "$INSTALL_DIR/$BINARY_NAME" . ) \
    || die "build failed (see the output above)."
  ok "built $INSTALL_DIR/$BINARY_NAME"
fi

# --- 8. credentials + .env -------------------------------------------------
step "Writing configuration"
ENV_FILE="$INSTALL_DIR/.env"
KEY_FILE="$INSTALL_DIR/serviceAccountKey.json"
NEW_PASSWORD=""
EXISTING_PASSWORD=""
if [ -f "$ENV_FILE" ]; then
  EXISTING_PASSWORD="$(grep -m1 '^DASHBOARD_PASSWORD=' "$ENV_FILE" 2>/dev/null | cut -d= -f2- || true)"
fi
if [ -n "$EXISTING_PASSWORD" ] && [ "$ROTATE_PASSWORD" != 1 ]; then
  DASHBOARD_PASSWORD="$EXISTING_PASSWORD"
  ok "kept the existing dashboard password"
else
  DASHBOARD_PASSWORD="$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | cut -c1-24)"
  NEW_PASSWORD="$DASHBOARD_PASSWORD"
  ok "generated a new dashboard password"
fi

if [ "$DRY_RUN" = 1 ]; then
  printf '   (dry-run) write %s and %s (mode 600)\n' "$ENV_FILE" "$KEY_FILE"
else
  if [ -s "$TMP_KEY" ]; then
    install -m 600 "$TMP_KEY" "$KEY_FILE"
  else
    rm -f "$KEY_FILE"
    : > "$KEY_FILE"
    chmod 600 "$KEY_FILE"
  fi
  umask 077
  declare -A ENVMAP=()
  if [ -f "$ENV_FILE" ]; then
    cp -a "$ENV_FILE" "$ENV_FILE.bak"
    while IFS= read -r envline || [ -n "$envline" ]; do
      case "$envline" in ''|'#'*) continue ;; esac
      case "$envline" in *=*) : ;; *) continue ;; esac
      ENVMAP["${envline%%=*}"]="${envline#*=}"
    done < "$ENV_FILE"
    ok "kept ${#ENVMAP[@]} existing setting(s); previous file saved as .env.bak"
  fi
  ENVMAP[BOT_TOKEN]="$BOT_TOKEN"
  ENVMAP[ADMIN_CHAT_IDS]="$ADMIN_CHAT_IDS"
  ENVMAP[PRIMARY_DATABASE]="$PRIMARY_DATABASE"
  if [ "$PRIMARY_DATABASE" = "turso" ]; then
    ENVMAP[TURSO_DATABASE_URL]="$TURSO_DATABASE_URL"
    ENVMAP[TURSO_AUTH_TOKEN]="$TURSO_AUTH_TOKEN"
  fi
  if [ -n "$FIREBASE_PROJECT_ID" ]; then ENVMAP[FIREBASE_PROJECT_ID]="$FIREBASE_PROJECT_ID"; fi
  if [ -s "$KEY_FILE" ]; then ENVMAP[FIREBASE_CREDENTIALS_FILE]="$KEY_FILE"; fi
  ENVMAP[DASHBOARD_PASSWORD]="$DASHBOARD_PASSWORD"
  if [ -n "${GITHUB_TOKEN:-}" ]; then
    # kept so the bot's /update command can fetch a private repository later
    ENVMAP[GITHUB_TOKEN]="$GITHUB_TOKEN"
  fi
  [ -n "${ENVMAP[DASHBOARD_USERNAME]:-}" ] || ENVMAP[DASHBOARD_USERNAME]="$DASHBOARD_USERNAME"
  [ -n "${ENVMAP[DASHBOARD_ADDR]:-}" ] || ENVMAP[DASHBOARD_ADDR]="127.0.0.1:$DASHBOARD_PORT"
  for pair in \
    "MAINTENANCE_MODE=false" \
    "MAINTENANCE_MESSAGE=We are doing a quick update. Please try again soon." \
    "TEMPORARY_AUTO_APPROVE=false" \
    "EXPIRY_NOTIFICATIONS_ENABLED=true" \
    "REQUIRED_CHANNELS_ENABLED=false" "PREMIUM_CHANNELS_ENABLED=false" \
    "REQUIRED_CHANNELS=" "PREMIUM_CHANNELS=" \
    "FREE_FILES_ENABLED=false" "FREE_FILES_URL=" \
    "PROMO_ENABLED=false" "OWNER_CONTACT=" "BACKUP_SERVER_ID=" \
    "PANEL_BACKUP_CAPTION=" "BOT_BACKUP_CAPTION=" "START_ANIMATION="; do
    envkey="${pair%%=*}"
    [ -n "${ENVMAP[$envkey]+set}" ] || ENVMAP["$envkey"]="${pair#*=}"
  done
  {
    printf '# Written by install.sh on %s\n' "$(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    for envkey in $(printf '%s\n' "${!ENVMAP[@]}" | sort); do
      printf '%s=%s\n' "$envkey" "${ENVMAP[$envkey]}"
    done
  } > "$ENV_FILE"
  chmod 600 "$ENV_FILE"
  ok "$ENV_FILE written (owner-only, existing values preserved)"
fi

# --- 9. clear any stale Telegram webhook ----------------------------------
if [ "$DRY_RUN" = 0 ]; then
  curl -fsS --max-time 20 "https://api.telegram.org/bot${BOT_TOKEN}/deleteWebhook?drop_pending_updates=true" >/dev/null 2>&1 \
    && ok "cleared any old webhook on this token" || warn "could not clear the webhook (continuing)"
fi

# --- 10. systemd -----------------------------------------------------------
step "Installing the service"
UNIT="/etc/systemd/system/${SERVICE_NAME}.service"
if [ "$DRY_RUN" = 1 ]; then
  printf '   (dry-run) write %s and start it\n' "$UNIT"
else
  cat > "$UNIT" <<UNITEOF
[Unit]
Description=V2ray Telegram Bot and admin dashboard
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=$INSTALL_DIR
EnvironmentFile=$INSTALL_DIR/.env
ExecStart=$INSTALL_DIR/$BINARY_NAME
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
UNITEOF
  systemctl daemon-reload
  systemctl enable --now "$SERVICE_NAME" >/dev/null 2>&1 || true
  systemctl restart "$SERVICE_NAME"
  ok "service $SERVICE_NAME enabled and started"
fi

# --- 11. nginx -------------------------------------------------------------
if [ "$UPDATE" = 1 ]; then
  ok "update mode: nginx and HTTPS left exactly as they are"
else
step "Configuring nginx"
SITE_NAME="${DOMAIN:-v2raybot}"
if [ "$DRY_RUN" = 1 ]; then
  printf '   (dry-run) write /etc/nginx/sites-available/%s\n' "$SITE_NAME"
else
  cat > "/etc/nginx/sites-available/$SITE_NAME" <<NGINXEOF
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN:-_};

    # dashboard uploads: service-account JSON and broadcast photos
    client_max_body_size 20m;

    location / {
        proxy_pass http://127.0.0.1:$DASHBOARD_PORT;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 300s;
    }
}
NGINXEOF
  ln -sf "/etc/nginx/sites-available/$SITE_NAME" "/etc/nginx/sites-enabled/$SITE_NAME"
  rm -f /etc/nginx/sites-enabled/default
  nginx -t >/dev/null 2>&1 || die "nginx config test failed; run 'nginx -t' to see why."
  systemctl reload nginx
  ok "nginx proxying port 80 to the dashboard"
fi

# --- 12. HTTPS -------------------------------------------------------------
if [ -n "$DOMAIN" ] && [ -n "$TLS_EMAIL" ] && [ "$NO_TLS" = 0 ]; then
  step "Requesting a Let's Encrypt certificate for $DOMAIN"
  if [ "$DRY_RUN" = 1 ]; then
    printf '   (dry-run) certbot --nginx -d %s\n' "$DOMAIN"
  else
    apt-get install -y -qq certbot python3-certbot-nginx >/dev/null
    if certbot --nginx -d "$DOMAIN" --agree-tos -m "$TLS_EMAIL" --no-eff-email --redirect --non-interactive; then
      ok "HTTPS enabled and auto-renewal scheduled"
    else
      warn "certificate request failed - the dashboard still works over http://"
      warn "check that $DOMAIN points at this server, then run: certbot --nginx -d $DOMAIN"
    fi
  fi
else
  warn "skipping HTTPS (no domain or no email given)"
fi

fi

# --- 13. health check ------------------------------------------------------
if [ "$DRY_RUN" = 0 ]; then
  step "Checking that it came up"
  sleep 6
  systemctl is-active --quiet "$SERVICE_NAME" \
    || die "service failed to start. See: journalctl -u $SERVICE_NAME -n 40 --no-pager"
  CODE="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$DASHBOARD_PORT/login" || true)"
  [ "$CODE" = 200 ] && ok "dashboard responding on port $DASHBOARD_PORT" \
    || warn "dashboard returned HTTP $CODE - check: journalctl -u $SERVICE_NAME -n 40"
fi

# --- 14. done --------------------------------------------------------------
if [ -n "$DOMAIN" ]; then
  if [ -n "$TLS_EMAIL" ] && [ "$NO_TLS" = 0 ]; then URL="https://$DOMAIN"; else URL="http://$DOMAIN"; fi
else
  URL="http://$(curl -fsS --max-time 10 https://api.ipify.org 2>/dev/null || echo 'your-server-ip')"
fi

printf '\n%s============================================================%s\n' "$BOLD" "$OFF"
TITLE="V2ray-Bot is installed"
[ "$UPDATE" = 1 ] && TITLE="V2ray-Bot is updated"
printf '%s  %s%s\n' "$GRN$BOLD" "$TITLE" "$OFF"
printf '%s============================================================%s\n\n' "$BOLD" "$OFF"
printf '  Bot          @%s\n' "$BOT_NAME"
printf '  Dashboard    %s\n' "$URL"
printf '  Username     %s\n' "$DASHBOARD_USERNAME"
if [ -n "$NEW_PASSWORD" ]; then
  printf '  Password     %s%s%s\n\n' "$BOLD$YEL" "$NEW_PASSWORD" "$OFF"
  printf '  %sWrite this password down now - it is shown this one time only.%s\n' "$BOLD" "$OFF"
  printf '  Change it any time from Settings -> Dashboard Login.\n'
else
  printf '  Password     (unchanged from the previous install)\n\n'
  printf '  Re-run with --rotate-password to generate a new one.\n'
fi
if [ "$PRIMARY_DATABASE" = "turso" ]; then
  printf '\n  Database     Turso (%s)\n' "$TURSO_DATABASE_URL"
  if [ -n "$FIREBASE_PROJECT_ID" ]; then printf '  Firebase     %s (optional backup/import)\n' "$FIREBASE_PROJECT_ID"; fi
else
  printf '\n  Database     Firebase (%s)\n' "$FIREBASE_PROJECT_ID"
fi
printf '  Admin ID     %s\n' "$ADMIN_CHAT_IDS"
COMMIT="$(git -C "$INSTALL_DIR" log -1 --pretty=format:'%h %s' 2>/dev/null || true)"
[ -n "$COMMIT" ] || COMMIT="unknown"
printf '  Version      %s\n' "$COMMIT"
printf '  Update       bash install.sh --update\n'
printf '  Logs         journalctl -u %s -f\n' "$SERVICE_NAME"
printf '  Restart      systemctl restart %s\n' "$SERVICE_NAME"
printf '\n  Next: open the dashboard, then add your ISPs, packages, data plans,\n'
printf '  durations, locations, payment methods and at least one panel server.\n'
printf '  In Telegram, send /start to @%s.\n\n' "$BOT_NAME"
if [ "$DRY_RUN" = 1 ]; then
  printf '%s  dry-run only: nothing above was actually installed.%s\n\n' "$YEL" "$OFF"
fi
