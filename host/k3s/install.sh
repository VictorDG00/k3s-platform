#!/usr/bin/env bash
# Install single-node k3s with a pinned version and verified checksums.
# Run as root:  sudo host/k3s/install.sh
#
# What it does:
#  1. downloads the k3s binary of the pinned tag and checks its sha256 against
#     the sha256sum-amd64.txt published in the same release;
#  2. checks the sha256 of the upstream install.sh (pinned below) and runs it
#     from the same tag with INSTALL_K3S_SKIP_DOWNLOAD (so it never downloads
#     anything itself);
#  3. hands the kubeconfig to the operator user.
# Idempotent. To upgrade: change K3S_VERSION and INSTALL_SH_SHA256.
set -euo pipefail

# ---- values to set ---------------------------------------------------------
K3S_VERSION='v1.36.5+k3s1'
# sha256 of https://raw.githubusercontent.com/k3s-io/k3s/<K3S_VERSION>/install.sh
# (compute it yourself after reading the script: curl -fsSL <url> | sha256sum)
INSTALL_SH_SHA256='46177d4c99440b4c0311b67233823a8e8a2fc09693f6c89af1a7161e152fbfad'
OPERATOR_USER="${SUDO_USER:-operator}"
# -----------------------------------------------------------------------------

[ "$(id -u)" -eq 0 ] || { echo "run with sudo" >&2; exit 1; }
[ "$(uname -m)" = x86_64 ] || { echo "x86_64 only (sha256sum-amd64)" >&2; exit 1; }

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TAG_URL=${K3S_VERSION//+/%2B}
CONF_REPO=$HERE/config.yaml
CONF_DEST=/etc/rancher/k3s/config.yaml
KUBECONFIG_DEST=$(getent passwd "$OPERATOR_USER" | cut -d: -f6)/.kube/k3s.yaml

# Refuse to continue if the live config was edited by hand.
if [ -e "$CONF_DEST" ] && ! cmp -s "$CONF_REPO" "$CONF_DEST"; then
    echo "$CONF_DEST differs from $CONF_REPO; resolve first (diff -u)" >&2
    exit 1
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# Binary: skip if the installed one is already the pinned version.
if [ "$(/usr/local/bin/k3s --version 2>/dev/null | awk 'NR==1{print $3}')" != "$K3S_VERSION" ]; then
    base=https://github.com/k3s-io/k3s/releases/download/$TAG_URL
    curl -fsSL -o "$tmp/k3s" "$base/k3s"
    curl -fsSL -o "$tmp/sha256sum-amd64.txt" "$base/sha256sum-amd64.txt"
    expected=$(awk '$2=="k3s"{print $1}' "$tmp/sha256sum-amd64.txt")
    [ -n "$expected" ] || { echo "k3s not listed in sha256sum-amd64.txt" >&2; exit 1; }
    echo "$expected  $tmp/k3s" | sha256sum -c -
    install -m 0755 -o root -g root "$tmp/k3s" /usr/local/bin/k3s
fi

# Upstream install.sh of the same tag, with a pinned hash.
curl -fsSL -o "$tmp/install.sh" "https://raw.githubusercontent.com/k3s-io/k3s/$TAG_URL/install.sh"
echo "$INSTALL_SH_SHA256  $tmp/install.sh" | sha256sum -c -

install -d -m 0755 /etc/rancher/k3s
[ -e "$CONF_DEST" ] || install -m 0600 -o root -g root "$CONF_REPO" "$CONF_DEST"

INSTALL_K3S_SKIP_DOWNLOAD=true INSTALL_K3S_VERSION=$K3S_VERSION sh "$tmp/install.sh"

# Wait for the kubeconfig and hand it to the operator.
for _ in $(seq 1 60); do [ -s /etc/rancher/k3s/k3s.yaml ] && break; sleep 1; done
[ -s /etc/rancher/k3s/k3s.yaml ] || { echo "k3s.yaml did not appear; see journalctl -u k3s" >&2; exit 1; }
install -d -m 0700 -o "$OPERATOR_USER" -g "$OPERATOR_USER" "$(dirname "$KUBECONFIG_DEST")"
install -m 0600 -o "$OPERATOR_USER" -g "$OPERATOR_USER" /etc/rancher/k3s/k3s.yaml "$KUBECONFIG_DEST"
echo "ok: $K3S_VERSION installed; kubeconfig at $KUBECONFIG_DEST"
