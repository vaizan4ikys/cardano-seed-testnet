FROM ghcr.io/intersectmbo/cardano-node:11.1.3 AS cn
FROM handsonsecurity/seedemu-multiarch-base:buildx-latest
COPY --from=cn /nix /nix
COPY --from=cn /usr/local/bin/cardano-node /usr/local/bin/cardano-cli /usr/local/bin/
COPY --from=cn /usr/local/bin/jq /usr/local/bin/jq-nix
