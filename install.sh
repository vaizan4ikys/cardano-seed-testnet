#!/bin/bash
# Install and check everything the demo needs. Runs ON THE UBUNTU VM (not on the Mac).
#
#   ./install.sh --check   only check: one PASS or FAIL line per item, with a hint for every FAIL. Changes nothing.
#   ./install.sh           the same checks, then installs what is missing, in this order:
#     1. system steps that need administrator rights: apt packages (Docker, Python tools, jq ...), the docker group,
#        starting Docker, giving / the unused part of the disk. It SHOWS every command and asks once
#        "Run them now? [y/N]"; sudo then asks for your password. Answer N and it only prints them for you.
#     2. without sudo, into your home folder:
#          ~/seed-emulator   the SEED Emulator, release v1.1 (git clone)
#          ~/seed-venv       its Python packages (requirements.txt; pip installs inside this environment only)
#          ~/tools           Aiken v1.1.24 (compiler of the smart contract) and Kupo v2.12.0 (the indexer),
#                            then the Aiken standard library (aiken downloads it itself)
#     3. checks everything again and says what is still missing.
# Running it again is safe: what is already there is skipped.
#
# Paths and versions are in scripts/tools.sh; AIKEN, KUPO_BIN, SEED_EMULATOR and SEED_PYTHON can be overridden:
#   ~/tools/aiken-1.1.24/aiken-<aarch64|x86_64>-unknown-linux-musl/aiken      (CPU type detected with uname -m)
#   ~/tools/kupo-2.12.0/bin/kupo
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CHECK_ONLY=0
case "${1:-}" in
  "") ;;
  --check) CHECK_ONLY=1 ;;
  -h|--help) sed -n '2,/^set -u$/p' "$0" | sed '$d'; exit 0 ;;
  *) echo "unknown option $1 (try --help)"; exit 1 ;;
esac

# This script is for Linux only (the Mac side of the demo needs none of this).
if [ "$(uname -s)" != Linux ]; then
  echo "  FAIL  Linux only: this script checks the Ubuntu VM, but this machine is $(uname -s)"
  echo "        hint: run it inside the Ubuntu VM (on the Mac nothing has to be installed for the demo)"
  exit 1
fi
. "$ROOT/scripts/tools.sh"     # AIKEN, KUPO_BIN, SEED_EMULATOR, SEED_TAG, TOOLS_ARCH, versions, seed_python
ME=$(id -un)

# ======================================================================================================
# Results of the checks (run_checks fills them; they are reset on every run)
# ======================================================================================================
FAILS=0         # number of FAIL lines
APT=""          # missing apt packages, installed with one apt command
SUDO_CMDS=()    # other system steps that need sudo ...
SUDO_WHY=()     # ... and why each one is needed
NEED_VENV=0     # 1: ~/seed-venv has to be created
RELOGIN=0       # 1: the user is in the group docker, but this login started before that

# ---- output helpers: one line per check ----
# pass TEXT / fail TEXT / hint TEXT: print one result line (fail also counts the failure)
pass() { printf '  PASS  %s\n' "$*"; }
fail() { FAILS=$((FAILS + 1)); printf '  FAIL  %s\n' "$*"; }
hint() { printf '        hint: %s\n' "$*"; }

# want_apt PACKAGE: remember a missing apt package (once)
want_apt() {
  case " $APT " in
    *" $1 "*) ;;                 # already in the list
    *) APT="$APT $1" ;;
  esac
}

# want_sudo "COMMAND" "WHY": remember a system step (once)
want_sudo() {
  local known
  # (bash >= 4.4: an empty array is fine with set -u)
  for known in "${SUDO_CMDS[@]}"; do
    [ "$known" = "$1" ] && return
  done
  SUDO_CMDS+=("$1")
  SUDO_WHY+=("$2")
}

# has_pkg PACKAGE: is this apt package installed?
has_pkg() { dpkg -s "$1" > /dev/null 2>&1; }

# in_group_now: this login session may use docker
in_group_now() { id -nG | tr ' ' '\n' | grep -qx docker; }

# in_group_db: the user is listed in the group docker (maybe only since a moment ago)
in_group_db() { id -nG "$ME" 2> /dev/null | tr ' ' '\n' | grep -qx docker; }

# ======================================================================================================
# Checks
# ======================================================================================================
# check_docker: the engine, the permission to use it without sudo, and the compose plugin
check_docker() {
  if ! command -v docker > /dev/null 2>&1; then
    fail "docker is not installed"
    hint "sudo apt install -y docker.io docker-compose-v2   (Ubuntu's own Docker packages)"
    want_apt docker.io; want_apt docker-compose-v2
    in_group_db || want_sudo "sudo usermod -aG docker $ME" "use docker without sudo (takes effect at the next login)"
    return
  fi
  if docker info > /dev/null 2>&1; then
    pass "docker engine runs and works without sudo"
  elif in_group_now; then
    fail "docker is installed, but the engine does not answer"
    hint "sudo systemctl enable --now docker   (then: docker info)"
    want_sudo "sudo systemctl enable --now docker" "start the docker engine now and at every boot"
  elif in_group_db; then
    RELOGIN=1
    fail "you are in the group docker, but this login started before you were added"
    hint "log out and in again (exit, then ssh again), or in this terminal only: newgrp docker. No reboot needed"
  else
    fail "docker is installed, but this user may not use it (not in the group docker)"
    hint "sudo usermod -aG docker $ME   then log out and in again (no reboot needed)"
    want_sudo "sudo usermod -aG docker $ME" "use docker without sudo (takes effect at the next login)"
  fi
  if docker compose version > /dev/null 2>&1; then
    pass "docker compose plugin: $(docker compose version --short 2>/dev/null)"
  else
    fail "docker compose plugin missing (the command 'docker compose' does not work)"
    hint "sudo apt install -y docker-compose-v2   (or docker-compose-plugin from Docker's own repository)"
    want_apt docker-compose-v2
  fi
}

# need_cmd COMMAND APT-PACKAGE: PASS when the command exists, else FAIL and remember the package
need_cmd() {
  if command -v "$1" > /dev/null 2>&1; then
    pass "$1"
  else
    fail "$1 is missing"
    hint "sudo apt install -y $2"
    want_apt "$2"
  fi
}

# check_programs: python3 and the small tools the scripts use
check_programs() {
  if command -v python3 > /dev/null 2>&1; then
    pass "python3 ($(python3 -c 'import sys; print("%d.%d.%d" % sys.version_info[:3])'))"
  else
    fail "python3 is missing"
    hint "sudo apt install -y python3"
    want_apt python3
  fi
  need_cmd git git
  need_cmd curl curl
  need_cmd jq jq
  need_cmd openssl openssl
  need_cmd rsync rsync
}

# check_seed: seedemu is imported from the clone ($SEED_EMULATOR) and needs the packages of its requirements.txt
# (web3 5.31.1 and others). They go into the virtual environment ~/seed-venv; a machine that has them system-wide
# just uses python3.
check_seed() {
  local py pkg head_now
  py=$(seed_python)
  if [ ! -d "$SEED_EMULATOR/seedemu" ]; then
    fail "seed-emulator is not cloned (no $SEED_EMULATOR/seedemu)"
    if [ $CHECK_ONLY = 1 ]; then
      hint "./install.sh clones it, or: git clone --branch $SEED_TAG https://github.com/seed-labs/seed-emulator" \
           "$SEED_EMULATOR"
    else hint "it is cloned below"; fi
    NEED_VENV=1
  elif command -v "$py" > /dev/null 2>&1 && PYTHONPATH=$SEED_EMULATOR "$py" -c 'import seedemu' > /dev/null 2>&1; then
    pass "seed-emulator can be imported (from $SEED_EMULATOR, Python: $py)"
    head_now=$(git -C "$SEED_EMULATOR" rev-parse HEAD 2> /dev/null)
    if [ -n "$head_now" ] && [ "$head_now" != "$SEED_COMMIT" ]; then
      echo "        note: seed-emulator is at commit ${head_now:0:7}, the tested one is ${SEED_COMMIT:0:7}" \
           "(release $SEED_TAG): git -C $SEED_EMULATOR checkout $SEED_TAG"
    fi
    return
  elif [ -z "${SEED_PYTHON:-}" ] && [ ! -x "$HOME/seed-venv/bin/python3" ]; then
    fail "seed-emulator cannot be imported yet (its Python packages are not installed)"
    if [ $CHECK_ONLY = 1 ]; then hint "./install.sh creates the Python environment ~/seed-venv with them"
    else hint "the Python environment ~/seed-venv is created below"; fi
    NEED_VENV=1
  else
    fail "seed-emulator cannot be imported with $py (from $SEED_EMULATOR)"
    hint "see the error with   PYTHONPATH=$SEED_EMULATOR $py -c 'import seedemu'   (to rebuild the environment:" \
         "rm -rf ~/seed-venv and run ./install.sh again)"
    return
  fi
  # the environment needs venv; python3-dev and build-essential in case pip has to compile a package
  for pkg in python3-venv python3-dev build-essential; do
    has_pkg "$pkg" || want_apt "$pkg"
  done
}

# lvm_unused_gb: GB of the disk partition below / that / does not use yet (0 unless / is Ubuntu's default LVM volume).
# Ubuntu's server installer gives / only part of the disk by default (for example 10 GB of 20 GB).
lvm_unused_gb() {
  local lv=/dev/mapper/ubuntu--vg-ubuntu--lv sizes lv_bytes below_bytes
  findmnt -n -o SOURCE / 2> /dev/null | grep -qx "$lv" || { echo 0; return; }
  sizes=$(lsblk -bnr -s -o SIZE,TYPE "$lv" 2> /dev/null)   # the volume first, then the partition (or disk) below it
  lv_bytes=$(printf '%s\n' "$sizes" | awk '$2 == "lvm" {print $1; exit}')
  below_bytes=$(printf '%s\n' "$sizes" | awk '$2 != "lvm" {print $1; exit}')
  [ -n "$lv_bytes" ] && [ -n "$below_bytes" ] || { echo 0; return; }
  echo $(( (below_bytes - lv_bytes) / 1073741824 ))
}

# check_disk_and_ram: at least 15 GB free in the home folder and 3.5 GB of memory
check_disk_and_ram() {
  local disk unused memkb
  disk=$(df -BG --output=avail "$HOME" 2>/dev/null | tail -1 | tr -dc 0-9)
  if [ "${disk:-0}" -ge 15 ]; then
    pass "free disk: $disk GB (needed: 15 GB)"
  else
    fail "free disk: ${disk:-?} GB, needed: 15 GB"
    unused=$(lvm_unused_gb)
    if [ "$unused" -ge 1 ]; then
      hint "Ubuntu's installer left $unused GB of the disk unused; one command gives them to /"
      want_sudo "sudo lvextend -r -l +100%FREE /dev/ubuntu-vg/ubuntu-lv" "give / the unused $unused GB of the disk"
    else
      hint "enlarge the virtual disk of the VM, or remove files (docker system prune)"
    fi
  fi
  memkb=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null)
  if [ "${memkb:-0}" -ge 3670016 ]; then   # 3.5 GB in kB
    pass "RAM: $((memkb / 1024)) MB (needed: 3.5 GB)"
  else
    fail "RAM: $((${memkb:-0} / 1024)) MB, needed: 3.5 GB"
    hint "give the VM more memory (at least 4 GB) in its settings, then start it again"
  fi
}

# check_repo: this repository must be reachable as ~/cardano-seed-testnet (the demo scripts expect that path)
check_repo() {
  local want have
  want=$(cd -P "$HOME/cardano-seed-testnet" 2>/dev/null && pwd -P)
  have=$(cd -P "$ROOT" && pwd -P)
  if [ -n "$want" ] && [ "$want" = "$have" ]; then
    pass "repository is in ~/cardano-seed-testnet"
  else
    fail "the repository is in $ROOT, not in ~/cardano-seed-testnet"
    hint "git clone https://github.com/vaizan4ikys/cardano-seed-testnet ~/cardano-seed-testnet" \
         "  or   ln -s $ROOT ~/cardano-seed-testnet"
  fi
}

# check_tools: the Aiken and Kupo programs exist and start
check_tools() {
  local toolhint="run ./install.sh (without --check) to download it"
  [ $CHECK_ONLY = 0 ] && toolhint="it is downloaded below"
  if [ "$TOOLS_ARCH" = unknown ]; then
    fail "CPU type '$(uname -m)' is not supported (aarch64/arm64 or x86_64/amd64 needed)"
    return
  fi
  if [ ! -x "$AIKEN" ]; then
    fail "Aiken not found: $AIKEN"
    hint "$toolhint"
  elif "$AIKEN" --version > /dev/null 2>&1; then
    pass "Aiken: $AIKEN ($("$AIKEN" --version 2>&1 | head -1))"
  else
    fail "Aiken does not run: $AIKEN"
    hint "wrong file or CPU type: delete $(dirname "$AIKEN") and run this script again"
  fi
  if [ ! -x "$KUPO_BIN" ]; then
    fail "Kupo not found: $KUPO_BIN"
    hint "$toolhint"
  elif "$KUPO_BIN" --version > /dev/null 2>&1; then
    pass "Kupo: $KUPO_BIN ($("$KUPO_BIN" --version 2>&1 | head -1))"
  else
    fail "Kupo does not run: $KUPO_BIN"
    hint "wrong file or CPU type: delete $(dirname "$(dirname "$KUPO_BIN")") and run this script again"
  fi
}

# run_checks: all checks, from scratch
run_checks() {
  FAILS=0; APT=""; SUDO_CMDS=(); SUDO_WHY=(); NEED_VENV=0; RELOGIN=0
  pass "Linux ($(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-Linux}"))"
  check_docker
  check_programs
  if command -v python3 > /dev/null 2>&1; then check_seed; fi
  check_disk_and_ram
  check_repo
  check_tools
}

# ======================================================================================================
# 1. System steps (sudo, only after the user said yes)
# ======================================================================================================
# show_system_steps: print the commands that need sudo, each with the reason
show_system_steps() {
  local i
  if [ -n "$APT" ]; then
    printf '  %-58s # %s\n' "sudo apt update" "refresh the package lists"
    printf '  %-58s # %s\n' "sudo apt install -y$APT" "missing packages"
  fi
  for i in "${!SUDO_CMDS[@]}"; do printf '  %-58s # %s\n' "${SUDO_CMDS[$i]}" "${SUDO_WHY[$i]}"; done
}

# run_system_steps: show them, ask once, run them. Returns 1 when they were not run or one of them failed.
run_system_steps() {
  local answer i failed=0
  echo
  echo "These steps need administrator rights (sudo). They are run exactly as shown:"
  show_system_steps
  if [ ! -t 0 ]; then echo "  (no terminal to ask you: run them yourself, then this script again)"; return 1; fi
  read -r -p "Run them now? sudo asks for your password once. [y/N] " answer
  case "$answer" in
    y|Y|yes|YES) ;;
    *) echo "  Not run. You can run them yourself, then this script again."; return 1 ;;
  esac
  if [ -n "$APT" ]; then
    # an error of "apt update" about one source (for example the install disk "cdrom" that is no longer attached)
    # must not stop the install: the packages usually come from the other sources
    sudo apt update || echo "  (apt update reported an error, see above; continuing)"
    sudo apt install -y $APT || { echo "  apt install FAILED (see above)"; failed=1; }
  fi
  for i in "${!SUDO_CMDS[@]}"; do
    echo "  running: ${SUDO_CMDS[$i]}"
    bash -c "${SUDO_CMDS[$i]}" || { echo "  FAILED: ${SUDO_CMDS[$i]}"; failed=1; }
  done
  return $failed
}

# ======================================================================================================
# 2. Home-folder steps (no sudo)
# ======================================================================================================
# sha_of FILE: the sha256 checksum of a file
sha_of() { sha256sum "$1" | awk '{print $1}'; }

# first_file DIR NAME: path of the first regular file called NAME below DIR (empty if none)
first_file() { find "$1" -type f -name "$2" 2> /dev/null | head -1; }

# clone_seed: git clone of the SEED Emulator release; returns 1 when the clone fails or is not the tested commit
clone_seed() {
  echo "  cloning the SEED Emulator, release $SEED_TAG, into $SEED_EMULATOR (about 400 MB) ..."
  if git clone --quiet --branch "$SEED_TAG" https://github.com/seed-labs/seed-emulator "$SEED_EMULATOR" 2> /dev/null \
     && [ "$(git -C "$SEED_EMULATOR" rev-parse HEAD)" = "$SEED_COMMIT" ]; then
    echo "  SEED Emulator ready (commit ${SEED_COMMIT:0:7})"
  else
    echo "  git clone failed (does this machine reach github.com?)"
    return 1
  fi
}

# install_aiken: download Aiken, verify its checksum when one is published, copy the program to $AIKEN
install_aiken() {
  local name=aiken-$TOOLS_ARCH-unknown-linux-musl
  local url=https://github.com/aiken-lang/aiken/releases/download/v$AIKEN_VERSION/$name.tar.gz
  local tmp want got bin
  tmp=$(mktemp -d) || return 1
  echo "  downloading $url"
  if ! curl -fL --retry 3 -sS -o "$tmp/aiken.tar.gz" "$url"; then
    echo "  download failed"
    rm -rf "$tmp"
    return 1
  fi
  got=$(sha_of "$tmp/aiken.tar.gz")
  # the release publishes <archive>.sha256 next to the archive
  want=$(curl -fL --retry 3 -sS "$url.sha256" 2> /dev/null | awk '{print $1}' | head -1)
  if printf '%s' "$want" | grep -qE '^[0-9a-fA-F]{64}$'; then
    if [ "$(printf '%s' "$want" | tr 'A-F' 'a-f')" = "$got" ]; then
      echo "  sha256 matches the published checksum: $got"
    else
      echo "  CHECKSUM MISMATCH: published $want, downloaded $got. Nothing installed."
      rm -rf "$tmp"
      return 1
    fi
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

# install_kupo: download Kupo, copy bin/kupo to $KUPO_BIN, remove it again if it does not run here
install_kupo() {
  # tag v2.12, file kupo-v2.12.0-<aarch64|x86_64>-linux.zip (no checksum file is published: we print the sha256)
  local name=kupo-v$KUPO_VERSION-$TOOLS_ARCH-linux.zip
  local url=https://github.com/CardanoSolutions/kupo/releases/download/v${KUPO_VERSION%.*}/$name
  local tmp bin
  tmp=$(mktemp -d) || return 1
  echo "  downloading $url"
  if ! curl -fL --retry 3 -sS -o "$tmp/kupo.zip" "$url"; then
    echo "  download failed"
    rm -rf "$tmp"
    return 1
  fi
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
  echo "  fetching the Aiken standard library (aiken check in the contract folder;" \
       "downloads aiken-lang/stdlib v4.0.0) ..."
  (cd "$dir" && "$AIKEN" check 2>&1 | grep -E "Summary|rror" | tail -3 | sed 's/^/    /')
  if [ -d "$dir/build/packages" ]; then
    echo "  standard library ready"
  else
    echo "  could not fetch the standard library: does this machine reach github.com?"
  fi
}

# make_venv: ~/seed-venv with the packages of seed-emulator's requirements.txt (pinned versions: web3==5.31.1 ...).
# pip installs only into the venv, nothing system-wide, no sudo.
make_venv() {
  local venv=$HOME/seed-venv out rc
  case " $APT " in
    *" python3-venv "*)
      echo "  Python environment NOT created: the package python3-venv is missing (system steps above)"
      return 1 ;;
  esac
  echo "  creating the Python environment $venv and installing $SEED_EMULATOR/requirements.txt" \
       "(takes about 1-2 minutes) ..."
  python3 -m venv "$venv" || { echo "  python3 -m venv failed"; rm -rf "$venv"; return 1; }
  out=$("$venv/bin/pip" install --disable-pip-version-check -r "$SEED_EMULATOR/requirements.txt" 2>&1); rc=$?
  if [ $rc != 0 ]; then
    printf '%s\n' "$out" | tail -15 | sed 's/^/    /'
    echo "  pip install failed (see above)"
    rm -rf "$venv"      # no half-made environment: the next run starts again
    return 1
  fi
  echo "  Python environment ready: $venv ($("$venv/bin/python3" --version 2>&1))"
}

# install_home_steps: everything that needs no sudo: the SEED clone, Aiken, Kupo, the stdlib, the Python venv
install_home_steps() {
  echo
  echo "Installing into your home folder (no sudo) ..."
  # the SEED Emulator clone
  if [ ! -d "$SEED_EMULATOR/seedemu" ]; then
    if command -v git > /dev/null 2>&1; then
      clone_seed || echo "  SEED Emulator NOT cloned"
    else
      echo "  git is needed to clone the SEED Emulator (system steps above)"
    fi
    run_checks > /dev/null          # NEED_VENV now refers to the new clone
  fi
  # Aiken, Kupo and the Aiken standard library
  if [ "$TOOLS_ARCH" = unknown ]; then
    echo "  CPU type not supported: Aiken and Kupo cannot be downloaded"
  elif ! command -v curl > /dev/null 2>&1 || ! command -v python3 > /dev/null 2>&1; then
    echo "  curl and python3 are needed to download (system steps above)"
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
  fi
  # the Python environment
  if [ $NEED_VENV = 1 ] && [ -d "$SEED_EMULATOR/seedemu" ]; then
    make_venv || echo "  Python environment NOT created"
  fi
}

# ======================================================================================================
# Main
# ======================================================================================================
echo "Checking this machine ($(uname -m), $TOOLS_ARCH) ..."
run_checks

if [ $CHECK_ONLY = 0 ]; then
  if [ -n "$APT" ] || [ ${#SUDO_CMDS[@]} -gt 0 ]; then
    run_system_steps
    run_checks > /dev/null          # what is still missing after the system steps
  fi
  install_home_steps
  echo
  echo "Checking again ..."
  run_checks
fi

echo
if [ -n "$APT" ] || [ ${#SUDO_CMDS[@]} -gt 0 ]; then
  echo "Still needed: these steps need administrator rights (./install.sh offers to run them for you):"
  show_system_steps
  echo
fi
if [ $FAILS -eq 0 ]; then echo "ALL PASS"; exit 0; fi
if [ $FAILS -eq 1 ] && [ $RELOGIN = 1 ]; then
  echo "Almost done: log out and in again (exit, then ssh again) so that docker works without sudo; then check:"
  echo "  ./install.sh --check"
elif [ $CHECK_ONLY = 1 ]; then
  echo "Some checks failed (see the FAIL lines and hints). ./install.sh installs what it can."
else
  echo "Some checks failed (see the FAIL lines and hints). Fix them and run this script again."
fi
exit 1
