#!/bin/bash
# Runs on the chain host, called by run.sh right after "docker compose up".
# Checks that every running container really holds the files that cardano.py generated for it (router configs,
# interface setup, node configs). Why: on 19 November 2026, 14 images on one VM (routers and hosts) had been built with
# files of other nodes; docker reused those wrong images in every later run and the network was only half connected.
# Any service with a wrong file is rebuilt WITHOUT the build cache and its container is recreated, then checked again.
#
#   NET=1 ./scripts/check-images.sh          (run.sh does this; prints one summary line, exit 1 if still wrong)
#   ./scripts/check-images.sh --check        only compare and list wrong services, repair nothing (exit 1 if any)
#
# Files are only compared (cmp -s), never printed: some of them are keys.
set -uo pipefail
source "$(dirname "$0")/lib.sh"

COMPOSE_FILE=$OUTPUT/docker-compose.yml

# container_of SERVICE: the container_name of a service in the generated compose file
container_of() {
  awk -v svc="    $1:" '$0 == svc { found = 1; next }
                       found && $1 == "container_name:" { print $2; exit }
                       found && /^    [^ ]/ { exit }' "$COMPOSE_FILE"
}

# copied_files SERVICE: "local-file destination" for every COPY line of the service's Dockerfile
copied_files() {
  awk '$1 == "COPY" && NF == 3 { print $2, $3 }' "$OUTPUT/$1/Dockerfile"
}

# service_ok SERVICE: 0 when every copied file in the running container equals the generated one
service_ok() {
  local service=$1 container src dest
  container=$(container_of "$service")
  [ -n "$container" ] || return 0                       # not a container of this network: nothing to compare
  while read -r src dest; do
    docker exec "$container" cat "$dest" 2>/dev/null | cmp -s - "$OUTPUT/$service/$src" || return 1
  done < <(copied_files "$service")
  return 0
}

# wrong_services: the services whose container differs from the generated files
wrong_services() {
  local dir service
  for dir in "$OUTPUT"/*/Dockerfile; do
    service=$(basename "$(dirname "$dir")")
    service_ok "$service" || echo "$service"
  done
}

wrong=$(wrong_services)
if [ "${1:-}" = --check ]; then
  [ -z "$wrong" ] && { echo "container files: all match the generated network"; exit 0; }
  echo "container files: wrong in: $(echo $wrong)"; exit 1
fi
if [ -z "$wrong" ]; then
  echo "container files: all match the generated network"
  exit 0
fi
echo "container files: wrong in $(echo $wrong | wc -w) service(s): $(echo $wrong)"
echo "rebuilding them without the build cache and recreating their containers ..."
(cd "$OUTPUT" && docker compose -p "$PROJECT" build --no-cache $wrong >/dev/null 2>&1 \
               && docker compose -p "$PROJECT" up -d --force-recreate --no-deps $wrong >/dev/null 2>&1)
sleep 5
still=$(wrong_services)
if [ -n "$still" ]; then
  echo "container files: STILL wrong in: $(echo $still)"
  exit 1
fi
echo "container files: repaired, all match the generated network"
