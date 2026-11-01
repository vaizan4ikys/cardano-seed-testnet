#!/bin/bash
# Inside a pool container: "<rx bytes> <tx bytes> <cpu ticks of cardano-node>" (100 ticks = 1 CPU second)
awk '$1 ~ /^net0:/ { sub(/^net0:/, "", $1); if ($1 == "") print $2, $10; else print $1, $9 }' /proc/net/dev | tr '\n' ' '
PID=$(ps -eo pid,comm | awk '$2 == "cardano-node" { print $1; exit }')
awk '{ print $14 + $15 }' /proc/$PID/stat
