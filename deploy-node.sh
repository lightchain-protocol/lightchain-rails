#!/usr/bin/env bash
# =============================================================================
#  Lightchain node, one shot.
#
#  Turns a fresh Ubuntu 22.04 / 24.04 server into a synced Lightchain node
#  (geth execution client + Prysm beacon node), optionally with a validator
#  client. Idempotent: run it again to re-apply the configuration.
#
#  One-liner (RedSwitches post-install hook or your own shell):
#    curl -fsSL https://raw.githubusercontent.com/lightchain-protocol/redswitches-deploy/main/deploy-node.sh \
#      | bash -s -- --network mainnet
#
#  What it does
#    1. Preflight: root, OS, amd64, RAM, CPU, free disk, public IP.
#    2. Installs Docker CE, ufw, fail2ban, chrony and unattended-upgrades.
#    3. Downloads the network bundle (CL config.yml, genesis.ssz, EL genesis)
#       and verifies its SHA-256 against networks/SHA256SUMS.
#    4. Generates the Engine-API JWT secret, initialises the geth datadir.
#    5. Writes /opt/lightchain/<network>/docker-compose.yml with the public
#       ghcr.io images, pinned, and starts geth + beacon (+ validator).
#    6. Opens only SSH (port read from sshd) and the p2p ports in ufw. RPC
#       stays on localhost unless --public-rpc is given, and then only for
#       the CIDRs you list.
#    7. Waits for checkpoint sync, prunes superseded images, prints the status.
#
#  Every run logs to /var/log/lightchain-deploy.log and writes a machine-
#  readable result to /etc/lightchain/deploy-status.json.
#  Exit codes: 0 running, 1 failed (see the log), 4 preflight refused.
#
#  Nothing here phones home. The only remote reads are the public images on
#  ghcr.io, the network bundle on GitHub, and the public Lightchain beacon API
#  used for checkpoint sync.
# =============================================================================
set -Eeuo pipefail

VERSION="1.0.0"
LOG=/var/log/lightchain-deploy.log
STATUS=/etc/lightchain/deploy-status.json
LOCK=/var/lock/lightchain-deploy.lock

# ---- defaults ---------------------------------------------------------------
NETWORK="mainnet"
ROLE="node"
DATADIR=""
KEYSTORES=""
PASSWORD_FILE=""
FEE_RECIPIENT=""
PUBLIC_RPC=0
RPC_ALLOW=""
EXTIP=""
FIREWALL=1
GRAFFITI="redswitches"
DRY_RUN=0
UNINSTALL=0
PURGE=0
BUNDLE_BASE="${LIGHTCHAIN_BUNDLE_BASE:-https://raw.githubusercontent.com/lightchain-protocol/redswitches-deploy/main/networks}"

GETH_IMAGE="ghcr.io/lightchain-protocol/geth:v1.17.0-lc.1"
BEACON_IMAGE="ghcr.io/lightchain-protocol/prysm:v7.1.2-lc.2.2"
VALIDATOR_IMAGE="ghcr.io/lightchain-protocol/prysm:v7.1.2-lc.2"   # validator client build of the same release

usage() {
  cat <<EOF
Lightchain node one-shot deploy $VERSION

Usage (as root):
  bash deploy-node.sh [options]

  --network mainnet|testnet     default mainnet
  --role node|validator         default node
  --keystores DIR               validator: Prysm wallet directory from the deposit tooling
  --password FILE               validator: wallet password file
  --fee-recipient 0x…           validator: address that receives priority fees
  --graffiti TEXT               validator: block graffiti, default redswitches
  --public-rpc                  bind HTTP/WS RPC and the beacon API on all interfaces…
  --rpc-allow CIDR[,CIDR]       …and allow only these networks in the firewall (required with --public-rpc)
  --extip IP                    public IPv4 (auto-detected)
  --datadir DIR                 default /opt/lightchain/<network>
  --no-firewall                 leave ufw alone
  --dry-run                     preflight and print the plan, change nothing
  --uninstall                   stop and remove the containers, images and firewall rules; keep the data
  --purge                       with --uninstall: also delete the data directory
  --version                     print the script version
  -h, --help                    this text

Exit codes: 0 running, 1 failed, 4 preflight refused.
Log: $LOG    Status: $STATUS
EOF
  exit "${1:-0}"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --network) NETWORK="$2"; shift 2;;
    --role) ROLE="$2"; shift 2;;
    --datadir) DATADIR="$2"; shift 2;;
    --keystores) KEYSTORES="$2"; shift 2;;
    --password) PASSWORD_FILE="$2"; shift 2;;
    --fee-recipient) FEE_RECIPIENT="$2"; shift 2;;
    --public-rpc) PUBLIC_RPC=1; shift;;
    --rpc-allow) RPC_ALLOW="$2"; shift 2;;
    --extip) EXTIP="$2"; shift 2;;
    --graffiti) GRAFFITI="$2"; shift 2;;
    --no-firewall) FIREWALL=0; shift;;
    --dry-run) DRY_RUN=1; shift;;
    --uninstall) UNINSTALL=1; shift;;
    --purge) PURGE=1; shift;;
    --version) echo "deploy-node.sh $VERSION"; exit 0;;
    -h|--help) usage 0;;
    *) echo "unknown option: $1" >&2; usage 1;;
  esac
done

# ---- network table ----------------------------------------------------------
case "$NETWORK" in
  mainnet)
    CHAIN_ID=9200
    CHECKPOINT_URL="https://beacon.mainnet.lightchain.ai"
    BOOTNODES="enode://3b730c35f191ea1ba602d9d6cc7171d849a735633b7ea6acadf603b97eeca23f45e2657f0482adaeba1e0ac28d20ba2308a4b78b6ab90acbcbcc632f757d2862@103.41.177.44:30303,enode://bed01747094a5e7fa77d750dd8da1fa43fe8a415a9ba5d97933573a2e1c9982330b53cee7360f01f906fccb63003e66a2c81998ab83623041cbb6b050b977e3a@43.250.54.66:30313,enode://81d8a0c7b0625660012524a5835cd92c9ea81a112804f33c8a26d05354a72f50aa220b62da3fa441b92adb649dfed7f3fe4d76e5ab8536d353230eb78b0df33b@184.107.122.232:30313"
    PEERS="/ip4/103.41.177.44/tcp/13000/p2p/16Uiu2HAmExPXY5MQu38z9Uo41eJ8sq8ngAQS2TCCZvMc7v6xY1cY /ip4/43.250.54.66/tcp/13100/p2p/16Uiu2HAkxip4eergCzjtPeQZQTF5YPVxWcn2FsQQL79uTTVHrB2u /ip4/184.107.122.232/tcp/13100/p2p/16Uiu2HAm8sMF73EtknDFHyGbcTupBc4PfULZgxNtuQ57ivozAX4a"
    STAKE="500,000 LCAI";;
  testnet)
    CHAIN_ID=8200
    CHECKPOINT_URL="https://beacon.testnet.lightchain.ai"
    BOOTNODES="enode://766588399c04615d3d878716d07f1a6a001d5709c10ada4d6179a5e35d7931c97e2976511bb26763e2ff3523f6da088ea2cdd7e508168e7fe1bad62cf4e126dd@43.250.54.66:30303,enode://7d48c201caa46f03cb4f634b91c596a9c774e78ac6bf0eacb2bf55c73d4a447b5a83f852b7bb7f6ed9f1e706b302cf1bc64cfd0d9ed73d38ddfabeb3914ee744@84.75.40.87:30303,enode://516b3af7abd8c48aa52112ae5eb17df31f37b69d179f705413f021e0f038657e92ca2572056d0fa147463e3082aef0471b365a5c70b318acfbdc0b00984d4989@103.41.177.45:30303"
    PEERS="/ip4/43.250.54.66/tcp/13000/p2p/16Uiu2HAm9tWhMVq6vYxTYVVTEC1v8uwaowWFmLjpE2MHkiPjsosc /ip4/84.75.40.87/tcp/13000/p2p/16Uiu2HAmAMMdoENPsFigjFGZKQbtBWg8fAzqVi1KhWfpRbqn7xg7 /ip4/103.41.177.45/tcp/13000/p2p/16Uiu2HAm6q4FHEXRBiMisZ2edRkvUhYnko5XjzS9bx9oLrm1XMd6"
    STAKE="100,000 LCAI-t";;
  *) echo "--network must be mainnet or testnet" >&2; exit 1;;
esac
[ -n "$DATADIR" ] || DATADIR="/opt/lightchain/$NETWORK"

# ---- helpers ----------------------------------------------------------------
if [ -t 1 ]; then C1=$'\033[1;36m'; C2=$'\033[1;32m'; C3=$'\033[1;33m'; C4=$'\033[1;31m'; C0=$'\033[0m'; else C1=""; C2=""; C3=""; C4=""; C0=""; fi
STEP="startup"
log()  { STEP="$*"; printf '%s==> %s%s\n' "$C1" "$*" "$C0"; }
ok()   { printf '%s    %s%s\n' "$C2" "$*" "$C0"; }
warn() { printf '%s    %s%s\n' "$C3" "$*" "$C0"; }
die()  { printf '%sERROR: %s%s\n' "$C4" "$*" "$C0" >&2; write_status failed; exit "${2:-1}"; }
write_status() { # state
  mkdir -p "$(dirname "$STATUS")"
  printf '{"script":"deploy-node.sh","version":"%s","network":"%s","role":"%s","state":"%s","datadir":"%s","extip":"%s","updated":"%s"}\n' \
    "$VERSION" "$NETWORK" "$ROLE" "$1" "$DATADIR" "${EXTIP:-}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$STATUS"
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
APT="apt-get -o DPkg::Lock::Timeout=600 -qq"
CURL="curl -fsSL --retry 3 --retry-delay 5 --retry-all-errors"

[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 4; }
mkdir -p "$(dirname "$LOG")"
exec > >(tee -a "$LOG") 2>&1
exec 9>"$LOCK"; flock -n 9 || { echo "another Lightchain deploy is already running (lock $LOCK)" >&2; exit 1; }
trap 'on_err $LINENO $?' ERR
echo; echo "---- deploy-node.sh $VERSION  $(date -u +%Y-%m-%dT%H:%M:%SZ)  network=$NETWORK role=$ROLE datadir=$DATADIR"

# ---- uninstall --------------------------------------------------------------
if [ "$UNINSTALL" = 1 ]; then
  log "Uninstalling the Lightchain $NETWORK node from $DATADIR"
  if [ -f "$DATADIR/docker-compose.yml" ] && command -v docker >/dev/null; then
    ( cd "$DATADIR" && docker compose down --remove-orphans >/dev/null 2>&1 ) || true
    ok "containers stopped and removed (geth got its full shutdown grace)"
  fi
  if command -v docker >/dev/null; then
    docker images --format '{{.Repository}}:{{.Tag}}' | grep '^ghcr.io/lightchain-protocol/' | xargs -r docker rmi >/dev/null 2>&1 || true
    ok "images removed"
  fi
  if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q '^Status: active'; then
    for r in 30303/tcp 30303/udp 13000/tcp 13000/udp 12000/udp; do ufw delete allow "$r" >/dev/null 2>&1 || true; done
    ufw status numbered 2>/dev/null | grep -E '8545,8546,3500' | sed -E 's/^\[ *([0-9]+)\].*/\1/' | sort -rn | while read -r n; do yes | ufw delete "$n" >/dev/null 2>&1 || true; done
    ok "p2p and RPC firewall rules removed (SSH, ufw and fail2ban stay)"
  fi
  rm -f "$DATADIR/docker-compose.yml"
  if [ "$PURGE" = 1 ]; then rm -rf "$DATADIR"; ok "data directory deleted"; else ok "data kept in $DATADIR (add --purge to delete it)"; fi
  write_status removed
  exit 0
fi

# ---- 1. preflight -----------------------------------------------------------
log "Preflight"
. /etc/os-release
case "${VERSION_ID:-}" in 22.04|24.04) ;; *) warn "tested on Ubuntu 22.04 and 24.04, you have ${PRETTY_NAME:-unknown}; continuing";; esac
ARCH=$(dpkg --print-architecture 2>/dev/null || uname -m)
[ "$ARCH" = amd64 ] || die "the Lightchain client images are built for amd64; this machine is $ARCH" 4
[ "$ROLE" = node ] || [ "$ROLE" = validator ] || die "--role must be node or validator" 4
if [ "$ROLE" = validator ]; then
  [ -d "$KEYSTORES" ] || die "--keystores DIR (Prysm wallet directory produced by the deposit tooling) is required for --role validator" 4
  [ -f "$PASSWORD_FILE" ] || die "--password FILE (wallet password) is required for --role validator" 4
  [[ "$FEE_RECIPIENT" =~ ^0x[0-9a-fA-F]{40}$ ]] || die "--fee-recipient 0x… (your address, receives priority fees) is required for --role validator" 4
fi
if [ "$PUBLIC_RPC" = 1 ]; then
  [ -n "$RPC_ALLOW" ] || die "--public-rpc needs --rpc-allow CIDR[,CIDR]: never expose a node RPC to the whole internet" 4
  IFS=, read -ra _CIDRS <<< "$RPC_ALLOW"
  for c in "${_CIDRS[@]}"; do [[ "$c" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]{1,2})?$ ]] || die "--rpc-allow: '$c' is not an IPv4 address or CIDR" 4; done
fi
RAM_GB=$(( $(awk '/MemTotal/{print $2}' /proc/meminfo) / 1024 / 1024 ))
CPUS=$(nproc)
mkdir -p "$DATADIR"
FREE_GB=$(df -BG --output=avail "$DATADIR" | tail -1 | tr -dc 0-9)
[ "$RAM_GB" -ge 8 ]    || die "${RAM_GB} GB RAM: a node needs at least 8 GB (16 GB recommended)" 4
[ "$FREE_GB" -ge 150 ] || die "${FREE_GB} GB free under $DATADIR: a node needs at least 150 GB (200 GB NVMe recommended)" 4
[ "$RAM_GB" -ge 16 ]   || warn "${RAM_GB} GB RAM is below the recommended 16 GB"
[ "$CPUS" -ge 4 ]      || warn "$CPUS vCPU is below the recommended 4"
[ "$FREE_GB" -ge 200 ] || warn "${FREE_GB} GB free is below the recommended 200 GB; the chain grows"
if [ -z "$EXTIP" ]; then
  EXTIP=$(curl -fsS -m 10 https://api.ipify.org || curl -fsS -m 10 https://ifconfig.me || true)
fi
[[ "$EXTIP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "could not determine the public IPv4 address; pass --extip" 4
SSH_PORTS=$(ssh_ports)
ok "${PRETTY_NAME:-Ubuntu} $ARCH, $CPUS vCPU, ${RAM_GB} GB RAM, ${FREE_GB} GB free, public IP $EXTIP, SSH on port(s) $SSH_PORTS"
if [ "$DRY_RUN" = 1 ]; then
  cat <<EOF
    plan: $ROLE on $NETWORK (chain $CHAIN_ID) in $DATADIR
          images $GETH_IMAGE, $BEACON_IMAGE$( [ "$ROLE" = validator ] && echo ", $VALIDATOR_IMAGE")
          firewall $( [ "$FIREWALL" = 1 ] && echo "SSH $SSH_PORTS + p2p 30303/13000/12000$( [ "$PUBLIC_RPC" = 1 ] && echo " + RPC from $RPC_ALLOW")" || echo "untouched")
          checkpoint sync from $CHECKPOINT_URL
    dry run: nothing changed
EOF
  exit 0
fi
write_status deploying

# ---- 2. packages ------------------------------------------------------------
log "Installing packages"
export DEBIAN_FRONTEND=noninteractive
retry 3 $APT update || die "apt-get update failed"
retry 3 $APT install -y ca-certificates curl gnupg ufw fail2ban chrony unattended-upgrades jq openssl python3 rsync iproute2 >/dev/null || die "package install failed"
if ! command -v docker >/dev/null; then
  install -m 0755 -d /etc/apt/keyrings
  $CURL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$ARCH signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" > /etc/apt/sources.list.d/docker.list
  retry 3 $APT update || die "apt-get update (docker repo) failed"
  retry 3 $APT install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin >/dev/null || die "docker install failed"
fi
systemctl enable --now docker >/dev/null 2>&1
# give geth time to flush on shutdown (a hard kill forces a long state re-sync),
# keep containers alive across daemon restarts, cap container logs
mkdir -p /etc/docker
DAEMON_CHANGED=$(python3 - <<'PY'
import json, os
p = "/etc/docker/daemon.json"
d = {}
if os.path.exists(p):
    try:
        d = json.load(open(p))
    except Exception:
        d = {}
want = {"shutdown-timeout": 600, "live-restore": True}
changed = any(d.get(k) != v for k, v in want.items())
d.update(want)
if d.get("log-driver", "json-file") == "json-file" and d.get("log-opts", {}).get("max-size") != "50m":
    d["log-driver"] = "json-file"; d["log-opts"] = {"max-size": "50m", "max-file": "5"}; changed = True
if changed:
    json.dump(d, open(p, "w"), indent=2)
print("yes" if changed else "no")
PY
)
if [ "$DAEMON_CHANGED" = yes ]; then systemctl restart docker; ok "docker daemon.json updated (shutdown-timeout 600s, live-restore, log caps)"; fi
printf 'APT::Periodic::Update-Package-Lists "1";\nAPT::Periodic::Unattended-Upgrade "1";\n' > /etc/apt/apt.conf.d/20auto-upgrades
systemctl enable --now chrony >/dev/null 2>&1 || true
ok "docker $(docker --version | awk '{print $3}' | tr -d ,), compose $(docker compose version --short)"

# ---- 3. network bundle ------------------------------------------------------
log "Fetching the $NETWORK network bundle"
mkdir -p "$DATADIR/chain-config" "$DATADIR/geth" "$DATADIR/beacon"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo /nonexistent)"
for f in config.yml genesis.ssz genesis-generated.json; do
  if [ -f "$SCRIPT_DIR/networks/$NETWORK/$f" ]; then
    cp "$SCRIPT_DIR/networks/$NETWORK/$f" "$DATADIR/chain-config/$f"
  else
    $CURL -o "$DATADIR/chain-config/$f" "$BUNDLE_BASE/$NETWORK/$f" || die "download of $f failed"
  fi
done
if [ -f "$SCRIPT_DIR/networks/SHA256SUMS" ]; then cp "$SCRIPT_DIR/networks/SHA256SUMS" "$DATADIR/chain-config/SHA256SUMS"; else $CURL -o "$DATADIR/chain-config/SHA256SUMS" "$BUNDLE_BASE/SHA256SUMS" || die "download of SHA256SUMS failed"; fi
( cd "$DATADIR/chain-config" && grep " \*\?networks/$NETWORK/" SHA256SUMS | sed "s#networks/$NETWORK/##" | sha256sum -c --quiet ) || die "network bundle checksum mismatch; refusing to continue"
if [ ! -s "$DATADIR/chain-config/jwt.hex" ]; then
  openssl rand -hex 32 | tr -d '\n' > "$DATADIR/chain-config/jwt.hex"
  chmod 600 "$DATADIR/chain-config/jwt.hex"
fi
ok "bundle verified: $(grep -c '' "$DATADIR/chain-config/config.yml") lines of CL config, genesis.ssz $(stat -c %s "$DATADIR/chain-config/genesis.ssz") bytes"

# ---- 4. images --------------------------------------------------------------
log "Pulling images"
retry 3 docker pull -q "$GETH_IMAGE" >/dev/null || die "pull of $GETH_IMAGE failed"
retry 3 docker pull -q "$BEACON_IMAGE" >/dev/null || die "pull of $BEACON_IMAGE failed"
if [ "$ROLE" = validator ]; then retry 3 docker pull -q "$VALIDATOR_IMAGE" >/dev/null || die "pull of $VALIDATOR_IMAGE failed"; fi
ok "$GETH_IMAGE"; ok "$BEACON_IMAGE"

# ---- 5. geth init -----------------------------------------------------------
if [ ! -d "$DATADIR/geth/geth/chaindata" ]; then
  log "Initialising the geth datadir"
  if ! docker run --rm -v "$DATADIR/chain-config:/chain-config:ro" -v "$DATADIR/geth:/gethdata" "$GETH_IMAGE" \
       init --datadir=/gethdata /chain-config/genesis-generated.json >/dev/null 2>&1; then
    rm -rf "$DATADIR/geth/geth"   # never leave a half-written datadir that a re-run would skip
    die "geth init failed"
  fi
  ok "genesis written, chain id $CHAIN_ID"
fi

# ---- 6. validator files -----------------------------------------------------
if [ "$ROLE" = validator ]; then
  log "Installing validator keys"
  FRESH_DB=0; [ -d "$DATADIR/validator/db" ] || FRESH_DB=1
  mkdir -p "$DATADIR/validator/db"
  rsync -a --delete "$KEYSTORES/" "$DATADIR/validator/keystores/"
  install -m 600 "$PASSWORD_FILE" "$DATADIR/validator/password.txt"
  chmod -R go-rwx "$DATADIR/validator"
  ok "$(find "$DATADIR/validator/keystores" -name '*.json' | wc -l) key files, wallet password installed (0600)"
  [ "$FRESH_DB" = 1 ] && warn "if these keys ever validated on another machine, import its slashing-protection history before the first duties (validator slashing-protection-history import); doppelganger protection is on but is not a substitute"
fi

# ---- 7. compose -------------------------------------------------------------
log "Writing $DATADIR/docker-compose.yml"
if [ "$PUBLIC_RPC" = 1 ]; then HTTP_ADDR="0.0.0.0"; else HTTP_ADDR="127.0.0.1"; fi
PEER_FLAGS=""; for p in $PEERS; do PEER_FLAGS="$PEER_FLAGS
      - \"--peer=$p\""; done
cat > "$DATADIR/docker-compose.yml" <<EOF
# Lightchain $NETWORK node, written by deploy-node.sh $VERSION on $(date -u +%Y-%m-%dT%H:%MZ). Re-run the script instead of editing.
services:
  geth:
    image: $GETH_IMAGE
    container_name: geth
    network_mode: host
    restart: always
    stop_grace_period: 10m
    volumes:
      - $DATADIR/chain-config:/chain-config:ro
      - $DATADIR/geth:/gethdata
    command:
      - "--datadir=/gethdata"
      - "--syncmode=snap"
      - "--http"
      - "--http.addr=$HTTP_ADDR"
      - "--http.api=eth,net,web3,txpool"
      - "--http.vhosts=*"
      - "--ws"
      - "--ws.addr=$HTTP_ADDR"
      - "--ws.api=eth,net,web3"
      - "--ws.origins=*"
      - "--authrpc.addr=127.0.0.1"
      - "--authrpc.jwtsecret=/chain-config/jwt.hex"
      - "--authrpc.vhosts=*"
      - "--miner.gasprice=1"
      - "--nat=extip:$EXTIP"
      - "--port=30303"
      - "--bootnodes=$BOOTNODES"
  beacon-chain:
    image: $BEACON_IMAGE
    container_name: beacon-chain
    entrypoint: ["beacon-chain"]
    user: "0:0"
    network_mode: host
    restart: always
    stop_grace_period: 2m
    depends_on: [geth]
    volumes:
      - $DATADIR/chain-config:/chain-config:ro
      - $DATADIR/beacon:/beacondata
    command:
      - "--accept-terms-of-use"
      - "--chain-config-file=/chain-config/config.yml"
      - "--genesis-state=/chain-config/genesis.ssz"
      - "--datadir=/beacondata"
      - "--execution-endpoint=http://127.0.0.1:8551"
      - "--jwt-secret=/chain-config/jwt.hex"
      - "--checkpoint-sync-url=$CHECKPOINT_URL"
      - "--genesis-beacon-api-url=$CHECKPOINT_URL"
      - "--grpc-gateway-host=$HTTP_ADDR"
      - "--grpc-gateway-port=3500"
      - "--rpc-host=127.0.0.1"
      - "--rpc-port=4000"
      - "--monitoring-host=127.0.0.1"
      - "--monitoring-port=8080"
      - "--min-sync-peers=1"
      - "--p2p-host-ip=$EXTIP"
      - "--p2p-tcp-port=13000"
      - "--p2p-udp-port=12000"
      - "--p2p-quic-port=13000"
      - "--p2p-static-id"$PEER_FLAGS
EOF
if [ "$ROLE" = validator ]; then cat >> "$DATADIR/docker-compose.yml" <<EOF
  validator:
    image: $VALIDATOR_IMAGE
    container_name: validator
    entrypoint: ["validator"]
    user: "0:0"
    network_mode: host
    restart: always
    depends_on: [beacon-chain]
    volumes:
      - $DATADIR/chain-config:/chain-config:ro
      - $DATADIR/validator/keystores:/wallet:ro
      - $DATADIR/validator/password.txt:/password.txt:ro
      - $DATADIR/validator/db:/root/.eth2
    command:
      - "--accept-terms-of-use"
      - "--chain-config-file=/chain-config/config.yml"
      - "--beacon-rpc-provider=127.0.0.1:4000"
      - "--wallet-dir=/wallet"
      - "--wallet-password-file=/password.txt"
      - "--suggested-fee-recipient=$FEE_RECIPIENT"
      - "--graffiti=$GRAFFITI"
      - "--enable-doppelganger"
      - "--monitoring-host=127.0.0.1"
      - "--monitoring-port=8081"
EOF
fi

# ---- 8. firewall ------------------------------------------------------------
if [ "$FIREWALL" = 1 ]; then
  log "Firewall: SSH + p2p only"
  ufw --force reset >/dev/null
  ufw default deny incoming >/dev/null; ufw default allow outgoing >/dev/null
  for p in $SSH_PORTS; do ufw allow "$p/tcp" >/dev/null; done
  ufw allow 30303/tcp >/dev/null; ufw allow 30303/udp >/dev/null
  ufw allow 13000/tcp >/dev/null; ufw allow 13000/udp >/dev/null; ufw allow 12000/udp >/dev/null
  if [ "$PUBLIC_RPC" = 1 ]; then
    IFS=, read -ra CIDRS <<< "$RPC_ALLOW"
    for c in "${CIDRS[@]}"; do ufw allow from "$c" to any port 8545,8546,3500 proto tcp >/dev/null; ok "RPC 8545/8546/3500 allowed from $c"; done
  fi
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
  ok "ufw active (SSH $SSH_PORTS, p2p), fail2ban active"
fi

# ---- 9. start ---------------------------------------------------------------
log "Starting containers"
cd "$DATADIR"
docker compose up -d --remove-orphans >/dev/null
sleep 8
docker compose ps --format 'table {{.Name}}\t{{.Status}}'
for c in geth beacon-chain $( [ "$ROLE" = validator ] && echo validator ); do
  [ "$(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null)" = true ] || { docker logs --tail 40 "$c" 2>&1 | tail -40; die "container $c is not running"; }
done

# ---- 10. cleanup ------------------------------------------------------------
log "Cleaning up"
docker images --format '{{.Repository}}:{{.Tag}}' | grep '^ghcr.io/lightchain-protocol/' \
  | grep -vx -e "$GETH_IMAGE" -e "$BEACON_IMAGE" -e "$VALIDATOR_IMAGE" | xargs -r docker rmi >/dev/null 2>&1 || true
docker image prune -f >/dev/null 2>&1 || true
$APT clean >/dev/null 2>&1 || true
ok "superseded images removed, apt cache cleared"

# ---- 11. wait for checkpoint sync -------------------------------------------
log "Waiting for the beacon node to finish checkpoint sync (usually 1 to 3 minutes)"
for i in $(seq 1 60); do
  s=$(curl -s -m 3 http://127.0.0.1:3500/eth/v1/node/syncing || true)
  if echo "$s" | grep -q '"is_syncing":false'; then ok "beacon synced: $(echo "$s" | jq -c .data)"; break; fi
  sleep 10
  [ "$i" = 60 ] && warn "beacon still syncing; watch it with: docker logs -f beacon-chain"
done
el=$(curl -s -m 3 -X POST -H 'content-type: application/json' --data '{"jsonrpc":"2.0","id":1,"method":"eth_syncing","params":[]}' http://127.0.0.1:8545 | jq -c .result 2>/dev/null || echo "?")
ok "geth eth_syncing: $el  (false means the execution layer is at head; snap sync takes 10 to 60 minutes)"
write_status running

cat <<EOF

=============================================================================
 Lightchain $NETWORK $ROLE is running from $DATADIR
   status:   cd $DATADIR && docker compose ps      (machine-readable: $STATUS)
   logs:     docker logs -f --tail 100 geth | beacon-chain$( [ "$ROLE" = validator ] && echo " | validator")
   head:     curl -s localhost:3500/eth/v1/node/syncing | jq .
   stop:     cd $DATADIR && docker compose stop        (always stop before a reboot: geth needs a clean shutdown)
   update:   re-run this script (new image tags are picked up, old images pruned)
   remove:   re-run with --uninstall [--purge]
   deploy log: $LOG
$( [ "$ROLE" = validator ] && printf '   validator: each key needs a %s deposit to 0x4242…4242 before it activates; doppelganger protection delays the first duties by two epochs.\n' "$STAKE")
 RPC is bound to $HTTP_ADDR. $( [ "$PUBLIC_RPC" = 1 ] && echo "Allowed from: $RPC_ALLOW" || echo "Use --public-rpc --rpc-allow CIDR to serve other machines." )
=============================================================================
EOF
