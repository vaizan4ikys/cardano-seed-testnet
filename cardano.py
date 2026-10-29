#!/usr/bin/env python3
# encoding: utf-8
"""
Private Cardano testnet inside the SEED emulator.

Three stake pools run on hosts in three different stub ASes. They talk to each
other over the emulated Internet (BGP/OSPF routers), not over docker bridges.

Normally started through ./run.sh. Settings come from environment variables:

    NET=1|2|...   which network to build (default 1)
    ARCH=arm|amd  CPU architecture of the containers (default: this machine's)

Every network gets its own AS, IX and transit numbers, so several of them can
run on one machine without colliding:

              IX         transit ASes     stub ASes        pools (host_0)
    NET=1     100-104    2, 3, 4, 12      150-154, 160-164  150, 151, 152
    NET=2     110-114    22, 23, 24, 32   200-204, 210-214  200, 201, 202
"""
import json
import os
import platform as host

from seedemu import *

NET = int(os.environ.get('NET', '1'))
ARCH = os.environ.get('ARCH', 'arm' if host.machine() in ('aarch64', 'arm64') else 'amd')

PORT = 3001                                   # Cardano node-to-node port
IMAGE_NAME = 'seedemu-cardano:local'
ROOT = os.path.dirname(os.path.abspath(__file__))
BUILD = os.path.join(ROOT, 'build', 'net-{}'.format(NET))
TESTNET = os.path.join(BUILD, 'testnet')      # genesis + keys, made by scripts/gen-testnet.sh
OUTPUT = os.path.join(BUILD, 'output')        # the docker-compose files written below

# How far this network's numbers are shifted away from network 1
IX_SHIFT = 10 * (NET - 1)
TRANSIT_SHIFT = 20 * (NET - 1)
STUB_SHIFT = 50 * (NET - 1)

# Stake pool i runs on host_0 of this AS
POOL_ASNS = [150 + STUB_SHIFT, 151 + STUB_SHIFT, 152 + STUB_SHIFT]

# Only network 1 starts the Internet map (it has a fixed name and port 8080).
# It lists every SEED container on the machine, so it shows the other networks too.
WITH_MAP = NET == 1


def make_internet():
    """The SEED 'ten stub ASes' Internet, with every number shifted for this network.

    Same layout as Makers.makeEmulatorBaseWith10StubASAndHosts, but with
    shifted numbers so that a second copy does not collide with the first.
    """
    ix = lambda n: n + IX_SHIFT
    transit = lambda n: n + TRANSIT_SHIFT
    stub = lambda n: n + STUB_SHIFT

    emu, base = Emulator(), Base()
    routing, ebgp, ibgp, ospf = Routing(), Ebgp(), Ibgp(), Ospf()

    # Internet exchanges: the cities where the networks meet
    for n, city in [(100, 'NYC'), (101, 'San Jose'), (102, 'Chicago'), (103, 'Miami'), (104, 'Boston')]:
        base.createInternetExchange(ix(n)).getPeeringLan().setDisplayName('{}-{}'.format(city, ix(n)))

    # Transit ASes: the backbone, each spanning a few exchanges
    Makers.makeTransitAs(base, transit(2),  [ix(100), ix(101), ix(102)], [(ix(100), ix(101)), (ix(101), ix(102))])
    Makers.makeTransitAs(base, transit(3),  [ix(100), ix(103), ix(104)], [(ix(100), ix(103)), (ix(103), ix(104))])
    Makers.makeTransitAs(base, transit(4),  [ix(100), ix(102), ix(104)], [(ix(100), ix(104)), (ix(102), ix(104))])
    Makers.makeTransitAs(base, transit(12), [ix(101), ix(104)],          [(ix(101), ix(104))])

    # Stub ASes (one router + one host each), attached to an exchange
    stub_exchange = {150: 100, 151: 100, 152: 101, 153: 101, 154: 102,
                     160: 103, 161: 103, 162: 103, 163: 104, 164: 104}
    for asn, exchange in stub_exchange.items():
        Makers.makeStubAsWithHosts(emu, base, stub(asn), ix(exchange), 1)

    # BGP: route servers at the exchanges, then customer/provider links
    ebgp.addRsPeers(ix(100), [transit(2), transit(3), transit(4)])
    ebgp.addRsPeers(ix(102), [transit(2), transit(4)])
    ebgp.addRsPeers(ix(104), [transit(3), transit(4)])

    provider = PeerRelationship.Provider
    ebgp.addPrivatePeerings(ix(100), [transit(2)],                [stub(150), stub(151)], provider)
    ebgp.addPrivatePeerings(ix(100), [transit(3)],                [stub(150)],            provider)
    ebgp.addPrivatePeerings(ix(101), [transit(2)],                [transit(12)],          provider)
    ebgp.addPrivatePeerings(ix(101), [transit(12)],               [stub(152), stub(153)], provider)
    ebgp.addPrivatePeerings(ix(102), [transit(2), transit(4)],    [stub(154)],            provider)
    ebgp.addPrivatePeerings(ix(103), [transit(3)],                [stub(160), stub(161), stub(162)], provider)
    ebgp.addPrivatePeerings(ix(104), [transit(3), transit(4)],    [transit(12)],          provider)
    ebgp.addPrivatePeerings(ix(104), [transit(4)],                [stub(163)],            provider)
    ebgp.addPrivatePeerings(ix(104), [transit(12)],               [stub(164)],            provider)

    for layer in (base, routing, ebgp, ibgp, ospf):
        emu.addLayer(layer)
    return emu


def pool_topology(own_index, pool_ips):
    """Topology file of one pool: it dials every other pool."""
    peers = [{'address': ip, 'port': PORT} for j, ip in enumerate(pool_ips) if j != own_index]
    return {
        'localRoots': [{'accessPoints': peers, 'advertise': False,
                        'trustable': True, 'hotValency': len(peers)}],
        'publicRoots': [],
        'useLedgerAfterSlot': -1,
    }


def pool_command(n):
    """Shell command that starts the cardano-node of pool n inside its container."""
    keys = '/cardano/pools-keys/pool{}'.format(n)
    return (
        'mkdir -p /cardano-db && '
        'cardano-node run '
        '--config /cardano/config.json '
        '--topology /cardano-topology.json '
        '--database-path /cardano-db '
        '--socket-path /node.socket '
        '--host-addr 0.0.0.0 --port {port} '
        '--shelley-kes-key {k}/kes.skey '
        '--shelley-vrf-key {k}/vrf.skey '
        '--shelley-operational-certificate {k}/opcert.cert '
        '> /var/log/cardano-node.log 2>&1'
    ).format(port=PORT, k=keys)


emu = make_internet()
emu.render()   # assigns the IP addresses, which the topology files need

base = emu.getLayer('Base')
pools = [base.getAutonomousSystem(asn).getHost('host_0') for asn in POOL_ASNS]
pool_ips = [str(p.getInterfaces()[0].getAddress()) for p in pools]

for i, node in enumerate(pools):
    n = i + 1
    label = 'Cardano' if NET == 1 else 'Cardano{}'.format(NET)
    node.setDisplayName('{}-Pool-{}'.format(label, n))
    node.setFile('/cardano-topology.json', json.dumps(pool_topology(i, pool_ips), indent=2))
    node.addSharedFolder('/cardano', TESTNET)
    node.appendStartCommand(pool_command(n), fork=True)

docker = Docker(internetMapEnabled=WITH_MAP, platform={'arm': Platform.ARM64, 'amd': Platform.AMD64}[ARCH])
docker.addImage(DockerImage(name=IMAGE_NAME, software=[]), priority=100)
for node in pools:
    docker.setImageOverride(node, IMAGE_NAME)

os.makedirs(BUILD, exist_ok=True)   # SEED creates only the last folder of the path
emu.compile(docker, OUTPUT, override=True)
print('net-{}: pool IPs {}'.format(NET, pool_ips))
