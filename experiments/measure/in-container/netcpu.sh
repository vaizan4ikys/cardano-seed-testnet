#!/bin/bash
# Runs INSIDE a pool container (fed to "bash -s" over ssh by ../fanout.sh).
# Prints one line:  <rx bytes> <tx bytes> <cpu ticks of cardano-node>   (100 ticks = 1 CPU second)
# The bytes are the counters of the container's network card net0; the ticks are user + system time of the node.

# rx and tx bytes of net0 (the /proc/net/dev line is "net0: <rx> ..." or "net0:<rx> ...")
awk '$1 ~ /^net0:/ { sub(/^net0:/, "", $1); if ($1 == "") print $2, $10; else print $1, $9 }' /proc/net/dev | tr '\n' ' '
PID=$(ps -eo pid,comm | awk '$2 == "cardano-node" { print $1; exit }')
awk '{ print $14 + $15 }' /proc/$PID/stat
