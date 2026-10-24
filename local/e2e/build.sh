#!/usr/bin/env bash
# Build every service needed by the local E2E stack from the sibling
# delivery.core.* checkouts and wrap each boot jar in a local image.
#
# Sources are copied into .build/ (git-ignored) first, so building never
# touches the repos themselves (several still track target/ output).
#
#   CORE_ROOT      folder that holds the delivery.core.* repos (default: parent of the gitops repo)
#   E2E_SOURCES    per-service source overrides, e.g. "notification=/path/to/worktree dispatch=/path"
#   MVN_FLAGS      extra Maven flags, e.g. "-o" to stay offline
#   ONLY           space-separated subset of services to rebuild
#   SKIP_SHARED    true to reuse already installed starters/contracts
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/services.sh"
# Default: the folder holding this gitops checkout (works from git worktrees too).
CORE_ROOT="${CORE_ROOT:-$(cd "$(git -C "$HERE" rev-parse --path-format=absolute --git-common-dir)/../.." && pwd)}"
BUILD_ROOT="$HERE/.build"
MVN="mvn -B -q ${MVN_FLAGS:-} -DskipTests"
JRE_IMAGE="${JRE_IMAGE:-eclipse-temurin:17-jre}"

source_dir() { # service-or-repo name -> source checkout
  local name="$1" entry
  for entry in ${E2E_SOURCES:-}; do
    [ "${entry%%=*}" = "$name" ] && { echo "${entry#*=}"; return; }
  done
  echo "$CORE_ROOT/delivery.core.$(service_repo "$name")"
}

# Copy a checkout (working tree, without .git/target) into .build/<name>.
stage() {
  local name="$1" src="$2" dst="$BUILD_ROOT/$1"
  [ -d "$src" ] || { echo "missing source for $name: $src" >&2; exit 1; }
  rm -rf "$dst" && mkdir -p "$dst"
  rsync -a --delete --exclude .git --exclude target --exclude node_modules "$src/" "$dst/"
  echo "$dst"
}

if [ -z "${ONLY:-}" ] && [ "${SKIP_SHARED:-false}" != "true" ]; then
  echo "==> shared starters + contracts"
  (cd "$(stage starters "$CORE_ROOT/delivery.core.starters")" && $MVN install)
  (cd "$(stage contracts "$CORE_ROOT/delivery.core.contracts")" && $MVN install)
fi

for svc in ${ONLY:-$E2E_SERVICES}; do
  src="$(source_dir "$svc")"
  echo "==> $svc ($src @ $(git -C "$src" rev-parse --short HEAD 2>/dev/null || echo '?'))"
  dir="$(stage "$svc" "$src")"
  (cd "$dir" && $MVN package)
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
