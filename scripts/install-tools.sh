#!/bin/bash
# Check (and install) what the demo needs on the Ubuntu VM. Runs ON THE LINUX VM, not on the Mac.
#
#   ./scripts/install-tools.sh --check    only check: one PASS or FAIL line per item, with a hint for every FAIL
#   ./scripts/install-tools.sh            the same checks, then download what is missing into ~/tools:
#                                           Aiken v1.1.24  (compiler of the smart contract)
#                                           Kupo  v2.12.0  (the indexer the web page reads the chain through)
#                                         and, if seed-emulator is cloned but cannot be imported, the Python virtual environment
#                                         ~/seed-venv with seed-emulator's requirements.txt (pip, inside the venv only)
#
# The folders are the same ones our own VM uses (the paths are set in scripts/tools.sh):
#   ~/tools/aiken-1.1.24/aiken-<aarch64|x86_64>-unknown-linux-musl/aiken      (the CPU type is detected with uname -m)
#   ~/tools/kupo-2.12.0/bin/kupo
# It never installs system packages (no sudo): for missing packages it prints the apt command to run yourself.
# The Python that runs seed-emulator is chosen by seed_python in tools.sh: $SEED_PYTHON, else ~/seed-venv/bin/python3, else python3.
# Running it again is safe: what is already there is skipped. Other settings: AIKEN, KUPO_BIN, SEED_EMULATOR (see tools.sh).
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CHECK_ONLY=0
case "${1:-}" in
  "") ;;
  --check) CHECK_ONLY=1 ;;
  -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
  *) echo "unknown option $1 (try --help)"; exit 1 ;;
esac

FAILS=0
APT=""        # apt packages that are missing, collected for one command at the end

# ---- output helpers: one line per check ----
pass() { printf '  PASS  %s\n' "$*"; }
fail() { FAILS=$((FAILS + 1)); printf '  FAIL  %s\n' "$*"; }
hint() { printf '        hint: %s\n' "$*"; }
want_apt() { case " $APT " in *" $1 "*) ;; *) APT="$APT $1";; esac; }

# This script is for Linux only (the Mac side of the demo needs none of this).
if [ "$(uname -s)" != Linux ]; then
  echo "  FAIL  Linux only: this script checks the Ubuntu VM, but this machine is $(uname -s)"
  echo "        hint: run it inside the Ubuntu VM (on the Mac nothing has to be installed for the demo)"
  exit 1
fi
. "$ROOT/scripts/tools.sh"     # AIKEN, KUPO_BIN, SEED_EMULATOR, TOOLS_ARCH, versions

echo "Checking this machine ($(uname -m), $TOOLS_ARCH) ..."
pass "Linux ($(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-Linux}"))"

# ---- docker ----
if ! command -v docker > /dev/null 2>&1; then
  fail "docker is not installed"
  hint "sudo apt install -y docker.io   (or Docker's own repository: https://docs.docker.com/engine/install/ubuntu/)"
  want_apt docker.io
elif docker info > /dev/null 2>&1; then
  pass "docker engine runs and works without sudo"
elif id -nG | tr ' ' '\n' | grep -qx docker; then
  fail "docker is installed, but the engine does not answer"
  hint "sudo systemctl enable --now docker   (then: docker info)"
else
  fail "docker is installed, but this user may not use it (not in the group docker, or the engine is not running)"
  hint "sudo usermod -aG docker \$USER   then log out and in again (or reboot); also: sudo systemctl enable --now docker"
fi
if docker compose version > /dev/null 2>&1; then
  pass "docker compose plugin: $(docker compose version --short 2>/dev/null)"
else
  fail "docker compose plugin missing (the command 'docker compose' does not work)"
  hint "sudo apt install -y docker-compose-v2   (Ubuntu 22.04 and 24.04, from 'universe'), or docker-compose-plugin from Docker's repository"
  want_apt docker-compose-v2
fi

# ---- programs ----
need_cmd() {   # need_cmd COMMAND APT-PACKAGE
  if command -v "$1" > /dev/null 2>&1; then pass "$1"
  else fail "$1 is missing"; hint "sudo apt install -y $2"; want_apt "$2"; fi
}
if command -v python3 > /dev/null 2>&1; then
  pass "python3 ($(python3 -c 'import sys; print("%d.%d.%d" % sys.version_info[:3])'))"
else
  fail "python3 is missing"; hint "sudo apt install -y python3"; want_apt python3
fi
need_cmd git git
need_cmd curl curl
need_cmd jq jq
need_cmd openssl openssl
need_cmd rsync rsync

# ---- seed-emulator ----
# seedemu is imported from the clone ($SEED_EMULATOR) and needs the packages of its requirements.txt
# (web3 5.31.1 and others). They are installed into a virtual environment ~/seed-venv (below);
# a machine that has them system-wide just uses python3.
NEED_VENV=0
check_seed() {
  local py
  py=$(seed_python)
  if [ ! -d "$SEED_EMULATOR/seedemu" ]; then
    fail "seed-emulator is not cloned (no $SEED_EMULATOR/seedemu)"
    hint "git clone --branch $SEED_TAG https://github.com/seed-labs/seed-emulator $SEED_EMULATOR"
    hint "(another folder: export SEED_EMULATOR=<folder>). Run this script again afterwards: it then creates the Python environment"
  elif command -v "$py" > /dev/null 2>&1 && PYTHONPATH=$SEED_EMULATOR "$py" -c 'import seedemu' > /dev/null 2>&1; then
    pass "seed-emulator can be imported (from $SEED_EMULATOR, Python: $py)"
    HEAD_NOW=$(git -C "$SEED_EMULATOR" rev-parse HEAD 2> /dev/null)
    if [ -n "$HEAD_NOW" ] && [ "$HEAD_NOW" != "$SEED_COMMIT" ]; then
      echo "        note: seed-emulator is at commit ${HEAD_NOW:0:7}, the tested one is ${SEED_COMMIT:0:7} (release $SEED_TAG): git -C $SEED_EMULATOR checkout $SEED_TAG"
    fi
  else
    fail "seed-emulator cannot be imported with $py (from $SEED_EMULATOR)"
    if [ -z "${SEED_PYTHON:-}" ] && [ ! -x "$HOME/seed-venv/bin/python3" ]; then
      NEED_VENV=1
      hint "$([ $CHECK_ONLY = 1 ] && echo "run ./scripts/install-tools.sh (without --check): it creates" || echo "this script creates it below:") the Python environment ~/seed-venv with seed-emulator's requirements.txt"
      if ! "$py" -c 'import ensurepip, venv' > /dev/null 2>&1; then
        hint "python3-venv is needed for that: sudo apt install -y python3-venv"; want_apt python3-venv
      fi
    else
      hint "see the error with   PYTHONPATH=$SEED_EMULATOR $py -c 'import seedemu'   (the packages of $SEED_EMULATOR/requirements.txt must be installed in that Python; delete ~/seed-venv and run this script again to rebuild it)"
    fi
  fi
}
FAILS_BEFORE_SEED=$FAILS
if command -v python3 > /dev/null 2>&1; then check_seed; fi
SEED_FAILS=$((FAILS - FAILS_BEFORE_SEED))

# ---- disk and memory ----
DISK=$(df -BG --output=avail "$HOME" 2>/dev/null | tail -1 | tr -dc 0-9)
if [ "${DISK:-0}" -ge 15 ]; then
  pass "free disk: $DISK GB (needed: 15 GB)"
else
  fail "free disk: ${DISK:-?} GB, needed: 15 GB"
  hint "enlarge the virtual disk of the VM, or remove files (docker system prune)"
fi
MEMKB=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null)
if [ "${MEMKB:-0}" -ge 3670016 ]; then   # 3.5 GB in kB
  pass "RAM: $((MEMKB / 1024)) MB (needed: 3.5 GB)"
else
  fail "RAM: $((${MEMKB:-0} / 1024)) MB, needed: 3.5 GB"
  hint "give the VM more memory (at least 4 GB) in its settings, then start it again"
fi

# ---- repository ----
WANT=$(cd -P "$HOME/cardano-seed-testnet" 2>/dev/null && pwd -P)
HAVE=$(cd -P "$ROOT" && pwd -P)
if [ -n "$WANT" ] && [ "$WANT" = "$HAVE" ]; then pass "repository is in ~/cardano-seed-testnet"
else
  fail "the repository is in $ROOT, not in ~/cardano-seed-testnet"
  hint "git clone https://github.com/vaizan4ikys/cardano-seed-testnet ~/cardano-seed-testnet   or   ln -s $ROOT ~/cardano-seed-testnet"
fi

# ---- Aiken and Kupo ----
TOOLHINT="run ./scripts/install-tools.sh (without --check) to download it"
[ $CHECK_ONLY = 0 ] && TOOLHINT="it is downloaded below"
check_tools() {
  if [ "$TOOLS_ARCH" = unknown ]; then
    fail "CPU type '$(uname -m)' is not supported (aarch64/arm64 or x86_64/amd64 needed)"
    return
  fi
  if [ ! -x "$AIKEN" ]; then fail "Aiken not found: $AIKEN"; hint "$TOOLHINT"
  elif "$AIKEN" --version > /dev/null 2>&1; then pass "Aiken: $AIKEN ($("$AIKEN" --version 2>&1 | head -1))"
  else
    fail "Aiken does not run: $AIKEN"
    hint "wrong file or CPU type: delete $(dirname "$AIKEN") and run this script again"
  fi
  if [ ! -x "$KUPO_BIN" ]; then fail "Kupo not found: $KUPO_BIN"; hint "$TOOLHINT"
  elif "$KUPO_BIN" --version > /dev/null 2>&1; then pass "Kupo: $KUPO_BIN ($("$KUPO_BIN" --version 2>&1 | head -1))"
  else
    fail "Kupo does not run: $KUPO_BIN"
    hint "wrong file or CPU type: delete $(dirname "$(dirname "$KUPO_BIN")") and run this script again"
  fi
}
FAILS_OTHER=$FAILS      # failures of the checks above (not Aiken/Kupo): they stay when the tool checks are repeated
check_tools

# ---- download ----
sha_of() { sha256sum "$1" | awk '{print $1}'; }

# first_file DIR NAME: path of the first regular file called NAME below DIR (empty if none)
first_file() { find "$1" -type f -name "$2" 2> /dev/null | head -1; }

install_aiken() {
  local name=aiken-$TOOLS_ARCH-unknown-linux-musl
  local url=https://github.com/aiken-lang/aiken/releases/download/v$AIKEN_VERSION/$name.tar.gz
  local tmp want got bin
  tmp=$(mktemp -d) || return 1
  echo "  downloading $url"
  if ! curl -fL --retry 3 -sS -o "$tmp/aiken.tar.gz" "$url"; then echo "  download failed"; rm -rf "$tmp"; return 1; fi
  got=$(sha_of "$tmp/aiken.tar.gz")
  # the release publishes <archive>.sha256 next to the archive
  want=$(curl -fL --retry 3 -sS "$url.sha256" 2> /dev/null | awk '{print $1}' | head -1)
  if printf '%s' "$want" | grep -qE '^[0-9a-fA-F]{64}$'; then
    if [ "$(printf '%s' "$want" | tr 'A-F' 'a-f')" = "$got" ]; then echo "  sha256 matches the published checksum: $got"
    else echo "  CHECKSUM MISMATCH: published $want, downloaded $got. Nothing installed."; rm -rf "$tmp"; return 1; fi
  else
    echo "  no published checksum could be read; sha256 of the download: $got"
  fi
  mkdir -p "$tmp/x" && tar -xzf "$tmp/aiken.tar.gz" -C "$tmp/x" \
    || { echo "  could not unpack the archive"; rm -rf "$tmp"; return 1; }
  bin=$(first_file "$tmp/x" aiken)
  [ -n "$bin" ] || { echo "  no file named aiken in the archive"; rm -rf "$tmp"; return 1; }
  mkdir -p "$(dirname "$AIKEN")" && cp "$bin" "$AIKEN" && chmod +x "$AIKEN" || { rm -rf "$tmp"; return 1; }
  rm -rf "$tmp"
  echo "  installed: $AIKEN ($("$AIKEN" --version 2>&1 | head -1))"
}

install_kupo() {
  # tag v2.12, file kupo-v2.12.0-<aarch64|x86_64>-linux.zip (no checksum file is published: we print the sha256)
  local name=kupo-v$KUPO_VERSION-$TOOLS_ARCH-linux.zip
  local url=https://github.com/CardanoSolutions/kupo/releases/download/v${KUPO_VERSION%.*}/$name
  local tmp bin
  tmp=$(mktemp -d) || return 1
  echo "  downloading $url"
  if ! curl -fL --retry 3 -sS -o "$tmp/kupo.zip" "$url"; then echo "  download failed"; rm -rf "$tmp"; return 1; fi
  echo "  no published checksum for Kupo; sha256 of the download: $(sha_of "$tmp/kupo.zip")"
  mkdir -p "$tmp/x" && python3 -I -m zipfile -e "$tmp/kupo.zip" "$tmp/x" \
    || { echo "  could not unpack the archive"; rm -rf "$tmp"; return 1; }
  # the archive holds bin/kupo (the program) and also a file called kupo in share/ (bash completion):
  # take the one in bin/
  bin=$(find "$tmp/x" -type f -path '*/bin/kupo' 2> /dev/null | head -1)
  [ -n "$bin" ] || { echo "  no bin/kupo in the archive"; rm -rf "$tmp"; return 1; }
  mkdir -p "$(dirname "$KUPO_BIN")" && cp "$bin" "$KUPO_BIN" && chmod +x "$KUPO_BIN" || { rm -rf "$tmp"; return 1; }
  rm -rf "$tmp"
  if ! "$KUPO_BIN" --version > /dev/null 2>&1; then
    echo "  the installed file does not run on this machine: $KUPO_BIN"
    rm -f "$KUPO_BIN"
    return 1
  fi
  echo "  installed: $KUPO_BIN ($("$KUPO_BIN" --version 2>&1 | head -1))"
}

# The Aiken standard library (aiken-lang/stdlib v4.0.0, named in the contract's aiken.toml) is fetched by aiken
# itself the first time it runs in the contract folder (needs internet). We do that now so a problem shows up
# here, not in fresh.sh.
fetch_stdlib() {
  local dir=$ROOT/experiments/contract/gateway-registry
  [ -d "$dir" ] || return 0
  if [ -d "$dir/build/packages" ] && [ -n "$(ls -A "$dir/build/packages" 2> /dev/null)" ]; then
    echo "  Aiken standard library already downloaded (build/packages)"
    return 0
  fi
  echo "  fetching the Aiken standard library (aiken check in the contract folder; downloads aiken-lang/stdlib v4.0.0) ..."
  (cd "$dir" && "$AIKEN" check 2>&1 | grep -E "Summary|rror" | tail -3 | sed 's/^/    /')
  if [ -d "$dir/build/packages" ]; then echo "  standard library ready"
  else echo "  could not fetch the standard library: does this machine reach github.com?"; STDLIB_FAIL=1; fi
}
STDLIB_FAIL=0

# make_venv: ~/seed-venv with the packages of seed-emulator's requirements.txt (pinned versions: web3==5.31.1 ...).
# pip installs only into the venv, nothing system-wide, no sudo.
make_venv() {
  local venv=$HOME/seed-venv out rc
  if [ -n "$APT" ]; then
    echo "  Python environment NOT created: install the missing packages first (the apt command below)"
    return 1
  fi
  echo "  creating the Python environment $venv and installing $SEED_EMULATOR/requirements.txt (takes about 1-2 minutes) ..."
  python3 -m venv "$venv" || { echo "  python3 -m venv failed"; rm -rf "$venv"; return 1; }
  out=$("$venv/bin/pip" install --disable-pip-version-check -r "$SEED_EMULATOR/requirements.txt" 2>&1); rc=$?
  if [ $rc != 0 ]; then
    printf '%s\n' "$out" | tail -15 | sed 's/^/    /'
    echo "  pip install failed (see above)"
    hint "if it says a compiler or Python.h is missing: sudo apt install -y python3-dev build-essential"
    want_apt python3-dev; want_apt build-essential
    rm -rf "$venv"      # no half-made environment: the next run starts again
    return 1
  fi
  echo "  Python environment ready: $venv ($("$venv/bin/python3" --version 2>&1))"
}

if [ $CHECK_ONLY = 0 ]; then
  echo
  echo "Downloading what is missing into ~/tools ..."
  if [ "$TOOLS_ARCH" = unknown ]; then echo "  CPU type not supported: nothing to download"
  elif ! command -v curl > /dev/null 2>&1 || ! command -v python3 > /dev/null 2>&1; then
    echo "  curl and python3 are needed to download: install them first (see the hints above)"
  else
    if [ -x "$AIKEN" ]; then
      echo "  Aiken is already there: skipped"
    else
      install_aiken || echo "  Aiken NOT installed"
    fi
    if [ -x "$KUPO_BIN" ]; then
      echo "  Kupo is already there: skipped"
    else
      install_kupo || echo "  Kupo NOT installed"
    fi
    [ -x "$AIKEN" ] && fetch_stdlib
    if [ $NEED_VENV = 1 ] && [ -d "$SEED_EMULATOR/seedemu" ]; then
      make_venv || echo "  Python environment NOT created"
    fi
    echo
    echo "Checking again ..."
    FAILS=$((FAILS_OTHER - SEED_FAILS + STDLIB_FAIL))
    if command -v python3 > /dev/null 2>&1; then check_seed; fi
    check_tools
  fi
fi

echo
if [ -n "$APT" ]; then
  echo "Missing packages. Install them yourself (this script never uses sudo):"
  echo "  sudo apt update && sudo apt install -y$APT"
  echo
fi
if [ $FAILS -eq 0 ] && [ -z "$APT" ]; then echo "ALL PASS"; exit 0; fi
if [ $CHECK_ONLY = 1 ]; then
  echo "Some checks failed (see the FAIL lines and hints). Then: ./scripts/install-tools.sh"
else
  echo "Some checks failed (see the FAIL lines and hints). Fix them and run this script again."
fi
exit 1
