# image

`Dockerfile` builds `seedemu-cardano:local`: the SEED base image plus the `cardano-node` and
`cardano-cli` binaries copied from the official `ghcr.io/intersectmbo/cardano-node:11.1.3` image.
`run.sh` builds it automatically the first time.

The base image is multi-arch, so the same file works on arm64 and amd64.
