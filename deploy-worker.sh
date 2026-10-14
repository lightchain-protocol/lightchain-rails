#!/usr/bin/env bash
# =============================================================================
#  Lightchain GPU worker, one shot.
#
#  Turns a fresh Ubuntu 22.04 / 24.04 server with an NVIDIA GPU into a
#  Lightchain inference worker: NVIDIA driver, Ollama with the models you
#  choose, the official lightchain-worker binary, a hardened systemd service,
#  firewall, and the on-chain registration (stake) once the worker address is
#  funded. Idempotent: run it again at any point and it continues where it
#  stopped.
#
#  One-liner (a hosting provider post-install hook or your own shell):
#    curl -fsSL https://raw.githubusercontent.com/lightchain-protocol/lightchain-rails/main/deploy-worker.sh \
#      | bash -s -- --network mainnet --models llama3-8b --auto-reboot
#
#  What it does
#    1. Preflight: root, OS, GPU on the bus, RAM, CPU, free disk.
#    2. Installs ufw, fail2ban, chrony, unattended-upgrades; firewall is SSH
#       only (port read from sshd).
#    3. Installs the NVIDIA driver if nvidia-smi is missing, arms a one-shot
#       systemd unit that resumes this deploy after the reboot, and reboots
#       (with --auto-reboot) or asks you to (exit 3).
#    4. Installs Ollama bound to localhost, tuned for serving, pulls the
#       models under the exact names the chain expects, warms the first one.
#    5. Installs /usr/local/bin/lightchain-worker from the official GitHub
#       release (the installer checks the SHA-256 of the build) and the
#       `lcw` helper.
#    6. Writes /etc/lightchain/worker/env (0600) and a hardened systemd unit.
#       Model list and parallelism survive re-runs unless you pass new flags.
#    7. Runs `lightchain-worker init`: generates (or imports) the worker key,
#       prints the address to fund, registers on-chain once funded, runs the
#       preflight checks. Starts the service and verifies it.
#
#  Every run logs to /var/log/lightchain-deploy.log and writes a machine-
#  readable result to /etc/lightchain/deploy-status.json.
#  Exit codes: 0 running, 1 failed, 2 needs funding (address in the status
#  file), 3 reboot required, 4 preflight refused.
#
#  The worker needs no inbound ports. The worker key is generated on this
#  machine and never leaves it. Back up /etc/lightchain/worker/ once done.
# =============================================================================
set -Eeuo pipefail

VERSION="1.0.0"
SCRIPT_URL="https://raw.githubusercontent.com/lightchain-protocol/lightchain-rails/main/deploy-worker.sh"
LOG=/var/log/lightchain-deploy.log
STATUS=/etc/lightchain/deploy-status.json
LOCK=/var/lock/lightchain-deploy.lock
RESUME_UNIT=lightchain-deploy-resume
RESUME_DIR=/usr/local/lib/lightchain
ORIG_ARGS=("$@")

NETWORK="mainnet"
MODELS=""; MODELS_DEFAULT="llama3-8b"
IMPORT_KEY_FILE=""
PARALLEL=""
MODELS_DISK=""
FIREWALL=1
AUTO_REBOOT=0
DRY_RUN=0
UNINSTALL=0
PURGE=0
PURGE_KEYS=0
WORKER_VERSION="${LIGHTCHAIN_WORKER_VERSION:-}"   # empty = latest release

usage() {
  cat <<EOF
Lightchain GPU worker one-shot deploy $VERSION

Usage (as root):
  bash deploy-worker.sh [options]

  --network mainnet|testnet     default mainnet
  --models a,b,c                chain model names; default llama3-8b on first run, kept from the env file on re-runs
  --import-key-file FILE        reuse an existing worker key (hex private key in a root-only file)
  --parallel N                  Ollama parallel slots; default by VRAM (2 / 4 / 8), kept on re-runs
  --models-disk /dev/sdX        format and mount a second disk for the model store
  --auto-reboot                 reboot by itself after a driver install and resume automatically
  --no-firewall                 leave ufw alone
  --dry-run                     preflight and print the plan, change nothing
  --uninstall                   stop and remove the service, helper, binary and Ollama profile; keep keys, state and models
  --purge                       with --uninstall: also delete the state directory and the models
  --purge-keys                  with --uninstall: also delete /etc/lightchain/worker (the worker key: unrecoverable, deregister first)
  --version                     print the script version
  -h, --help                    this text

Exit codes: 0 running, 1 failed, 2 needs funding, 3 reboot required, 4 preflight refused.
Log: $LOG    Status: $STATUS
EOF
  exit "${1:-0}"
}
while [ $# -gt 0 ]; do
  case "$1" in
    --network) NETWORK="$2"; shift 2;;
    --models) MODELS="$2"; shift 2;;
    --import-key-file) IMPORT_KEY_FILE="$2"; shift 2;;
    --parallel) PARALLEL="$2"; shift 2;;
    --models-disk) MODELS_DISK="$2"; shift 2;;
    --auto-reboot) AUTO_REBOOT=1; shift;;
    --no-firewall) FIREWALL=0; shift;;
    --dry-run) DRY_RUN=1; shift;;
    --uninstall) UNINSTALL=1; shift;;
    --purge) PURGE=1; shift;;
    --purge-keys) PURGE_KEYS=1; shift;;
    --version) echo "deploy-worker.sh $VERSION"; exit 0;;
    -h|--help) usage 0;;
    *) echo "unknown option: $1" >&2; usage 1;;
  esac
done

# ---- network table (from the official run-node docs) ------------------------
case "$NETWORK" in
  mainnet)
    CHAIN_ID=9200
    RPC_URL="https://rpc.mainnet.lightchain.ai"
    BEACON_API_URL="https://beacon.mainnet.lightchain.ai"
    WORKER_GATEWAY_URL="https://worker-gateway-v2.mainnet.lightchain.ai"
    WORKER_REGISTRY_ADDRESS="0x0000000000000000000000000000000000001002"
    JOB_REGISTRY_ADDRESS="0xfB15F90298e4CcD7106E76fFB5e520315cC42B0b"
    SESSION_MANAGER_ADDRESS="0xfFFCed75eF4Cdae0Cc33A27Bb46531B957a9f4e7"
    AI_CONFIG_ADDRESS="0x24D11533C354092ed6E18b964257819cE78Ce77D"
    MODEL_LIST_URL="https://chat-api.mainnet.lightchain.ai/api/indexer/models"
    STAKE_HINT="50,000 LCAI stake plus about 50 LCAI for gas";;
  testnet)
    CHAIN_ID=8200
    RPC_URL="https://rpc.testnet.lightchain.ai"
    BEACON_API_URL="https://beacon.testnet.lightchain.ai"
    WORKER_GATEWAY_URL="https://worker-gateway.testnet.lightchain.ai"
    WORKER_REGISTRY_ADDRESS="0x0000000000000000000000000000000000001002"
    JOB_REGISTRY_ADDRESS="0x531b3A87c5D785441B9cF55b98169F20FD9056a7"
    SESSION_MANAGER_ADDRESS="0x86AdA80864e87dE2275200FeE905b5C32b32Bf68"
    AI_CONFIG_ADDRESS="0xeCF4Ca5Ba6D97ae586993e170764a1E92231b67e"
    MODEL_LIST_URL="https://chat-api.testnet.lightchain.ai/api/indexer/models"
    STAKE_HINT="5,000 LCAI-t stake plus about 50 LCAI-t for gas";;
  *) echo "--network must be mainnet or testnet" >&2; exit 1;;
esac
ENV_DIR=/etc/lightchain/worker
STATE_DIR=/var/lib/lightchain-worker
UNIT=lightchain-worker

# ---- helpers ----------------------------------------------------------------
if [ -t 1 ]; then C1=$'\033[1;36m'; C2=$'\033[1;32m'; C3=$'\033[1;33m'; C4=$'\033[1;31m'; C0=$'\033[0m'; else C1=""; C2=""; C3=""; C4=""; C0=""; fi
STEP="startup"; ADDR=""
log()  { STEP="$*"; printf '%s==> %s%s\n' "$C1" "$*" "$C0"; }
ok()   { printf '%s    %s%s\n' "$C2" "$*" "$C0"; }
warn() { printf '%s    %s%s\n' "$C3" "$*" "$C0"; }
die()  { printf '%sERROR: %s%s\n' "$C4" "$*" "$C0" >&2; write_status failed; exit "${2:-1}"; }
write_status() { # state
  mkdir -p "$(dirname "$STATUS")"
  printf '{"script":"deploy-worker.sh","version":"%s","network":"%s","role":"worker","state":"%s","address":"%s","models":"%s","updated":"%s"}\n' \
    "$VERSION" "$NETWORK" "$1" "$ADDR" "${MODELS:-}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$STATUS"
}
on_err() { # line exit-code
  [ "${BASH_SUBSHELL:-0}" = 0 ] || exit "$2"
  printf '%sERROR: step "%s" failed at line %s (exit %s). Full log: %s%s\n' "$C4" "$STEP" "$1" "$2" "$LOG" "$C0" >&2
  write_status failed; exit "$2"
}
retry() { # n cmd...
  local n=$1 i; shift
  for i in $(seq 1 "$n"); do
    "$@" && return 0
    [ "$i" = "$n" ] && break
    warn "attempt $i/$n failed: $1; retrying in $((i*5))s"; sleep $((i*5))
  done
  return 1
}
ssh_ports() { # every port sshd is configured for or listening on; 22 if none found
  local p
  p=$( { grep -shE '^\s*Port\s+[0-9]+' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null | awk '{print $2}'
         ss -tlnpH 2>/dev/null | awk '/"sshd"/ {sub(/.*:/,"",$4); print $4}'; } | grep -E '^[0-9]+$' | sort -un | tr '\n' ' ')
  echo "${p:-22}"
}
env_get() { grep -s "^$1=" "$ENV_DIR/env" | head -1 | cut -d= -f2- || true; }
APT="apt-get -o DPkg::Lock::Timeout=600 -qq"
CURL="curl -fsSL --retry 3 --retry-delay 5 --retry-all-errors"

[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 4; }
mkdir -p "$(dirname "$LOG")"
exec > >(tee -a "$LOG") 2>&1
exec 9>"$LOCK"; flock -n 9 || { echo "another Lightchain deploy is already running (lock $LOCK)" >&2; exit 1; }
trap 'on_err $LINENO $?' ERR
echo; echo "---- deploy-worker.sh $VERSION  $(date -u +%Y-%m-%dT%H:%M:%SZ)  network=$NETWORK args: ${ORIG_ARGS[*]:-}"

# ---- uninstall --------------------------------------------------------------
if [ "$UNINSTALL" = 1 ]; then
  log "Uninstalling the Lightchain worker"
  warn "this does not deregister: the stake stays bound to the worker key until you run 'lcw deregister' and the dispute window passes"
  systemctl disable --now "$UNIT" >/dev/null 2>&1 || true
  systemctl disable --now "$RESUME_UNIT" >/dev/null 2>&1 || true
  rm -f "/etc/systemd/system/$UNIT.service" "/etc/systemd/system/$RESUME_UNIT.service" /usr/local/bin/lcw /usr/local/bin/lightchain-worker
  rm -rf "$RESUME_DIR"
  rm -f /etc/systemd/system/ollama.service.d/lightchain.conf
  systemctl daemon-reload; systemctl try-restart ollama >/dev/null 2>&1 || true
  ok "service, helper, binary and Ollama serving profile removed"
  if [ "$PURGE" = 1 ]; then
    OLD=$(env_get SUPPORTED_MODELS); IFS=, read -ra OLD_ARR <<< "$OLD"
    for m in "${OLD_ARR[@]}"; do m=$(echo "$m" | xargs); [ -n "$m" ] && ollama rm "$m" >/dev/null 2>&1 || true; done
    rm -rf "$STATE_DIR"; ok "state directory and listed models deleted"
  else ok "state kept in $STATE_DIR, models kept in Ollama (add --purge to delete them)"; fi
  if [ "$PURGE_KEYS" = 1 ]; then rm -rf "$ENV_DIR"; ok "$ENV_DIR deleted (worker key gone)"; else ok "keys kept in $ENV_DIR (add --purge-keys to delete them; back them up first)"; fi
  write_status removed
  exit 0
fi

# ---- 1. preflight -----------------------------------------------------------
log "Preflight"
. /etc/os-release
case "${VERSION_ID:-}" in 22.04|24.04) ;; *) warn "tested on Ubuntu 22.04 and 24.04, you have ${PRETTY_NAME:-unknown}; continuing";; esac
ARCH=$(dpkg --print-architecture 2>/dev/null || uname -m)
[ "$ARCH" = amd64 ] || warn "this machine is $ARCH; the worker and Ollama ship arm64 builds but NVIDIA on arm64 is untested here"
command -v lspci >/dev/null || { $APT update >/dev/null 2>&1 || true; $APT install -y pciutils >/dev/null 2>&1 || true; }
lspci 2>/dev/null | grep -qi nvidia || die "no NVIDIA GPU found on the PCI bus" 4
RAM_GB=$(( $(awk '/MemTotal/{print $2}' /proc/meminfo) / 1024 / 1024 ))
CPUS=$(nproc)
FREE_GB=$(df -BG --output=avail / | tail -1 | tr -dc 0-9)
MIN_FREE=60; [ -n "$MODELS_DISK" ] && MIN_FREE=20
[ "$RAM_GB" -ge 16 ]          || die "${RAM_GB} GB RAM: a worker needs at least 16 GB (32 GB recommended)" 4
[ "$FREE_GB" -ge "$MIN_FREE" ] || die "${FREE_GB} GB free on /: a worker needs at least ${MIN_FREE} GB (100 GB NVMe recommended, or --models-disk)" 4
[ "$RAM_GB" -ge 32 ]          || warn "${RAM_GB} GB RAM is below the recommended 32 GB"
[ "$CPUS" -ge 8 ]             || warn "$CPUS vCPU is below the recommended 8"
[ "$FREE_GB" -ge 100 ] || [ -n "$MODELS_DISK" ] || warn "${FREE_GB} GB free is below the recommended 100 GB; models are 5 to 40 GB each"
if [ -n "$IMPORT_KEY_FILE" ] && [ ! -f "$ENV_DIR/keystore.json" ]; then [ -f "$IMPORT_KEY_FILE" ] || die "--import-key-file: $IMPORT_KEY_FILE not found" 4; fi
# flags win; otherwise keep what the previous run wrote; otherwise defaults
MODELS_FROM="flag"; PARALLEL_FROM="flag"
if [ -z "$MODELS" ]; then MODELS=$(env_get SUPPORTED_MODELS); MODELS_FROM="env file"; fi
if [ -z "$MODELS" ]; then MODELS="$MODELS_DEFAULT"; MODELS_FROM="default"; fi
if [ -z "$PARALLEL" ]; then PARALLEL=$(env_get MAX_CONCURRENT_JOBS); PARALLEL_FROM="env file"; fi
[ -z "$PARALLEL" ] || [[ "$PARALLEL" =~ ^[0-9]+$ ]] || die "--parallel must be a number" 4
SSH_PORTS=$(ssh_ports)
ok "${PRETTY_NAME:-Ubuntu} $ARCH, $CPUS vCPU, ${RAM_GB} GB RAM, ${FREE_GB} GB free, NVIDIA GPU present, SSH on port(s) $SSH_PORTS"
ok "models: $MODELS ($MODELS_FROM)"
if [ "$DRY_RUN" = 1 ]; then
  cat <<EOF
    plan: worker on $NETWORK (chain $CHAIN_ID), models $MODELS, parallel ${PARALLEL:-auto by VRAM}
          driver: $(command -v nvidia-smi >/dev/null && nvidia-smi >/dev/null 2>&1 && echo "present" || echo "to install, then reboot ($( [ "$AUTO_REBOOT" = 1 ] && echo automatic || echo "manual, exit 3"))")
          worker binary: ${WORKER_VERSION:-latest release}$( [ -n "$MODELS_DISK" ] && echo ", model store on $MODELS_DISK")
          firewall: $( [ "$FIREWALL" = 1 ] && echo "SSH $SSH_PORTS only" || echo "untouched")
    dry run: nothing changed
EOF
  exit 0
fi
write_status deploying

# ---- 2. base packages + firewall -------------------------------------------
log "Installing packages"
export DEBIAN_FRONTEND=noninteractive
retry 3 $APT update || die "apt-get update failed"
retry 3 $APT install -y ca-certificates curl gnupg ufw fail2ban chrony unattended-upgrades jq openssl pciutils iproute2 >/dev/null || die "package install failed"
printf 'APT::Periodic::Update-Package-Lists "1";\nAPT::Periodic::Unattended-Upgrade "1";\n' > /etc/apt/apt.conf.d/20auto-upgrades
systemctl enable --now chrony >/dev/null 2>&1 || true
if [ "$FIREWALL" = 1 ]; then
  ufw --force reset >/dev/null; ufw default deny incoming >/dev/null; ufw default allow outgoing >/dev/null
  for p in $SSH_PORTS; do ufw allow "$p/tcp" >/dev/null; done
  ufw --force enable >/dev/null
  cat > /etc/fail2ban/jail.d/lightchain.conf <<EOF
[DEFAULT]
backend = systemd
bantime = 1h
findtime = 10m
maxretry = 5
[sshd]
enabled = true
port = $(echo "$SSH_PORTS" | tr ' ' ',' | sed 's/,$//')
EOF
  systemctl enable --now fail2ban >/dev/null 2>&1; systemctl restart fail2ban
  ok "ufw: SSH $SSH_PORTS only; fail2ban active"
fi

# ---- 3. NVIDIA driver -------------------------------------------------------
if ! command -v nvidia-smi >/dev/null || ! nvidia-smi >/dev/null 2>&1; then
  log "Installing the NVIDIA driver (ubuntu-drivers)"
  retry 3 $APT install -y ubuntu-drivers-common >/dev/null || die "ubuntu-drivers-common install failed"
  ubuntu-drivers install >/dev/null 2>&1 || ubuntu-drivers autoinstall >/dev/null 2>&1 || die "driver install failed; see $LOG"
  # arm a one-shot unit that resumes this deploy, with the same arguments, after the reboot
  mkdir -p "$RESUME_DIR"
  SELF="${BASH_SOURCE[0]:-}"
  if [ -n "$SELF" ] && [ -f "$SELF" ] && [ "$(basename "$SELF")" != bash ]; then cp "$SELF" "$RESUME_DIR/deploy-worker.sh"; RUN="bash $RESUME_DIR/deploy-worker.sh"
  else RUN="curl -fsSL --retry 5 --retry-delay 10 --retry-all-errors $SCRIPT_URL | bash -s --"; fi
  { echo '#!/usr/bin/env bash'; echo 'set -e'; printf '%s' "$RUN"; [ ${#ORIG_ARGS[@]} -eq 0 ] || printf ' %q' "${ORIG_ARGS[@]}"; echo; } > "$RESUME_DIR/resume.sh"
  chmod 700 "$RESUME_DIR/resume.sh"
  cat > "/etc/systemd/system/$RESUME_UNIT.service" <<EOF
[Unit]
Description=Resume the Lightchain worker deploy after the driver reboot
After=network-online.target
Wants=network-online.target
ConditionPathExists=$RESUME_DIR/resume.sh

[Service]
Type=oneshot
ExecStart=$RESUME_DIR/resume.sh
ExecStartPost=/bin/systemctl disable $RESUME_UNIT.service
StandardOutput=journal+console
StandardError=journal+console
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload; systemctl enable "$RESUME_UNIT" >/dev/null 2>&1
  write_status reboot-required
  if [ "$AUTO_REBOOT" = 1 ]; then
    ok "driver installed; rebooting now, the deploy resumes by itself (journalctl -u $RESUME_UNIT -f after the reboot)"
    sleep 2; systemctl reboot; exit 3
  fi
  cat <<EOF

 The NVIDIA driver is installed but not loaded. Reboot; the deploy resumes
 by itself with the same options (watch it: journalctl -u $RESUME_UNIT -f).
    reboot
EOF
  exit 3
fi
systemctl disable "$RESUME_UNIT" >/dev/null 2>&1 || true; rm -f "/etc/systemd/system/$RESUME_UNIT.service"; rm -rf "$RESUME_DIR"; systemctl daemon-reload
GPU=$(nvidia-smi --query-gpu=name,memory.total --format=csv,noheader | head -1)
VRAM_MB=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits | head -1 | tr -dc 0-9)
ok "GPU: $GPU"
nvidia-smi -pm 1 >/dev/null 2>&1 || true
[ "$VRAM_MB" -ge 8000 ] || warn "less than 8 GB of VRAM: llama3-8b will not fit; choose a smaller model"

# ---- 4. Ollama ----------------------------------------------------------------
if ! command -v ollama >/dev/null; then
  log "Installing Ollama"
  $CURL https://ollama.com/install.sh | sh >/dev/null 2>&1 || die "Ollama install failed"
fi
if [ -n "$MODELS_DISK" ]; then
  log "Mounting $MODELS_DISK at /opt/ollama for the model store"
  [ -b "$MODELS_DISK" ] || die "--models-disk: $MODELS_DISK is not a block device"
  blkid "$MODELS_DISK" >/dev/null 2>&1 || mkfs.ext4 -q -L ollama "$MODELS_DISK"
  mkdir -p /opt/ollama
  grep -q " /opt/ollama " /etc/fstab || echo "LABEL=ollama /opt/ollama ext4 defaults,nofail 0 2" >> /etc/fstab
  mountpoint -q /opt/ollama || mount /opt/ollama
  mkdir -p /opt/ollama/models; chown -R ollama:ollama /opt/ollama
  MODELS_DIR=/opt/ollama/models
else
  MODELS_DIR=/usr/share/ollama/.ollama/models
fi
if [ -z "$PARALLEL" ]; then
  if [ "$VRAM_MB" -ge 40000 ]; then PARALLEL=8; elif [ "$VRAM_MB" -ge 20000 ]; then PARALLEL=4; else PARALLEL=2; fi
  PARALLEL_FROM="auto by VRAM"
fi
mkdir -p /etc/systemd/system/ollama.service.d
OLLAMA_CONF=/etc/systemd/system/ollama.service.d/lightchain.conf
cat > "$OLLAMA_CONF.new" <<EOF
[Unit]
StartLimitIntervalSec=0
[Service]
# written by deploy-worker.sh $VERSION; serving profile measured on L4 / A100 class cards
Environment="OLLAMA_HOST=127.0.0.1:11434"
Environment="OLLAMA_MODELS=$MODELS_DIR"
Environment="OLLAMA_KEEP_ALIVE=-1"
Environment="OLLAMA_MAX_LOADED_MODELS=2"
Environment="OLLAMA_NUM_PARALLEL=$PARALLEL"
Environment="OLLAMA_CONTEXT_LENGTH=8192"
Environment="OLLAMA_FLASH_ATTENTION=1"
Environment="OLLAMA_KV_CACHE_TYPE=q8_0"
EOF
# restart Ollama only when the profile changed or it is down: a needless restart drops every loaded model
if ! cmp -s "$OLLAMA_CONF.new" "$OLLAMA_CONF" || ! systemctl is-active -q ollama; then
  mv "$OLLAMA_CONF.new" "$OLLAMA_CONF"; systemctl daemon-reload; systemctl enable ollama >/dev/null 2>&1; systemctl restart ollama
else rm -f "$OLLAMA_CONF.new"; fi
for i in $(seq 1 30); do curl -s -m 2 http://127.0.0.1:11434/api/tags >/dev/null && break; sleep 1; done
curl -s -m 2 http://127.0.0.1:11434/api/tags >/dev/null || die "Ollama did not come up on 127.0.0.1:11434 (journalctl -u ollama)"
ok "Ollama $(ollama --version 2>/dev/null | awk '{print $NF}') on 127.0.0.1:11434, $PARALLEL parallel slots ($PARALLEL_FROM), models in $MODELS_DIR"

# ---- 5. models --------------------------------------------------------------
# On-chain, a model is keccak256 of its NAME, and the worker hands that same
# name to Ollama. The Ollama tag for a chain name is not always identical:
# "llama3-8b" on chain is Ollama's "llama3:8b", copied under the chain name.
ollama_tag_for() { case "$1" in llama3-8b) echo "llama3:8b";; *) echo "$1";; esac; }
has_model() { ollama list 2>/dev/null | awk 'NR>1{print $1}' | grep -qx -e "$1" -e "$1:latest"; }
log "Pulling models: $MODELS"
IFS=, read -ra MODEL_ARR <<< "$MODELS"
FIRST_MODEL=""
for m in "${MODEL_ARR[@]}"; do
  m=$(echo "$m" | xargs); [ -n "$m" ] || continue
  [ -n "$FIRST_MODEL" ] || FIRST_MODEL="$m"
  if has_model "$m"; then ok "$m already present"; continue; fi
  tag=$(ollama_tag_for "$m")
  retry 3 ollama pull "$tag" >/dev/null 2>&1 || die "ollama pull $tag failed; is $m on the $NETWORK model list ($MODEL_LIST_URL)?"
  if [ "$tag" != "$m" ]; then ollama cp "$tag" "$m" >/dev/null; ollama rm "$tag" >/dev/null 2>&1 || true; fi
  ok "$m ready"
done
# models dropped from the list since the previous run are removed; anything you pulled by hand is left alone
OLD_MODELS=$(env_get SUPPORTED_MODELS); IFS=, read -ra OLD_ARR <<< "$OLD_MODELS"
for om in "${OLD_ARR[@]}"; do
  om=$(echo "$om" | xargs); [ -n "$om" ] || continue
  printf ',%s,' "$MODELS" | grep -q ",$om," && continue
  ollama rm "$om" >/dev/null 2>&1 && ok "$om removed (no longer in the model list)" || true
done
log "Warming up $FIRST_MODEL"
curl -s -m 300 http://127.0.0.1:11434/api/generate -d "{\"model\":\"$FIRST_MODEL\",\"prompt\":\"hi\",\"stream\":false,\"keep_alive\":-1}" >/dev/null \
  && ok "$FIRST_MODEL loaded on the GPU" || warn "warm-up of $FIRST_MODEL did not finish in 5 minutes; the first job will load it"

# ---- 6. worker binary + lcw -------------------------------------------------
if ! command -v lightchain-worker >/dev/null || [ -n "$WORKER_VERSION" ]; then
  log "Installing lightchain-worker ${WORKER_VERSION:-latest}"
  if [ -n "$WORKER_VERSION" ]; then
    $CURL "https://github.com/lightchain-protocol/lightchain-worker/releases/download/$WORKER_VERSION/install.sh" | LIGHTCHAIN_WORKER_VERSION="$WORKER_VERSION" sh || die "worker install failed"
  else
    $CURL https://github.com/lightchain-protocol/lightchain-worker/releases/latest/download/install.sh | sh || die "worker install failed"
  fi
fi
cat > /usr/local/bin/lcw <<'EOF'
#!/bin/sh
# lcw: run the Lightchain worker CLI with the service's env file loaded
set -a; . /etc/lightchain/worker/env; set +a
exec /usr/local/bin/lightchain-worker "$@"
EOF
chmod 755 /usr/local/bin/lcw
ok "lightchain-worker at $(command -v lightchain-worker) ($(stat -c %s "$(command -v lightchain-worker)") bytes), helper /usr/local/bin/lcw"

# ---- 7. config + unit -------------------------------------------------------
log "Writing $ENV_DIR/env"
mkdir -p "$ENV_DIR" "$STATE_DIR"; chmod 700 "$ENV_DIR" "$STATE_DIR"
KS_PASS=$(env_get WORKER_KEYSTORE_PASSWORD)   # keep: it unlocks an existing keystore
[ -n "$KS_PASS" ] || KS_PASS=$(openssl rand -hex 24)
cat > "$ENV_DIR/env" <<EOF
# Lightchain $NETWORK worker, written by deploy-worker.sh $VERSION on $(date -u +%Y-%m-%dT%H:%MZ)
# Re-running the script keeps SUPPORTED_MODELS and MAX_CONCURRENT_JOBS unless you pass --models / --parallel.
CHAIN_ID=$CHAIN_ID
RPC_URL=$RPC_URL
BEACON_API_URL=$BEACON_API_URL
WORKER_REGISTRY_ADDRESS=$WORKER_REGISTRY_ADDRESS
JOB_REGISTRY_ADDRESS=$JOB_REGISTRY_ADDRESS
SESSION_MANAGER_ADDRESS=$SESSION_MANAGER_ADDRESS
AI_CONFIG_ADDRESS=$AI_CONFIG_ADDRESS

# external worker profile: sortition claims, results streamed through the gateway, no inbound ports
SORTITION_ENABLED=true
SORTITION_POLL_INTERVAL=1s
WORKER_GATEWAY_URL=$WORKER_GATEWAY_URL
BLOB_MODE=beacon

# identity (init creates both keys; back this directory up)
WORKER_KEYSTORE_PATH=$ENV_DIR/keystore.json
WORKER_KEYSTORE_PASSWORD=$KS_PASS
ENCRYPTION_KEYSTORE_PATH=$ENV_DIR/encryption.key

# models and inference
SUPPORTED_MODELS=$MODELS
OLLAMA_URL=http://127.0.0.1:11434
OLLAMA_TIMEOUT=300s
MAX_CONCURRENT_JOBS=$PARALLEL

# in-flight jobs get this long to finish on stop (keep under TimeoutStopSec in the unit)
SHUTDOWN_TIMEOUT=240s

# state that must survive restarts
SESSION_KEY_FILE=$STATE_DIR/session-keys.enc
SORTITION_STATE_DIR=$STATE_DIR/sortition-state
RELEASE_STATE_PATH=$STATE_DIR/release_state.json

WORKER_METRICS_ADDR=127.0.0.1:9111
LOG_FORMAT=text
EOF
chmod 600 "$ENV_DIR/env"
cat > /etc/systemd/system/$UNIT.service <<EOF
[Unit]
Description=Lightchain worker ($NETWORK)
After=network-online.target ollama.service
Wants=network-online.target
Requires=ollama.service
StartLimitIntervalSec=0

[Service]
EnvironmentFile=$ENV_DIR/env
ExecStart=/usr/local/bin/lightchain-worker run
Restart=always
RestartSec=5
KillSignal=SIGTERM
TimeoutStopSec=300
# hardening
NoNewPrivileges=true
ProtectSystem=strict
ReadWritePaths=$ENV_DIR $STATE_DIR
ProtectHome=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
ok "unit $UNIT written"

# ---- 8. init: key, funding, registration, preflight ------------------------
log "Running lightchain-worker init"
INIT_ARGS=(--yes)
if [ ! -f "$ENV_DIR/keystore.json" ]; then
  if [ -n "$IMPORT_KEY_FILE" ]; then INIT_ARGS+=(--import-key-file "$IMPORT_KEY_FILE"); else INIT_ARGS+=(--generate); fi
fi
set +e
lcw init "${INIT_ARGS[@]}"; rc=$?
set -e
ADDR=$(jq -r '.address // empty' "$ENV_DIR/keystore.json" 2>/dev/null || true)
[ -n "$ADDR" ] && ADDR="0x$ADDR"
if [ $rc -ne 0 ]; then
  write_status needs-funding
  cat <<EOF

=============================================================================
 Worker key is ready but registration did not complete (see the init output).
 Most often the address simply is not funded yet:

   worker address:  ${ADDR:-see $ENV_DIR/keystore.json}
   send:            $STAKE_HINT  (the init output prints the exact minimum)

 Then run this script again with the same options; it registers and starts
 the worker. Back up $ENV_DIR/ now: it holds the worker key, the encryption
 key and the password that unlocks them.
 Machine-readable: $STATUS
=============================================================================
EOF
  exit 2
fi

# ---- 9. start + verify ------------------------------------------------------
log "Starting $UNIT"
START_TS=$(date +%s)
systemctl enable --now $UNIT >/dev/null 2>&1; systemctl restart $UNIT
AUTHED=0
for i in $(seq 1 18); do
  sleep 5
  if ! systemctl is-active -q $UNIT; then
    journalctl -u $UNIT --no-pager -n 30 -o cat | cut -c1-160
    die "$UNIT stopped right after start; see the lines above and: journalctl -u $UNIT"
  fi
  if journalctl -u $UNIT --since "@$START_TS" -o cat 2>/dev/null | grep -q 'authenticated with worker-gateway'; then AUTHED=1; break; fi
done
if [ "$AUTHED" = 1 ]; then ok "service active, authenticated with the worker gateway"; else warn "service active but no gateway authentication in 90 s yet; watch: journalctl -u $UNIT -f"; fi

# ---- 10. cleanup ------------------------------------------------------------
$APT clean >/dev/null 2>&1 || true
write_status running
cat <<EOF

=============================================================================
 Lightchain $NETWORK worker ${ADDR:-} is running
   status:    systemctl status $UNIT ; lcw status  (machine-readable: $STATUS)
   logs:      journalctl -u $UNIT -f    (look for: authenticated with worker-gateway)
   earnings:  lcw balance ; lcw withdraw
   stop:      systemctl stop $UNIT      (drains in-flight jobs, up to 4 minutes)
   leave:     lcw deregister            (withdraws the stake after the dispute window)
   models:    re-run this script with --models a,b,c (pulls new ones, removes dropped ones)
   update:    LIGHTCHAIN_WORKER_VERSION=vX.Y.Z and re-run
   remove:    re-run with --uninstall [--purge] [--purge-keys]
   GPU:       $GPU, $PARALLEL parallel Ollama slots
   deploy log: $LOG

 Back up $ENV_DIR/ (worker key, encryption key, password). Losing the
 encryption key after registering means the worker cannot serve sessions.
=============================================================================
EOF
journalctl -u $UNIT --no-pager -n 15 -o cat | cut -c1-160 || true
