# Install and run the demo on your own Ubuntu virtual machine

This guide takes you from "a Windows PC with nothing installed" to "the demo runs and I see it in my Windows browser".
Follow the steps in order. Every step has the exact command and a line that says what you should see.

## What you get

* A private Cardano blockchain with 3 stake pools, running inside a virtual Ubuntu machine on your PC.
* Simulated sensors that send readings to a gateway; the gateway writes them into the chain through a smart contract
  (a small program on the chain that only lets approved gateways in).
* A web page (opened in your Windows browser) that reads the data back from the chain.

**Time:** plan about 1 hour the first time (installing Ubuntu, the downloads, the build of the docker image; it depends on your internet speed).
On our test VM (2 CPUs, 4 GB RAM, fast internet) the home-folder part of `install.sh` took about 1.5 minutes (plus the apt downloads), `fresh.sh --yes` 4.5 minutes and the rehearsal `demo.sh --yes` about 5 minutes
(the build of the `seedemu-cardano` docker image from scratch was not part of that run: see "Tested on").
Later runs (a new chain with `fresh.sh --yes`, then the demo) need about 5 minutes plus the demo.

## Words used in this guide

* **VM** (virtual machine): a computer simulated by a program, with its own Ubuntu inside your Windows.
* **Host**: your Windows PC. **Guest**: the Ubuntu inside the VM.
* **Docker**: runs programs in isolated "containers". The whole blockchain (about 35 containers) runs in Docker.
* **Stake pool**: a node that makes blocks. This chain has 3.
* **Kupo**: a small indexer that lets the web page read the chain quickly.
* **Aiken**: the language and compiler of the smart contract.

## 0. Requirements

| | Minimum | Recommended |
|---|---|---|
| PC | Windows 10 or 11, 64 bit | same |
| Virtualization | switched on in BIOS/UEFI (called VT-x, AMD-V or "SVM mode") | same |
| VM CPUs | 2 | 4 |
| VM RAM | 4 GB | 6 GB |
| VM disk | 30 GB | 40 GB |
| Internet | needed (downloads of about 5 GB in total, see below) | |

Check that virtualization is on: Task Manager (Ctrl+Shift+Esc) -> tab Performance -> CPU -> "Virtualization: Enabled".
If it says "Disabled", switch it on in the BIOS/UEFI (the key at power-on differs per PC: Del, F2, F10 ...).

Downloads. What was measured on the test VM: the SEED clone 400 MB on disk, its Python packages 70 MB, Aiken 14 MB, Kupo 54 MB (273 MB unpacked),
the SEED router and map images about 1.1 GB on disk (pulled by the first `fresh.sh`).
Not measured (plan for them): the Ubuntu ISO (about 2 GB), the apt packages for Docker and Python (about 150-250 MB), the base image `handsonsecurity/seedemu-multiarch-base` and the `cardano-node` image
from ghcr.io that our image is built from. So "about 5 GB in total" is an estimate. `install.sh` checks for 15 GB of free disk.

## Part A. Create the VM

### 1. Install VirtualBox on Windows

Download VirtualBox (free) from <https://www.virtualbox.org/wiki/Downloads> ("Windows hosts") and install it with the defaults.

*You should see:* VirtualBox Manager opens.

If VirtualBox later says that virtualization is not available although it is on in the BIOS, another Windows feature
(Hyper-V, "Virtual Machine Platform", "Windows Hypervisor Platform") may be using it. VirtualBox 7 normally works next
to them, only slower; if the VM does not start, switch these features off in "Turn Windows features on or off" and restart.

*VMware Workstation instead:* it is also free for personal use. Create the VM in the same way (Linux, Ubuntu 64-bit, same sizes).
VMware has no port forwarding rule to set: use "NAT", find the VM's address with `ip -4 addr` inside the VM, and in the ssh
commands below replace `-p 2222 ... 127.0.0.1` by the VM address (for example `ssh <user>@192.168.xxx.xxx`).

### 2. Download Ubuntu Server 22.04 LTS

Download the ISO "Ubuntu Server 22.04 LTS" (22.04.x, `...-live-server-amd64.iso`) for **amd64** (the normal PC processor) from <https://releases.ubuntu.com/22.04/>.
(If your PC has an ARM processor, download the arm64 version instead.)

**Use 22.04, not 24.04.** The SEED Emulator version we use needs old pinned Python packages (web3 5.31.1, requests 2.22.0 ...).
We tried to install them on both versions (in containers): on Ubuntu 22.04 (Python 3.10) it works; on Ubuntu 24.04 (Python 3.12) the import of `seedemu`
fails three times in a row (`urllib3` needs `six.moves`, `web3` needs `pkg_resources`, `parsimonious` needs `inspect.getargspec`), and it is not worth patching.
(Ubuntu 20.04, Python 3.8, also works, with the same commands: our test VMs run it.)

*You should see:* a file `ubuntu-22.04...-live-server-amd64.iso` of about 2 GB.

### 3. Create the VM in VirtualBox

1. Click **New**. Name: `cardano-demo`. ISO Image: the file from step 2. Tick **Skip Unattended Installation**.
2. Hardware: Base Memory 6144 MB (minimum 4096), Processors 4 (minimum 2).
3. Virtual Hard Disk: 40 GB (minimum 30 GB).
4. Finish. Then select the VM -> **Settings** -> **Network** -> Adapter 1 (must be **NAT**) -> **Advanced** -> **Port Forwarding** -> add a rule:

   | Name | Protocol | Host IP | Host Port | Guest IP | Guest Port |
   |---|---|---|---|---|---|
   | ssh | TCP | 127.0.0.1 | 2222 | (empty) | 22 |

*You should see:* the rule in the list; click OK twice.

### 4. Install Ubuntu in the VM

Start the VM and go through the Ubuntu installer. Keep the defaults, except:

* Type of install: **Ubuntu Server** (not "minimized").
* Storage: use the whole disk (the default). **Then check the summary screen** ("Storage configuration"): with the
  default LVM layout Ubuntu gives the system (`ubuntu-lv`, mounted at `/`) only part of the disk, for example 10 GB of 20 GB,
  and the demo needs about 15 GB free. Select `ubuntu-lv` -> Edit -> set Size to the maximum shown -> Save.
  (Forgot it? After the install, one command gives `/` the rest of the disk:
  `sudo lvextend -r -l +100%FREE /dev/ubuntu-vg/ubuntu-lv`; `df -h /` then shows the bigger size.)
* Your name, server name, **user name** and password: choose them and write them down. Below `<user>` means your user name.
* **Install OpenSSH server**: tick it. (Leave "Import SSH identity" at No.)
* Do not select extra "featured server snaps" (no docker snap: `install.sh` installs Docker in step 8).

When the installer says "Installation complete", choose **Reboot Now**. If it asks to remove the installation medium, press Enter.

*You should see:* a text login prompt `cardano-demo login:`. You can log in there, but it is easier to work from Windows (step 5).

A VM without a desktop is fine. Everything is done in the terminal; the web page is shown in your Windows browser.

### 5. Log in from Windows with ssh

Open **PowerShell** (Start menu -> type `PowerShell`) and run (replace `<user>`):

```
ssh -p 2222 <user>@127.0.0.1
```

Answer `yes` to the question about the host key, then type your password.

*You should see:* a prompt like `<user>@cardano-demo:~$`. This is the Ubuntu terminal. Everything from here on is typed there
(you can paste with a right-click in PowerShell).

If `ssh` is "not recognized": Windows Settings -> Apps -> Optional features -> Add a feature -> **OpenSSH Client**.
If ssh says "REMOTE HOST IDENTIFICATION HAS CHANGED" (you had another VM on port 2222 before), run in PowerShell
`ssh-keygen -R "[127.0.0.1]:2222"` and try again.

## Part B. Get the code and install everything (in the VM)

### 6. This repository

Ubuntu Server already has `git`. The folder must be exactly `~/cardano-seed-testnet`: some scripts rely on it.

```
git clone https://github.com/vaizan4ikys/cardano-seed-testnet ~/cardano-seed-testnet
cd ~/cardano-seed-testnet
```

*You should see:* `ls` lists `README.md`, `install.sh`, `run.sh`, `scripts`, `experiments`, `docs` ...
(If `git` is "not found": `sudo apt update`, then `sudo apt install -y git`.)

### 7. Check the clock

```
timedatectl
```

*You should see:* the line `System clock synchronized: yes`. If it says `no`, run `sudo timedatectl set-ntp true`, wait a minute and check again.

Why: the blockchain takes its time from the VM clock. The chain only starts if the clock is right, and `fresh.sh` refuses to start with an unsynchronised clock.
Do not set the clock by hand while the chain runs.

### 8. Run the installer

```
./install.sh
```

It checks the VM, then installs what is missing, in this order:

1. **System steps that need administrator rights** (`sudo`). It first SHOWS them and asks once; on a new Ubuntu they look like this:
   ```
   These steps need administrator rights (sudo). They are run exactly as shown:
     sudo apt update                                            # refresh the package lists
     sudo apt install -y docker.io docker-compose-v2 jq ...     # missing packages
     sudo usermod -aG docker <user>                             # use docker without sudo (takes effect at the next login)
     sudo lvextend -r -l +100%FREE /dev/ubuntu-vg/ubuntu-lv     # give / the unused 10 GB of the disk
   Run them now? sudo asks for your password once. [y/N]
   ```
   Type `y`, press Enter, then type your password (it is not shown while you type).
   The `lvextend` line only appears when Ubuntu's installer left part of the disk unused (step 4).
   Docker comes from Ubuntu's own packages (`docker.io`, `docker-compose-v2`: on 22.04 Docker 29.x and Compose 2.40.x,
   on 20.04 Docker 26.1 and Compose 2.27). Prefer to type these commands yourself? Answer `N` and follow Part C.
2. **Without sudo, into your home folder:** the SEED Emulator release v1.1 (`~/seed-emulator`, about 400 MB), its pinned Python
   packages in the environment `~/seed-venv` (web3 5.31.1 and others, about 70 MB), **Aiken v1.1.24** (compiler of the smart
   contract, checked against its published checksum) and **Kupo v2.12.0** (the indexer) for your CPU type in `~/tools`,
   and the Aiken standard library (downloaded by `aiken check`, needs github.com).
3. **All checks again.**

*You should see,* the first time, at the end:

```
Almost done: log out and in again (exit, then ssh again) so that docker works without sudo; then check:
  ./install.sh --check
```

If `apt update` prints an error about `cdrom`, that is harmless (see the troubleshooting table). The scripts find SEED and
`~/seed-venv` by themselves: there is nothing to put into `~/.bashrc`.

### 9. Log in again and check

Docker may only be used without `sudo` after a new login (Linux reads a user's groups when they log in; no reboot needed):

```
exit
```

In PowerShell log in again (`ssh -p 2222 <user>@127.0.0.1`), then:

```
cd ~/cardano-seed-testnet
./install.sh --check
```

*You should see:* one `PASS` line per item (Linux, docker, docker compose, python3, git, curl, jq, openssl, rsync, seed-emulator,
free disk at least 15 GB, RAM at least 3.5 GB, repository folder, Aiken, Kupo) and at the end `ALL PASS`.
For every `FAIL` the script prints a hint; `./install.sh` (without `--check`) installs what it can.
On an amd64 PC the Aiken folder is `aiken-x86_64-unknown-linux-musl` (not tested).

## Part C. Optional: the same by hand (skip it if step 9 printed `ALL PASS`)

Only if you answered `N` in step 8 and prefer to type the system commands yourself. Afterwards run `./install.sh` again:
it then finds nothing to do with `sudo` and installs the rest.

### 10. System packages

```
sudo apt update
sudo apt install -y git python3 python3-venv python3-dev build-essential curl jq openssl rsync ca-certificates docker.io docker-compose-v2
```

(`python3-venv`, `python3-dev` and `build-essential` are for the Python environment of the SEED Emulator; `build-essential` is only
needed when a Python package has to be compiled. An error of `apt update` about `cdrom`: see the troubleshooting table.)

*You should see:* the install finishes without red errors; `sudo systemctl is-active docker` prints `active`.
(Alternative for Docker, the official packages from Docker's own repository: <https://docs.docker.com/engine/install/ubuntu/>;
install `docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin`. The scripts only need that `docker`
and `docker compose` work.)

### 11. Use Docker without sudo

```
sudo usermod -aG docker $USER
exit
```

Log in again (a new login is enough; to stay logged in, `newgrp docker` gives the group to the current terminal only). Check:

```
docker run --rm hello-world
docker compose version
```

*You should see:* "Hello from Docker!" and a line like `Docker Compose version v2.x.x`.

### 12. Disk (only if `./install.sh --check` says `free disk ... needed: 15 GB`)

If the hint says that Ubuntu's installer left part of the disk unused, give it to `/`:

```
sudo lvextend -r -l +100%FREE /dev/ubuntu-vg/ubuntu-lv
df -h /
```

### 13. The rest (no sudo)

```
cd ~/cardano-seed-testnet
./install.sh
```

It clones the SEED Emulator (by hand it would be `git clone --branch v1.1 https://github.com/seed-labs/seed-emulator ~/seed-emulator`;
a release is a fixed version, git calls that "detached HEAD", which is normal), creates `~/seed-venv`, downloads Aiken and Kupo,
and ends with `ALL PASS`.

## Part D. Build the chain and rehearse (in the VM)

### 14. See what `fresh.sh` will do (changes nothing)

```
./experiments/demo/fresh.sh --dry-run
```

*You should see:* numbered steps (new chain, wait for blocks, Kupo, administrator and gateway keys, Aiken build, registry, funding, preflight),
each with the command that would run. Nothing is changed.

### 15. Build the chain, the contract and the registry

```
./experiments/demo/fresh.sh --yes
```

This creates a **new** chain (new genesis, new keys), compiles and deploys the smart contract, creates the gateway registry
(the list of approved gateways: gateway A is approved, gateway B is not), and funds the two gateway wallets.
On the test VM (2 CPUs, 4 GB RAM) it took **4 minutes 25 seconds**, including the download of the SEED router and map images (about 1.1 GB) by `docker compose`.
**The first time on a new VM it takes longer** than that: the image `seedemu-cardano:local` does not exist yet, so `run.sh` builds it first
(`docker build` of `image/Dockerfile`, which downloads the Cardano node image `ghcr.io/intersectmbo/cardano-node:11.1.3` and the SEED base image). This build was **not tested** by us
(our test VM already had the image); expect 5 to 15 more minutes, depending on your internet.
The first Aiken build also downloads the Aiken standard library from GitHub (already done by `install.sh` in step 8).
Do not close the terminal while it runs. If the ssh window might close (laptop sleeps), run it inside `tmux` (`sudo apt install -y tmux`, then `tmux`; we did not use tmux in our test, we used a background job).
The output of `run.sh` goes to `~/fresh-run.log`; `fresh.sh` itself prints only the steps.

*You should see:* the steps `0.` to `10.` one after the other, ending with the preflight (step 10) and only `PASS` lines. The last lines are:

```
  step 0: PASS, 13 s

==================== SUMMARY
  step 0  PASS        13 s

Fresh chain ready. Run the demo: /home/<user>/cardano-seed-testnet/experiments/demo/demo.sh
```

`fresh.sh` also rewrites `experiments/pipeline/gateways.json` with the new wallet addresses (it did so in local mode). If you cloned the repository with git, `git status` shows that file as changed. This is normal.

### 16. Rehearsal: run the whole demo without pauses

```
./experiments/demo/demo.sh --yes
```

*You should see:* the steps 0 to 6, each with `PASS` lines, and at the end a summary with `PASS` for every step (`step 6  PASS`). It took 5 minutes 15 seconds on the test VM (steps 0 to 6: 4, 1, 102, 29, 78, 71, 30 seconds).
If a line says `FAIL`, it prints a `hint:` line below it; see the troubleshooting table.
Everything the demo starts is stopped again at the end.

## Part E. See it in your Windows browser

The page runs inside the VM, listening only on the VM's own address (`127.0.0.1:8088`). To see it from Windows you open an
ssh **tunnel** (a forwarded port). The Windows PC is not directly connected to that port.

### 17. Open the tunnel

Open a **second** PowerShell window (keep it open during the whole demo) and run:

```
ssh -p 2222 -L 8088:127.0.0.1:8088 <user>@127.0.0.1
```

*You should see:* a normal login, as in step 5. This window now forwards port 8088 of Windows to port 8088 of the VM.

### 18. Start the demo and open the page

In your first terminal (in the VM) start the real demo:

```
cd ~/cardano-seed-testnet
./experiments/demo/demo.sh
```

It stops before every step with `[press Enter to start this step]`. After step 1 has started the page server, open
<http://127.0.0.1:8088> in your Windows browser.

*You should see:* the page "Sensor data on the blockchain" with the header "Sensors live / Readings stored permanently / Approved gateways"
and three tabs: Sensors, Trust, Details. In step 2 sensor cards appear and the numbers move.
What to click and what to say is in [`experiments/demo/README.md`](../experiments/demo/README.md).
In local mode `demo.sh` opens no tunnel and no browser; step 1 prints `>>> open http://127.0.0.1:8088 in the browser <<<` and the ssh command for a tunnel (checked on the test VM).

## Presenting the demo

Use [`experiments/demo/README.md`](../experiments/demo/README.md): what the demo proves, what to say and click in each step, timings, and what to do if something goes wrong.
Before a presentation: run the rehearsal (step 16) at least 10 minutes earlier, so that the chain already holds batches that are "final".

Useful commands:

```
./experiments/demo/demo.sh --step 0      # only the preflight: is everything ready?
./experiments/demo/demo.sh --step 6      # clean stop of everything the demo started
```

## Optional: three gateway sites on the same VM

The demo above has one enrolled gateway (GW01) and one refused gateway (GW02). `experiments/multisite` adds three more
"sites" (GW03-GW05), each with its own Cardano node container, wallet and 10 sensors, on the same VM. It needs about
0.4 GB more RAM. Build the chain with pool 1 exposed (asks for your sudo password once), then follow
[`experiments/multisite/README.md`](../experiments/multisite/README.md), section "On the one VM":

```
EXPOSE=1 ./experiments/demo/fresh.sh --yes
```

Measured results of the 3-site tests (revoke one site, cut one site off the network) are in
[`experiments/multisite/RESULTS.md`](../experiments/multisite/RESULTS.md).

## Stopping, restarting, after a reboot

| You want to | Do |
|---|---|
| Stop the demo processes (page, gateways, sensors) | `./experiments/demo/demo.sh --step 6` |
| Stop the whole chain (removes the containers) | `./stop.sh` |
| Make a new chain with new demo data | `./experiments/demo/fresh.sh --yes` |

**Important: the chain cannot be paused.** Blocks are tied to the wall clock. If all nodes stand still for more than about
15 minutes (3k/f = 900 seconds), they cannot continue and the chain is dead. This happens when you shut the VM down,
suspend or save its state, close the laptop lid, or the PC goes to sleep. So:

* After the VM was off, suspended or the PC slept for more than about 10 minutes: do not try to repair the chain. Run `./experiments/demo/fresh.sh --yes` again.
  It builds a **new** chain; the old demo data (batches, sensors on the page) is gone. The image is already built, so it is faster than the first time.
* After a short pause run `./experiments/demo/demo.sh --step 0`; if every line is `PASS`, you can go on.
* Before a presentation, switch off sleep in Windows (Settings -> System -> Power -> Screen and sleep: "Never") and do not suspend the VM.
* After a reboot of the VM the containers are not running. Run `./stop.sh` once, then `./experiments/demo/fresh.sh --yes`.
  (All 37 containers have the Docker restart policy `no`, checked with `docker inspect`: they are not started again by Docker after a reboot. We did not reboot the test VM.)

The exact limits are in [`spec/README.md`](../spec/README.md) and [`docs/troubleshooting.md`](troubleshooting.md).

## Troubleshooting

| Symptom | Cause | What to do |
|---|---|---|
| `permission denied while trying to connect to the Docker daemon socket` | your user is not in the `docker` group yet, or you did not log in again | `sudo usermod -aG docker $USER`, then `exit` and log in again; check with `docker run --rm hello-world` |
| `ModuleNotFoundError: No module named 'seedemu'` | the clone of the SEED Emulator is not in `~/seed-emulator` (the scripts set `PYTHONPATH` themselves) | `./install.sh` clones it (step 8), or set the folder: `export SEED_EMULATOR=<folder>`; `./install.sh --check` shows what is missing |
| `ModuleNotFoundError: No module named 'web3'` (or `yaml`, `eth_account`, `requests`, `urllib3`, `pkg_resources`, `parsimonious`) | the Python packages of SEED are missing, or you run a different Python than `~/seed-venv`, or you use Ubuntu 24.04 (its Python 3.12 is too new for the pinned packages, see step 2) | `./install.sh` creates `~/seed-venv`; if `~/seed-venv` is broken, delete it (`rm -rf ~/seed-venv`) and run the script again; on 24.04 install Ubuntu 22.04 instead |
| `sudo apt update`: `The repository 'file:/cdrom ... Release' no longer has a Release file` | the Ubuntu installer added the install ISO ("cdrom") as a package source; the ISO is not attached any more | `sudo sed -i '/cdrom/s/^deb/# deb/' /etc/apt/sources.list`, then `sudo apt update` again. If `apt install` then says `Unable to locate package`, the installer had no internet and wrote no online sources: check `grep -v '^#' /etc/apt/sources.list` |
| `install.sh --check`: `free disk: ... needed: 15 GB`, although the VM disk is big enough | Ubuntu's installer gave `/` only part of the disk (default LVM layout; `lsblk` shows `ubuntu--vg-ubuntu--lv` smaller than its partition) | `sudo lvextend -r -l +100%FREE /dev/ubuntu-vg/ubuntu-lv`, then `df -h /` |
| `fresh.sh` stops with `container files: STILL wrong in: ...` | older version of this repository: the legacy docker builder put files of one container into another container's image | `git pull`, then run `fresh.sh` again (since 19 Nov 2026 `run.sh` prevents it) |
| `clock is not NTP-synced yet, wait and retry` | the VM clock is not synchronised | `sudo timedatectl set-ntp true`, wait 1 minute, `timedatectl` must show `System clock synchronized: yes` |
| `fresh.sh` or the preflight says the page port 8088 is busy | an old page server or another program uses the port | `./experiments/demo/demo.sh --step 6`; find the owner with `ss -ltnp \| grep 8088`; or use another port: `PORT=8089 ./experiments/demo/demo.sh` (then use 8089 in the tunnel and in the browser) |
| Windows: `bind [127.0.0.1]:8088: Address already in use` / `Could not request local forwarding` | an old tunnel window or another program on Windows uses port 8088 | close the old ssh window; find the owner in PowerShell: `netstat -ano \| findstr :8088`; or use another local port: `ssh -p 2222 -L 8090:127.0.0.1:8088 <user>@127.0.0.1` and open <http://127.0.0.1:8090> |
| Browser shows "connection refused" at 127.0.0.1:8088 | the tunnel is not open, or the page server is not running yet (before step 1 of the demo) | check the tunnel window (step 17) and that `demo.sh` is past step 1; in the VM: `curl -s http://127.0.0.1:8088/health` |
| `no space left on device`, or the check says the free disk is too low | VM disk too small | at least 15 GB free in the VM (`df -h /`); free space with `docker system prune` (only when the chain is stopped) or enlarge the VM disk |
| Containers killed, `Cannot allocate memory`, VM freezes | not enough RAM | give the VM at least 4 GB (6 GB recommended), stop other programs on Windows |
| `DeadlineExceeded` while building the image | too many parallel builds | `COMPOSE_PARALLEL_LIMIT=2 ./experiments/demo/fresh.sh --yes` |
| `fresh.sh` fails at the Aiken step ("aiken step failed") | Aiken missing or wrong CPU type in `~/tools`, or no access to github.com (the Aiken standard library is downloaded on the first build) | run `./install.sh` again; test `curl -sI https://github.com \| head -1`; then run `fresh.sh --yes` again |
| Preflight: `Kupo not ok` | Kupo is not running, or still catching up with the chain | the hint says: `cd ~/cardano-seed-testnet/experiments/pipeline && ./kupo.sh start` (after a **new** chain: `./kupo.sh wipe` first, then `./kupo.sh start`); `./kupo.sh status` shows `behind: N slots`, wait until N is 30 or less and run `demo.sh --step 0` again |
| Preflight: `tip not advancing` | the chain stands still (VM was paused or suspended) | `./experiments/demo/fresh.sh --yes` (new chain) |
| `fresh.sh` waits for blocks and gives up | the first block must come within 900 s of the genesis start; slow machine | run `./experiments/demo/fresh.sh --yes` again; give the VM more CPUs |

More known problems: [`docs/troubleshooting.md`](troubleshooting.md).

## Tested on

Checked on 19 November 2026 by following this guide (from step 6 on, with the differences below) on a test VM: **Ubuntu 20.04.5 arm64, 2 CPUs, 4 GB RAM**, a new user without `sudo` rights.
That test used the manual system steps (now Part C). The `sudo` question of `install.sh` (step 8) was added later the same day.

A second test the same day, on a **new VM** (VMware Fusion, Ubuntu 20.04.5 arm64, 2 CPUs, 4 GB RAM, 20 GB disk), with the
system steps typed by hand, found three problems that are fixed now: the `cdrom` error of `apt update` (troubleshooting
table), only 10 GB of the 20 GB disk given to `/` by Ubuntu's installer (step 4, `install.sh` offers `lvextend`), and docker
images that got files of other containers on the first build (`fresh.sh` stopped with `container files: STILL wrong`;
`run.sh` now prevents it). On that VM `install.sh --check`, the answer `N` and a run without a terminal were tested;
the answer `y` and a full `fresh.sh` with the fix are the next test.

| What | Result |
|---|---|
| System packages (now step 8, or by hand steps 10 and 11): `docker.io`, `docker-compose-v2`, Python tools | done with `sudo` by the administrator of the test VM (Docker 26.1.3, Compose 2.27.1); the user `leader` is in the group `docker` |
| Clone of SEED (now done by `install.sh`) | 10 s |
| `install.sh --check`, then `install.sh` (home-folder part) | 40 s, `ALL PASS` |
| Step 14 (`fresh.sh --dry-run`) | no changes, steps 0 to 10 listed |
| Step 15 (`fresh.sh --yes`) | 4 min 25 s, preflight all `PASS`; a second run 4 min 28 s |
| Step 16 (`demo.sh --yes`) | 5 min 15 s, steps 0 to 6 all `PASS` |
| Step 18, page through a tunnel | `http://127.0.0.1:8089` -> VM port 8088: HTTP 200, `/api/state` shows `registry known=true` |

Not tested (be careful, report problems with the step number and the output):

* **amd64** (a normal Windows PC). The scripts choose the Aiken and Kupo files by `uname -m`, but only the arm64 files were downloaded and run.
* **Ubuntu 22.04**, the version this guide asks for: only the Python packages were tested there, in a container (`pip install -r requirements.txt` and `import seedemu` work with Python 3.10).
  The whole demo ran on Ubuntu 20.04 only. In a container on Ubuntu 24.04 the same packages do **not** work (see step 2).
  The Ubuntu 22.04 packages `docker.io` (29.1.3) and `docker-compose-v2` (2.40.3) exist in `universe` (checked with `apt-cache policy`) but were not run; the test VM had Docker 26.1.3 and Compose 2.27.1.
* **The first build of the docker image** `seedemu-cardano:local` (pulls `ghcr.io/intersectmbo/cardano-node:11.1.3` and `handsonsecurity/seedemu-multiarch-base`): the test VM already had the image.
* Steps 1 to 5 (VirtualBox, Ubuntu installer, Windows ssh), 7 (clock in a VirtualBox VM) and step 17 (tunnel from Windows) were written from the documentation of VirtualBox and OpenSSH and not run.
  (The tunnel was tested from a Mac with the same `ssh -L` option.)
* `git clone` of this repository on the VM: the repository is public and answers without a login (`git ls-remote`), but the test VM got a copy with `rsync`, not a clone.
* A reboot of the VM, and a run on a machine with only 3 GB RAM or a slow disk.
