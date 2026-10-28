#!/usr/bin/env bash
# FITCOM Linux Hardening Practice Lab | 2.0.0 | 2026-10-28
# Independent practice material for rexaa. NOT an official FITCOM challenge.
# Intentionally weak configuration. Run ONLY in a disposable Ubuntu VM.
# Usage: sudo bash install.sh [install|upgrade|brief|watch|check|hint ID|solutions|status|uninstall]
# FITCOM update: live counts of successful Linux fixes, not LKS task requirements.
# Practice assumptions: 12 scenarios, one point each, polling after a 10-second gap.
# Actual FITCOM tasks/weights/protocol/regression penalties are NOT known.
# Ubuntu targets: 26.04 LTS; 24.04 LTS accepted for fallback practice.
# All lab network services listen on 127.0.0.1. No firewall rules are changed.
# Dependencies are installed from the VM's configured APT repositories.
# Reference docs:
# https://ubuntu.com/server/docs/how-to/security/openssh-server/
# https://nginx.org/en/docs/ngx_core_module.html
# https://nginx.org/en/docs/http/ngx_http_autoindex_module.html
# https://www.freedesktop.org/software/systemd/man/latest/systemd.timer.html
# Snapshot rollback is the full reset. Uninstall removes lab-owned objects only.

set -Eeuo pipefail
export LC_ALL=C
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
umask 022

LAB_VERSION=2.0.0
BASE=/opt/fitcom-lab
CONF=/etc/fitcom-lab
STATE=/var/lib/fitcom-lab
WEB=/srv/fitcom-lab
LOG=/var/log/fitcom-lab
MANAGER=/usr/local/sbin/fitcom-lab
PUBLIC=/run/fitcom-score
OWNER_MARKER=fitcom-practice-lab-v1
STAGE=initialization
TARGET_UNITS=(fitcom-web.service fitcom-ssh.service fitcom-backup.service fitcom-backup.timer fitcom-diagnostics.service)
JUDGE_UNITS=(fitcom-score.service fitcom-board.service)
UNITS=("${TARGET_UNITS[@]}" "${JUDGE_UNITS[@]}")
LAB_USERS=(fitops fithelpdesk fitlegacy fitweb)

say() { printf '\n[fitcom] %s\n' "$*"; }
die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }
root_required() { [[ $EUID -eq 0 ]] || die 'Jalankan dengan sudo.'; }
owned_state() { [[ -f "$STATE/.owner" ]] && [[ $(cat "$STATE/.owner") == "$OWNER_MARKER" ]]; }
installed_required() { owned_state && [[ -f "$STATE/installed" ]] || die 'Lab belum selesai terpasang. Gunakan install; jika instalasi terputus, gunakan uninstall dahulu.'; }

usage() {
  cat <<'USAGE'
FITCOM Linux Hardening Practice Lab (mandiri; bukan soal resmi)

  sudo bash install.sh                 Instal lab; otomatis upgrade jika v1 sudah ada
  sudo bash install.sh upgrade         Update penilai tanpa menanam ulang celah
  sudo bash install.sh brief           Brief, aturan, dan identitas akun
  sudo bash install.sh watch           Papan skor otomatis langsung di terminal
  sudo bash install.sh check           Pemeriksaan tambahan secara manual
  sudo bash install.sh check --json    Laporan terstruktur ke stdout
  sudo bash install.sh hint 04         Petunjuk untuk satu nomor (01..12)
  sudo bash install.sh solutions       Pembahasan dan contoh perbaikan
  sudo bash install.sh status          Status service + port lab
  sudo bash install.sh uninstall       Hapus objek milik lab

Sesudah install, "sudo fitcom-lab ..." dapat menggantikan "sudo bash install.sh ...".
Ubuntu 26.04 disarankan; Ubuntu 24.04 juga diterima untuk latihan.
Butuh VM dengan systemd, sudo, serta internet jika dependensi belum ada.
Gunakan snapshot sebelum install. Jangan gunakan VM berisi data/layanan penting.
NAT tanpa port forwarding atau jaringan internal cocok untuk latihan ini.
Jangan gunakan bridged networking. Semua layanan lab bind ke loopback.
Tidak ada auto-fix: kamu memperbaiki konfigurasi sendiri.
Penilai berjalan otomatis, jeda 10 detik antar putaran. Dashboard lokal: port 8090.
12 perbaikan = 12 poin latihan; bobot, soal, dan interval bukan ketentuan resmi.
Ubuntu Server tidak membutuhkan GUI. Gunakan watch, atau SSH tunnel dari laptop.
USAGE
}

restore_policy() {
  # A marker makes restoration retryable even after an interrupted installation.
  if [[ -f "$STATE/policy-temporary" ]]; then
    rm -f -- /usr/sbin/policy-rc.d
    if [[ -e "$STATE/policy-rc.d.original" || -L "$STATE/policy-rc.d.original" ]]; then
      mv -- "$STATE/policy-rc.d.original" /usr/sbin/policy-rc.d
    fi
    rm -f -- "$STATE/policy-temporary"
  fi
}

on_failure() {
  local code=$? line=${1:-unknown}
  trap - ERR
  printf '\nInstalasi/perintah gagal pada tahap "%s", baris %s (exit %s).\n' "$STAGE" "$line" "$code" >&2
  if owned_state; then
    printf 'Untuk status: sudo bash install.sh status\nUntuk membersihkan instalasi parsial: sudo bash install.sh uninstall\n' >&2
  fi
  exit "$code"
}
trap 'on_failure "$LINENO"' ERR

preflight() {
  root_required
  [[ -r /etc/os-release ]] || die 'OS tidak terdeteksi.'
  # shellcheck disable=SC1091
  source /etc/os-release
  [[ ${ID:-} == ubuntu ]] || die 'Installer ini ditujukan untuk Ubuntu.'
  case ${VERSION_ID:-} in
    26.04) ;;
    24.04) say 'Ubuntu 24.04: materi latihan sama, tetapi cocokkan kembali dengan 26.04 sebelum lomba.' ;;
    *) die "Versi ${VERSION_ID:-unknown} belum ditargetkan. Gunakan Ubuntu 26.04 atau 24.04." ;;
  esac
  command -v systemd-detect-virt >/dev/null || die 'systemd-detect-virt tidak tersedia.'
  systemd-detect-virt --vm --quiet || die 'Tidak terdeteksi sebagai VM penuh. Installer menolak host fisik, container, dan WSL. Gunakan VM Ubuntu.'
  [[ $(ps -p 1 -o comm=) == systemd ]] || die 'PID 1 harus systemd.'
  command -v sudo >/dev/null || die 'sudo harus tersedia sebelum instalasi.'
  command -v flock >/dev/null || die 'util-linux/flock tidak tersedia.'
  local p name
  for p in "$BASE" "$CONF" "$STATE" "$WEB" "$LOG" "$MANAGER" \
      /etc/sudoers.d/fitcom-helpdesk /run/fitcom-nginx "$PUBLIC"; do
    [[ ! -e "$p" && ! -L "$p" ]] || die "Path sudah ada: $p. Tidak ditimpa. Jika ini lab sebelumnya, uninstall atau restore snapshot." 
  done
  for name in "${LAB_USERS[@]}" fitjudge; do
    if getent passwd "$name" >/dev/null || getent group "$name" >/dev/null; then
      die "User/grup $name sudah ada. Gunakan VM bersih."
    fi
    [[ ! -e /home/$name && ! -L /home/$name ]] || die "Home /home/$name sudah ada."
  done
  for name in "${UNITS[@]}"; do
    [[ ! -e /etc/systemd/system/$name && ! -L /etc/systemd/system/$name ]] || die "Unit $name sudah ada."
    if systemctl cat "$name" >/dev/null 2>&1; then die "Unit $name sudah dikenal systemd."; fi
  done
  # Port check without needing Python before dependencies are installed.
  if ss -H -ltn | awk '{print $4}' | grep -Eq ':(2222|8080|8090|9090)$'; then
    die 'Port 2222, 8080, 8090, atau 9090 sedang dipakai. Installer tidak menghentikan pemilik port.'
  fi
  local options
  options=$(findmnt -n -o OPTIONS -T /opt)
  case ",$options," in
    *,nosuid,*|*,noexec,*) die '/opt berada pada mount nosuid/noexec. Gunakan disk VM normal agar latihan SUID/capabilities bermakna.' ;;
  esac
  visudo -c >/dev/null || die 'Konfigurasi sudo awal tidak valid. Perbaiki dahulu.'
}

dependencies() {
  STAGE=dependencies
  local pkg
  local -a missing=()
  for pkg in openssh-server openssh-client nginx python3 libcap2-bin acl curl; do
    if [[ $(dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null || true) != 'install ok installed' ]]; then
      missing+=("$pkg")
    fi
  done
  if ((${#missing[@]})); then
    say "Memasang dependensi dari APT: ${missing[*]}"
    # Suppress package-triggered service starts; preserve an existing policy file.
    if [[ -e /usr/sbin/policy-rc.d || -L /usr/sbin/policy-rc.d ]]; then
      mv -- /usr/sbin/policy-rc.d "$STATE/policy-rc.d.original"
    fi
    : > "$STATE/policy-temporary"
    printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d
    chmod 0755 /usr/sbin/policy-rc.d
    trap restore_policy EXIT
    apt-get -o DPkg::Lock::Timeout=60 update
    DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l \
      apt-get -o DPkg::Lock::Timeout=60 -o Dpkg::Options::=--force-confold \
      install -y --no-install-recommends "${missing[@]}"
    restore_policy
    trap - EXIT
  fi
  for pkg in /usr/sbin/sshd /usr/sbin/nginx /usr/bin/python3 /usr/sbin/setcap /usr/sbin/getcap; do
    [[ -x "$pkg" ]] || die "Dependensi tidak ditemukan: $pkg"
  done
}

install_lab() {
  root_required
  if owned_state && [[ -f "$STATE/installed" ]]; then
    upgrade_lab
    return
  fi
  STAGE=preflight
  preflight
  exec 9>/run/lock/fitcom-lab-install.lock
  flock -n 9 || die 'Installer lain sedang berjalan.'
  say 'Menyiapkan lab rentan. Gunakan snapshot VM untuk mengulang dari kondisi awal.'
  install -d -m 0700 "$STATE"
  printf '%s\n' "$OWNER_MARKER" > "$STATE/.owner"
  # Keep an uninstall entry point even if dependency installation is interrupted.
  install -m 0755 "$(readlink -f "${BASH_SOURCE[0]}")" "$MANAGER"
  dependencies
  STAGE=accounts
  local name
  for name in fitops fithelpdesk fitlegacy; do
    useradd -m -U -d "/home/$name" -s /bin/bash "$name"
    printf '%s:Fitcom-Lab-Only-26!\n' "$name" | chpasswd
    chmod 0750 "/home/$name"
  done
  useradd -r -U -M -d /nonexistent -s /usr/sbin/nologin fitweb
  usermod -aG sudo fitlegacy
  printf 'fithelpdesk ALL=(ALL:ALL) NOPASSWD: ALL\n' > /etc/sudoers.d/fitcom-helpdesk
  chmod 0440 /etc/sudoers.d/fitcom-helpdesk
  visudo -c >/dev/null

  STAGE=files
  install -d -m 0755 "$BASE" "$BASE/bin" "$BASE/jobs" "$CONF" "$WEB" "$WEB/www" "$WEB/www/reports" "$LOG"
  install -d -m 0700 "$STATE/keys" "$STATE/backup"
  cat > "$WEB/www/index.html" <<'HTML'
<!doctype html><html lang="id"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>FITCOM Practice Portal</title>
<style>body{margin:0;background:#101826;color:#e7eefb;font:17px/1.6 system-ui}main{max-width:760px;margin:70px auto;padding:30px}small{color:#75e2bc}h1{font-size:40px;line-height:1.15}a{color:#8bc8ff}code{background:#243146;padding:3px 7px;border-radius:5px}.card{border:1px solid #344157;border-radius:16px;padding:24px;margin-top:25px}</style>
<main><small>REXAA / LINUX HARDENING PRACTICE</small><h1>FITCOM Practice Portal</h1><p>Portal ini harus tetap berfungsi selama latihan hardening.</p><div class="card"><p>Periksa <a href="/health.txt">health check</a> dan <a href="/reports/q3-demo.txt">laporan contoh</a>.</p><p>Brief dan pengecekan: <code>sudo fitcom-lab brief</code> / <code>sudo fitcom-lab check</code></p></div><p>Semua identitas dan data di lab ini fiktif. Bukan soal resmi FITCOM.</p></main></html>
HTML
  printf 'FITCOM_OK\n' > "$WEB/www/health.txt"
  printf 'FITCOM_DEMO_REPORT\nRevenue=1000 (data fiktif)\n' > "$WEB/www/reports/q3-demo.txt"
  cat > "$WEB/www/.env" <<'ENV'
APP_MODE=fitcom-practice
DB_HOST=127.0.0.1
DB_USER=demo_app
DB_PASSWORD=FAKE_SECRET_TRAINING_ONLY
ENV
  chown root:fitweb "$WEB/www/.env"
  chmod 0644 "$WEB/www/.env"
  cat > "$BASE/jobs/backup.sh" <<'BACKUP'
#!/usr/bin/env bash
set -euo pipefail
umask 077
tar -czf /var/lib/fitcom-lab/backup/latest.tar.gz -C /srv/fitcom-lab/www .
printf 'backup completed at %s\n' "$(date -Is)"
BACKUP
  chmod 0777 "$BASE/jobs/backup.sh"
  # These are separate copies. The system's own bash/python binaries are untouched.
  cp -- /bin/bash "$BASE/bin/diag-shell"
  chown root:root "$BASE/bin/diag-shell"
  chmod 4755 "$BASE/bin/diag-shell"
  cp -- "$(readlink -f /usr/bin/python3)" "$BASE/bin/diag-python"
  chown root:root "$BASE/bin/diag-python"
  chmod 0755 "$BASE/bin/diag-python"
  setcap cap_setuid=ep "$BASE/bin/diag-python"
  getcap "$BASE/bin/diag-python" | grep -q cap_setuid || die 'Filesystem tidak menyimpan file capabilities.'

  STAGE=ssh
  ssh-keygen -q -t ed25519 -N '' -C fitcom-host -f "$CONF/ssh_host_ed25519_key"
  ssh-keygen -q -t ed25519 -N '' -C fitcom-approved-operator -f "$STATE/keys/operator"
  ssh-keygen -q -t ed25519 -N '' -C fitcom-retired-key -f "$STATE/keys/retired"
  install -d -m 0700 -o fitops -g fitops /home/fitops/.ssh
  cat "$STATE/keys/operator.pub" "$STATE/keys/retired.pub" > /home/fitops/.ssh/authorized_keys
  chown fitops:fitops /home/fitops/.ssh/authorized_keys
  chmod 0600 /home/fitops/.ssh/authorized_keys
  # Keep only the retired public key as a checker fixture; no usable private backdoor key.
  rm -- "$STATE/keys/retired"
  printf '[127.0.0.1]:2222 %s\n' "$(cut -d ' ' -f1,2 "$CONF/ssh_host_ed25519_key.pub")" > "$STATE/keys/known_hosts"
  cat > "$CONF/sshd_config" <<'SSHD'
# Separate practice SSH daemon. The VM's normal sshd_config is not used.
Port 2222
ListenAddress 127.0.0.1
HostKey /etc/fitcom-lab/ssh_host_ed25519_key
PidFile /run/fitcom-sshd.pid
PermitRootLogin yes
PasswordAuthentication yes
KbdInteractiveAuthentication no
PermitEmptyPasswords no
PubkeyAuthentication yes
UsePAM yes
AuthorizedKeysFile .ssh/authorized_keys
StrictModes yes
AllowUsers fitops fitlegacy root
X11Forwarding no
AllowTcpForwarding no
AllowAgentForwarding no
PermitTunnel no
LogLevel VERBOSE
Subsystem sftp internal-sftp
SSHD
  chmod 0600 "$CONF/ssh_host_ed25519_key"
  install -d -m 0755 /run/sshd
  /usr/sbin/sshd -t -f "$CONF/sshd_config"

  STAGE=web
  cat > "$CONF/nginx.conf" <<'NGINX'
user root;
worker_processes 1;
pid /run/fitcom-nginx/nginx.pid;
error_log /var/log/fitcom-lab/nginx-error.log;
events { worker_connections 128; }
http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    access_log /var/log/fitcom-lab/nginx-access.log;
    server {
        listen 127.0.0.1:8080;
        server_name localhost;
        root /srv/fitcom-lab/www;
        index index.html;
        autoindex on;
        include /etc/fitcom-lab/nginx-extra.conf;
        location / { try_files $uri $uri/ =404; }
    }
}
NGINX
  printf '# Tambahkan aturan akses spesifik sesuai kebutuhan lab.\n' > "$CONF/nginx-extra.conf"
  cat > "$BASE/diagnostics.py" <<'PY_DIAG'
from http.server import BaseHTTPRequestHandler, HTTPServer

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        body = b"FITCOM obsolete diagnostics: demo only; no sensitive data\n"
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

HTTPServer(("127.0.0.1", 9090), Handler).serve_forever()
PY_DIAG
  chmod 0644 "$BASE/diagnostics.py"

  STAGE=systemd
  cat > /etc/systemd/system/fitcom-web.service <<'UNIT_WEB'
[Unit]
Description=FITCOM practice portal (independent nginx instance)
After=network.target
[Service]
Type=simple
RuntimeDirectory=fitcom-nginx
ExecStartPre=/usr/sbin/nginx -t -c /etc/fitcom-lab/nginx.conf
ExecStart=/usr/sbin/nginx -c /etc/fitcom-lab/nginx.conf -g "daemon off;"
ExecReload=/usr/sbin/nginx -t -c /etc/fitcom-lab/nginx.conf
ExecReload=/bin/kill -HUP $MAINPID
KillSignal=SIGQUIT
TimeoutStopSec=15
Restart=on-failure
[Install]
WantedBy=multi-user.target
UNIT_WEB
  cat > /etc/systemd/system/fitcom-ssh.service <<'UNIT_SSH'
[Unit]
Description=FITCOM practice SSH on loopback port 2222
After=network.target
[Service]
Type=simple
ExecStartPre=/usr/bin/install -d -m 0755 /run/sshd
ExecStartPre=/usr/sbin/sshd -t -f /etc/fitcom-lab/sshd_config
ExecStart=/usr/sbin/sshd -D -e -f /etc/fitcom-lab/sshd_config
ExecReload=/usr/sbin/sshd -t -f /etc/fitcom-lab/sshd_config
ExecReload=/bin/kill -HUP $MAINPID
Restart=on-failure
[Install]
WantedBy=multi-user.target
UNIT_SSH
  cat > /etc/systemd/system/fitcom-backup.service <<'UNIT_BACKUP'
[Unit]
Description=FITCOM required portal backup
[Service]
Type=oneshot
User=root
UMask=0077
ExecStart=/opt/fitcom-lab/jobs/backup.sh
UNIT_BACKUP
  cat > /etc/systemd/system/fitcom-backup.timer <<'UNIT_TIMER'
[Unit]
Description=FITCOM scheduled backup every five minutes
[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
Unit=fitcom-backup.service
[Install]
WantedBy=timers.target
UNIT_TIMER
  cat > /etc/systemd/system/fitcom-diagnostics.service <<'UNIT_DIAG'
[Unit]
Description=FITCOM obsolete diagnostics listener
After=network.target
[Service]
Type=simple
User=fitweb
ExecStart=/usr/bin/python3 /opt/fitcom-lab/diagnostics.py
Restart=on-failure
[Install]
WantedBy=multi-user.target
UNIT_DIAG
  for name in "${TARGET_UNITS[@]}"; do chmod 0644 "/etc/systemd/system/$name"; done
  /usr/bin/python3 - "$STATE" "$LAB_VERSION" <<'PY_MANIFEST'
import json, pathlib, pwd, sys, time
state = pathlib.Path(sys.argv[1])
manifest = {
    "version": sys.argv[2], "created_at": int(time.time()),
    "users": {name: pwd.getpwnam(name).pw_uid for name in ("fitops", "fithelpdesk", "fitlegacy", "fitweb")},
    "approved_key": (state / "keys/operator.pub").read_text().split()[1],
    "retired_key": (state / "keys/retired.pub").read_text().split()[1],
}
(state / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
PY_MANIFEST
  systemctl daemon-reload
  systemctl enable --now fitcom-web.service fitcom-ssh.service fitcom-backup.timer fitcom-diagnostics.service
  systemctl start fitcom-backup.service
  : > "$STATE/installed"
  install_judge
  STAGE=baseline-validation
  # Small bounded readiness loop; not a fixed blind wait.
  local attempt
  for ((attempt = 0; attempt < 20; attempt++)); do
    if curl --noproxy '*' --silent --fail --max-time 1 http://127.0.0.1:8080/health.txt >/dev/null \
       && curl --noproxy '*' --silent --fail --max-time 1 http://127.0.0.1:9090/ >/dev/null; then break; fi
    sleep 0.25
  done
  check_lab --json > "$STATE/baseline.json"
  /usr/bin/python3 - "$STATE/baseline.json" <<'PY_BASELINE'
import json, sys
r = json.load(open(sys.argv[1]))
if not r["healthy"] or r["raw_score"] != 0:
    print("Baseline tidak sesuai. Jangan mulai simulasi dahulu.", file=sys.stderr)
    print(json.dumps(r, indent=2), file=sys.stderr)
    sys.exit(1)
print("Baseline OK: layanan berfungsi, 12 temuan masih terbuka, 0/12 perbaikan valid.")
PY_BASELINE
  start_judge
  say 'Instalasi selesai. Baca brief, lalu mulai timer latihanmu.'
  brief
}

install_judge() {
  STAGE=judge-setup
  local unit
  if [[ ! -f "$STATE/judge-owned" ]]; then
    for unit in "${JUDGE_UNITS[@]}"; do
      if [[ -e /etc/systemd/system/$unit || -L /etc/systemd/system/$unit ]] || systemctl cat "$unit" >/dev/null 2>&1; then
        die "Nama unit penilai sudah digunakan: $unit"
      fi
    done
    if getent passwd fitjudge >/dev/null || getent group fitjudge >/dev/null; then
      die 'User/grup fitjudge sudah ada dan bukan milik lab.'
    fi
    [[ ! -e "$BASE/judge" && ! -L "$BASE/judge" && ! -e "$PUBLIC" && ! -L "$PUBLIC" ]] || die 'Path penilai sudah ada dan tidak ditimpa.'
    if ss -H -ltn | awk '{print $4}' | grep -Eq ':8090$'; then die 'Port dashboard 8090 sedang dipakai.'; fi
    : > "$STATE/judge-owned"
  fi
  systemctl stop "${JUDGE_UNITS[@]}" >/dev/null 2>&1 || true
  if ! getent passwd fitjudge >/dev/null; then
    if getent group fitjudge >/dev/null; then
      useradd -r -g fitjudge -M -d /nonexistent -s /usr/sbin/nologin fitjudge
    else
      useradd -r -U -M -d /nonexistent -s /usr/sbin/nologin fitjudge
    fi
  fi
  [[ $(id -u fitjudge) -gt 0 ]] || die 'Akun tampilan penilai tidak boleh UID 0.'
  install -d -m 0755 -o root -g root "$BASE/judge" "$PUBLIC"
  write_dashboard
  cat > /etc/systemd/system/fitcom-score.service <<'UNIT_SCORE'
[Unit]
Description=FITCOM practice continuous Linux hardening judge
After=network.target fitcom-web.service fitcom-ssh.service
[Service]
Type=exec
User=root
RuntimeDirectory=fitcom-score
RuntimeDirectoryMode=0755
RuntimeDirectoryPreserve=yes
ExecStart=/usr/local/sbin/fitcom-lab score-daemon
Restart=on-failure
RestartSec=3
TimeoutStopSec=5
[Install]
WantedBy=multi-user.target
UNIT_SCORE
  cat > /etc/systemd/system/fitcom-board.service <<'UNIT_BOARD'
[Unit]
Description=FITCOM practice read-only scoreboard on loopback port 8090
After=fitcom-score.service
Wants=fitcom-score.service
[Service]
Type=exec
User=fitjudge
Group=fitjudge
ExecStart=/usr/bin/python3 /opt/fitcom-lab/judge/board.py
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
CapabilityBoundingSet=
RestrictAddressFamilies=AF_INET AF_UNIX
Restart=on-failure
RestartSec=3
[Install]
WantedBy=multi-user.target
UNIT_BOARD
  for unit in "${JUDGE_UNITS[@]}"; do chmod 0644 "/etc/systemd/system/$unit"; done
  /usr/bin/python3 - "$STATE" "$LAB_VERSION" <<'PY_UPGRADE'
import json, pathlib, pwd, sys
state = pathlib.Path(sys.argv[1])
path = state / 'manifest.json'
data = json.loads(path.read_text())
data['version'] = sys.argv[2]
data['users']['fitjudge'] = pwd.getpwnam('fitjudge').pw_uid
temporary = state / '.manifest-upgrade.json'
temporary.write_text(json.dumps(data, indent=2) + '\n')
temporary.chmod(0o600)
temporary.replace(path)
PY_UPGRADE
  if [[ $(readlink -f "${BASH_SOURCE[0]}") != "$MANAGER" ]]; then
    install -m 0755 "$(readlink -f "${BASH_SOURCE[0]}")" "$MANAGER"
  fi
  systemctl daemon-reload
}

start_judge() {
  STAGE=judge-start
  systemctl enable --now "${JUDGE_UNITS[@]}"
  local attempt
  for ((attempt = 0; attempt < 30; attempt++)); do
    if curl --noproxy '*' --silent --fail --max-time 1 http://127.0.0.1:8090/api/score >/dev/null; then
      say 'Penilai otomatis aktif. Papan skor: sudo fitcom-lab watch atau http://127.0.0.1:8090/.'
      return
    fi
    sleep 0.25
  done
  die 'Dashboard belum siap. Periksa: sudo journalctl -u fitcom-score -u fitcom-board -n 40 --no-pager'
}

upgrade_lab() {
  root_required
  installed_required
  STAGE=upgrade
  exec 9>/run/lock/fitcom-lab-install.lock
  flock -n 9 || die 'Installer/upgrade lain sedang berjalan.'
  say 'Mengupdate penilai ke v2. Konfigurasi target dan perbaikanmu dipertahankan.'
  install_judge
  check_lab --json >/dev/null
  start_judge
  brief
}

score_daemon() {
  root_required
  installed_required
  while true; do
    if ! "$MANAGER" check --json >/dev/null; then
      printf 'Pemeriksaan gagal; hasil lama dipertahankan dan akan ditandai kedaluwarsa oleh tampilan.\n' >&2
    fi
    sleep 10
  done
}

watch_lab() {
  installed_required
  /usr/bin/python3 - <<'PY_WATCH'
import json, pathlib, sys, time
path = pathlib.Path('/run/fitcom-score/score.json')
interactive = sys.stdout.isatty()
try:
    while True:
        if interactive:
            print('\033[2J\033[H', end='')
        print('FITCOM / PAPAN SKOR LATIHAN REXAA\n')
        try:
            data = json.loads(path.read_text())
            age = max(0, int(time.time()) - data['checked_at'])
            freshness = 'TERLAMBAT / CEK PENILAI' if age > 45 else 'AKTIF'
            print(f"Perbaikan valid: {data['current_score']}/{data['maximum']} poin latihan")
            print(f"Pernah lolos: {data['ever_passed_count']} | Hasil {age} detik lalu | {freshness}\n")
            for row in data['checks']:
                mark = {'passed':'SELESAI', 'open':'TERBUKA', 'blocked':'TERHALANG'}[row['status']]
                print(f" {row['id']} [{mark:9}] {row['title']}")
            issues = [k for k, v in data['health'].items() if not v]
            print('\nGangguan layanan: ' + (', '.join(issues) if issues else 'tidak ada'))
            print('1 perbaikan = 1 poin latihan. Bobot dan soal bukan ketentuan resmi FITCOM.')
            if age > 45:
                print('Diagnosis: sudo systemctl status fitcom-score; sudo journalctl -u fitcom-score -n 30')
        except (OSError, ValueError, KeyError, TypeError):
            print('Menunggu hasil. Periksa: sudo systemctl status fitcom-score')
        print('\nTampilan diperbarui 2 detik; penilai jeda 10 detik antar putaran. Ctrl+C untuk keluar.')
        if not interactive:
            break
        time.sleep(2)
except KeyboardInterrupt:
    print('\nTampilan ditutup. Penilai otomatis tetap berjalan.')
PY_WATCH
}

write_dashboard() {
  cat > "$BASE/judge/board.py" <<'PY_BOARD'
"""Local, read-only scoreboard. No shell execution and no filesystem browsing."""
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit

PAGE = Path(__file__).with_name('index.html')
REPORT = Path('/run/fitcom-score/score.json')

class Board(BaseHTTPRequestHandler):
    server_version = 'FitcomPractice/2'
    sys_version = ''

    def setup(self):
        super().setup()
        self.connection.settimeout(10)

    def respond(self, code, content_type, data, head=False):
        self.send_response(code)
        self.send_header('Content-Type', content_type)
        self.send_header('Content-Length', str(len(data)))
        self.send_header('Cache-Control', 'no-store')
        self.send_header('X-Content-Type-Options', 'nosniff')
        self.send_header('X-Frame-Options', 'DENY')
        self.send_header('Content-Security-Policy', "default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; connect-src 'self'; base-uri 'none'; frame-ancestors 'none'")
        self.end_headers()
        if not head:
            self.wfile.write(data)

    def do_GET(self, head=False):
        try:
            host = urlsplit('//' + self.headers.get('Host', '')).hostname
        except ValueError:
            host = None
        if host not in ('localhost', '127.0.0.1', '::1'):
            self.respond(403, 'text/plain', b'Local scoreboard only. Use localhost or an SSH tunnel.', head)
            return
        route = urlsplit(self.path).path
        try:
            if route == '/':
                self.respond(200, 'text/html; charset=utf-8', PAGE.read_bytes(), head)
            elif route == '/api/score':
                data = REPORT.read_bytes()
                json.loads(data)
                self.respond(200, 'application/json; charset=utf-8', data, head)
            elif route == '/favicon.ico':
                self.respond(204, 'image/x-icon', b'', head)
            else:
                self.respond(404, 'text/plain', b'Not found', head)
        except (OSError, ValueError):
            self.respond(503, 'application/json', b'{"error":"Waiting for a valid judge report"}', head)

    def do_HEAD(self):
        self.do_GET(head=True)

    def do_POST(self):
        self.respond(405, 'text/plain', b'Read-only scoreboard')

    def log_message(self, *args):
        pass

if __name__ == '__main__':
    ThreadingHTTPServer(('127.0.0.1', 8090), Board).serve_forever()
PY_BOARD
  cat > "$BASE/judge/index.html" <<'HTML_BOARD'
<!doctype html>
<html lang="id"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>FITCOM — Papan Skor Latihan</title>
<style>
:root{--navy:#112741;--ink:#172b40;--muted:#67798a;--line:#dce4e9;--paper:#f3f6f8;--green:#11765c;--gold:#986322;--red:#a53c44}
*{box-sizing:border-box}body{margin:0;background:var(--paper);color:var(--ink);font:15px/1.5 system-ui,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}header{background:var(--navy);color:white;padding:19px 5vw;display:flex;align-items:center;justify-content:space-between;gap:20px}.brand{font-weight:800;letter-spacing:.06em;font-size:19px}.brand span{font-weight:400;opacity:.6;margin:0 10px}.practice{font-size:11px;letter-spacing:.12em;border:1px solid #587082;padding:5px 9px;border-radius:5px}.identity{font-size:13px;color:#b8cbda}main{max-width:1320px;padding:34px 30px 20px;margin:auto}.intro{display:flex;justify-content:space-between;align-items:end;gap:20px;margin-bottom:25px}.eyebrow{font-size:11px;letter-spacing:.16em;font-weight:700;color:var(--green)}h1{font-size:32px;letter-spacing:-.04em;margin:5px 0 8px;line-height:1.2}.sub{margin:0;color:var(--muted);max-width:760px;font-size:14px}.live{white-space:nowrap;display:inline-flex;align-items:center;gap:8px;font-size:12px;background:white;border:1px solid var(--line);padding:8px 12px;border-radius:30px}.dot{width:7px;height:7px;background:var(--muted);border-radius:50%}.live.fresh .dot{background:var(--green);box-shadow:0 0 0 4px #e5f3ed}.live.stale .dot{background:var(--red)}.metrics{display:grid;grid-template-columns:1.4fr 1fr 1fr 1fr;gap:14px;margin-bottom:25px}.metric{background:white;border:1px solid var(--line);border-radius:12px;padding:20px}.metric.primary{background:var(--navy);color:white;border-color:var(--navy)}.label{font-size:12px;color:var(--muted)}.primary .label,.primary .small{color:#b8cbda}.number{font-size:38px;line-height:1.25;font-weight:700;letter-spacing:-.04em;margin:7px 0}.number small{font-weight:400;font-size:20px;opacity:.55}.small{font-size:11px;color:var(--muted)}.track{height:4px;border-radius:8px;background:#324960;margin:10px 0 0}.fill{height:100%;width:0;background:#75ddb2;border-radius:8px;transition:width .4s}.content{display:grid;grid-template-columns:minmax(0,1.8fr) minmax(300px,1fr);gap:20px}.panel{background:white;border:1px solid var(--line);border-radius:12px;overflow:hidden}.panel-top{padding:19px 22px;display:flex;justify-content:space-between;align-items:center;gap:12px;border-bottom:1px solid var(--line)}h2{font-size:15px;margin:0}select{font:inherit;font-size:12px;border:1px solid var(--line);border-radius:6px;padding:6px 9px;background:white;color:var(--ink);max-width:155px}select:focus{outline:2px solid #4393a6;outline-offset:2px}table{border-collapse:collapse;width:100%;font-size:13px}th{text-align:left;font-size:10px;text-transform:uppercase;letter-spacing:.1em;color:var(--muted);padding:12px 18px;background:#f9fafb;font-weight:600}td{padding:13px 18px;border-top:1px solid #eef2f5;vertical-align:middle}td:first-child{font-variant-numeric:tabular-nums;color:var(--muted);width:48px}td:last-child{width:115px}.pill{display:inline-block;border-radius:5px;padding:4px 7px;font-size:10px;font-weight:700;letter-spacing:.03em;white-space:nowrap}.passed{background:#e8f5ef;color:var(--green)}.open{background:#eff2f5;color:#667787}.blocked{background:#fff0dc;color:var(--gold)}.footnote{padding:14px 20px;color:var(--muted);font-size:11px;border-top:1px solid var(--line)}aside{display:flex;flex-direction:column;gap:18px}.health{padding:10px 20px 13px}.health-row{display:flex;justify-content:space-between;gap:12px;padding:8px 0;font-size:12px}.health-row strong{font-size:10px;font-weight:700}.ok{color:var(--green)}.bad{color:var(--red)}.timeline{padding:6px 20px 16px;max-height:300px;overflow:auto}.event{padding:11px 0;border-bottom:1px solid #eef2f5;font-size:12px}.event small{display:block;font-size:10px;color:var(--muted);margin-bottom:4px}.empty{padding:24px 20px;color:var(--muted);font-size:12px}.notice{margin-top:23px;color:var(--muted);font-size:11px;display:flex;justify-content:space-between;gap:20px;align-items:start}.notice p{margin:0;max-width:860px}.timestamp{white-space:nowrap}.alert{display:none;margin-bottom:20px;border-left:3px solid var(--gold);background:#fff6e9;padding:12px 15px;font-size:12px;color:#80551b}.alert.show{display:block}footer{max-width:1320px;padding:10px 30px 25px;margin:auto;font-size:11px;color:var(--muted)}code{background:#eef2f5;padding:2px 5px;border-radius:3px;font-size:11px}
@media(max-width:950px){.content{grid-template-columns:1fr}aside{display:grid;grid-template-columns:1fr 1fr}.metrics{grid-template-columns:repeat(2,1fr)}.intro{align-items:start}.number{font-size:34px}}@media(max-width:580px){header{padding:16px 20px}.identity{display:none}main{padding:25px 15px 15px}.intro{display:block}.live{margin-top:15px}h1{font-size:27px}.metrics{gap:10px}.metric{padding:15px}.number{font-size:30px}.content{gap:15px}aside{display:flex}.panel-top{padding:15px}th,td{padding:11px 10px}td:last-child{width:95px}.notice{display:block}.timestamp{margin-top:8px}footer{padding:10px 15px 20px}.practice{font-size:9px}}
</style></head><body>
<header><div class="brand">FITCOM <span>/</span><span class="practice">LATIHAN MANDIRI</span></div><div class="identity">rexaa · Ubuntu Server · v2</div></header>
<main>
<div class="intro"><div><div class="eyebrow">LINUX HARDENING</div><h1>Papan skor latihan</h1><p class="sub">Perbaiki konfigurasi sistem. Hasil pemeriksaan akan tercatat otomatis di sini.</p></div><div class="live" id="live"><span class="dot"></span><span id="liveText">Menunggu penilai</span></div></div>
<div class="alert" id="alert" role="status"></div>
<section class="metrics" aria-label="Ringkasan penilaian">
<div class="metric primary"><div class="label">Perbaikan valid saat ini</div><div class="number"><span id="score">—</span><small> / <span id="maximum">12</span></small></div><div class="small">1 perbaikan valid = 1 poin latihan</div><div class="track"><div class="fill" id="progress"></div></div></div>
<div class="metric"><div class="label">Belum valid</div><div class="number" id="remaining">—</div><div class="small">Terbuka atau pemeriksaannya terhalang</div></div>
<div class="metric"><div class="label">Pernah lolos</div><div class="number" id="ever">—</div><div class="small">Riwayat unik; bukan skor saat ini</div></div>
<div class="metric"><div class="label">Gangguan fungsi</div><div class="number" id="issues">—</div><div class="small">Hanya memengaruhi soal yang terkait</div></div>
</section>
<div class="content"><section class="panel"><div class="panel-top"><h2>Status perbaikan</h2><select id="filter" aria-label="Filter status"><option value="all">Semua status</option><option value="open">Terbuka</option><option value="passed">Selesai</option><option value="blocked">Terhalang</option></select></div><table><thead><tr><th>No.</th><th>Pemeriksaan</th><th>Status</th></tr></thead><tbody id="checks"><tr><td colspan="3" class="empty">Menunggu pemeriksaan pertama…</td></tr></tbody></table><div class="footnote">Terhalang berarti fungsi pendukung belum memenuhi kebutuhan latihan. Perbaikan lain tetap dihitung.</div></section>
<aside><section class="panel"><div class="panel-top"><h2>Fungsi layanan</h2></div><div class="health" id="health"><div class="empty">Belum ada hasil.</div></div></section><section class="panel"><div class="panel-top"><h2>Riwayat perubahan</h2><span class="small">Terbaru dahulu</span></div><div class="timeline" id="events"><div class="empty">Belum ada perubahan.</div></div></section></aside></div>
<div class="notice"><p>Simulasi berdasarkan informasi penilaian FITCOM, bukan sistem juri resmi. Soal, bobot 1 poin, jeda pemeriksaan, dan pengurangan saat konfigurasi kembali rentan adalah pilihan latihan. Portal pada port 8080 hanyalah satu layanan target.</p><div class="timestamp" id="updated">Belum diperiksa</div></div>
</main><footer>Penilai otomatis: jeda 10 detik antar putaran · Alternatif tanpa browser: <code>sudo fitcom-lab watch</code></footer>
<script>
const $=id=>document.getElementById(id);let latest=null;let connected=false;let fetching=false;
const labels={authorized_accounts:'Identitas akun sah',portal:'Portal web',http_health:'HTTP health check',public_report:'Unduhan laporan publik',application_data:'Akses data aplikasi',approved_ssh_login:'Login SSH operator',fresh_backup:'Hasil backup terbaru',backup_schedule:'Jadwal backup'};
const statusNames={passed:'SELESAI',open:'TERBUKA',blocked:'TERHALANG'};
function clock(t){return new Intl.DateTimeFormat('id-ID',{timeZone:'Asia/Jakarta',hour:'2-digit',minute:'2-digit',second:'2-digit'}).format(new Date(t*1000))+' WIB'}
function node(tag,text,className){const e=document.createElement(tag);if(text!==undefined)e.textContent=text;if(className)e.className=className;return e}
function renderRows(){if(!latest)return;const body=$('checks');body.replaceChildren();const chosen=$('filter').value;const rows=latest.checks.filter(r=>chosen==='all'||r.status===chosen);for(const r of rows){const tr=node('tr');tr.append(node('td',r.id),node('td',r.title));const cell=node('td');const pill=node('span',statusNames[r.status]||r.status,'pill '+r.status);cell.append(pill);if(r.blocked_by?.length)cell.title=r.blocked_by.map(k=>labels[k]||k).join(', ');tr.append(cell);body.append(tr)}if(!rows.length){const tr=node('tr');const td=node('td','Tidak ada pemeriksaan dengan status ini.','empty');td.colSpan=3;tr.append(td);body.append(tr)}}
function render(d){latest=d;$('score').textContent=d.current_score;$('maximum').textContent=d.maximum;$('remaining').textContent=d.maximum-d.current_score;$('ever').textContent=d.ever_passed_count;$('issues').textContent=Object.values(d.health).filter(v=>!v).length;$('progress').style.width=Math.max(0,Math.min(100,d.current_score/d.maximum*100))+'%';renderRows();const health=$('health');health.replaceChildren();for(const [key,ok]of Object.entries(d.health)){const row=node('div',undefined,'health-row');row.append(node('span',labels[key]||key),node('strong',ok?'OK':'PERLU DIPERIKSA',ok?'ok':'bad'));health.append(row)}const events=$('events');events.replaceChildren();for(const ev of [...d.events].reverse().slice(0,15)){const e=node('div',undefined,'event');e.append(node('small',clock(ev.at)+' · '+(statusNames[ev.status]||ev.status)),node('span',ev.id+' — '+ev.title));events.append(e)}if(!d.events.length)events.append(node('div','Belum ada perubahan status. Mulai audit dan perbaiki konfigurasi di VM.','empty'));$('updated').textContent='Diperiksa '+clock(d.checked_at);freshness()}
function freshness(){const age=latest?Math.max(0,Math.floor(Date.now()/1000-latest.checked_at)):null;const stale=!connected||age===null||age>45;$('live').className='live '+(stale?'stale':'fresh');$('liveText').textContent=age===null?'Menunggu penilai':(stale?'Hasil belum diperbarui':'Penilai aktif')+' · '+age+' dtk lalu';const message=!connected?'Papan skor belum terhubung. Periksa service fitcom-board dan koneksi SSH tunnel.':(age!==null&&age>45?'Hasil penilaian terlambat. Periksa service fitcom-score; angka di layar adalah hasil terakhir.':'');$('alert').textContent=message;$('alert').className='alert'+(message?' show':'')}
async function poll(){if(fetching)return;fetching=true;try{const r=await fetch('/api/score',{cache:'no-store',signal:AbortSignal.timeout(5000)});if(!r.ok)throw Error('not ready');const d=await r.json();if(d.schema!==2||!Array.isArray(d.checks))throw Error('invalid report');connected=true;render(d)}catch(e){connected=false;freshness()}finally{fetching=false}}
$('filter').addEventListener('change',renderRows);poll();setInterval(poll,3000);setInterval(freshness,1000);
</script></body></html>
HTML_BOARD
  chmod 0644 "$BASE/judge/board.py" "$BASE/judge/index.html"
}

brief() {
  installed_required
  cat <<'BRIEF'

FITCOM PRACTICE / BRIEF UNTUK REXAA
=================================
Kamu mendapat Ubuntu Server dengan salah konfigurasi pada akun, privilege,
permission, SSH, job sistem, dan layanan. Cari lalu perbaiki masalahnya.
Portal web hanyalah satu contoh layanan yang terpasang pada server.
Ada 12 temuan latihan. Setiap perbaikan valid bernilai 1 poin: maksimum 12.
Jumlah soal, bobot, dan interval di sini adalah pilihan latihan, bukan aturan resmi.
Kisi-kisi FITCOM: jumlah perbaikan Linux dan pencatatan poin secara real-time.
Dokumen LKS adalah lomba berbeda; requirement LKS tidak diimpor sebagai soal FITCOM.
Detail protokol penilaian "wireless", bobot, dan penalti FITCOM belum diketahui.
Saran sesi: 15 menit inventarisasi, 70 menit perbaikan, 20 menit validasi,
15 menit laporan. Durasi ini hanya saran untuk latihanmu, bukan durasi lomba.

LAYANAN WAJIB
  Portal: http://127.0.0.1:8080/ (buka dari dalam VM, atau gunakan curl)
  Health: /health.txt; laporan publik: /reports/q3-demo.txt
  SSH operator: fitops@127.0.0.1 port 2222, key resmi harus tetap berfungsi.
  Backup: fitcom-backup.timer harus aktif dan enabled; hasil backup harus valid.
  Data .env fiktif harus tetap ada dan dapat dibaca akun layanan fitweb.

IDENTITAS DAN KEBIJAKAN
  fitops      : operator sah, akun biasa; tidak membutuhkan sudo.
  fithelpdesk : helpdesk sah, akun biasa; tidak boleh menjalankan perintah sudo.
  fitweb      : akun layanan web, non-root, tanpa login interaktif.
  fitjudge    : akun tampilan papan skor; bukan target soal, jangan dihapus.
  fitlegacy   : pegawai lama; akses login dan hak adminnya harus dicabut.
  Akun admin asli VM-mu tetap digunakan untuk mengerjakan latihan.
  Password dummy fitops/fithelpdesk/fitlegacy: Fitcom-Lab-Only-26!
  Tidak ada perubahan password root atau akun admin asli.

BATAS LATIHAN
  Layanan diagnostik lama tidak diperlukan lagi dan tidak boleh autostart.
  Konfigurasi layanan lab menggunakan nama fitcom-*.service dan /etc/fitcom-lab.
  Nginx master boleh tetap root; worker harus memakai fitweb.
  File laporan tetap dapat diunduh langsung, tetapi listing direktori dilarang.
  Data .env tidak boleh diunduh melalui HTTP atau dibaca akun biasa.
  Binary diagnostik tidak membutuhkan SUID atau Linux file capabilities.
  Jangan menghapus data wajib, mengubah checker/fixture, atau mengganti port lab.
  Pertahankan SSH key resmi di bawah; hapus akses key yang tidak diotorisasi.
  Root login pada daemon SSH lab harus dinonaktifkan secara eksplisit.

ALUR
  sudo fitcom-lab watch          Papan skor live di terminal (Ctrl+C untuk keluar)
  sudo fitcom-lab check          Pemeriksaan tambahan secara manual
  sudo fitcom-lab hint 04        Buka satu petunjuk jika buntu
  sudo fitcom-lab solutions      Buka pembahasan setelah mencoba
  sudo fitcom-lab status         Diagnosis service/port

PENILAIAN OTOMATIS
  fitcom-score.service memeriksa otomatis, dengan jeda 10 detik antar putaran.
  fitcom-board.service menampilkan papan skor di http://127.0.0.1:8090/.
  Papan skor terpisah dari portal target pada port 8080.
  Dari laptop yang dapat SSH ke VM, jalankan (ganti USER dan IP_VM):
    ssh -N -L 8090:127.0.0.1:8090 USER@IP_VM
  Lalu buka http://127.0.0.1:8090/ di browser laptop. Pakai SSH admin VM biasa,
  bukan SSH target port 2222. Ubuntu Server tidak perlu desktop/GUI.

Skor latihan = jumlah perbaikan yang valid saat pemeriksaan terakhir.
Tidak ada aturan seluruh skor menjadi nol ketika satu layanan rusak.
Hanya soal yang bergantung pada layanan rusak yang berstatus TERHALANG.
Papan skor juga mencatat perubahan dan jumlah soal yang pernah lolos.
Jika konfigurasi dibuat rentan lagi, jumlah valid saat ini turun. Perilaku ini
dipakai untuk feedback latihan; aturan regresi skor resmi belum diketahui.
Kerusakan layanan ditampilkan terpisah. Backup diuji dari hasil job terbaru
(maksimum 7 menit), bukan dijalankan ulang pada setiap pemeriksaan.
Setelah memperbaiki backup, boleh uji: sudo systemctl start fitcom-backup.service
Pemeriksaan SSH root memakai konfigurasi pada disk: validasi lalu reload daemon.
Checker terbatas pada skenario yang ditanam; bukan audit menyeluruh/anti-cheat.
Setelah latihan: restore snapshot untuk reset penuh. Uninstall hanya menghapus
objek milik lab, bukan paket dependensi atau perubahan di luar lab.

FINGERPRINT KEY OPERATOR YANG SAH:
BRIEF
  ssh-keygen -lf "$STATE/keys/operator.pub"
  printf '\nTemplate catatan: Temuan | Bukti awal | Dampak | Perubahan | Uji ulang | Rollback\n'
}

check_lab() {
  installed_required
  [[ -f "$STATE/judge-owned" ]] || die 'Versi penilai lama. Jalankan file install.sh terbaru dengan perintah install atau upgrade dahulu.'
  [[ ${1:-} == '' || ${1:-} == --json ]] || die 'Gunakan check atau check --json.'
  /usr/bin/python3 - "${1:-}" <<'PY_CHECK'
import fcntl
import grp
import json
import os
import pathlib
import pwd
import socket
import stat
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.error
import urllib.request

STATE = pathlib.Path('/var/lib/fitcom-lab')
BASE = pathlib.Path('/opt/fitcom-lab')
CONF = pathlib.Path('/etc/fitcom-lab')
WWW = pathlib.Path('/srv/fitcom-lab/www')
PUBLIC = pathlib.Path('/run/fitcom-score')
M = json.loads((STATE / 'manifest.json').read_text())
OUT_JSON = '--json' in sys.argv
LOCK = (STATE / 'checker.lock').open('a')
deadline = time.monotonic() + 30
while True:
    try:
        fcntl.flock(LOCK, fcntl.LOCK_EX | fcntl.LOCK_NB)
        break
    except BlockingIOError:
        if time.monotonic() >= deadline:
            print('Pemeriksaan lain masih berjalan; lihat papan skor terakhir.', file=sys.stderr)
            LOCK.close()
            sys.exit(75)
        time.sleep(0.1)
started = time.monotonic()

def run(args, timeout=12):
    try:
        return subprocess.run(args, capture_output=True, text=True, timeout=timeout,
                              env={**os.environ, 'LC_ALL': 'C', 'PATH': '/usr/sbin:/usr/bin:/sbin:/bin'})
    except (OSError, subprocess.TimeoutExpired) as e:
        return subprocess.CompletedProcess(args, 125, '', str(e))

def http(path):
    # Ignore the caller's proxy settings, including for error pages.
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    try:
        with opener.open('http://127.0.0.1:8080' + path, timeout=3) as r:
            return r.status, r.read(65536).decode('utf-8', 'replace')
    except urllib.error.HTTPError as e:
        return e.code, e.read(65536).decode('utf-8', 'replace')
    except (OSError, urllib.error.URLError):
        return 0, ''

def readable(user, path):
    return run(['/usr/sbin/runuser', '-u', user, '--', '/usr/bin/test', '-r', str(path)]).returncode == 0

def writable(user, path):
    return run(['/usr/sbin/runuser', '-u', user, '--', '/usr/bin/test', '-w', str(path)]).returncode == 0

def no_sudo(user):
    result = run(['/usr/bin/sudo', '-l', '-U', user])
    text = result.stdout + result.stderr
    # A command/query failure is not automatically treated as a secure policy.
    return result.returncode in (0, 1) and ('not allowed to run sudo' in text or 'is not allowed to run' in text)

def enabled(unit):
    r = run(['systemctl', 'is-enabled', unit])
    return r.returncode == 0 and r.stdout.strip() == 'enabled'

def active(unit):
    return run(['systemctl', 'is-active', '--quiet', unit]).returncode == 0

def same_user(name):
    try:
        return pwd.getpwnam(name).pw_uid == M['users'][name] and M['users'][name] > 0
    except KeyError:
        return False

health = {}
health['authorized_accounts'] = all(same_user(n) for n in ('fitops', 'fithelpdesk', 'fitweb'))
code, body = http('/')
health['portal'] = code == 200 and 'FITCOM Practice Portal' in body and enabled('fitcom-web.service')
code, body = http('/health.txt')
health['http_health'] = code == 200 and body.strip() == 'FITCOM_OK'
code, body = http('/reports/q3-demo.txt')
health['public_report'] = code == 200 and 'FITCOM_DEMO_REPORT' in body
secret = WWW / '.env'
try:
    health['application_data'] = ('APP_MODE=fitcom-practice' in secret.read_text()
                                  and readable('fitweb', secret))
except OSError:
    health['application_data'] = False

ssh_result = run([
    '/usr/bin/ssh', '-F', '/dev/null', '-p', '2222', '-i', str(STATE / 'keys/operator'),
    '-o', 'BatchMode=yes', '-o', 'IdentitiesOnly=yes', '-o', 'ConnectTimeout=4',
    '-o', 'StrictHostKeyChecking=yes', '-o', 'GlobalKnownHostsFile=/dev/null',
    '-o', 'UserKnownHostsFile=' + str(STATE / 'keys/known_hosts'),
    'fitops@127.0.0.1', 'printf FITCOM_SSH_OK'
], timeout=8)
health['approved_ssh_login'] = (ssh_result.returncode == 0 and ssh_result.stdout == 'FITCOM_SSH_OK'
                                and enabled('fitcom-ssh.service'))

# Observe the scheduled job without executing a root-writable script on every poll.
archive = STATE / 'backup/latest.tar.gz'
backup = run(['systemctl', 'show', '-p', 'Result', '--value', 'fitcom-backup.service'])
backup_ok = False
try:
    with tarfile.open(archive, 'r:gz') as tf:
        names = {n[2:] if n.startswith('./') else n for n in tf.getnames()}
        backup_ok = {'index.html', 'health.txt', 'reports/q3-demo.txt', '.env'} <= names
    age = time.time() - archive.stat().st_mtime
    backup_ok = backup_ok and 0 <= age <= 420
except (OSError, tarfile.TarError):
    pass
health['fresh_backup'] = backup.returncode == 0 and backup.stdout.strip() == 'success' and backup_ok
health['backup_schedule'] = active('fitcom-backup.timer') and enabled('fitcom-backup.timer')

rows = []
def add(number, title, test, depends=()):
    try:
        ok = bool(test())
    except Exception:
        ok = False
    blocked_by = [key for key in depends if not health.get(key, False)]
    passed = ok and not blocked_by
    rows.append({'id': f'{number:02d}', 'title': title, 'points': 1,
                 'passed': passed, 'status': 'blocked' if blocked_by else ('passed' if passed else 'open'),
                 'blocked_by': blocked_by})

def retired_user():
    try:
        u = pwd.getpwnam('fitlegacy')
    except KeyError:
        return True
    groups = {g.gr_name for g in grp.getgrall() if 'fitlegacy' in g.gr_mem or g.gr_gid == u.pw_gid}
    ps = run(['/usr/bin/passwd', '-S', 'fitlegacy']).stdout.split()
    locked = len(ps) > 1 and ps[1] == 'L'
    return (u.pw_uid != 0 and u.pw_gid != 0 and locked
            and u.pw_shell in ('/usr/sbin/nologin', '/sbin/nologin', '/bin/false', '/usr/bin/false')
            and not groups.intersection({'sudo', 'admin', 'wheel'}) and no_sudo('fitlegacy'))

def secret_permission():
    s = secret.stat()
    return (s.st_uid == 0 and not stat.S_IMODE(s.st_mode) & 0o007
            and not writable('fitweb', secret) and readable('fitweb', secret)
            and not readable('fithelpdesk', secret) and not readable('fitops', secret))

def backup_permission():
    script = BASE / 'jobs/backup.sh'
    if not script.is_file():
        return False
    for path in (script, BASE / 'jobs', BASE, BASE.parent):
        s = path.stat()
        if s.st_uid != 0 or stat.S_IMODE(s.st_mode) & 0o022:
            return False
        if any(writable(user, path) for user in ('fitops', 'fithelpdesk', 'fitweb')):
            return False
    return os.access(script, os.X_OK)

def suid_removed():
    p = BASE / 'bin/diag-shell'
    return not p.exists() or not (p.stat().st_mode & (stat.S_ISUID | stat.S_ISGID))

def caps_removed():
    p = BASE / 'bin/diag-python'
    if not p.exists():
        return True
    r = run(['/usr/sbin/getcap', str(p)])
    return r.returncode == 0 and not r.stdout.strip()

def ssh_root_policy():
    r = run(['/usr/sbin/sshd', '-T', '-f', str(CONF / 'sshd_config'),
             '-C', 'user=root,host=localhost,addr=127.0.0.1'])
    # Global policy in the supplied scenario; separately test the live operator session above.
    return r.returncode == 0 and 'permitrootlogin no' in r.stdout.splitlines()

def authorized_keys():
    p = pathlib.Path('/home/fitops/.ssh/authorized_keys')
    tokens = p.read_text().split()
    return M['approved_key'] in tokens and M['retired_key'] not in tokens

def no_listing():
    code, _ = http('/reports/')
    return code in (403, 404)

def no_http_secret():
    code, _ = http('/.env')
    return secret.is_file() and code in (403, 404)

def workers_unprivileged():
    r = run(['systemctl', 'show', '-p', 'MainPID', '--value', 'fitcom-web.service'])
    if r.returncode or not r.stdout.strip().isdigit() or int(r.stdout.strip()) <= 0:
        return False
    master = int(r.stdout.strip())
    r = run(['ps', '-eo', 'pid=,ppid=,euid=,args='])
    workers = []
    for line in r.stdout.splitlines():
        cols = line.split(None, 3)
        if len(cols) == 4 and cols[1] == str(master) and 'nginx: worker process' in cols[3]:
            workers.append(int(cols[2]))
    return bool(workers) and all(uid == M['users']['fitweb'] for uid in workers)

def diagnostics_off():
    result = run(['systemctl', 'is-enabled', 'fitcom-diagnostics.service'])
    off = result.stdout.strip() in ('disabled', 'masked', 'not-found') or 'not found' in result.stderr
    try:
        with socket.create_connection(('127.0.0.1', 9090), timeout=1):
            listening = True
    except OSError:
        listening = False
    return not active('fitcom-diagnostics.service') and off and not listening

add(1, 'Akun pegawai lama: akses dan hak admin dicabut', retired_user)
add(2, 'Helpdesk tidak memiliki izin sudo', lambda: same_user('fithelpdesk') and no_sudo('fithelpdesk'))
add(3, 'Data aplikasi hanya terbaca pihak yang berhak', secret_permission, ('application_data',))
add(4, 'Script backup root dan jalur induknya terlindungi', backup_permission, ('fresh_backup', 'backup_schedule'))
add(5, 'Binary diagnostik tanpa SUID/SGID', suid_removed)
add(6, 'Interpreter diagnostik tanpa file capabilities', caps_removed)
add(7, 'Konfigurasi efektif SSH menolak login root', ssh_root_policy, ('approved_ssh_login',))
add(8, 'Hanya key operator resmi yang dipertahankan', authorized_keys, ('approved_ssh_login',))
add(9, 'Directory listing laporan dinonaktifkan', no_listing, ('portal', 'public_report'))
add(10, 'Data .env tidak dapat diunduh melalui HTTP', no_http_secret, ('portal', 'application_data'))
add(11, 'Nginx worker berjalan sebagai fitweb', workers_unprivileged, ('portal', 'http_health'))
add(12, 'Diagnostik lama berhenti dan tidak autostart', diagnostics_off)

raw = sum(r['points'] for r in rows if r['passed'])
healthy = all(health.values())
try:
    previous = json.loads((STATE / 'last-report.json').read_text())
except (OSError, ValueError):
    previous = {}
if previous.get('schema') != 2:
    previous = {}
now = int(time.time())
valid_ids = {r['id'] for r in rows if r['passed']}
ever = set(previous.get('ever_passed_ids', [])) | valid_ids
old_rows = {r['id']: r for r in previous.get('checks', [])}
events = previous.get('events', [])[-80:]
for row in rows:
    old = old_rows.get(row['id'])
    if (old and old.get('status') != row['status']) or (not old and row['passed']):
        events.append({'at': now, 'id': row['id'], 'title': row['title'], 'status': row['status']})
report = {'version': M['version'], 'checked_at': int(time.time()), 'health': health,
          'healthy': healthy, 'checks': rows, 'raw_score': raw,
          'final_score': raw, 'current_score': raw, 'maximum': len(rows), 'schema': 2,
          'ever_passed_ids': sorted(ever), 'ever_passed_count': len(ever),
          'events': events[-80:], 'poll_gap_seconds': 10,
          'check_duration_seconds': round(time.monotonic() - started, 2),
          'scoring_note': '1 perbaikan valid = 1 poin latihan. Soal, bobot, interval dan aturan regresi bukan aturan resmi FITCOM.'}

def atomic_json(path, value, mode):
    fd, name = tempfile.mkstemp(prefix='.report-', dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as f:
            json.dump(value, f, indent=2)
            f.write('\n')
            os.fchmod(f.fileno(), mode)
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)

atomic_json(STATE / 'last-report.json', report, 0o600)
PUBLIC.mkdir(mode=0o755, exist_ok=True)
atomic_json(PUBLIC / 'score.json', report, 0o644)
if OUT_JSON:
    print(json.dumps(report, indent=2))
else:
    print('\nFITCOM PRACTICE / HASIL PEMERIKSAAN\n')
    print('FUNGSI WAJIB')
    for key, ok in health.items():
        print(f'  [{"OK" if ok else "RUSAK"}] {key}')
    print('\nKONFIGURASI')
    for row in rows:
        mark = {'passed': 'SELESAI', 'open': 'TERBUKA', 'blocked': 'TERHALANG'}[row['status']]
        print(f'  {row["id"]} [{mark}] {row["title"]} ({row["points"]} poin)')
    print(f'\nPerbaikan valid saat ini / poin latihan: {raw}/{len(rows)}')
    print(f'Pernah lolos (riwayat, bukan skor saat ini): {len(ever)}/{len(rows)}')
    if not healthy:
        print('Gangguan layanan dicatat terpisah; hanya soal terkait yang terhalang. Skor lainnya tetap dihitung.')
        if not health['approved_ssh_login']:
            print('Diagnosis SSH: sudo journalctl -u fitcom-ssh -n 30 --no-pager')
    elif raw == len(rows):
        print('Seluruh skenario lolos. Selesaikan laporan bukti sebelum/ sesudah perbaikan.')
    print('Laporan terakhir: /var/lib/fitcom-lab/last-report.json')
    print('Pemeriksaan SSH menilai konfigurasi pada disk; validasi lalu reload daemon setelah mengedit.')
    print('Ini skor lab mandiri, bukan sistem penilaian resmi FITCOM.')
LOCK.close()
PY_CHECK
}

hint() {
  case ${1:-} in
    1|01) cat <<'H01'
01 / Bandingkan roster pada brief dengan getent passwd dan getent group sudo.
Mencabut sudo saja belum menonaktifkan login. Periksa status password dan shell.
H01
      ;;
    2|02) cat <<'H02'
02 / Jalankan sudo -l -U fithelpdesk sebagai admin. Telusuri sudoers dan include-nya.
Kebijakan lab: akun helpdesk tetap ada, tetapi tidak membutuhkan perintah sudo.
H02
      ;;
    3|03) cat <<'H03'
03 / Cari file dotfile pada document root. Bandingkan stat, getfacl, dan akses aktual
sebagai fithelpdesk versus fitweb. Akun layanan harus masih dapat membacanya.
H03
      ;;
    4|04) cat <<'H04'
04 / systemctl cat fitcom-backup.service fitcom-backup.timer
Periksa siapa yang menjalankan job, siapa yang bisa menulis script, dan permission
direktori induknya. Mematikan timer akan merusak fungsi wajib.
H04
      ;;
    5|05) cat <<'H05'
05 / Cari file dengan bit SUID/SGID di /opt/fitcom-lab/bin menggunakan find/stat.
Binary diagnostik tidak punya kebutuhan bisnis untuk berjalan dengan privilege pemiliknya.
H05
      ;;
    6|06) cat <<'H06'
06 / getcap -r /opt/fitcom-lab 2>/dev/null
Permission 0755 tidak berarti aman jika file memperoleh capability berbahaya.
H06
      ;;
    7|07) cat <<'H07'
07 / Audit daemon SSH LAB, bukan sshd utama port 22:
sudo sshd -T -f /etc/fitcom-lab/sshd_config -C user=root,host=localhost,addr=127.0.0.1
Periksa PermitRootLogin. Uji sintaks sebelum reload fitcom-ssh.
H07
      ;;
    8|08) cat <<'H08'
08 / ssh-keygen -lf /home/fitops/.ssh/authorized_keys
Bandingkan fingerprint dengan brief. Mengganti password tidak mencabut SSH key.
Jangan menghapus key operator yang sah.
H08
      ;;
    9|09) cat <<'H09'
09 / Bandingkan GET /reports/ dan GET /reports/q3-demo.txt pada port 8080.
Pahami autoindex pada konfigurasi nginx lab. File publik harus tetap dapat diunduh.
H09
      ;;
    10) cat <<'H10'
10 / Uji curl --noproxy '*' -i http://127.0.0.1:8080/.env
Permission OS dan kebijakan HTTP adalah dua lapisan berbeda. Periksa location pada nginx.
Menghapus .env akan merusak kebutuhan data aplikasi dalam lab ini.
H10
      ;;
    11) cat <<'H11'
11 / ps -eo pid,ppid,euser,args | grep nginx
Bedakan master dan worker. Periksa directive user di konfigurasi nginx LAB.
Master root dapat normal; worker root tidak sesuai kebijakan skenario ini.
H11
      ;;
    12) cat <<'H12'
12 / ss -tulpn dan systemctl list-unit-files 'fitcom-*'
Brief menyatakan diagnostik lama tidak dibutuhkan. Stop saja tidak mencegah autostart.
H12
      ;;
    *) die 'Gunakan hint 01 sampai hint 12, misalnya: sudo fitcom-lab hint 04' ;;
  esac
}

solutions() {
  cat <<'SOLUTIONS'
PEMBAHASAN / SPOILER
===================
Ini contoh perbaikan untuk konfigurasi awal lab. Baca dahulu dan sesuaikan jika
kamu telah mengubah file. Perintah di bawah DITAMPILKAN saja, tidak dieksekusi.
Backup file yang akan diedit. Setelah setiap kelompok perubahan, jalankan check.

01. Akun lama harus kehilangan akses, bukan hanya keluar dari satu grup.
    sudo usermod -L -s /usr/sbin/nologin -G '' fitlegacy
    sudo -l -U fitlegacy
    Alternatif dalam lab: hapus akun lama, setelah memastikan data yang dibutuhkan.
    Lock password tidak otomatis mencabut SSH key; audit keduanya di sistem nyata.

02. Hapus rule lab yang memberikan hak admin kepada helpdesk.
    sudo rm /etc/sudoers.d/fitcom-helpdesk
    sudo visudo -c
    sudo -l -U fithelpdesk
    Jangan mengubah izin sudo akun admin asli VM.

03. Pertahankan akses baca akun layanan, cabut akses akun biasa.
    sudo chown root:fitweb /srv/fitcom-lab/www/.env
    sudo chmod 0640 /srv/fitcom-lab/www/.env
    sudo -u fitweb test -r /srv/fitcom-lab/www/.env
    sudo -u fithelpdesk test -r /srv/fitcom-lab/www/.env
    Perintah terakhir seharusnya exit 1 (ditolak). Pastikan ACL tambahan tidak membuka akses.

04. Script yang dijalankan root harus terlindungi dari modifikasi user biasa.
    sudo chown root:root /opt/fitcom-lab/jobs/backup.sh
    sudo chmod 0750 /opt/fitcom-lab/jobs/backup.sh
    sudo systemctl start fitcom-backup.service
    sudo systemctl status fitcom-backup.timer --no-pager
    Direktori induk juga tidak boleh writable oleh akun tidak tepercaya.

05. Hilangkan SUID/SGID yang tidak diperlukan pada COPY binary lab.
    sudo chmod u-s,g-s /opt/fitcom-lab/bin/diag-shell
    Jangan menghapus SUID semua binary sistem secara massal.

06. Hilangkan capability pada COPY interpreter lab.
    sudo setcap -r /opt/fitcom-lab/bin/diag-python
    getcap /opt/fitcom-lab/bin/diag-python
    Output kosong sesuai kebutuhan skenario ini.

07. Edit /etc/fitcom-lab/sshd_config: PermitRootLogin no
    sudo sed -i 's/^PermitRootLogin .*/PermitRootLogin no/' /etc/fitcom-lab/sshd_config
    sudo sshd -t -f /etc/fitcom-lab/sshd_config
    sudo systemctl reload fitcom-ssh.service
    Jalankan check untuk memastikan login operator sah masih berfungsi.

08. Hapus hanya key yang tidak diotorisasi; fingerprint resmi ada pada brief.
    Pada file awal lab, komentar key tidak sah adalah fitcom-retired-key:
    sudo sed -i '/fitcom-retired-key$/d' /home/fitops/.ssh/authorized_keys
    sudo chown fitops:fitops /home/fitops/.ssh/authorized_keys
    sudo chmod 0600 /home/fitops/.ssh/authorized_keys
    Jangan menghapus seluruh .ssh atau key resmi.

09. Edit /etc/fitcom-lab/nginx.conf: autoindex off;
    sudo sed -i 's/autoindex on;/autoindex off;/' /etc/fitcom-lab/nginx.conf
    sudo nginx -t -c /etc/fitcom-lab/nginx.conf
    sudo systemctl reload fitcom-web.service
    /reports/ akan 403; /reports/q3-demo.txt harus tetap 200.

10. Tambahkan blok berikut ke /etc/fitcom-lab/nginx-extra.conf:
    location ~ /\. {
        deny all;
    }
    Lalu:
    sudo nginx -t -c /etc/fitcom-lab/nginx.conf
    sudo systemctl reload fitcom-web.service
    curl --noproxy '*' -i http://127.0.0.1:8080/.env
    Harus ditolak. Pada produksi, secret idealnya juga ditempatkan di luar document root;
    lab ini mempertahankan path tetap agar pengujian permission dan HTTP dapat dibandingkan.

11. Edit /etc/fitcom-lab/nginx.conf: user fitweb;
    sudo sed -i 's/^user root;/user fitweb;/' /etc/fitcom-lab/nginx.conf
    sudo nginx -t -c /etc/fitcom-lab/nginx.conf
    sudo systemctl reload fitcom-web.service
    ps -eo pid,ppid,euser,args | grep nginx
    Tunggu worker lama selesai; master boleh tetap root, worker harus fitweb.

12. Nonaktifkan service diagnostik yang sudah tidak dibutuhkan.
    sudo systemctl disable --now fitcom-diagnostics.service
    ss -ltnp
    Port 9090 harus berhenti listening.

VALIDASI AKHIR
    sudo fitcom-lab check
    sudo fitcom-lab check --json
    Target latihan: 12/12 perbaikan valid dan fungsi layanan OK.
    Skor diperbarui otomatis; simpan juga bukti dan penjelasan dampak tiap temuan.
    Jika diizinkan pada latihanmu, reboot VM lalu ulangi check untuk menguji persistensi.

MATERI TAMBAHAN DI LUAR 12 SKENARIO
    UFW/nftables, PAM/password policy, AppArmor, paket/CVE, dan analisis log juga
    patut dipelajari. Installer ini tidak menanam semua kemungkinan materi lomba.
SOLUTIONS
}

status_lab() {
  printf '\nUnit lab:\n'
  systemctl --no-pager --full status "${UNITS[@]}" || true
  printf '\nListener lab:\n'
  ss -ltnp | awk 'NR == 1 || /:(2222|8080|8090|9090)[[:space:]]/'
  printf '\nLog terkait: sudo journalctl -u fitcom-score -u fitcom-board -u fitcom-web -u fitcom-ssh -u fitcom-backup -n 60 --no-pager\n'
}

uninstall_lab() {
  root_required
  owned_state || die 'Marker kepemilikan lab tidak ditemukan; tidak menghapus apa pun.'
  STAGE=uninstall
  restore_policy
  local unit name uid
  local -a owned_units=("${TARGET_UNITS[@]}")
  local -a owned_users=("${LAB_USERS[@]}")
  if [[ -f "$STATE/judge-owned" ]]; then
    owned_units=("${JUDGE_UNITS[@]}" "${TARGET_UNITS[@]}")
    owned_users+=(fitjudge)
  fi
  for unit in "${owned_units[@]}"; do
    systemctl disable --now "$unit" >/dev/null 2>&1 || true
  done
  for name in "${owned_users[@]}"; do
    if getent passwd "$name" >/dev/null; then
      uid=$(id -u "$name")
      [[ $uid -gt 0 ]] || die "Akun $name memiliki UID 0; perbaiki identitasnya dahulu, uninstall dihentikan."
      # Kill only accounts created by this lab, never the VM administrator.
      pkill -TERM -u "$uid" 2>/dev/null || true
      userdel "$name" || die "Tidak dapat menghapus $name. Tutup sesi/proses akun lab, lalu ulangi uninstall."
    fi
    if getent group "$name" >/dev/null; then groupdel "$name"; fi
  done
  for unit in "${owned_units[@]}"; do rm -f -- "/etc/systemd/system/$unit"; done
  rm -f -- /etc/sudoers.d/fitcom-helpdesk /run/fitcom-sshd.pid
  rm -rf -- /home/fitops /home/fithelpdesk /home/fitlegacy "$BASE" "$CONF" "$WEB" "$LOG" /run/fitcom-nginx
  systemctl daemon-reload
  systemctl reset-failed "${owned_units[@]}" 2>/dev/null || true
  if [[ -f "$STATE/judge-owned" ]]; then rm -rf -- "$PUBLIC"; fi
  rm -rf -- "$STATE"
  rm -f -- "$MANAGER"
  say 'Objek lab dihapus. Paket APT dan perubahanmu di luar lab tetap ada. Restore snapshot untuk kembali persis ke kondisi awal.'
}

main() {
  local command=${1:-install}
  if (($#)); then shift; fi
  case "$command" in
    -h|--help|help) usage ;;
    install) (($# == 0)) || die 'install tidak menerima argumen tambahan.'; install_lab ;;
    upgrade) (($# == 0)) || die 'upgrade tidak menerima argumen tambahan.'; upgrade_lab ;;
    brief) root_required; brief ;;
    watch) root_required; watch_lab ;;
    score-daemon) score_daemon ;;
    check) root_required; check_lab "${1:-}" ;;
    hint) root_required; installed_required; hint "${1:-}" ;;
    solutions) solutions ;;
    status) root_required; status_lab ;;
    uninstall) uninstall_lab ;;
    *) usage; die "Perintah tidak dikenal: $command" ;;
  esac
}

main "$@"
