#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
output_dir="$(mktemp -d /tmp/spectral-deb-output.XXXXXX)"
cleanup() {
  rm -rf "$output_dir"
}
trap cleanup EXIT INT TERM

if [[ $# -gt 1 ]]; then
  echo "Использование: $0 [версия-пакета]" >&2
  exit 2
fi

if [[ $# -eq 1 ]]; then
  package_version="$1"
else
  commit="$(git -C "$repo_root" rev-parse --short=12 HEAD 2>/dev/null || printf local)"
  dirty_suffix=""
  if [[ -n "$(git -C "$repo_root" status --porcelain 2>/dev/null || true)" ]]; then
    dirty_suffix=".dirty"
  fi
  source_fingerprint="$(
    cd "$repo_root"
    find CMakeLists.txt CMakePresets.json packaging transport harness tools \
      -type f ! -path 'harness/bin/*' -print0 \
      | LC_ALL=C sort -z \
      | xargs -0 sha256sum \
      | sha256sum \
      | cut -c1-12
  )"
  package_version="0.1.0+git${commit}${dirty_suffix}.src${source_fingerprint}"
fi

if [[ ! "$package_version" =~ ^[0-9][0-9A-Za-z.+~]*(-[0-9A-Za-z.+~]+)?$ ]]; then
  echo "Некорректная Debian-версия: $package_version" >&2
  exit 2
fi

mkdir -p "$repo_root/dist"

builder_name="${SPECTRAL_BUILDX_BUILDER:-spectral-task}"
if ! docker buildx inspect "$builder_name" >/dev/null 2>&1; then
  docker buildx create \
    --name "$builder_name" \
    --driver docker-container \
    >/dev/null
fi

docker buildx build \
  --builder "$builder_name" \
  --file "$repo_root/packaging/Dockerfile.ubuntu24" \
  --platform linux/amd64 \
  --build-arg "PACKAGE_VERSION=$package_version" \
  --target package \
  --output "type=local,dest=$output_dir" \
  "$repo_root"

package_path="$(find "$output_dir" -maxdepth 1 -type f \
  -name "spectral-task_${package_version}_amd64.deb" -print -quit)"

if [[ -z "$package_path" ]]; then
  echo "Сборка завершилась без ожидаемого .deb" >&2
  exit 1
fi

package_sha256="$(sha256sum "$package_path" | awk '{print $1}')"
archived_path="$repo_root/dist/spectral-task_${package_version}+sha${package_sha256:0:12}_amd64.deb"
if [[ -e "$archived_path" ]]; then
  archived_sha256="$(sha256sum "$archived_path" | awk '{print $1}')"
  if [[ "$archived_sha256" != "$package_sha256" ]]; then
    echo "Конфликт content-addressed пакета: $archived_path" >&2
    exit 1
  fi
else
  install -m 0644 "$package_path" "$archived_path"
fi
printf '%s\n' "$archived_path" >"$repo_root/dist/.latest-package"

printf 'Готово: %s\nSHA256: %s\n' "$archived_path" "$package_sha256"
