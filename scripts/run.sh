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

if [ -n "${GITHUB_ACTIONS:-}" ] && [ -z "${XBPS_PRIVKEY:-}" ]; then
    echo "ERROR: XBPS_PRIVKEY secret is not set; packages cannot be signed" >&2
    exit 1
fi
if [ -n "${XBPS_PRIVKEY:-}" ]; then
    umask 077
    mkdir -p work/key
    printf '%s\n' "$XBPS_PRIVKEY" > work/signing_key
    openssl rsa -in work/signing_key -pubout -out work/key/pubkey.pem 2>/dev/null
    fp=$(ssh-keygen -y -f work/signing_key | python3 -c 'import base64,hashlib,sys; b=base64.b64decode(sys.stdin.read().split()[1]); print(":".join("%02x"%x for x in hashlib.md5(b).digest()))')
    python3 - "$fp" <<'PYEOF'
import plistlib, sys
pem = open("work/key/pubkey.pem", "rb").read()
plistlib.dump({"public-key": pem}, open("work/key/%s.plist" % sys.argv[1], "wb"), fmt=plistlib.FMT_XML)
PYEOF
fi

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
    local tag dir dbf pkn pkv pkgver expected
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

    keymount=""
    if [ -f work/signing_key ]; then
        keymount="-v $PWD/work/signing_key:/signing_key:ro"
    fi
    docker run --rm \
        -v "$PWD/$dir/debs:/in:ro" \
        -v "$PWD/$dir/pkgroot:/pkgroot" \
        -v "$PWD/scripts:/ci:ro" \
        $keymount \
        "$IMAGE" /ci/convert.sh /in /pkgroot "$@" || return 1

    gh release view "$RELEASE_TAG" >/dev/null 2>&1 || \
        gh release create "$RELEASE_TAG" --title "xbps repository" \
            --notes "Auto-converted .xbps packages, RSA-signed. Install: xbps-install -S -R ${RELEASE_URL} <pkg> (answer Y to import the signing key)" || return 1
    gh release edit "$RELEASE_TAG" --draft=false || return 1
    gh release upload "$RELEASE_TAG" "$dir"/pkgroot/binpkgs/*.xbps "$dir"/pkgroot/binpkgs/*.xbps.sig2 "$dir/pkgroot/binpkgs/x86_64-repodata" --clobber || return 1

    if [ ! -s "$dir/pkgroot/manifest" ]; then
        echo "ERROR: conversion manifest missing for $repo" >&2
        return 1
    fi
    while IFS=$'\t' read -r dbf pkn pkv; do
        pkgver=$(docker run --rm -v "$PWD/$dir/pkgroot:/pkgroot:ro" "$IMAGE" \
            xbps-query --repository=/pkgroot/binpkgs -p pkgver "$pkn") || return 1
        if [ "$pkgver" != "$pkv" ]; then
            echo "ERROR: repodata has $pkgver for $pkn, expected $pkv" >&2
            return 1
        fi
        expected="${pkv}.x86_64.xbps"
        [ -f "$dir/pkgroot/binpkgs/$expected" ] || { echo "ERROR: produced $dbf != $expected" >&2; return 1; }
        check_url "$RELEASE_URL/x86_64-repodata" || { echo "ERROR: repodata not served" >&2; return 1; }
        check_url "$RELEASE_URL/$expected" || { echo "ERROR: $expected not served" >&2; return 1; }
        check_url "$RELEASE_URL/${expected}.sig2" || { echo "ERROR: ${expected}.sig2 not served" >&2; return 1; }
        eprefix=""
        ekeymount=""
        if [ -f work/signing_key ]; then
            eprefix="cp /key/*.plist /var/db/xbps/keys/ && "
            ekeymount="-v $PWD/work/key:/key:ro"
        fi
        attempt=0
        until docker run --rm $ekeymount "$IMAGE" sh -c "${eprefix}xbps-install --repository='$RELEASE_URL' -R '$REPO_URL' -S && xbps-install --repository='$RELEASE_URL' -R '$REPO_URL' --dry-run '$pkn'"; do
            attempt=$((attempt + 1))
            if [ "$attempt" -ge 6 ]; then
                echo "ERROR: dry-run verification failed for $pkn after $attempt attempts" >&2
                return 1
            fi
            sleep 30
        done
    done < "$dir/pkgroot/manifest"

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
