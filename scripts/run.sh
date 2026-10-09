#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

ONLY_REPO=${ONLY_REPO:-}
FORCE=${FORCE:-}

[ -d .git ] || { echo "ERROR: not a git checkout repo root" >&2; exit 1; }

RELEASE_TAG=xbps-repo
IMAGE=ghcr.io/void-linux/void-buildroot-glibc:latest
RELEASE_URL="https://github.com/${GITHUB_REPOSITORY:?GITHUB_REPOSITORY must be set}/releases/download/${RELEASE_TAG}"
REPO_URL=https://repo-default.voidlinux.org/current

check_url() {
    local code attempt
    for attempt in 1 2 3 4 5 6; do
        code=$(curl -sL -r 0-0 -o /dev/null -w '%{http_code}' --retry 3 --retry-delay 2 "$1")
        if [ "$code" = 200 ] || [ "$code" = 206 ]; then
            return 0
        fi
        if [ "$attempt" -lt 6 ]; then
            sleep 10
        fi
    done
    echo "ERROR: $1 not served (http_code=$code)" >&2
    return 1
}

convert_one() {
    local repo=$1 glob=$2
    shift 2
    local tag dir pkgname pkgver expected
    local -a deb_files

    tag=$(gh api "repos/$repo/releases/latest" --jq .tag_name) || return 1

    if [ "$FORCE" != true ] && [ -f "state/$repo.txt" ] && [ "$(cat "state/$repo.txt")" = "$tag" ]; then
        echo "skip $repo@$tag"
        return 0
    fi

    dir="work/${repo//\//__}"
    rm -rf "$dir" || return 1
    mkdir -p "$dir/debs" || return 1

    gh release download -R "$repo" "$tag" -p "$glob" -D "$dir/debs" || true
    shopt -s nullglob
    deb_files=("$dir"/debs/*.deb)
    shopt -u nullglob
    if [ ${#deb_files[@]} -eq 0 ]; then
        echo "::error::glob '$glob' matched nothing in $repo@$tag; assets: $(gh api "repos/$repo/releases/latest" --jq '.assets[].name' | tr '\n' ' ')"
        return 1
    fi

    mkdir -p "$dir/pkgroot/binpkgs" || return 1
    curl --retry 3 -fsSL -o "$dir/pkgroot/binpkgs/x86_64-repodata" "$RELEASE_URL/x86_64-repodata" \
        || rm -f "$dir/pkgroot/binpkgs/x86_64-repodata"

    docker run --rm \
        -v "$PWD/$dir/debs:/in:ro" \
        -v "$PWD/$dir/pkgroot:/pkgroot" \
        -v "$PWD/scripts:/ci:ro" \
        "$IMAGE" /ci/convert.sh /in /pkgroot "$@" || return 1

    gh release view "$RELEASE_TAG" >/dev/null 2>&1 || \
        gh release create "$RELEASE_TAG" --title "xbps repository" \
            --notes "Auto-converted .xbps packages. Install: xbps-install -R ${RELEASE_URL}" || return 1
    gh release edit "$RELEASE_TAG" --draft=false || return 1
    gh release upload "$RELEASE_TAG" "$dir"/pkgroot/binpkgs/*.xbps "$dir/pkgroot/binpkgs/x86_64-repodata" --clobber || return 1

    for deb in "${deb_files[@]}"; do
        pkgname=$(basename "$deb" | cut -d_ -f1)
        pkgver=$(docker run --rm -v "$PWD/$dir/pkgroot:/pkgroot:ro" "$IMAGE" \
            xbps-query --repository=/pkgroot/binpkgs -p pkgver "$pkgname") || return 1
        expected="${pkgver}.x86_64.xbps"
        [ -f "$dir/pkgroot/binpkgs/$expected" ] || { echo "ERROR: produced $(basename "$deb") != $expected" >&2; return 1; }
        check_url "$RELEASE_URL/x86_64-repodata" || { echo "ERROR: repodata not served" >&2; return 1; }
        check_url "$RELEASE_URL/$expected" || { echo "ERROR: $expected not served" >&2; return 1; }
        docker run --rm "$IMAGE" sh -c "xbps-install --repository='$RELEASE_URL' -R '$REPO_URL' -S && xbps-install --repository='$RELEASE_URL' -R '$REPO_URL' --dry-run '$pkgname'" || return 1
    done

    mkdir -p "$(dirname "state/$repo.txt")" || return 1
    printf '%s\n' "$tag" > "state/$repo.txt" || return 1
    converted_here=true
    return 0
}

failures=0
any_converted=false
matched_any=false
while IFS='|' read -r repo glob extra || [ -n "$repo" ]; do
    case "$repo" in ''|'#'*) continue;; esac
    if [ -n "$ONLY_REPO" ] && [ "$repo" != "$ONLY_REPO" ]; then continue; fi
    matched_any=true
    if [ -z "$glob" ]; then
        echo "::error::watchlist entry '$repo' missing glob field"
        failures=$((failures + 1))
        continue
    fi
    converted_here=false
    if convert_one "$repo" "$glob" $extra; then
        if [ "$converted_here" = true ]; then any_converted=true; fi
    else
        echo "::error::conversion failed: $repo"
        failures=$((failures + 1))
    fi
done < watchlist.txt

if [ "$matched_any" = false ]; then
    if [ -n "$ONLY_REPO" ]; then
        echo "::error::ONLY_REPO '$ONLY_REPO' not found in watchlist"
    else
        echo "::error::watchlist has no usable entries"
    fi
    exit 1
fi

if [ -d state ]; then
    git add -A state
    if ! git diff --cached --quiet; then
        git config user.name  "bagaskara815"
        git config user.email "bagaskara815@gmail.com"
        git commit -m "state: record converted release tags"
        if [ "${GITHUB_ACTIONS:-}" = "true" ]; then git push; fi
    fi
fi

if [ -n "${GITHUB_OUTPUT:-}" ] && [ "$any_converted" = true ]; then
    echo "converted=true" >> "$GITHUB_OUTPUT"
fi
[ "$failures" -eq 0 ] || exit 1
