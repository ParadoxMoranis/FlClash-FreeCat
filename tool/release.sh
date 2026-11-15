#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"
push=false
dry_run=false
for option in "$@"; do
  case "$option" in
    --push) push=true ;;
    --dry-run) dry_run=true ;;
    --help|-h)
      echo 'Usage: tool/release.sh [--dry-run] [--push]'
      echo 'Tag the committed pubspec version; see RELEASING.md for signing and AUR.'
      exit 0
      ;;
    *) echo "Unknown option: $option" >&2; exit 64 ;;
  esac
done

version="$(awk '/^version:/{sub(/\+.*/, "", $2); print $2; exit}' pubspec.yaml)"
if [[ ! "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?$ ]]; then
  echo 'pubspec.yaml must contain a release version' >&2
  exit 1
fi
if [[ "$version" == *-* ]]; then
  IFS='.' read -ra identifiers <<<"${version#*-}"
  for identifier in "${identifiers[@]}"; do
    if [[ "$identifier" =~ ^0[0-9]+$ ]]; then
      echo 'Numeric prerelease identifiers cannot have leading zeroes' >&2
      exit 1
    fi
  done
fi
tag="v$version"
branch="$(git symbolic-ref --short HEAD)"
if [[ -n "$(git status --porcelain)" ]]; then
  echo 'Commit the intended release changes before creating its tag' >&2
  exit 1
fi
if git show-ref --verify --quiet "refs/tags/$tag"; then
  echo "Tag $tag already exists; update pubspec.yaml for the next release" >&2
  exit 1
fi
printf 'Release %s from %s; remote: %s\n' "$tag" "$branch" "$(git remote get-url origin)"
if "$dry_run"; then
  exit 0
fi
git tag "$tag"
if "$push"; then
  git push origin "$branch"
  git push origin "$tag"
else
  printf 'Tagged locally. Publish with: git push origin %q && git push origin %q\n' "$branch" "$tag"
fi
