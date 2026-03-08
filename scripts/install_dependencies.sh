#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=../scanner/common.sh
source "${PROJECT_ROOT}/scanner/common.sh"

INSTALL_NATIVE="yes"
INSTALL_DOCKER="yes"
INSTALL_CEWL="yes"
INSTALL_WPSCAN="yes"
PULL_IMAGES="yes"
INSTALL_ERRORS=0

usage() {
  cat <<'EOF'
Usage: install_dependencies.sh [--native] [--docker] [--cewl] [--wpscan] [--no-pull] [--help]

Options:
  --native     install native dependencies only
  --docker     pull Docker fallback images only
  --cewl       limit actions to CeWL
  --wpscan     limit actions to WPScan
  --no-pull    skip Docker image pulls
  -h, --help   show help

Default behavior:
  - install native WPScan where practical
  - rely on Docker as the cross-platform fallback for CeWL and WPScan
EOF
}

OS_NAME="$(uname -s)"

reset_tools() {
  INSTALL_CEWL="no"
  INSTALL_WPSCAN="no"
}

install_wpscan_native() {
  if has_command wpscan && command_works wpscan --version; then
    printf 'WPScan already available natively.\n'
    return 0
  fi

  case "${OS_NAME}" in
    Darwin)
      if has_command brew; then
        brew tap wpscanteam/tap
        if brew list --versions wpscanteam/tap/wpscan >/dev/null 2>&1; then
          brew reinstall wpscanteam/tap/wpscan
        else
          brew install wpscanteam/tap/wpscan
        fi
      else
        printf 'Homebrew is required for native WPScan on macOS.\n' >&2
        return 1
      fi
      ;;
    Linux)
      if has_command gem; then
        gem install wpscan
      else
        printf 'RubyGems is required for native WPScan on Linux.\n' >&2
        return 1
      fi
      ;;
    *)
      printf 'Native WPScan install is not automated for %s.\n' "${OS_NAME}" >&2
      return 1
      ;;
  esac
}

pull_image() {
  local image="$1"

  if [[ "${PULL_IMAGES}" != "yes" ]]; then
    printf 'Skipping Docker image pull for %s\n' "${image}"
    return 0
  fi

  if ! has_command docker; then
    printf 'Docker is not installed; cannot pull %s\n' "${image}" >&2
    return 1
  fi

  if ! docker_available; then
    printf 'Docker is installed but the daemon is not running; cannot pull %s\n' "${image}" >&2
    return 1
  fi

  docker pull "${image}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --native)
      INSTALL_NATIVE="yes"
      INSTALL_DOCKER="no"
      shift
      ;;
    --docker)
      INSTALL_NATIVE="no"
      INSTALL_DOCKER="yes"
      shift
      ;;
    --cewl)
      reset_tools
      INSTALL_CEWL="yes"
      shift
      ;;
    --wpscan)
      reset_tools
      INSTALL_WPSCAN="yes"
      shift
      ;;
    --no-pull)
      PULL_IMAGES="no"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'Unknown option: %s\n' "$1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ "${INSTALL_NATIVE}" == "yes" && "${INSTALL_WPSCAN}" == "yes" ]]; then
  install_wpscan_native || INSTALL_ERRORS=1
fi

if [[ "${INSTALL_DOCKER}" == "yes" ]]; then
  if [[ "${INSTALL_CEWL}" == "yes" ]]; then
    pull_image "ghcr.io/digininja/cewl:latest" || INSTALL_ERRORS=1
  fi

  if [[ "${INSTALL_WPSCAN}" == "yes" ]]; then
    pull_image "wpscanteam/wpscan" || INSTALL_ERRORS=1
  fi
fi

if [[ "${INSTALL_ERRORS}" -gt 0 ]]; then
  printf 'Dependency installation flow completed with errors.\n' >&2
  exit 1
fi

printf 'Dependency installation flow completed successfully.\n'
