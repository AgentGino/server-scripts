#!/usr/bin/env bash
#
# install-node-and-pi.sh
# Install Node.js 22 LTS (system-wide, checksum-verified from nodejs.org)
# and then install Pi via the official installer (https://pi.dev/install.sh).
# Intended to be run as root.
#
# Usage: sudo ./install-node-and-pi.sh
#
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Run as root: sudo $0" >&2
  exit 1
fi

NODE_DIST_BASE="https://nodejs.org/dist/latest-v22.x"
NODE_MIN_MAJOR=22
NODE_MIN_MINOR=19
NODE_PREFIX="/usr/local/lib/nodejs"
PI_INSTALLER="https://pi.dev/install.sh"

# --- helpers ----------------------------------------------------------------
node_is_new_enough() {
  command -v node >/dev/null 2>&1 || return 1
  node -e "const [maj,min]=process.versions.node.split('.').map(Number); process.exit(maj>${NODE_MIN_MAJOR}||(maj===${NODE_MIN_MAJOR}&&min>=${NODE_MIN_MINOR})?0:1)" >/dev/null 2>&1
}

detect_node_arch() {
  case "$(uname -m)" in
    x86_64|amd64)  echo x64 ;;
    aarch64|arm64) echo arm64 ;;
    armv7l)        echo armv7l ;;
    ppc64le)       echo ppc64le ;;
    s390x)         echo s390x ;;
    *) return 1 ;;
  esac
}

# --- prerequisites ----------------------------------------------------------
echo "==> Installing prerequisites"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y --no-install-recommends ca-certificates curl xz-utils

# --- Node.js ----------------------------------------------------------------
if node_is_new_enough; then
  echo "==> Node.js already satisfies >= ${NODE_MIN_MAJOR}.${NODE_MIN_MINOR} ($(node --version)); skipping"
else
  echo "==> Installing Node.js 22 LTS from nodejs.org"
  arch="$(detect_node_arch)" || { echo "Unsupported architecture: $(uname -m)" >&2; exit 1; }
  platform="linux-${arch}"

  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT

  echo "--> Resolving latest v22.x for ${platform}"
  curl -fsSL "${NODE_DIST_BASE}/SHASUMS256.txt" -o "${tmp}/SHASUMS256.txt"
  node_file="$(awk -v suffix="-${platform}.tar.xz" '
    index($2, "node-v") == 1 && substr($2, length($2) - length(suffix) + 1) == suffix { print $2; exit }
  ' "${tmp}/SHASUMS256.txt")"
  [[ -n "$node_file" ]] || { echo "No Node.js binary found for ${platform}" >&2; exit 1; }

  echo "--> Downloading ${node_file}"
  curl -fsSL "${NODE_DIST_BASE}/${node_file}" -o "${tmp}/${node_file}"

  echo "--> Verifying checksum"
  awk -v file="$node_file" '$2 == file' "${tmp}/SHASUMS256.txt" > "${tmp}/selected.sha"
  ( cd "$tmp" && sha256sum -c selected.sha )

  echo "--> Extracting to ${NODE_PREFIX}"
  mkdir -p "$NODE_PREFIX"
  tar -xf "${tmp}/${node_file}" -C "$NODE_PREFIX"
  node_dir="${NODE_PREFIX}/${node_file%.tar.xz}"
  ln -sfn "$node_dir" "${NODE_PREFIX}/current"

  echo "--> Linking node/npm/npx/corepack into /usr/local/bin"
  for bin in node npm npx corepack; do
    [[ -e "${NODE_PREFIX}/current/bin/${bin}" ]] && ln -sfn "${NODE_PREFIX}/current/bin/${bin}" "/usr/local/bin/${bin}"
  done
  hash -r
fi

echo "==> node $(node --version), npm $(npm --version)"

# --- Pi ---------------------------------------------------------------------
echo "==> Installing Pi via ${PI_INSTALLER}"
curl -fsSL "$PI_INSTALLER" | sh

# Make sure `pi` is reachable on PATH for root and other shells
if ! command -v pi >/dev/null 2>&1; then
  pi_bin="$(find /root/.pi "$HOME/.pi" -type f -name pi -path '*/bin/*' 2>/dev/null | head -1 || true)"
  if [[ -n "$pi_bin" ]]; then
    echo "--> Linking ${pi_bin} -> /usr/local/bin/pi"
    ln -sfn "$pi_bin" /usr/local/bin/pi
    hash -r
  fi
fi

echo
echo "==> Done."
echo "    node: $(node --version)"
echo "    pi:   $(command -v pi >/dev/null 2>&1 && pi --version || echo 'not on PATH yet (restart your shell)')"
