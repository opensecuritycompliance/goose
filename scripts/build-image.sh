#!/usr/bin/env bash
# Build (and optionally push) the goose ACP server image.
#
#   ./scripts/build-image.sh                          # local: goose-acp:<branch>-<sha>
#   ./scripts/build-image.sh --tag v1.48.0-cc1
#   ./scripts/build-image.sh --registry ghcr.io/arul-cc --push
#   ./scripts/build-image.sh --jobs 6                 # cap on a memory-bound builder
#   ./scripts/build-image.sh --platform linux/amd64   # cross-build (slow, see below)
#
# Tag defaults to <branch>-<short-sha>, plus "-dirty" when the tree has uncommitted
# changes. That is deliberate: the last production incident here was an image built
# from `main` instead of `acp-migration`, which is invisible until it fails at
# runtime with `-32601: Method not found`. An immutable, branch-derived tag makes
# the mistake visible in `kubectl get pod -o wide`, and Dockerfile.server refuses
# to build a binary missing the fork's ACP methods at all.
#
# `latest` is never applied unless you ask for it with --latest. A mutable tag
# combined with imagePullPolicy: IfNotPresent is how a stale image survives a
# deploy that looked successful.

set -uo pipefail

cd "$(dirname "$0")/.." || exit 1
ROOT="$PWD"

REGISTRY=""
NAME="goose-acp"
TAG=""
PUSH=0
ALSO_LATEST=0
JOBS=""
FEATURES="rustls-tls"
PLATFORM=""
NO_CACHE=0
EXPECT_BRANCH="acp-migration"

die() { printf '\033[31merror:\033[0m %s\n' "$1" >&2; exit 1; }
warn() { printf '\033[33mwarning:\033[0m %s\n' "$1" >&2; }
note() { printf '  %s\n' "$1"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --registry) REGISTRY="${2%/}"; shift 2 ;;
    --name)     NAME="$2"; shift 2 ;;
    --tag)      TAG="$2"; shift 2 ;;
    --push)     PUSH=1; shift ;;
    --latest)   ALSO_LATEST=1; shift ;;
    --jobs)     JOBS="$2"; shift 2 ;;
    --features) FEATURES="$2"; shift 2 ;;
    --platform) PLATFORM="$2"; shift 2 ;;
    --no-cache) NO_CACHE=1; shift ;;
    -h|--help)  sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)          die "unknown argument: $1" ;;
  esac
done

# --- preflight: BuildKit ----------------------------------------------------
# Ubuntu's packaged `docker.io` can ship without BuildKit, and then the
# `# syntax=` header and every --mount=type=cache line in Dockerfile.server
# fail outright rather than degrading gracefully.
command -v docker >/dev/null 2>&1 || die "docker not found on PATH"
if ! docker buildx version >/dev/null 2>&1; then
  die "BuildKit/buildx not available.
    Dockerfile.server needs it for its cache mounts. On Ubuntu this usually means
    the distro's docker.io package; install Docker CE's docker-buildx-plugin, or
    as a stopgap export DOCKER_BUILDKIT=1."
fi

# --- git provenance ---------------------------------------------------------
# Never read the remote URL: this repo's remotes embed an access token, and
# anything derived from them would be baked into the image labels.
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
SHA="$(git rev-parse --short=12 HEAD 2>/dev/null || echo unknown)"
DIRTY=""
if [ -n "$(git status --porcelain 2>/dev/null)" ]; then DIRTY="-dirty"; fi
BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

if [ -z "$TAG" ]; then
  # Slashes are legal in branch names and illegal in tags.
  TAG="$(printf '%s' "$BRANCH" | tr '/' '-')-${SHA}${DIRTY}"
fi

if [ -n "$REGISTRY" ]; then IMAGE="$REGISTRY/$NAME"; else IMAGE="$NAME"; fi
REF="$IMAGE:$TAG"

[ "$PUSH" -eq 1 ] && [ -z "$REGISTRY" ] && die "--push needs --registry"

# --- preflight: the mistakes that cost real time ----------------------------
echo "goose ACP image"
note "branch:    $BRANCH"
note "revision:  $SHA${DIRTY}"
note "image:     $REF"
[ "$ALSO_LATEST" -eq 1 ] && note "also:      $IMAGE:latest"
note "features:  $FEATURES"

if [ "$BRANCH" != "$EXPECT_BRANCH" ] && [ "$BRANCH" != "unknown" ]; then
  warn "building from '$BRANCH', not '$EXPECT_BRANCH'.
    The fork's ACP methods live on $EXPECT_BRANCH. Dockerfile.server asserts they
    are present and will fail the build if they are not — so this is a warning,
    not a block, in case you branched intentionally."
fi
[ -n "$DIRTY" ] && warn "working tree is dirty; the tag is marked -dirty but the diff is not recorded anywhere else."

# --- preflight: build resources --------------------------------------------
DOCKER_CPUS="$(docker info --format '{{.NCPU}}' 2>/dev/null || echo "")"
DOCKER_MEM_BYTES="$(docker info --format '{{.MemTotal}}' 2>/dev/null || echo "")"

if [ -n "$DOCKER_MEM_BYTES" ] && [ "$DOCKER_MEM_BYTES" -gt 0 ] 2>/dev/null; then
  MEM_GB=$(( DOCKER_MEM_BYTES / 1073741824 ))
  note "builder:   ${DOCKER_CPUS:-?} CPU, ${MEM_GB} GiB"

  # Roughly 2GB per concurrent rustc in this workspace; `goose` (lib) alone was
  # SIGKILLed under 4GB after 364 crates had already compiled.
  MEM_JOBS=$(( MEM_GB / 2 ))
  [ "$MEM_JOBS" -lt 1 ] && MEM_JOBS=1
  if [ -z "$JOBS" ] && [ -n "$DOCKER_CPUS" ] && [ "$MEM_JOBS" -lt "$DOCKER_CPUS" ]; then
    JOBS="$MEM_JOBS"
    warn "only ${MEM_GB} GiB for ${DOCKER_CPUS} CPUs — capping to --jobs $JOBS to avoid an OOM mid-build.
    Raise the daemon's memory (or pass --jobs) for a faster build."
  fi
  [ "$MEM_GB" -lt 4 ] && warn "under 4 GiB: this workspace has OOM'd at that size even at one job."
fi

# --- preflight: emulation ---------------------------------------------------
HOST_ARCH="$(uname -m)"
case "$HOST_ARCH" in
  x86_64|amd64) HOST_PLATFORM="linux/amd64" ;;
  arm64|aarch64) HOST_PLATFORM="linux/arm64" ;;
  *) HOST_PLATFORM="" ;;
esac
if [ -n "$PLATFORM" ] && [ -n "$HOST_PLATFORM" ] && [ "$PLATFORM" != "$HOST_PLATFORM" ]; then
  warn "cross-building $PLATFORM on $HOST_PLATFORM runs every rustc under QEMU — expect 5-10x.
    540 crates emulated is the difference between ~15 minutes and over an hour.
    Build on a native host, or use CI, if you can."
fi

# --- build ------------------------------------------------------------------
echo
echo "building..."

BUILD_ARGS="--build-arg FEATURES=$FEATURES"
BUILD_ARGS="$BUILD_ARGS --build-arg GIT_REF=$BRANCH"
BUILD_ARGS="$BUILD_ARGS --build-arg GIT_SHA=${SHA}${DIRTY}"
BUILD_ARGS="$BUILD_ARGS --build-arg BUILD_DATE=$BUILD_DATE"
[ -n "$JOBS" ]     && BUILD_ARGS="$BUILD_ARGS --build-arg BUILD_JOBS=$JOBS"
[ -n "$PLATFORM" ] && BUILD_ARGS="$BUILD_ARGS --platform $PLATFORM"
[ "$NO_CACHE" -eq 1 ] && BUILD_ARGS="$BUILD_ARGS --no-cache"

START=$(date +%s)
# shellcheck disable=SC2086
if ! docker build $BUILD_ARGS -f Dockerfile.server -t "$REF" "$ROOT"; then
  die "build failed"
fi
ELAPSED=$(( $(date +%s) - START ))

[ "$ALSO_LATEST" -eq 1 ] && docker tag "$REF" "$IMAGE:latest"

# --- verify -----------------------------------------------------------------
# Dockerfile.server already fails the build when the fork methods are missing.
# This re-checks the finished image, which is what actually ships — a mismatch
# here would mean the tag does not point at what was just built.
echo
echo "verifying image"
BAKED_REF="$(docker inspect --format '{{index .Config.Labels "org.opencontainers.image.version"}}' "$REF" 2>/dev/null)"
BAKED_SHA="$(docker inspect --format '{{index .Config.Labels "org.opencontainers.image.revision"}}' "$REF" 2>/dev/null)"
if [ "$BAKED_REF" = "$BRANCH" ] && [ "$BAKED_SHA" = "${SHA}${DIRTY}" ]; then
  note "provenance: $BAKED_REF @ $BAKED_SHA"
else
  warn "image labels ($BAKED_REF @ $BAKED_SHA) do not match this checkout ($BRANCH @ ${SHA}${DIRTY})"
fi

# The fork's own two methods only. The upstream session-admin ones (info,
# rename, export) do not keep their string literals through a release build, so
# checking them failed on good binaries; and their presence would say nothing
# about which branch this came from.
MISSING=""
for m in "_goose/unstable/session/provider/update" \
         "_goose/unstable/session/extension_data/set" ; do
  if ! docker run --rm --entrypoint grep "$REF" -aqF "$m" /usr/local/bin/goose; then
    MISSING="$MISSING $m"
  fi
done
if [ -n "$MISSING" ]; then
  echo
  for m in $MISSING; do printf '  \033[31mMISSING\033[0m %s\n' "$m"; done
  die "the built image is missing fork ACP methods — do not deploy it"
fi
note "fork ACP methods: 2/2 present"

SIZE="$(docker image inspect --format '{{.Size}}' "$REF" 2>/dev/null || echo 0)"
note "size:       $(( SIZE / 1048576 )) MiB"
note "build time: $(( ELAPSED / 60 ))m $(( ELAPSED % 60 ))s"

# --- push -------------------------------------------------------------------
if [ "$PUSH" -eq 1 ]; then
  echo
  echo "pushing $REF"
  docker push "$REF" || die "push failed"
  [ "$ALSO_LATEST" -eq 1 ] && { docker push "$IMAGE:latest" || die "push of :latest failed"; }

  DIGEST="$(docker inspect --format '{{index .RepoDigests 0}}' "$REF" 2>/dev/null)"
  echo
  if [ -n "$DIGEST" ]; then
    echo "Pin the deployment by digest — a tag can be moved, a digest cannot:"
    echo
    echo "    image: $DIGEST"
  else
    echo "    image: $REF"
  fi
  echo
  echo "If you deploy by tag instead, set imagePullPolicy: Always. A mutable tag"
  echo "with IfNotPresent is how a node keeps serving the previous image."
else
  echo
  echo "Built locally, not pushed. Run it with:"
  echo
  echo "    GOOSE_IMAGE_REPO=$IMAGE GOOSE_IMAGE_TAG=$TAG docker compose up -d"
fi

exit 0
