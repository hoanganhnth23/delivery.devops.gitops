#!/usr/bin/env bash
# Build every service needed by the local E2E stack from the sibling
# delivery.core.* checkouts and wrap each boot jar in a local image.
#
#   CORE_ROOT   folder that holds the delivery.core.* repos (default: parent of the gitops repo)
#   MVN_FLAGS   extra Maven flags, e.g. "-o" to stay offline
#   ONLY        space-separated subset of services to rebuild
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/services.sh"
# Default: the folder holding this gitops checkout (works from git worktrees too).
CORE_ROOT="${CORE_ROOT:-$(cd "$(git -C "$HERE" rev-parse --path-format=absolute --git-common-dir)/../.." && pwd)}"
MVN="mvn -B -q ${MVN_FLAGS:-} -DskipTests"
JRE_IMAGE="${JRE_IMAGE:-eclipse-temurin:17-jre}"

repo() { echo "$CORE_ROOT/delivery.core.$1"; }

if [ -z "${ONLY:-}" ] && [ "${SKIP_SHARED:-false}" != "true" ]; then
  echo "==> shared starters + contracts"
  (cd "$(repo starters)" && $MVN install)
  (cd "$(repo contracts)" && $MVN install)
fi

for svc in ${ONLY:-$E2E_SERVICES}; do
  dir="$(repo "$(service_repo "$svc")")"
  [ -d "$dir" ] || { echo "missing repo for $svc: $dir" >&2; exit 1; }
  echo "==> $svc ($dir)"
  (cd "$dir" && $MVN install)
  jar_dir="$dir/boot/target"; [ -d "$jar_dir" ] || jar_dir="$dir/target"
  jar="$(ls "$jar_dir"/*.jar 2>/dev/null | grep -v -- '-plain.jar$' | grep -v -- '-sources.jar$' | head -n 1 || true)"
  [ -n "$jar" ] || { echo "no boot jar for $svc in $jar_dir" >&2; exit 1; }
  docker build -q -t "delivery-e2e/$svc:local" -f - "$(dirname "$jar")" >/dev/null <<DOCKERFILE
FROM $JRE_IMAGE
WORKDIR /app
COPY $(basename "$jar") app.jar
ENTRYPOINT ["java", "-jar", "app.jar"]
DOCKERFILE
  echo "    image delivery-e2e/$svc:local <- $(basename "$jar")"
done
