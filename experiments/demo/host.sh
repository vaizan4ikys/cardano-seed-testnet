# Shared by demo.sh and fresh.sh (sourced, not run). Decides WHERE the chain runs and gives both scripts the same helpers.
# bash 3.2 compatible (macOS). The caller sets SSHO (the ssh options) before sourcing this file.
#
#   CHAIN_HOST=local      everything runs on this machine (you are inside the Ubuntu VM). Default on Linux.
#   CHAIN_HOST=seedvm     drive the VM with the ssh alias seedvm from the Mac. Default on macOS.
#   CHAIN_HOST=<name>     any other ssh host name or alias: same as seedvm mode.
#
# In local mode the repository must be in $HOME/cardano-seed-testnet (the commands on the chain host use paths
# relative to $HOME, for example cardano-seed-testnet/experiments/...).

case "$(uname -s)" in
  Linux) CHAIN_HOST=${CHAIN_HOST:-local} ;;
  *) CHAIN_HOST=${CHAIN_HOST:-seedvm} ;;
esac
if [ "$CHAIN_HOST" = local ]; then LOCAL=1; else LOCAL=0; fi

# The folder of seed-emulator, written so that the CHAIN HOST evaluates it (single quotes: nothing is expanded here).
# Use it inside a double-quoted vm "..." command:   vm "PYTHONPATH=$SEEDPATH python3 -c 'import seedemu'"
SEEDPATH='${SEED_EMULATOR:-$HOME/seed-emulator}'
# The Python that runs seed-emulator on the chain host (SEED_PYTHON, else ~/seed-venv/bin/python3, else python3; see scripts/tools.sh).
# Also evaluated by the chain host; if tools.sh is missing or old there it falls back to python3. Same use:
#   vm "PYTHONPATH=$SEEDPATH $SEEDPY -c 'import seedemu'"
SEEDPY='$(. "$HOME/cardano-seed-testnet/scripts/tools.sh" > /dev/null 2>&1; seed_python 2> /dev/null || echo python3)'

# Lines that the ssh client prints about its key exchange; they are noise.
SSH_NOISE="post-quantum|vulnerable|upgraded"

# vm COMMAND...: run a shell command on the chain host, in $HOME. Prints its output (without ssh noise), returns its exit code.
# Remote mode: ssh. Local mode: bash -c in $HOME with no stdin, the same way ssh -n runs it.
vm() {
  local o rc=0
  if [ $LOCAL = 1 ]; then
    o=$(cd "$HOME" && bash -c "$*" 2>&1 < /dev/null) || rc=$?
  else
    o=$(ssh -n $SSHO "$CHAIN_HOST" "$@" 2>&1) || rc=$?
  fi
  [ -n "$o" ] && { printf '%s\n' "$o" | grep -v -E "$SSH_NOISE" || true; }
  return $rc
}

# push SRC DEST [rsync options]: copy a file or folder from this machine to $CHAIN_HOST:DEST (DEST is relative to $HOME there).
# Local mode: nothing to copy, the files are already in place.
push() {
  [ $LOCAL = 1 ] && return 0
  local src=$1 dst=$2; shift 2
  rsync -a -e "ssh $SSHO" "$@" "$src" "$CHAIN_HOST:$dst" 2>&1 | grep -v -E "$SSH_NOISE"
  return 0
}

# The repository must be in $HOME/cardano-seed-testnet in local mode. Prints a message and returns 1 when it is not.
# $1 = the repository this script belongs to.
local_repo_ok() {
  local want have
  want=$(cd -P "$HOME/cardano-seed-testnet" 2>/dev/null && pwd -P) || return 1
  have=$(cd -P "$1" && pwd -P)
  [ "$want" = "$have" ]
}
