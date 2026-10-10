#!/bin/sh
set -eu

debs_dir=$1
pkgroot=$2
shift 2

missing=""
for spec in xz:xz tar:tar curl:curl ar:binutils objdump:binutils xbps-rindex:xbps xbps-create:xbps; do
    command -v "${spec%%:*}" >/dev/null 2>&1 || missing="$missing ${spec##*:}"
done
if ! printf 'x\n' | grep -P 'x' >/dev/null 2>&1; then
    missing="$missing grep"
fi
if [ -n "$missing" ]; then
    xbps-install -R https://repo-default.voidlinux.org/current -Sfy $missing
fi
if ! printf 'x\n' | grep -P 'x' >/dev/null 2>&1; then
    echo "ERROR: grep without PCRE (-P) support; xdeb cannot parse control files" >&2
    exit 1
fi

mkdir -p "$pkgroot"
curl --retry 3 -fsSLo "$pkgroot/xdeb" https://github.com/xdeb-org/xdeb/releases/latest/download/xdeb
chmod 0755 "$pkgroot/xdeb"
export XDEB_PKGROOT="$pkgroot"

n=0
for f in "$debs_dir"/*.deb; do
    if [ -e "$f" ]; then n=$((n + 1)); fi
done
if [ "$n" -eq 0 ]; then
    echo "ERROR: no .deb in $debs_dir" >&2
    exit 1
fi

arch=$(uname -m)

: > "$pkgroot/manifest"

for f in "$debs_dir"/*.deb; do
    [ -e "$f" ] || continue
    "$pkgroot/xdeb" -Sedf "$@" "$f" || exit 1

    ctl=$(ar t "$f" | sed -n '/^control\.tar/{p;q;}')
    rm -rf "$pkgroot/ctldir"
    mkdir -p "$pkgroot/ctldir"
    case "$ctl" in
        control.tar.xz)  ar p "$f" "$ctl" | tar -xJf - -C "$pkgroot/ctldir" || exit 1;;
        control.tar.gz)  ar p "$f" "$ctl" | tar -zxf - -C "$pkgroot/ctldir" || exit 1;;
        control.tar.zst) ar p "$f" "$ctl" | tar --zstd -xf - -C "$pkgroot/ctldir" || exit 1;;
        control.tar.bz2) ar p "$f" "$ctl" | tar -xjf - -C "$pkgroot/ctldir" || exit 1;;
        control.tar)     ar p "$f" "$ctl" | tar -xf - -C "$pkgroot/ctldir" || exit 1;;
        *) echo "ERROR: unsupported control archive '$ctl' in $(basename "$f")" >&2; exit 1;;
    esac
    pkgname=$(sed -n 's/^Package:[[:space:]]*//p' "$pkgroot/ctldir/control" | head -n 1)
    if [ -z "$pkgname" ]; then
        echo "ERROR: no Package field in $(basename "$f")" >&2
        exit 1
    fi
    pkgver=$(xbps-query --repository="$pkgroot/binpkgs" -p pkgver "$pkgname" 2>/dev/null || true)
    if [ -z "$pkgver" ]; then
        echo "ERROR: $pkgname missing from repodata" >&2
        exit 1
    fi
    expected="${pkgver}.${arch}.xbps"
    if [ ! -f "$pkgroot/binpkgs/$expected" ]; then
        echo "ERROR: expected output $expected not produced for $(basename "$f")" >&2
        exit 1
    fi
    printf '%s\t%s\t%s\n' "$(basename "$f")" "$pkgname" "$pkgver" >> "$pkgroot/manifest"
done

if ! ls "$pkgroot"/binpkgs/*.xbps >/dev/null 2>&1; then
    echo "ERROR: no .xbps produced" >&2
    exit 1
fi
if [ ! -s "$pkgroot/binpkgs/${arch}-repodata" ]; then
    echo "ERROR: repodata missing" >&2
    exit 1
fi

if [ -f /signing_key ]; then
    xbps-rindex --sign --privkey /signing_key --signedby "bagaskara815 <bagaskara815@gmail.com>" "$pkgroot/binpkgs"
    xbps-rindex --sign-pkg --privkey /signing_key "$pkgroot"/binpkgs/*.xbps
fi
