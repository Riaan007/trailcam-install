#!/usr/bin/env bash
# TrailCam Alert installer.
#
#   curl -fsSL https://raw.githubusercontent.com/Riaan007/trailcam-install/main/install.sh | sudo bash
#
# Installs to /opt/trailcam with photos under /srv/trailcam, then prints a URL
# and a setup code. Everything else is done in the browser.
#
# Re-running is safe: an existing .env is reused, so secrets never change
# underneath a working install.
set -euo pipefail

REPO_RAW="${TRAILCAM_REPO_RAW:-https://raw.githubusercontent.com/Riaan007/trailcam-install/main}"
INSTALL_DIR="${TRAILCAM_DIR:-/opt/trailcam}"
DATA_DIR="${TRAILCAM_DATA:-/srv/trailcam}"
CONFIG_DIR="/etc/trailcam"
LOG_DIR="/var/log/trailcam"
REGISTRY="ghcr.io"
IMAGE_PREFIX="${TRAILCAM_IMAGE_PREFIX:-ghcr.io/riaan007}"
TAG="${TRAILCAM_TAG:-latest}"

RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; DIM=$'\033[2m'; OFF=$'\033[0m'
say()  { printf '%s\n' "$*"; }
ok()   { printf '  %s✓%s %s\n' "$GREEN" "$OFF" "$*"; }
warn() { printf '  %s!%s %s\n' "$YELLOW" "$OFF" "$*"; }
die()  { printf '  %s✗%s %s\n' "$RED" "$OFF" "$*" >&2; exit 1; }

# A tty is detected by OPENING /dev/tty, not by testing -t: this script is
# normally read from a pipe, and ssh without a pty is a real case.
HAS_TTY=0
if exec 3<>/dev/tty 2>/dev/null; then HAS_TTY=1; fi
ask() {  # ask <prompt> <default>
    local prompt="$1" default="${2:-}" reply=""
    if [ "$HAS_TTY" -eq 1 ]; then
        printf '%s%s' "$prompt" "${default:+ [$default]}" >&3
        printf ': ' >&3
        IFS= read -r reply <&3 || reply=""
    fi
    printf '%s' "${reply:-$default}"
}
ask_secret() {  # ask_secret <prompt> — nothing echoed, no default
    local reply=""
    if [ "$HAS_TTY" -eq 1 ]; then
        printf '%s: ' "$1" >&3
        IFS= read -rs reply <&3 || reply=""
        printf '\n' >&3
    fi
    printf '%s' "$reply"
}

[ "$(id -u)" -eq 0 ] || die "Run with sudo."

say ""
say "TrailCam Alert"
say "${DIM}Photos in by FTP, one alert per event, a web interface to review them.${OFF}"
say ""

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
say "Checking this machine"

ARCH="$(uname -m)"
case "$ARCH" in
    aarch64|arm64|x86_64|amd64) ok "Architecture $ARCH" ;;
    *) die "$ARCH is not supported. Images are built for arm64 and amd64." ;;
esac

if ! command -v docker >/dev/null 2>&1; then
    warn "Docker is not installed — installing it now"
    curl -fsSL https://get.docker.com | sh || die "Could not install Docker."
fi
docker compose version >/dev/null 2>&1 || die "This needs Docker Compose v2 (docker compose)."
ok "Docker $(docker --version | awk '{print $3}' | tr -d ,)"

# A TCP check is not enough: what fails on a farm link is the TLS handshake,
# and that is what took a whole site install down once already.
if ! curl -fsS --max-time 20 "https://$REGISTRY/v2/" >/dev/null 2>&1; then
    warn "Cannot complete a TLS handshake with $REGISTRY — the image pull may fail"
else
    ok "Registry reachable"
fi

# Only on a genuinely fresh install. On a working one the things holding 8098
# and 21 are trailcam_web and trailcam_ftp, so this check used to abort every
# re-run and then advise the operator to stop their own alerting system —
# while the header above promises that re-running is safe.
if [ -f "$INSTALL_DIR/.env" ] || docker ps -q -f name=trailcam_ 2>/dev/null | grep -q .; then
    ok "TrailCam is already installed here — leaving its ports alone"
else
    for port in "${WEB_PORT:-8098}" 21; do
        if ss -tlnH "sport = :$port" 2>/dev/null | grep -q .; then
            die "Port $port is already in use. Free it, or set WEB_PORT before running this."
        fi
    done
    ok "Ports free"
fi

mkdir -p "$DATA_DIR"/{incoming,archive,thumbs} "$CONFIG_DIR" "$LOG_DIR" "$INSTALL_DIR"

FREE_GB="$(df -BG --output=avail "$DATA_DIR" | tail -1 | tr -dc '0-9')"
[ "${FREE_GB:-0}" -ge 5 ] || die "Only ${FREE_GB}GB free on $DATA_DIR. Photos need room."
ok "${FREE_GB}GB free on $DATA_DIR"

# Trail cameras write constantly. An SD card will not survive it for long, and
# the failure mode is a corrupt filesystem rather than a warning.
SOURCE_DEV="$(df --output=source "$DATA_DIR" | tail -1)"
case "$SOURCE_DEV" in
    /dev/mmcblk*)
        # A warning was not enough. The live site measured 4.8 GB of photos in
        # one day; a consumer SD card under that write pattern is months from
        # failing, and it fails as a silently corrupt filesystem rather than as
        # an error anybody sees. Refusing is the only warning that works.
        if [ "${TRAILCAM_ALLOW_SDCARD:-0}" = "1" ]; then
            warn "$DATA_DIR is on an SD card ($SOURCE_DEV) — continuing because"
            warn "TRAILCAM_ALLOW_SDCARD=1. Expect the card to fail; keep backups off it."
        else
            say ""
            die "$DATA_DIR is on an SD card ($SOURCE_DEV). Trail cameras write
     constantly and SD cards do not survive it — the failure is a corrupt
     filesystem, not a warning. Point TRAILCAM_DATA at a USB SSD or an NVMe
     drive:

       TRAILCAM_DATA=/mnt/ssd/trailcam sudo -E bash install.sh

     If you have thought about it and want it anyway, set
     TRAILCAM_ALLOW_SDCARD=1."
        fi
        ;;
    *) ok "Archive is on $SOURCE_DEV" ;;
esac

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
say ""
say "Setting up $INSTALL_DIR"

cd "$INSTALL_DIR"
# The two scripts are not optional extras: every remedy in the documentation
# starts with ./selftest.sh or ./trailcam something, and until this loop
# fetched them all of it answered "No such file or directory" on a client
# machine. They are refreshed on every run — unlike .env and config.ini, they
# hold nothing that is the site's, so the newest copy is always the right one.
if [ ! -f docker-compose.yml ] || [ "${TRAILCAM_FORCE:-0}" = "1" ]; then
    curl -fsSL "$REPO_RAW/docker-compose.yml" -o docker-compose.yml \
        || die "Could not download docker-compose.yml"
fi
for file in selftest.sh trailcam; do
    if curl -fsSL "$REPO_RAW/$file" -o "$file.new"; then
        mv "$file.new" "$file"
        chmod +x "$file"
    else
        rm -f "$file.new"
        # A refresh that cannot reach the internet must not take a working
        # site down with it. The header above promises that re-running is
        # safe, and these installs are on farm 4G links where a curl failing
        # once is a Tuesday — so keep the copy that is already here, and only
        # refuse when there is nothing to keep.
        [ -f "$file" ] || die "Could not download $file, and there is no copy here."
        warn "Could not refresh $file — keeping the copy already in $INSTALL_DIR"
    fi
done
ok "Downloaded the stack definition and the support commands"

rand() { head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c "${1:-24}"; }

if [ -f .env ]; then
    # Re-runs must not roll the passwords of a working install.
    ok "Reusing the existing .env"
    SETUP_TOKEN="$(grep -E '^SETUP_TOKEN=' .env | cut -d= -f2- || true)"
else
    WEB_PORT="${WEB_PORT:-$(ask 'Port for the web interface' 8098)}"
    TZ_GUESS="$(cat /etc/timezone 2>/dev/null || echo UTC)"
    SETUP_TOKEN="$(rand 20)"
    cat > .env <<EOF
# Generated by install.sh on $(date -Is). Keep this file.
DB_ROOT_PASSWORD=$(rand 28)
DB_PASSWORD=$(rand 28)
DB_NAME=trailcam
DB_USER=trailcam
DB_PORT=3308

WEB_PORT=$WEB_PORT

FTP_PORT=21
PASV_MIN_PORT=40000
PASV_MAX_PORT=40100
# Set this to the address the CAMERA uses to reach this machine if it is
# behind NAT. On a LAN, leave it blank.
PASV_ADDRESS=

DATA_DIR=$DATA_DIR
CONFIG_FILE=$CONFIG_DIR/config.ini
LOG_DIR=$LOG_DIR
PUID=$(stat -c %u "$DATA_DIR")
PGID=$(stat -c %g "$DATA_DIR")

TZ=$TZ_GUESS

APP_IMAGE=$IMAGE_PREFIX/trailcam-app:$TAG
WEB_IMAGE=$IMAGE_PREFIX/trailcam-web:$TAG
FTP_IMAGE=$IMAGE_PREFIX/trailcam-ftp:$TAG

SETUP_TOKEN=$SETUP_TOKEN
EOF
    chmod 600 .env
    ok "Generated .env with fresh passwords"
fi

# shellcheck disable=SC1091
set -a; . ./.env; set +a

if [ ! -f "$CONFIG_DIR/config.ini" ]; then
    cat > "$CONFIG_DIR/config.ini" <<EOF
; TrailCam Alert — bootstrap only. Tuning lives on the System page, and every
; credential lives in the database, written by the setup wizard.
[paths]
incoming    = $DATA_DIR/incoming
archive     = $DATA_DIR/archive
thumbs      = $DATA_DIR/thumbs
log         = $LOG_DIR
min_free_gb = 2

[db]
host     = db
port     = 3306
user     = $DB_USER
password = $DB_PASSWORD
name     = $DB_NAME

; A feature is live only when its flag is on AND its credential is set, so
; everything ships on and stays silent until the wizard configures it.
[features]
yolo     = true
telegram = true
ntfy     = true
gemini   = true

[detect]
backend    = onnx
model      = /opt/trailcam/models/yolo11n-dyn.onnx
image_size = 640
max_frames_per_event = 6

[ingest]
settle_seconds   = 3
clock_skew_hours = 24
thumb_width      = 480

[web]
base_url = http://$(hostname -I 2>/dev/null | awk '{print $1}'):$WEB_PORT

[gemini]
model  = gemini-2.5-flash
prompt = Describe exactly what is visible in this trail camera photo in one or two plain sentences. Say how many people, vehicles or animals there are, what they are doing, and which way they are moving. Do not speculate about intent. If the frame is too dark or blurred to tell, say so plainly.
EOF
    chmod 600 "$CONFIG_DIR/config.ini"
    ok "Wrote $CONFIG_DIR/config.ini"
else
    ok "Keeping the existing $CONFIG_DIR/config.ini"
fi

chown -R "${PUID:-1000}:${PGID:-1000}" "$DATA_DIR" "$LOG_DIR"

# ---------------------------------------------------------------------------
# Registry login — the images are private, and stay private
# ---------------------------------------------------------------------------
# The three trailcam images live in a private GitHub registry, and that is a
# decision rather than an oversight, so every pull needs a login: this one,
# and every `./trailcam update` after it. Docker keeps the credential in
# root's own store (/root/.docker/config.json, mode 0600) and that is the only
# place it lives — it is not written to .env, and a re-run finds it there.
#
# Unattended:   GHCR_TOKEN=<token> curl … | sudo -E bash
# By hand:      paste the token when asked — the prompt does not echo it.
# The token is a GitHub access token with the read:packages scope, issued by
# whoever owns the images; the username is that owner's, and defaults to it.
say ""
say "Registry login"
GHCR_USER="${GHCR_USER:-${IMAGE_PREFIX##*/}}"
GHCR_TOKEN="${GHCR_TOKEN:-}"

registry_login() {
    # The token goes in through a pipe of its own: this script's stdin is the
    # script itself when it is curl'd, so --password-stdin cannot read from it.
    printf '%s' "$GHCR_TOKEN" | docker login "$REGISTRY" -u "$GHCR_USER" --password-stdin >/dev/null 2>&1
}
have_registry_login() {
    # A credential from an earlier run. Docker writes the registry's name
    # into config.json whether it stores the secret inline or in a helper.
    local cfg="${DOCKER_CONFIG:-$HOME/.docker}/config.json"
    [ -f "$cfg" ] && grep -q "\"$REGISTRY\"" "$cfg"
}

if [ -n "$GHCR_TOKEN" ]; then
    registry_login && ok "Logged in to $REGISTRY as $GHCR_USER" \
        || die "$REGISTRY refused that token for $GHCR_USER. It needs the read:packages scope; check it and run this again."
elif have_registry_login; then
    ok "Using the $REGISTRY login already on this machine"
elif [ "$HAS_TTY" -eq 1 ]; then
    say "  The images are in a private registry. You need the access token"
    say "  you were given for it — a GitHub token with the read:packages scope."
    GHCR_USER="$(ask "  GitHub username" "$GHCR_USER")"
    GHCR_TOKEN="$(ask_secret "  Access token")"
    [ -n "$GHCR_TOKEN" ] || die "No token given. Get one from the person who runs the images and run this again."
    registry_login && ok "Logged in to $REGISTRY as $GHCR_USER" \
        || die "$REGISTRY refused that token for $GHCR_USER. Check it and run this again."
else
    die "The images are in a private registry and there is no terminal to ask on. Run this from a terminal, or pass GHCR_TOKEN=<token> (and GHCR_USER=<github user>) with sudo -E."
fi

# ---------------------------------------------------------------------------
# Images — pulled one at a time, because `docker compose pull` is
# all-or-nothing and one slow registry has taken a whole install down before.
# ---------------------------------------------------------------------------
say ""
say "Pulling images"

pull_one() {  # pull_one <service> <tries>
    local svc="$1" tries="${2:-3}" n=1 image
    # From .env rather than from `docker compose config --images <service>`,
    # which also lists the images of everything the service depends on and in
    # no promised order — it answers "mariadb:11" for the watcher, so the
    # "already on this machine" branch below was asking about the wrong image
    # and would have declared a missing watcher image present.
    case "$svc" in
        db)      image="mariadb:11" ;;
        watcher) image="${APP_IMAGE:-}" ;;
        web)     image="${WEB_IMAGE:-}" ;;
        ftp)     image="${FTP_IMAGE:-}" ;;
        *)       image="" ;;
    esac

    while [ "$n" -le "$tries" ]; do
        if docker compose pull "$svc" >/dev/null 2>&1; then
            ok "$svc"
            return 0
        fi
        # Already on the machine is as good as pulled: covers a re-run, a site
        # with no working registry route, and an image loaded by hand from a
        # USB stick.
        if [ -n "$image" ] && docker image inspect "$image" >/dev/null 2>&1; then
            ok "$svc (already on this machine)"
            return 0
        fi
        warn "$svc pull failed (attempt $n of $tries)"
        sleep $((n * 10))
        n=$((n + 1))
    done
    return 1
}

pull_one db 3       || die "Could not pull MariaDB. Check the network and run this again."
pull_one watcher 4  || die "Could not pull the watcher image. The registry login worked, so check the token is allowed read:packages for these images."
pull_one web 3      || die "Could not pull the web image. The registry login worked, so check the token is allowed read:packages for these images."
pull_one ftp 3      || warn "Could not pull the FTP image — cameras cannot upload until it is there."

say ""
say "Starting"
docker compose up -d || die "The stack did not start. See: docker compose logs"

printf '  waiting for the database'
for _ in $(seq 1 60); do
    if docker compose exec -T db healthcheck.sh --connect >/dev/null 2>&1; then break; fi
    printf '.'
    sleep 2
done
printf '\n'

# The wizard is gated by this, so nobody on the LAN can claim a fresh install.
#
# It has to wait for more than the database answering: the `secrets` table is
# created by the watcher applying schema.sql, which is a good few seconds after
# mariadbd starts accepting connections. Inserting too early failed with
# "table doesn't exist", the failure was swallowed, and setup.php then let any
# client on a private address — every LAN device and every VPN peer — name the
# site, create the admin account and read the camera positions. So keep trying
# until it lands, and only print a code that is really in the database.
#
# The password goes in through the environment rather than -p: an argv is
# readable from anything that can see the process table, on the host as well as
# in the container, and everything else in this system is careful with secrets.
store_token() {
    docker compose exec -T -e MYSQL_PWD="$DB_PASSWORD" db \
        mariadb -u"$DB_USER" "$DB_NAME" \
        -e "INSERT INTO secrets (name, value) VALUES ('setup_token', '$SETUP_TOKEN')
            ON DUPLICATE KEY UPDATE value = VALUES(value);" 2>/dev/null
}

printf '  waiting for the schema'
TOKEN_STORED=0
for _ in $(seq 1 60); do
    if store_token; then TOKEN_STORED=1; break; fi
    printf '.'
    sleep 2
done
printf '\n'
[ "$TOKEN_STORED" -eq 1 ] || warn "Could not store the setup code. The wizard will NOT fall back to trusting the LAN — re-run this installer to generate one."

# Nothing used to schedule a backup, so no client site had one — and the two
# files holding the database password are not in the database. Daily, at an
# hour nothing else is doing anything, keeping a fortnight of generations.
if [ -d /etc/cron.d ] && [ ! -f /etc/cron.d/trailcam-backup ]; then
    cat > /etc/cron.d/trailcam-backup <<EOF
# TrailCam Alert — nightly database and configuration backup.
# Keeps the newest 14 generations in \$DATA_DIR/backups. Photos are not in it:
# they are plain files, and they are far too big for a dump.
17 3 * * * root cd $INSTALL_DIR && ./trailcam backup >/dev/null 2>&1
EOF
    chmod 644 /etc/cron.d/trailcam-backup
    ok "Nightly backup scheduled (03:17)"
fi

IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
say ""
say "${GREEN}Installed.${OFF}"
say ""
say "  Open        ${GREEN}http://${IP}:${WEB_PORT}${OFF}"
if [ "$TOKEN_STORED" -eq 1 ]; then
    say "  Setup code  ${GREEN}${SETUP_TOKEN}${OFF}"
else
    say "  ${YELLOW}No setup code — finish the wizard now, before anyone else on"
    say "  the network does.${OFF}"
fi
say ""
say "${DIM}The wizard makes your account, adds the first camera and prints the FTP"
say "details to type into it, then asks where alerts should go."
say ""
say "Afterwards:  cd $INSTALL_DIR && ./selftest.sh"
say "Update:      cd $INSTALL_DIR && ./trailcam update${OFF}"
say ""
