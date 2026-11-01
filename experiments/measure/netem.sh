#!/bin/bash
# Add delay, packet loss and bandwidth limits to the traffic of the joiner container (see ../join-node).
# Only that container is affected, not the machine: ssh and everything else stay normal.
#
#   ./netem.sh set <delay-ms> [loss-percent [down-mbit [up-mbit]]]     e.g. ./netem.sh set 100 1
#   ./netem.sh clear
#   ./netem.sh show
#
# delay and loss act on what the joiner SENDS, so the round trip to its peer grows by <delay-ms>.
# up-mbit caps what the joiner sends; down-mbit caps what it receives (0 or empty: no cap). The download
# cap is set on the ingress side through an ifb device inside the container (module ifb: setup-clocks.sh
# does not need it, `sudo modprobe ifb numifbs=0` once per boot).
set -euo pipefail

NAME=${NAME:-cardano-joiner}            # NAME=hop4 ./netem.sh ... for an extra node on the machine
PID=$(docker inspect -f '{{.State.Pid}}' "$NAME")
tc_in_container() { sudo nsenter -t "$PID" -n tc "$@"; }
ip_in_container() { sudo nsenter -t "$PID" -n ip "$@"; }

clear_all() {
  tc_in_container qdisc del dev eth0 root 2>/dev/null || true
  tc_in_container qdisc del dev eth0 ingress 2>/dev/null || true
  ip_in_container link del ifb0 2>/dev/null || true
}

case ${1:-} in
  set)
    delay=${2:?delay in ms}; loss=${3:-0}; down=${4:-0}; up=${5:-0}
    rate=""; [ "$up" != 0 ] && rate="rate ${up}mbit"
    tc_in_container qdisc replace dev eth0 root netem delay "${delay}ms" loss "${loss}%" $rate
    if [ "$down" != 0 ]; then
      sudo modprobe ifb numifbs=0
      ip_in_container link show ifb0 >/dev/null 2>&1 || ip_in_container link add ifb0 type ifb
      ip_in_container link set ifb0 up
      tc_in_container qdisc replace dev eth0 handle ffff: ingress
      tc_in_container filter replace dev eth0 parent ffff: protocol all prio 1 u32 match u32 0 0 action mirred egress redirect dev ifb0
      tc_in_container qdisc replace dev ifb0 root tbf rate "${down}mbit" burst 64kb latency 200ms
    else
      tc_in_container qdisc del dev eth0 ingress 2>/dev/null || true
      ip_in_container link del ifb0 2>/dev/null || true
    fi ;;
  clear) clear_all ;;
  show)  tc_in_container qdisc show dev eth0; tc_in_container qdisc show dev ifb0 2>/dev/null || true ;;
  *)     sed -n '2,/^set /p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 1 ;;
esac
