# multisite: gateways at several sites (sensors -> own node -> registry contract)

`multisite.sh` runs up to three site gateways, each with its own Cardano node container (`site1..site3`), its own wallet
(the key is made inside the container and never leaves it), 10 simulated sensors, and an enrolment in the registry.
The page shows them as GW03, GW04, GW05. Run `./multisite.sh` without arguments for the list of commands.

## One machine or three? (switch `SITES`)

| `SITES=` | where the sites run | default when |
|---|---|---|
| `vms` | site k on its own machine seedvm2 / seedvm3 / seedvm4, chain on seedvm | the script runs on the Mac |
| `local` | the three node containers run next to the chain on the SAME machine, gateways and sensors are processes there (ports 9111..9113) | the script runs on Linux, i.e. inside the chain VM |

The chain host comes from `CHAIN_HOST` exactly as in `../demo/host.sh` (`local` on Linux, `seedvm` on the Mac).
From the Mac you can also drive a single VM: `SITES=local ./multisite.sh ...` (keep using the same machine for all commands:
the run folders of the sites are remembered in `state/`). Without `SITES=local` the Mac uses the three machines, as before.

`SITES_COUNT=1|2|3` (default 3) limits the number of sites; give it to every command (also `teardown`).

## RAM

Measured on a 4 GB VM (Ubuntu 20.04, 2 CPUs, chain with 3 pools + Kupo running): each site node container uses about
**55-70 MB** (`./multisite.sh mem`; the chain is young and small, it grows with the chain), a gateway process and a sensor process about
10-15 MB each. All three sites together cost roughly 250-300 MB. `setup` refuses to start another node when less than
`MINFREE` MB (default 500) of RAM is available. Chain, Kupo and the SEED containers need the rest.

## On the one VM (the leader's case)

The chain must be built with pool 1 exposed, because the site nodes dial pool 1 on the published port 3001:
`EXPOSE=1 ./experiments/demo/fresh.sh --yes` (it asks for your sudo password once, for one iptables rule).
Kupo must run (fresh.sh starts it). The repository must be in `~/cardano-seed-testnet`. `sudo` is needed for `cut`.

```
cd ~/cardano-seed-testnet/experiments/multisite
./multisite.sh setup                      # nodes, wallets, funding, enrolment (a few minutes)
cd ../demo && ./demo.sh --step 1 --keep   # restart the page server so that it reads the new gateways.json; page: http://127.0.0.1:8088
cd ../multisite
./multisite.sh start                      # gateways + 10 sensors per site
./multisite.sh status                     # sent / pending / dead per site
./multisite.sh mem                        # RAM of the site nodes
./multisite.sh revoke 2; ./multisite.sh enrol 2     # site 2 loses / regains its permission (its batches are refused meanwhile)
./multisite.sh cut 3; ./multisite.sh uncut 3         # site 3 loses the network (100 % loss) and gets it back
./multisite.sh stop
./multisite.sh teardown                   # revoke the sites, remove the nodes, delete the site keys, take GW03..05 off the page list
cd ../demo && ./demo.sh --step 6          # stop the page server
```

Two sites only (smaller VM): `export SITES_COUNT=2` first. `loadtest.sh` and `sample.sh` use `SITES_COUNT` and `PAGE`
(default http://127.0.0.1:8088); with `SITES=local` all sites share the CPUs of one machine, so loads above 10-20 sensors per site
mostly measure the VM, not the design.
