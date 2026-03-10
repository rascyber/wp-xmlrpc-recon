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

TOOLS_ROOT="${PROJECT_ROOT}/.tools"
WRAPPER_DIR="${TOOLS_ROOT}/bin"
GEM_ROOT="${TOOLS_ROOT}/gems"
GEM_BIN_DIR="${TOOLS_ROOT}/gem-bin"
BUNDLE_ROOT="${TOOLS_ROOT}/bundle"
SOURCE_ROOT="${TOOLS_ROOT}/src"

OS_NAME="$(uname -s)"
RUBY_BIN=""
GEM_CMD=""
BUNDLE_BIN=""

combined_gem_path() {
  printf '%s:%s' "${GEM_ROOT}" "$("${GEM_CMD}" env gempath)"
}

usage() {
  cat <<'EOF'
Usage: install_dependencies.sh [--native] [--docker] [--cewl] [--wpscan] [--no-pull] [--help]

Options:
  --native     install native dependencies only
  --docker     pull container fallback images only
  --cewl       limit actions to CeWL
  --wpscan     limit actions to WPScan
  --no-pull    skip container image pulls
  -h, --help   show help

Default behavior:
  - install native CeWL and WPScan into repo-local wrappers where practical
  - rely on Docker or Podman as the cross-platform fallback for CeWL and WPScan
EOF
}

reset_tools() {
  INSTALL_CEWL="no"
  INSTALL_WPSCAN="no"
}

ensure_local_dirs() {
  mkdir -p "${WRAPPER_DIR}" "${GEM_ROOT}" "${GEM_BIN_DIR}" "${BUNDLE_ROOT}" "${SOURCE_ROOT}" "${TOOLS_ROOT}/home/.wpscan/db"
}

resolve_homebrew_ruby_prefix() {
  if ! has_command brew; then
    return 1
  fi

  brew --prefix ruby 2>/dev/null || return 1
}

prepare_ruby_toolchain() {
  local brew_ruby_prefix=""

  if [[ "${OS_NAME}" == "Darwin" ]]; then
    if brew_ruby_prefix="$(resolve_homebrew_ruby_prefix)"; then
      RUBY_BIN="${brew_ruby_prefix}/bin/ruby"
      GEM_CMD="${brew_ruby_prefix}/bin/gem"
      BUNDLE_BIN="${brew_ruby_prefix}/bin/bundle"
      return 0
    fi

    if has_command brew; then
      brew install ruby
      brew_ruby_prefix="$(resolve_homebrew_ruby_prefix)"
      RUBY_BIN="${brew_ruby_prefix}/bin/ruby"
      GEM_CMD="${brew_ruby_prefix}/bin/gem"
      BUNDLE_BIN="${brew_ruby_prefix}/bin/bundle"
      return 0
    fi
  fi

  if has_command ruby && has_command gem && has_command bundle; then
    RUBY_BIN="$(command -v ruby)"
    GEM_CMD="$(command -v gem)"
    BUNDLE_BIN="$(command -v bundle)"
    return 0
  fi

  printf 'Ruby, RubyGems, and Bundler are required for native installs.\n' >&2
  return 1
}

ruby_meets_requirement() {
  local minimum_version="$1"

  "${RUBY_BIN}" -e 'required = Gem::Version.new(ARGV[0]); current = Gem::Version.new(RUBY_VERSION); exit(current >= required ? 0 : 1)' "${minimum_version}"
}

install_local_bundler() {
  ensure_local_dirs
  GEM_HOME="${GEM_ROOT}" GEM_PATH="$(combined_gem_path)" "${GEM_CMD}" install --install-dir "${GEM_ROOT}" --bindir "${GEM_BIN_DIR}" --no-document bundler
}

ensure_bundle_command() {
  if [[ -n "${BUNDLE_BIN}" && -x "${BUNDLE_BIN}" ]]; then
    return 0
  fi

  install_local_bundler

  if [[ -x "${GEM_BIN_DIR}/bundle" ]]; then
    BUNDLE_BIN="${GEM_BIN_DIR}/bundle"
    return 0
  fi

  printf 'Bundler is not available after installation attempt.\n' >&2
  return 1
}

write_wpscan_wrapper() {
  local default_gem_path=""

  default_gem_path="$("${GEM_CMD}" env gempath)"
  cat > "${WRAPPER_DIR}/wpscan" <<EOF
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="\$(cd "\${SCRIPT_DIR}/../.." && pwd)"
export GEM_HOME="\${PROJECT_ROOT}/.tools/gems"
export GEM_PATH="\${GEM_HOME}:${default_gem_path}"
export PATH="\${PROJECT_ROOT}/.tools/gem-bin:\${PATH}"
export HOME="\${PROJECT_ROOT}/.tools/home"
exec "\${PROJECT_ROOT}/.tools/gem-bin/wpscan" "\$@"
EOF
  chmod +x "${WRAPPER_DIR}/wpscan"
}

write_cewl_wrapper() {
  local default_gem_path=""

  default_gem_path="$("${GEM_CMD}" env gempath)"
  cat > "${WRAPPER_DIR}/cewl" <<EOF
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="\$(cd "\${SCRIPT_DIR}/../.." && pwd)"
export GEM_HOME="\${PROJECT_ROOT}/.tools/gems"
export GEM_PATH="\${GEM_HOME}:${default_gem_path}"
export PATH="$(dirname "${RUBY_BIN}"):\${PROJECT_ROOT}/.tools/gem-bin:\${PATH}"
export BUNDLE_PATH="\${PROJECT_ROOT}/.tools/bundle"
cd "\${PROJECT_ROOT}/.tools/src/CeWL"
exec "${BUNDLE_BIN}" exec ruby ./cewl.rb "\$@"
EOF
  chmod +x "${WRAPPER_DIR}/cewl"
}

install_wpscan_native() {
  ensure_local_dirs
  prepare_ruby_toolchain || return 1

  if tool_works wpscan --version; then
    printf 'WPScan already available via existing runtime.\n'
    return 0
  fi

  if ! ruby_meets_requirement "3.0.0"; then
    printf 'Native WPScan requires Ruby >= 3.0. Current runtime is too old.\n' >&2
    return 1
  fi

  GEM_HOME="${GEM_ROOT}" GEM_PATH="$(combined_gem_path)" "${GEM_CMD}" install --install-dir "${GEM_ROOT}" --bindir "${GEM_BIN_DIR}" --no-document wpscan
  write_wpscan_wrapper

  if ! tool_works wpscan --version; then
    printf 'WPScan wrapper was installed but did not pass a version check.\n' >&2
    return 1
  fi

  printf 'WPScan installed into %s.\n' "${WRAPPER_DIR}/wpscan"
}

install_cewl_native() {
  local cewl_src_dir="${SOURCE_ROOT}/CeWL"

  ensure_local_dirs
  prepare_ruby_toolchain || return 1
  ensure_bundle_command || return 1

  if [[ ! -d "${cewl_src_dir}/.git" ]]; then
    git clone https://github.com/digininja/CeWL.git "${cewl_src_dir}"
  else
    git -C "${cewl_src_dir}" pull --ff-only
  fi

  if ! grep -Eq '^[[:space:]]*gem[[:space:]]+["'\'']getoptlong["'\'']' "${cewl_src_dir}/Gemfile"; then
    printf '\ngem "getoptlong"\n' >> "${cewl_src_dir}/Gemfile"
  fi

  if ! grep -Eq '^[[:space:]]*gem[[:space:]]+["'\'']pstore["'\'']' "${cewl_src_dir}/Gemfile"; then
    printf 'gem "pstore"\n' >> "${cewl_src_dir}/Gemfile"
  fi

  if ! grep -Eq '^[[:space:]]*gem[[:space:]]+["'\'']logger["'\'']' "${cewl_src_dir}/Gemfile"; then
    printf 'gem "logger"\n' >> "${cewl_src_dir}/Gemfile"
  fi

  (
    cd "${cewl_src_dir}"
    GEM_HOME="${GEM_ROOT}" \
    GEM_PATH="$(combined_gem_path)" \
    BUNDLE_PATH="${BUNDLE_ROOT}" \
    PATH="${GEM_BIN_DIR}:$(dirname "${RUBY_BIN}"):${PATH}" \
    "${BUNDLE_BIN}" install
  )

  write_cewl_wrapper

  if ! tool_works cewl --help; then
    printf 'CeWL wrapper was installed but did not pass a help check.\n' >&2
    return 1
  fi

  printf 'CeWL installed into %s.\n' "${WRAPPER_DIR}/cewl"
}

pull_image() {
  local image="$1"
  local container_bin=""

  if [[ "${PULL_IMAGES}" != "yes" ]]; then
    printf 'Skipping container image pull for %s\n' "${image}"
    return 0
  fi

  if ! container_bin="$(container_runtime 2>/dev/null)"; then
    printf 'No running Docker or Podman runtime is available; cannot pull %s\n' "${image}" >&2
    return 1
  fi

  "${container_bin}" pull "${image}"
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

if [[ "${INSTALL_NATIVE}" == "yes" && "${INSTALL_CEWL}" == "yes" ]]; then
  install_cewl_native || INSTALL_ERRORS=1
fi

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
