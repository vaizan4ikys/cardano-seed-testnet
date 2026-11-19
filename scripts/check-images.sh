#!/bin/bash
# Runs on the chain host, called by run.sh right after "docker compose up".
# Checks that every running container really holds the files that cardano.py generated for it (router configs,
# interface setup, node configs). Why: on 19 November 2026, 14 images on one VM (routers and hosts) had been built with
# files of other nodes; docker reused those wrong images in every later run and the network was only half connected.
# Any service with a wrong file is rebuilt WITHOUT the build cache and its container is recreated, then checked again.
#
#   NET=1 ./scripts/check-images.sh          (run.sh does this; prints one summary line, exit 1 if still wrong)
#   ./scripts/check-images.sh --check        only compare and list wrong services, repair nothing (exit 1 if any)
#   ./scripts/check-images.sh --stamp        give every service folder its own file time (run.sh, before building)
#
# The cause, found on 19 November 2026: SEED writes all files within one clock tick, so files of different services
# have the same name, size and modification time. The legacy builder of "docker compose" (used when the buildx plugin
# is missing, as with Ubuntu's docker.io) then copies one service's file into another service's image, even with
# --no-cache. One file time per service folder prevents it (test: 28 of 30 images wrong before, 0 of 30 after).
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

# stamp_folders [SERVICE...]: give each service folder (default: all of them) its own file time, one second apart,
# counting back from now, so no two services share a file time
stamp_folders() {
  local now counter=0 services service
  now=$(date +%s)
  if [ $# -gt 0 ]; then
    services="$*"
  else
    services=$(cd "$OUTPUT" && ls -d */ | tr -d /)
  fi
  for service in $services; do
    counter=$((counter + 1))
    find "$OUTPUT/$service" -exec touch -h -d "@$((now - counter))" {} +
  done
}

# wrong_services: the services whose container differs from the generated files
wrong_services() {
  local dir service
  for dir in "$OUTPUT"/*/Dockerfile; do
    service=$(basename "$(dirname "$dir")")
    service_ok "$service" || echo "$service"
  done
}

# --stamp: only give the folders their file times (run.sh does this before "docker compose up"), then stop
if [ "${1:-}" = --stamp ]; then
  stamp_folders
  exit 0
fi
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
stamp_folders $wrong          # new file times first: --no-cache alone does not help (see the top of this file)
(cd "$OUTPUT" && docker compose -p "$PROJECT" build --no-cache $wrong >/dev/null 2>&1 \
               && docker compose -p "$PROJECT" up -d --force-recreate --no-deps $wrong >/dev/null 2>&1)
sleep 5
still=$(wrong_services)
if [ -n "$still" ]; then
  echo "container files: STILL wrong in: $(echo $still)"
  exit 1
fi
echo "container files: repaired, all match the generated network"
