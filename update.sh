#!/usr/bin/env bash
# Bump PKGBUILD/.SRCINFO to the latest miner7222/LTBox binary release.
set -euo pipefail

cd "$(dirname "$0")"

UPSTREAM_REPO="${UPSTREAM_REPO:-miner7222/LTBox}"
api="${GITHUB_API_URL:-https://api.github.com}/repos/${UPSTREAM_REPO}/releases/latest"

curl_auth=()
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
  curl_auth=(-H "Authorization: Bearer ${GITHUB_TOKEN}" -H "X-GitHub-Api-Version: 2022-11-28")
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

http_code=$(curl -sS "${curl_auth[@]}" -o "$tmp/latest.json" -w "%{http_code}" "$api" || true)
case "$http_code" in
  200) ;;
  404)
    echo "upstream ${UPSTREAM_REPO} has no latest release (HTTP 404); leaving package unchanged" >&2
    exit 0
    ;;
  *)
    echo "failed to resolve latest release for ${UPSTREAM_REPO}: HTTP ${http_code:-curl-error}" >&2
    [[ -s "$tmp/latest.json" ]] && cat "$tmp/latest.json" >&2
    exit 1
    ;;
esac

tag=$(jq -r '.tag_name // empty' "$tmp/latest.json")
[[ -n "$tag" && "$tag" != null ]] || { echo "failed to resolve latest tag" >&2; exit 1; }
ver="${tag#v}"
ver="${ver#V}"

current=$(sed -n 's/^pkgver=//p' PKGBUILD)
if [[ "$current" == "$ver" ]]; then
  echo "PKGBUILD already at ${ver}"
  exit 0
fi

echo "updating ${current} -> ${ver}"

x86_asset="LTBox-linux_x86_64-v${ver}.tar.gz"
arm_asset="LTBox-linux_arm64-v${ver}.tar.gz"
rules_url="https://raw.githubusercontent.com/${UPSTREAM_REPO}/v${ver}/misc/udev/51-ltbox-qcom.rules"
x86_url="https://github.com/${UPSTREAM_REPO}/releases/download/v${ver}/${x86_asset}"
arm_url="https://github.com/${UPSTREAM_REPO}/releases/download/v${ver}/${arm_asset}"

# Prefer upstream-published .sha256 sidecars when present; otherwise hash downloads.
fetch_sum() {
  local url="$1" out="$2"
  if curl -fsSL "${curl_auth[@]}" -o "$out.sha256" "${url}.sha256" 2>/dev/null; then
    awk '{print $1}' "$out.sha256"
  else
    curl -fsSL "${curl_auth[@]}" -o "$out" "$url"
    sha256sum "$out" | awk '{print $1}'
  fi
}

x86_sum=$(fetch_sum "$x86_url" "$tmp/$x86_asset")
arm_sum=$(fetch_sum "$arm_url" "$tmp/$arm_asset")
curl -fsSL "${curl_auth[@]}" -o "$tmp/51-ltbox-qcom.rules" "$rules_url"
rules_sum=$(sha256sum "$tmp/51-ltbox-qcom.rules" | awk '{print $1}')

sed -i \
  -e "s/^pkgver=.*/pkgver=${ver}/" \
  -e 's/^pkgrel=.*/pkgrel=1/' \
  -e "s/^sha256sums=.*/sha256sums=('${rules_sum}')/" \
  -e "s/^sha256sums_x86_64=.*/sha256sums_x86_64=('${x86_sum}')/" \
  -e "s/^sha256sums_aarch64=.*/sha256sums_aarch64=('${arm_sum}')/" \
  PKGBUILD

printsrcinfo() {
  if command -v makepkg >/dev/null 2>&1; then
    if [[ "$(id -u)" == 0 ]]; then
      local d
      d=$(mktemp -d)
      cp PKGBUILD ltbox-bin.install "$d/" 2>/dev/null || cp PKGBUILD "$d/"
      id srcinfo >/dev/null 2>&1 || useradd -M -N -s /bin/bash srcinfo
      chown -R srcinfo "$d"
      (cd "$d" && su srcinfo -c 'makepkg --printsrcinfo')
    else
      makepkg --printsrcinfo
    fi
  elif command -v docker >/dev/null 2>&1; then
    docker run --rm -v "$PWD":/pkg:ro -w /pkg archlinux:base-devel \
      bash -c 'useradd -M -N -s /bin/bash srcinfo && install -d -o srcinfo /tmp/p && cp /pkg/PKGBUILD /pkg/ltbox-bin.install /tmp/p && cd /tmp/p && su srcinfo -c "makepkg --printsrcinfo"'
  else
    echo "need makepkg or docker to generate .SRCINFO" >&2
    exit 1
  fi
}

printsrcinfo > .SRCINFO.tmp
mv .SRCINFO.tmp .SRCINFO
echo "updated to $ver"
