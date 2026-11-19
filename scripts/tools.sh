# Shared tool settings: where Aiken, Kupo and seed-emulator live, and the CPU name used in the Aiken file name.
# Source it (do not run it):   source "$HOME/cardano-seed-testnet/scripts/tools.sh"
# It runs on the machine that hosts the chain (the Ubuntu VM), plain bash 3.2 syntax, no bash 4 features.
# Every value can be overridden with an environment variable that is set BEFORE the script is sourced:
#   AIKEN=/path/to/aiken       KUPO_BIN=/path/to/kupo       SEED_EMULATOR=/path/to/seed-emulator
#   SEED_PYTHON=/path/to/python3   (the Python that runs seed-emulator; see seed_python below)
# Used by: experiments/contract/p0-aiken.sh, scripts/install-tools.sh, experiments/demo/fresh.sh (through ssh).

AIKEN_VERSION=1.1.24
KUPO_VERSION=2.12.0
# the seed-emulator version this repository was built and tested with (Mar 2024); install-tools.sh and the docs use it
SEED_COMMIT=e26637e915fb2f83be0b165d3fb731b400db6fe6

# tools_arch: the CPU name as the Aiken download calls it: aarch64 (ARM) or x86_64 (Intel/AMD, "amd64")
tools_arch() {
  case "$(uname -m)" in
    aarch64|arm64) echo aarch64 ;;
    x86_64|amd64) echo x86_64 ;;
    *) echo unknown ;;
  esac
}

TOOLS_ARCH=$(tools_arch)
AIKEN=${AIKEN:-$HOME/tools/aiken-$AIKEN_VERSION/aiken-$TOOLS_ARCH-unknown-linux-musl/aiken}
KUPO_BIN=${KUPO_BIN:-$HOME/tools/kupo-$KUPO_VERSION/bin/kupo}
SEED_EMULATOR=${SEED_EMULATOR:-$HOME/seed-emulator}

# seed_python: prints the Python that must run seed-emulator (cardano.py and the import checks):
#   $SEED_PYTHON if it is set, else ~/seed-venv/bin/python3 if that exists (made by scripts/install-tools.sh), else python3.
# The virtual environment ~/seed-venv holds the pinned packages seed-emulator needs (web3 5.31.1 and others);
# a machine that has them installed system-wide (our own VM) simply uses python3.
seed_python() {
  if [ -n "${SEED_PYTHON:-}" ]; then echo "$SEED_PYTHON"
  elif [ -x "$HOME/seed-venv/bin/python3" ]; then echo "$HOME/seed-venv/bin/python3"
  else echo python3
  fi
}
