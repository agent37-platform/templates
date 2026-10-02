#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SOURCE_URL="https://github.com/agent37-platform/templates"

ENV_FILE="${ENV_FILE:-${REPO_ROOT}/.env}"
if [[ -f "${ENV_FILE}" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  set +a
fi

usage() {
  cat <<'USAGE'
Publish an Agent37 template image to GHCR, then tag the commit it was built from.

Usage: ./scripts/publish-image.sh <image> [flags]

Images (key in images.json; Dockerfile under images/<dir>/):
  b2b-hermes    images/b2b/hermes/. Pushes hermes-base (--target base),
                  hermes-small (--target small), and hermes (--target full)
  b2b-openclaw  images/b2b/openclaw/. Pushes openclaw-base and openclaw
  b2b-claude-code  images/b2b/claude-code/. Pushes claude-code-base and claude-code
  b2b-codex     images/b2b/codex/. Pushes codex-base and codex
  b2b-grok      images/b2b/grok/. Pushes grok-base and grok
  b2b-opencode  images/b2b/opencode/. Pushes opencode-base and opencode
  b2b-pi        images/b2b/pi/. Pushes pi-base and pi
  b2b-n8n       images/b2b/n8n/. Pushes n8n
  consumer-app  images/consumer/app/. Pushes app
  consumer-openclaw  images/consumer/openclaw/. Pushes app-openclaw

Required env:
  GH_USER    GitHub user/org namespace for ghcr.io
  CR_PAT     GitHub PAT classic with write:packages

Flags:
  --tag <tag>   Image tag (default: the image's entry in images.json)
  --platform    Build platforms (default: linux/amd64)
  --no-cache    Disable Docker build cache for this publish
  -h, --help    Show help

Refuses a dirty tree, a commit that is not on origin/main, and a tag that was
already published. On success it pushes the git tag <image>/<tag>.

Examples:
  ./scripts/publish-image.sh b2b-hermes
USAGE
}

if [[ $# -lt 1 || "$1" == "-h" || "$1" == "--help" ]]; then
  usage
  exit 0
fi

IMAGE_KEY="$1"
shift

TAG=""
NO_CACHE=0
PLATFORM="linux/amd64"

# package:target pairs; an empty target builds the whole Dockerfile.
case "${IMAGE_KEY}" in
  b2b-hermes)
    IMAGE_DIR="b2b/hermes"
    PACKAGES=("hermes-base:base" "hermes-small:small" "hermes:full")
    ;;
  b2b-claude-code)
    IMAGE_DIR="b2b/claude-code"
    PACKAGES=("claude-code-base:base" "claude-code:full")
    ;;
  b2b-codex)
    IMAGE_DIR="b2b/codex"
    PACKAGES=("codex-base:base" "codex:full")
    ;;
  b2b-grok)
    IMAGE_DIR="b2b/grok"
    PACKAGES=("grok-base:base" "grok:full")
    ;;
  b2b-opencode)
    IMAGE_DIR="b2b/opencode"
    PACKAGES=("opencode-base:base" "opencode:full")
    ;;
  b2b-pi)
    IMAGE_DIR="b2b/pi"
    PACKAGES=("pi-base:base" "pi:full")
    ;;
  b2b-openclaw)
    IMAGE_DIR="b2b/openclaw"
    PACKAGES=("openclaw-base:base" "openclaw:full")
    ;;
  b2b-n8n)
    IMAGE_DIR="b2b/n8n"
    PACKAGES=("n8n:")
    ;;
  consumer-app)
    IMAGE_DIR="consumer/app"
    PACKAGES=("app:")
    ;;
  consumer-openclaw)
    IMAGE_DIR="consumer/openclaw"
    PACKAGES=("app-openclaw:")
    ;;
  *)
    echo "Unknown image: ${IMAGE_KEY}" >&2
    usage
    exit 1
    ;;
esac
BUILDER_NAME="agent37-${IMAGE_KEY#b2b-}-builder"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag)
      TAG="${2:-}"
      shift 2
      ;;
    --platform)
      PLATFORM="${2:-}"
      shift 2
      ;;
    --no-cache)
      NO_CACHE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

DOCKERFILE_PATH="${REPO_ROOT}/images/${IMAGE_DIR}/Dockerfile"
BUILD_CONTEXT="${REPO_ROOT}"
IMAGES_JSON="${REPO_ROOT}/images.json"

if [[ -z "${GH_USER:-}" ]]; then
  echo "Missing GH_USER. Set it in env or ${ENV_FILE}." >&2
  exit 1
fi

if [[ -z "${CR_PAT:-}" ]]; then
  echo "Missing CR_PAT. Set it in env or ${ENV_FILE}." >&2
  exit 1
fi

if [[ -z "${TAG}" ]]; then
  TAG="$(node -p "require('${IMAGES_JSON}')['${IMAGE_KEY}'] ?? ''")"
  if [[ -z "${TAG}" ]]; then
    echo "No tag for '${IMAGE_KEY}' in ${IMAGES_JSON} and no --tag given." >&2
    exit 1
  fi
fi

if [[ -z "${PLATFORM}" ]]; then
  echo "Missing --platform value." >&2
  exit 1
fi

if [[ ! -f "${DOCKERFILE_PATH}" ]]; then
  echo "Dockerfile not found: ${DOCKERFILE_PATH}" >&2
  exit 1
fi

# The git tag is the public record of what an image tag was built from, so the build must
# come from a commit everyone can see, and a published tag is never built twice.
GIT_TAG="${IMAGE_KEY}/${TAG}"
cd "${REPO_ROOT}"
if [[ -n "$(git status --porcelain)" ]]; then
  echo "Working tree is dirty. Commit and merge to main first." >&2
  exit 1
fi
git fetch --quiet --tags origin main
if ! git merge-base --is-ancestor HEAD origin/main; then
  echo "HEAD is not on origin/main. Merge your change, then publish from main." >&2
  exit 1
fi
if git rev-parse -q --verify "refs/tags/${GIT_TAG}" >/dev/null; then
  echo "${GIT_TAG} was already published. Pick a new tag in images.json." >&2
  exit 1
fi
REVISION="$(git rev-parse HEAD)"

GH_NAMESPACE="$(echo "${GH_USER}" | tr '[:upper:]' '[:lower:]')"

urlencode() {
  node -e "process.stdout.write(encodeURIComponent(process.argv[1]))" "$1"
}

github_api_get() {
  local path="$1"

  curl -fsS \
    -H "Authorization: Bearer ${CR_PAT}" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "https://api.github.com${path}"
}

parse_visibility() {
  node -e "const input = require('fs').readFileSync(0, 'utf8'); console.log(JSON.parse(input).visibility || 'unknown')"
}

get_package_visibility() {
  local package="$1"
  local encoded_owner encoded_package package_json

  encoded_owner="$(urlencode "${GH_NAMESPACE}")"
  encoded_package="$(urlencode "${package}")"

  if package_json="$(github_api_get "/orgs/${encoded_owner}/packages/container/${encoded_package}" 2>/dev/null)"; then
    parse_visibility <<<"${package_json}"
    return 0
  fi

  if package_json="$(github_api_get "/users/${encoded_owner}/packages/container/${encoded_package}" 2>/dev/null)"; then
    parse_visibility <<<"${package_json}"
    return 0
  fi

  echo "missing"
}

PRIVATE_PACKAGES=()
for entry in "${PACKAGES[@]}"; do
  PACKAGE="${entry%%:*}"
  VISIBILITY="$(get_package_visibility "${PACKAGE}")"
  if [[ "${VISIBILITY}" != "public" ]]; then
    PRIVATE_PACKAGES+=("${PACKAGE}")
  fi
done

echo "Publishing '${IMAGE_KEY}' at tag ${TAG} from ${REVISION} (platform ${PLATFORM}):"
for entry in "${PACKAGES[@]}"; do
  echo "  ghcr.io/${GH_NAMESPACE}/${entry%%:*}:${TAG}"
done

echo "${CR_PAT}" | docker login ghcr.io -u "${GH_USER}" --password-stdin

if docker buildx inspect "${BUILDER_NAME}" >/dev/null 2>&1; then
  docker buildx use "${BUILDER_NAME}"
else
  docker buildx create --name "${BUILDER_NAME}" --use
fi

docker buildx inspect --bootstrap >/dev/null

for entry in "${PACKAGES[@]}"; do
  PACKAGE="${entry%%:*}"
  TARGET="${entry#*:}"
  IMAGE="ghcr.io/${GH_NAMESPACE}/${PACKAGE}"

  # Every image also gets a moving :latest so customer builds can FROM *-base:latest.
  # Production pins the date tag, never :latest.
  BUILD_CMD=(
    docker buildx build
    --platform "${PLATFORM}"
    -f "${DOCKERFILE_PATH}"
    -t "${IMAGE}:${TAG}"
    -t "${IMAGE}:latest"
    --label "org.opencontainers.image.source=${SOURCE_URL}"
    --label "org.opencontainers.image.revision=${REVISION}"
  )

  if [[ -n "${TARGET}" ]]; then
    BUILD_CMD+=(--target "${TARGET}")
  fi

  if [[ "${NO_CACHE}" -eq 1 ]]; then
    BUILD_CMD+=(--no-cache)
  fi

  BUILD_CMD+=(--push "${BUILD_CONTEXT}")

  "${BUILD_CMD[@]}"
  echo "Published: ${IMAGE}:${TAG}"
done

git tag "${GIT_TAG}" "${REVISION}"
git push origin "refs/tags/${GIT_TAG}"

echo "Done. Tagged ${GIT_TAG}."
echo "Production still runs the old tag until agent37-web's docker/images.json"
echo "pins '${IMAGE_KEY}': '${TAG}'."
if [[ "${#PRIVATE_PACKAGES[@]}" -gt 0 ]]; then
  echo "Not public on GHCR: ${PRIVATE_PACKAGES[*]}."
fi
