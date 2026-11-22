#!/usr/bin/env bash
# AirPlay 2-mottagare på Raspberry Pi Zero 2 W + PCM5102A (I2S-DAC)
# Kör på nyinstallerat Raspberry Pi OS Lite (64-bit):
#   sudo bash setup-airplay.sh "Aiwa Kök"
set -euo pipefail

NAME="${1:-}"
if [[ -z "$NAME" ]]; then
  echo "Användning: sudo bash $0 \"Högtalarens namn\"" >&2
  exit 1
fi
if [[ $EUID -ne 0 ]]; then
  echo "Kör med sudo." >&2
  exit 1
fi

# Värdnamn/hotspot-namn: "Aiwa Kök" -> "aiwa-kok"
SLUG="$(printf '%s' "$NAME" | LC_ALL=C.UTF-8 sed 's/[åä]/a/g; s/ö/o/g; s/[ÅÄ]/A/g; s/Ö/O/g' \
  | tr 'A-Z' 'a-z' | tr -cs 'a-z0-9' '-' | sed 's/^-*//; s/-*$//')"
if [[ -z "$SLUG" ]]; then
  SLUG="aiwa"
fi

echo "== 1/6 Paket =="
apt-get update
apt-get install -y --no-install-recommends ca-certificates curl unattended-upgrades
apt-get install -y --no-install-recommends build-essential git autoconf automake libtool \
  libpopt-dev libconfig-dev libasound2-dev avahi-daemon libavahi-client-dev libssl-dev libsoxr-dev \
  libplist-dev libsodium-dev uuid-dev libgcrypt-dev xxd libplist-utils \
  libavutil-dev libavcodec-dev libavformat-dev libswresample-dev libglib2.0-dev
# Finns bara i nyare Raspberry Pi OS; hoppa över om paketet saknas.
apt-get install -y --no-install-recommends systemd-dev || true

echo "== 2/6 NQPTP + Shairport Sync (senaste stabila version) =="
cat > /usr/local/sbin/aiwa-update <<'AIWA_UPDATE_EOF'
#!/usr/bin/env bash
# Uppdaterar NQPTP och Shairport Sync till senaste stabila version, och sig själv.
# Körs av aiwa-update.timer. Flaggor: --build (första bygget), --force, --no-self-update
set -uo pipefail

STATE=/var/lib/aiwa
SRC=/usr/local/src
CONF=/etc/aiwa-update.conf
SELF=/usr/local/sbin/aiwa-update
SCRIPT_URL=""
# shellcheck disable=SC1090
[[ -f "$CONF" ]] && . "$CONF"
mkdir -p "$STATE" "$SRC"

MODE=update
SELF_UPDATE=1
for a in "$@"; do
  case "$a" in
    --build) MODE=build ;;
    --force) MODE=force ;;
    --no-self-update) SELF_UPDATE=0 ;;
  esac
done

log() {
  echo "[aiwa-update] $*"
  logger -t aiwa-update -- "$*" || true
}

# Senaste stabila taggen (t.ex. 5.6.3). Ignorerar -dev/-rc och gamla v/V-taggar.
latest_tag() {
  git ls-remote --tags --refs "$1" 2>/dev/null | sed 's|.*refs/tags/||' \
    | grep -E '^[0-9]+(\.[0-9]+)+$' | sort -V | tail -1
}

systemd_flag() {
  if ./configure --help | grep -q -- '--with-systemd-startup'; then
    echo "--with-systemd-startup"
  else
    echo "--with-systemd"
  fi
}

build() {
  local name=$1 url=$2 tag=$3
  shift 3
  local dir="$SRC/$name"
  rm -rf "$dir"
  git clone --quiet "$url" "$dir" || return 1
  cd "$dir" || return 1
  git checkout --quiet "$tag" || return 1
  autoreconf -fi >/dev/null || return 1
  ./configure "$@" "$(systemd_flag)" >/dev/null || return 1
  nice -n 19 make -j2 >/dev/null || return 1
  make install >/dev/null || return 1
}

update_component() {
  local name=$1 url=$2 bin=$3 service=$4
  shift 4
  local tag current failed
  tag=$(latest_tag "$url")
  if [[ -z "$tag" ]]; then
    log "$name: kunde inte hämta versioner"
    [[ "$MODE" == build ]] && return 1
    return 0
  fi
  current=$(cat "$STATE/$name.version" 2>/dev/null || true)
  failed=$(cat "$STATE/$name.failed" 2>/dev/null || true)
  if [[ "$MODE" == update && "$tag" == "$current" ]]; then
    log "$name: $tag är redan senaste"
    return 0
  fi
  if [[ "$MODE" == update && "$tag" == "$failed" ]]; then
    log "$name: $tag misslyckades tidigare, väntar på nyare version"
    return 0
  fi
  log "$name: ${current:-ny} -> $tag"
  [[ -x "$bin" ]] && cp -a "$bin" "$STATE/$name.bak"
  if ! build "$name" "$url" "$tag" "$@"; then
    log "$name: bygget av $tag misslyckades"
    [[ -f "$STATE/$name.bak" ]] && cp -a "$STATE/$name.bak" "$bin"
    echo "$tag" > "$STATE/$name.failed"
    return 1
  fi
  if [[ "$MODE" == build ]]; then
    echo "$tag" > "$STATE/$name.version"
    return 0
  fi
  systemctl daemon-reload
  systemctl restart "$service"
  sleep 15
  if systemctl is-active --quiet "$service"; then
    echo "$tag" > "$STATE/$name.version"
    rm -f "$STATE/$name.failed"
    log "$name: uppdaterad till $tag"
    return 0
  fi
  log "$name: $tag startar inte, återställer föregående version"
  [[ -f "$STATE/$name.bak" ]] && cp -a "$STATE/$name.bak" "$bin"
  systemctl restart "$service"
  echo "$tag" > "$STATE/$name.failed"
  return 1
}

self_update() {
  [[ -n "$SCRIPT_URL" ]] || return 0
  case "$SCRIPT_URL" in
    https://*) ;;
    *) log "SCRIPT_URL måste börja med https://"; return 0 ;;
  esac
  local tmp
  tmp=$(mktemp)
  if curl -fsSL --max-time 60 -o "$tmp" "$SCRIPT_URL" && bash -n "$tmp" \
     && head -1 "$tmp" | grep -q '^#!/usr/bin/env bash'; then
    if ! cmp -s "$tmp" "$SELF"; then
      install -m 755 "$tmp" "$SELF"
      rm -f "$tmp"
      log "uppdaterade sig själv från $SCRIPT_URL, kör om"
      exec "$SELF" --no-self-update
    fi
  else
    log "kunde inte hämta ett giltigt skript från $SCRIPT_URL"
  fi
  rm -f "$tmp"
}

if [[ "$SELF_UPDATE" == 1 && "$MODE" == update ]]; then
  self_update
fi

rc=0
update_component nqptp https://github.com/mikebrady/nqptp.git \
  /usr/local/bin/nqptp nqptp.service || rc=1
update_component shairport-sync https://github.com/mikebrady/shairport-sync.git \
  /usr/local/bin/shairport-sync shairport-sync.service \
  --sysconfdir=/etc --with-alsa --with-soxr --with-avahi \
  --with-ssl=openssl --with-airplay-2 || rc=1
exit $rc
AIWA_UPDATE_EOF
chmod 755 /usr/local/sbin/aiwa-update
if [[ ! -f /etc/aiwa-update.conf ]]; then
  cat > /etc/aiwa-update.conf <<'EOF'
# Valfritt: https-adress till senaste versionen av aiwa-update.
# Skriptet hämtar, syntaxkontrollerar och ersätter sig själv varje natt.
SCRIPT_URL="https://raw.githubusercontent.com/MatsPower/aiwa-speaker/main/aiwa-update"
EOF
fi
/usr/local/sbin/aiwa-update --build
systemctl enable nqptp

echo "== 3/6 I2S-DAC (PCM5102A) =="
CONFIG=/boot/firmware/config.txt
[[ -f "$CONFIG" ]] || CONFIG=/boot/config.txt
sed -i 's/^dtparam=audio=on/#dtparam=audio=on/' "$CONFIG"
grep -q '^dtoverlay=hifiberry-dac' "$CONFIG" || echo 'dtoverlay=hifiberry-dac' >> "$CONFIG"

echo "== 4/6 Konfiguration =="
hostnamectl set-hostname "$SLUG"
sed -i "s/^127\.0\.1\.1.*/127.0.1.1\t$SLUG/" /etc/hosts
[[ -f /etc/shairport-sync.conf && ! -f /etc/shairport-sync.conf.orig ]] && \
  cp /etc/shairport-sync.conf /etc/shairport-sync.conf.orig
cat > /etc/shairport-sync.conf <<EOF
general =
{
	name = "$NAME";
	playback_mode = "mono";
};

alsa =
{
	output_device = "hw:CARD=sndrpihifiberry";
};
EOF

# Wifi-strömspar ger hack i ljudet; stäng av.
mkdir -p /etc/NetworkManager/conf.d
cat > /etc/NetworkManager/conf.d/wifi-powersave-off.conf <<EOF
[connection]
wifi.powersave = 2
EOF
systemctl enable shairport-sync

echo "== 5/6 Automatiska uppdateringar och skydd av SD-kortet =="
# Säkerhetsuppdateringar (standardkällor, i första hand Debian-säkerhet).
cat > /etc/apt/apt.conf.d/20auto-upgrades <<EOF
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
cat > /etc/apt/apt.conf.d/52aiwa-unattended <<EOF
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "04:30";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Dpkg::Options { "--force-confold"; };
EOF
# Nattlig kontroll av ny version av Shairport Sync, NQPTP och uppdateringsskriptet.
cat > /etc/systemd/system/aiwa-update.service <<EOF
[Unit]
Description=Uppdatera AirPlay-mjukvara
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
Nice=19
IOSchedulingClass=idle
ExecStart=/usr/local/sbin/aiwa-update
EOF
cat > /etc/systemd/system/aiwa-update.timer <<EOF
[Unit]
Description=Daglig kontroll av AirPlay-mjukvara

[Timer]
OnCalendar=*-*-* 03:00:00
RandomizedDelaySec=30min
Persistent=true

[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload
systemctl enable aiwa-update.timer
# Inget skrivskyddat filsystem: sparade Wi-Fi-nätverk måste överleva omstart.
# Journalen i RAM sparar SD-kortet.
mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/volatile.conf <<EOF
[Journal]
Storage=volatile
RuntimeMaxUse=16M
EOF

echo "== 6/6 Comitup (byta Wi-Fi utan dator) =="
COMITUP_DEB=davesteele-comitup-apt-source_1.3_all.deb
curl -fsSL -o "/tmp/$COMITUP_DEB" "https://davesteele.github.io/comitup/deb/$COMITUP_DEB"
dpkg -i "/tmp/$COMITUP_DEB"
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y comitup
cat > /etc/comitup.conf <<EOF
ap_name: $SLUG
EOF
systemctl enable comitup

echo
echo "Klart. Startar om om 5 sekunder. Därefter syns \"$NAME\" som AirPlay-högtalare."
echo "Hittar högtalaren inget känt nätverk startar hotspoten \"$SLUG\" – anslut med telefonen och välj Wi-Fi."
sleep 5
reboot
