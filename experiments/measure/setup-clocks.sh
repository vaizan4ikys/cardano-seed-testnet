#!/bin/bash
# Make the clocks of the measurement machines agree to about a millisecond, so that block
# propagation can be compared between machines. Run it once, on your own machine.
#
#   ./setup-clocks.sh                                       seedvm is the time server
#   SERVER=seedvm CLIENTS="seedvm2 seedvm3 seedvm4" ./setup-clocks.sh
#
# Each machine on its own gets its time from the internet, and they differ by tens of
# milliseconds (VMware also adjusts the guest clocks by itself). Here the server keeps its
# internet time, the clients follow only the server, and VMware's time sync is switched off.
#
# The server does NOT keep its internet time: it is the only source of the group (stratum 10, the
# internet pools are switched off). A Mac that sleeps freezes its virtual machines, so their
# clocks fall behind the real time; a chrony that is connected to the internet would then step
# the clock forward by minutes, and a chain that sees a gap of more than 15 minutes (3k/f) is dead.
# The group clock only has to agree with itself.
# Installs chrony (needs internet and sudo on the machines); safe to run again.
set -euo pipefail

SERVER=${SERVER:-seedvm}
CLIENTS=${CLIENTS:-"seedvm2 seedvm3 seedvm4"}
CONF=/etc/chrony/chrony.conf
MARK='# measure: written by setup-clocks.sh'

on() { ssh -o BatchMode=yes "$1" "$2" 2> >(grep -v '^\*\*' >&2); }

SERVER_IP=$(on "$SERVER" "hostname -I" | cut -d' ' -f1)

install_chrony() {
  on "$1" "sudo apt-get update -q >/dev/null; sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -q chrony >/dev/null
           sudo sed -i '\|^$MARK|,\$d' $CONF                 # drop the block of an earlier run
           command -v vmware-toolbox-cmd >/dev/null && sudo vmware-toolbox-cmd timesync disable || true"
}

echo "server $SERVER ($SERVER_IP)"
install_chrony "$SERVER"
on "$SERVER" "sudo sed -i 's/^pool /#pool /' $CONF"
on "$SERVER" "printf '%s\nallow ${SERVER_IP%.*}.0/24\nlocal stratum 10\n' '$MARK' | sudo tee -a $CONF >/dev/null
              sudo systemctl restart chrony"

for client in $CLIENTS; do
  echo "client $client"
  install_chrony "$client"
  on "$client" "sudo sed -i 's/^pool /#pool /' $CONF
                printf '%s\nserver $SERVER_IP iburst minpoll 0 maxpoll 3\nmakestep 0.1 -1\n' '$MARK' | sudo tee -a $CONF >/dev/null
                sudo systemctl restart chrony"
done

echo "waiting for the clients to lock on ..."
sleep 15
for client in $CLIENTS; do
  echo "$client: $(on "$client" "chronyc tracking | grep -E 'System time' | xargs")"
done
