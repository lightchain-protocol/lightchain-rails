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
#  Usage (as root):
#    bash deploy-worker.sh [--network mainnet|testnet] [--models a,b,c]
#                          [--import-key-file FILE] [--parallel N]
#                          [--models-disk /dev/sdX] [--no-firewall]
#
#  One-liner (RedSwitches post-install hook or your own shell):
#    curl -fsSL https://raw.githubusercontent.com/lightchain-protocol/redswitches-deploy/main/deploy-worker.sh \
#      | bash -s -- --network mainnet --models llama3-8b
#
#  What it does
#    1. Installs the NVIDIA driver if nvidia-smi is missing (then asks you to
#       reboot and run the script again), ufw, fail2ban, unattended-upgrades.
#    2. Installs Ollama bound to localhost, tuned for serving, and pulls the
#       models under the exact names the chain expects.
#    3. Installs /usr/local/bin/lightchain-worker from the official GitHub
#       release (the installer checks the SHA-256 of the build).
#    4. Writes /etc/lightchain/worker/env (0600) with the network addresses
#       and a random keystore password, and a systemd unit.
#    5. Runs `lightchain-worker init`: generates (or imports) the worker key,
#       prints the address to fund, registers on-chain once funded, runs the
#       preflight checks, and starts the service.
#
#  The worker needs no inbound ports. Only SSH is open.
#  The worker key is generated on this machine and never leaves it. Back up
#  /etc/lightchain/worker/ once the script finishes.
# =============================================================================
set -euo pipefail

NETWORK="mainnet"
MODELS="llama3-8b"
IMPORT_KEY_FILE=""
PARALLEL=""
MODELS_DISK=""
FIREWALL=1
WORKER_VERSION="${LIGHTCHAIN_WORKER_VERSION:-}"   # empty = latest release

usage() { sed -n '2,36p' "$0" | sed 's/^# \{0,2\}//'; exit "${1:-0}"; }
while [ $# -gt 0 ]; do
  case "$1" in
    --network) NETWORK="$2"; shift 2;;
    --models) MODELS="$2"; shift 2;;
    --import-key-file) IMPORT_KEY_FILE="$2"; shift 2;;
    --parallel) PARALLEL="$2"; shift 2;;
    --models-disk) MODELS_DISK="$2"; shift 2;;
    --no-firewall) FIREWALL=0; shift;;
    -h|--help) usage 0;;
    *) echo "unknown option: $1" >&2; usage 1;;
  esac
done

log()  { printf '\033[1;36m==> %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m    %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m    %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || die "run as root"
. /etc/os-release
case "${VERSION_ID:-}" in 22.04|24.04) ;; *) warn "tested on Ubuntu 22.04 and 24.04, you have ${PRETTY_NAME:-unknown}; continuing";; esac

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
  *) die "--network must be mainnet or testnet";;
esac
ENV_DIR=/etc/lightchain/worker
STATE_DIR=/var/lib/lightchain-worker
UNIT=lightchain-worker

# ---- 1. base packages + firewall -------------------------------------------
log "Installing packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq ca-certificates curl gnupg ufw fail2ban chrony unattended-upgrades jq openssl pciutils >/dev/null
printf 'APT::Periodic::Update-Package-Lists "1";\nAPT::Periodic::Unattended-Upgrade "1";\n' > /etc/apt/apt.conf.d/20auto-upgrades
systemctl enable --now chrony >/dev/null 2>&1 || true
if [ "$FIREWALL" = 1 ]; then
  ufw --force reset >/dev/null; ufw default deny incoming >/dev/null; ufw default allow outgoing >/dev/null
  ufw allow 22/tcp >/dev/null; ufw --force enable >/dev/null
  cat > /etc/fail2ban/jail.d/lightchain.conf <<'EOF'
[DEFAULT]
backend = systemd
bantime = 1h
findtime = 10m
maxretry = 5
[sshd]
enabled = true
EOF
  systemctl enable --now fail2ban >/dev/null 2>&1; systemctl restart fail2ban
  ok "ufw: SSH only; fail2ban active"
fi

# ---- 2. NVIDIA driver -------------------------------------------------------
if ! command -v nvidia-smi >/dev/null || ! nvidia-smi >/dev/null 2>&1; then
  lspci | grep -qi nvidia || die "no NVIDIA GPU found on the PCI bus"
  log "Installing the NVIDIA driver (ubuntu-drivers autoinstall)"
  apt-get install -y -qq ubuntu-drivers-common >/dev/null
  ubuntu-drivers install >/dev/null 2>&1 || ubuntu-drivers autoinstall
  cat <<EOF

 The NVIDIA driver is installed but not loaded. Reboot, then run this script
 again with the same options; it continues from here.
    reboot
EOF
  exit 0
fi
GPU=$(nvidia-smi --query-gpu=name,memory.total --format=csv,noheader | head -1)
VRAM_MB=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits | head -1)
ok "GPU: $GPU"
nvidia-smi -pm 1 >/dev/null 2>&1 || true
[ "$VRAM_MB" -ge 8000 ] || warn "less than 8 GB of VRAM: llama3-8b will not fit; choose a smaller model"

# ---- 3. Ollama ----------------------------------------------------------------
if ! command -v ollama >/dev/null; then
  log "Installing Ollama"
  curl -fsSL https://ollama.com/install.sh | sh >/dev/null 2>&1
fi
if [ -n "$MODELS_DISK" ]; then
  log "Mounting $MODELS_DISK at /opt/ollama for the model store"
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
fi
mkdir -p /etc/systemd/system/ollama.service.d
cat > /etc/systemd/system/ollama.service.d/lightchain.conf <<EOF
[Unit]
StartLimitIntervalSec=0
[Service]
# written by deploy-worker.sh; serving profile measured on L4 / A100 class cards
Environment="OLLAMA_HOST=127.0.0.1:11434"
Environment="OLLAMA_MODELS=$MODELS_DIR"
Environment="OLLAMA_KEEP_ALIVE=-1"
Environment="OLLAMA_MAX_LOADED_MODELS=2"
Environment="OLLAMA_NUM_PARALLEL=$PARALLEL"
Environment="OLLAMA_CONTEXT_LENGTH=8192"
Environment="OLLAMA_FLASH_ATTENTION=1"
Environment="OLLAMA_KV_CACHE_TYPE=q8_0"
EOF
systemctl daemon-reload; systemctl enable --now ollama >/dev/null 2>&1; systemctl restart ollama
for i in $(seq 1 30); do curl -s -m 2 http://127.0.0.1:11434/api/tags >/dev/null && break; sleep 1; done
ok "Ollama $(ollama --version 2>/dev/null | awk '{print $NF}') on 127.0.0.1:11434, $PARALLEL parallel slots, models in $MODELS_DIR"

# ---- 4. models --------------------------------------------------------------
# On-chain, a model is keccak256 of its NAME, and the worker hands that same
# name to Ollama. The Ollama tag for a chain name is not always identical:
# "llama3-8b" on chain is Ollama's "llama3:8b", copied under the chain name.
ollama_tag_for() { case "$1" in llama3-8b) echo "llama3:8b";; *) echo "$1";; esac; }
log "Pulling models: $MODELS"
IFS=, read -ra MODEL_ARR <<< "$MODELS"
for m in "${MODEL_ARR[@]}"; do
  m=$(echo "$m" | xargs)
  if ollama list | awk '{print $1}' | grep -qx "$m" || ollama list | awk '{print $1}' | grep -qx "$m:latest"; then ok "$m already present"; continue; fi
  tag=$(ollama_tag_for "$m")
  ollama pull "$tag" >/dev/null 2>&1 || die "ollama pull $tag failed; is $m on the $NETWORK model list ($MODEL_LIST_URL)?"
  [ "$tag" != "$m" ] && ollama cp "$tag" "$m" >/dev/null
  ok "$m ready"
done

# ---- 5. worker binary -------------------------------------------------------
if ! command -v lightchain-worker >/dev/null || [ -n "$WORKER_VERSION" ]; then
  log "Installing lightchain-worker ${WORKER_VERSION:-latest}"
  if [ -n "$WORKER_VERSION" ]; then
    curl -fsSL "https://github.com/lightchain-protocol/lightchain-worker/releases/download/$WORKER_VERSION/install.sh" | LIGHTCHAIN_WORKER_VERSION="$WORKER_VERSION" sh
  else
    curl -fsSL https://github.com/lightchain-protocol/lightchain-worker/releases/latest/download/install.sh | sh
  fi
fi
ok "lightchain-worker installed at $(command -v lightchain-worker) ($(stat -c %s "$(command -v lightchain-worker)") bytes)"

# ---- 6. config + unit -------------------------------------------------------
log "Writing $ENV_DIR/env"
mkdir -p "$ENV_DIR" "$STATE_DIR"; chmod 700 "$ENV_DIR" "$STATE_DIR"
if [ -f "$ENV_DIR/env" ] && grep -q '^WORKER_KEYSTORE_PASSWORD=' "$ENV_DIR/env"; then
  KS_PASS=$(grep '^WORKER_KEYSTORE_PASSWORD=' "$ENV_DIR/env" | cut -d= -f2-)   # keep: it unlocks an existing keystore
else
  KS_PASS=$(openssl rand -hex 24)
fi
MAXJOBS=$PARALLEL
cat > "$ENV_DIR/env" <<EOF
# Lightchain $NETWORK worker, written by deploy-worker.sh on $(date -u +%Y-%m-%dT%H:%MZ)
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
MAX_CONCURRENT_JOBS=$MAXJOBS

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
# lcw: run the worker CLI with the env file loaded (status, balance, withdraw, deregister, ...)
cat > /usr/local/bin/lcw <<'EOF'
#!/bin/sh
set -a; . /etc/lightchain/worker/env; set +a
exec /usr/local/bin/lightchain-worker "$@"
EOF
chmod 755 /usr/local/bin/lcw
ok "unit $UNIT written, helper /usr/local/bin/lcw installed"

# ---- 7. init: key, funding, registration, preflight ------------------------
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
  cat <<EOF

=============================================================================
 Worker key is ready but registration did not complete (see the init output).
 Most often the address simply is not funded yet:

   worker address:  ${ADDR:-see $ENV_DIR/keystore.json}
   send:            $STAKE_HINT  (the init output prints the exact minimum)

 Then run this script again with the same options; it registers and starts
 the worker. Back up $ENV_DIR/ now: it holds the worker key, the encryption
 key and the password that unlocks them.
=============================================================================
EOF
  exit 2
fi

# ---- 8. start ---------------------------------------------------------------
systemctl enable --now $UNIT >/dev/null 2>&1; systemctl restart $UNIT
sleep 15
cat <<EOF

=============================================================================
 Lightchain $NETWORK worker ${ADDR:-} is running
   status:    systemctl status $UNIT ; lcw status  (lcw = run the CLI with the env loaded)
   logs:      journalctl -u $UNIT -f    (look for: authenticated with worker-gateway)
   earnings:  lcw balance ; lcw withdraw
   stop:      systemctl stop $UNIT      (drains in-flight jobs, up to 4 minutes)
   leave:     lcw deregister            (withdraws the stake after the dispute window)
   models:    edit SUPPORTED_MODELS in $ENV_DIR/env, pull them, re-run this script
   GPU:       $GPU, $PARALLEL parallel Ollama slots

 Back up $ENV_DIR/ (worker key, encryption key, password). Losing the
 encryption key after registering means the worker cannot serve sessions.
=============================================================================
EOF
journalctl -u $UNIT --no-pager -n 15 -o cat | cut -c1-160 || true
