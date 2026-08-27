#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

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
  package_version="0.1.0+git${commit}${dirty_suffix}"
fi

if [[ ! "$package_version" =~ ^[0-9][0-9A-Za-z.+~]*(-[0-9A-Za-z.+~]+)?$ ]]; then
  echo "Некорректная Debian-версия: $package_version" >&2
  exit 2
fi

mkdir -p "$repo_root/dist"

docker buildx build \
  --file "$repo_root/packaging/Dockerfile.ubuntu24" \
  --platform linux/amd64 \
  --build-arg "PACKAGE_VERSION=$package_version" \
  --target package \
  --output "type=local,dest=$repo_root/dist" \
  "$repo_root"

package_path="$(find "$repo_root/dist" -maxdepth 1 -type f \
  -name "spectral-task_${package_version}_amd64.deb" -print -quit)"

if [[ -z "$package_path" ]]; then
  echo "Сборка завершилась без ожидаемого .deb" >&2
  exit 1
fi

printf 'Готово: %s\n' "$package_path"
