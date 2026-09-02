#!/usr/bin/env bash
# scripts/build-p5-package.sh -- build ONE unpacked P5 package from this checkout.
#
#   PKG=$(bash scripts/build-p5-package.sh)
#   sh p5/bin/p5-install --package "$PKG" --role client --dry-run
#
# STDOUT IS THE PACKAGE PATH AND NOTHING ELSE. Every log line, every warning and
# every failure goes to stderr, because the only sanctioned way to use this
# script is `--package "$(bash scripts/build-p5-package.sh)"` and one stray
# echo there becomes an argument p5-install cannot parse.
#
# WHAT IT PRODUCES (the layout p5-install:159-166 requires, plus what a real
# deploy needs to run the installer from the package itself):
#
#   <pkg>/payload/filemap      p5/payload/filemap, verbatim: mode|role|src|dest
#   <pkg>/payload/<src>...     every file a filemap row names, at the row's src
#   <pkg>/PROVENANCE           key=value; every field shape-checked by
#                              p5-install:206-213 before anything is written
#   <pkg>/MANIFEST.sha256      sha256sum -c format, pinning every file in the
#                              package except itself
#   <pkg>/bin, lib, contract   p5/bin, p5/lib, p5/contract -- so the package is
#                              self-contained: p5-install locates its library at
#                              $(dirname $0)/../lib and its contract copies at
#                              ../contract (p5-install:86-88), and the files it
#                              places on the box (p5-uninstall, p5-version,
#                              p5-deadman, p5-common.sh, the three contract
#                              copies) come from $(dirname $0), NOT from the
#                              filemap (p5-install:305-312). A package without
#                              them installs only when the driver is run out of
#                              a source tree, which is not the deploy shape.
#
# WHY THE MANIFEST COVERS MORE THAN payload/. p5-install runs
# `sha256sum -c MANIFEST.sha256` from the package root (:170-172) and then walks
# `find $PKG/payload -type f` asserting each one is pinned (:179-182). The
# completeness half is payload-only, so payload/filemap and every payload file
# MUST be pinned or the install aborts with exit 3. Pinning bin/, lib/,
# contract/ and PROVENANCE as well is a strict strengthening: those are the
# files that are copied onto an unrecoverable box, and a truncated scp of one of
# them would otherwise be invisible until it ran.
#
# EVERY MISSING INPUT IS FATAL AND NAMED. There is no partial package and no
# best-effort row. A filemap row whose src is neither in the repo nor produced
# by a build step aborts the build naming the src, the row and the repo path it
# looked for -- because a package that silently omits a file is a package that
# installs a box into a state nobody planned, and the box in question has no
# console.

set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)

# The target architecture. Both boxes are aarch64: the GL-MT2500 server
# (.github/workflows/emulator-gate.yml:271-273) and the client
# (emulator-gate.yml:738). CONTRACT.md:348-350 makes the architecture choice
# U28's, "expressed as filemap rows" -- so it is spelled here AND in the src
# column of p5/payload/filemap, and the completeness check at the end refuses
# the build if the two ever disagree.
GOARCH_TARGET=arm64
GO_TARGETS="p4-bondagg/daemon|build/linux-${GOARCH_TARGET}/p5-datapath
p4-bondagg/server|build/linux-${GOARCH_TARGET}/p5-server"

FILEMAP_SRC="$REPO/p5/payload/filemap"

log()  { printf 'build-p5-package: %s\n' "$*" >&2; }
die()  { printf 'build-p5-package: FATAL: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 1. tools. Named individually, because "command not found" three levels down a
#    pipeline is how a build produces half a package and exits 0.
# ---------------------------------------------------------------------------
for t in git sha256sum find sort; do
    command -v "$t" >/dev/null 2>&1 \
        || die "missing required input: the tool '$t' is not on PATH"
done
command -v go >/dev/null 2>&1 || die \
    "missing required input: a Go toolchain. The package carries two compiled
  binaries (p4-bondagg/daemon -> /usr/sbin/p5-datapath, p4-bondagg/server ->
  /usr/sbin/p5-server) and they are cross-compiled here with
  GOOS=linux GOARCH=${GOARCH_TARGET} CGO_ENABLED=0. Both modules declare go 1.22
  (p4-bondagg/{daemon,server}/go.mod). Install go, or run this build inside the
  WSL clone where the repo's toolchain lives. This build does NOT ship a package
  with the binaries missing."

[ -r "$FILEMAP_SRC" ] || die "missing required input: $FILEMAP_SRC"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/p5-build.XXXXXX") || die "cannot create a scratch directory"
trap 'rm -rf "$WORK"' EXIT INT TERM
OUT=$(mktemp -d "${TMPDIR:-/tmp}/p5-pkg.XXXXXX")   || die "cannot create the package directory"

log "repo      $REPO"
log "package   $OUT"

# ---------------------------------------------------------------------------
# 2. read and SHAPE-CHECK the filemap before anything is copied.
#    p5-install refuses a malformed row at install time (:266-277). Refusing it
#    here as well means the failure lands on the build host, where there is a
#    console, rather than on the box, where there is not.
# ---------------------------------------------------------------------------
: > "$WORK/rows"
bad=0; lineno=0
while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    case "$line" in ''|'#'*) continue ;; esac
    IFS='|' read -r fm_mode fm_role fm_src fm_dest <<EOF
$line
EOF
    if [ -z "${fm_dest:-}" ]; then
        log "filemap:$lineno: malformed row (need mode|role|src|dest): $line"; bad=$((bad + 1)); continue
    fi
    case "$fm_mode" in
        [0-7][0-7][0-7]|[0-7][0-7][0-7][0-7]) : ;;
        *) log "filemap:$lineno: mode '$fm_mode' is not an octal file mode"; bad=$((bad + 1)); continue ;;
    esac
    case "$fm_role" in
        client|server|both) : ;;
        *) log "filemap:$lineno: role '$fm_role' is not client, server or both"; bad=$((bad + 1)); continue ;;
    esac
    case "$fm_src" in
        ''|/*|*..*|*' '*) log "filemap:$lineno: src '$fm_src' must be a relative path with no '..'"; bad=$((bad + 1)); continue ;;
    esac
    case "$fm_dest" in
        /*) : ;;
        *) log "filemap:$lineno: dest '$fm_dest' is not an absolute path"; bad=$((bad + 1)); continue ;;
    esac
    printf '%s|%s|%s|%s\n' "$fm_mode" "$fm_role" "$fm_src" "$fm_dest" >> "$WORK/rows"
done < "$FILEMAP_SRC"
[ "$bad" = 0 ] || die "$bad malformed filemap row(s) in $FILEMAP_SRC -- refusing to build a package from a filemap p5-install would reject"
[ -s "$WORK/rows" ] || die "$FILEMAP_SRC declares no payload rows -- an empty package is not a package"

dup=$(cut -d'|' -f4 "$WORK/rows" | LC_ALL=C sort | uniq -d)
[ -z "$dup" ] || die "two filemap rows claim the same destination, so one would silently overwrite the other:
$dup"

log "filemap   $(wc -l < "$WORK/rows" | tr -d ' ') row(s), shape-checked"

# ---------------------------------------------------------------------------
# 3. the compiled payload. Built straight into the package so there is no
#    intermediate copy that can go stale.
# ---------------------------------------------------------------------------
mkdir -p "$OUT/payload"
while IFS='|' read -r mod rel; do
    [ -n "$mod" ] || continue
    [ -d "$REPO/$mod" ] \
        || die "missing required input: Go module directory $mod (needed for payload/$rel)"
    [ -r "$REPO/$mod/go.mod" ] \
        || die "missing required input: $mod/go.mod (needed for payload/$rel)"
    mkdir -p "$OUT/payload/$(dirname "$rel")"
    log "building  $mod -> payload/$rel (GOOS=linux GOARCH=$GOARCH_TARGET CGO_ENABLED=0)"
    ( cd "$REPO/$mod" \
      && GOOS=linux GOARCH="$GOARCH_TARGET" CGO_ENABLED=0 \
         go build -trimpath -ldflags="-s -w" -o "$OUT/payload/$rel" . >&2 ) \
        || die "go build failed for $mod -- refusing to ship a package without payload/$rel"
    [ -s "$OUT/payload/$rel" ] \
        || die "go build produced no output for $mod at payload/$rel"
done <<EOF
$GO_TARGETS
EOF

# ---------------------------------------------------------------------------
# 4. the copied payload. A src that is neither in the repo nor already built is
#    a MISSING INPUT, named, and fatal.
# ---------------------------------------------------------------------------
while IFS='|' read -r fm_mode fm_role fm_src fm_dest; do
    dst="$OUT/payload/$fm_src"
    if [ -f "$dst" ]; then
        :                                   # produced by step 3
    elif [ -f "$REPO/$fm_src" ]; then
        mkdir -p "$(dirname "$dst")"
        cp -p "$REPO/$fm_src" "$dst"
    else
        die "missing required input for filemap row '$fm_mode|$fm_role|$fm_src|$fm_dest':
  not built by this script, and not present in the repo at $REPO/$fm_src.
  Refusing to ship a package that is missing a file it declares."
    fi
    chmod "$fm_mode" "$dst"
done < "$WORK/rows"

cp -p "$FILEMAP_SRC" "$OUT/payload/filemap"
chmod 644 "$OUT/payload/filemap"

# ---------------------------------------------------------------------------
# 5. the driver, its library and the contract copies.
# ---------------------------------------------------------------------------
for d in bin lib contract; do
    [ -d "$REPO/p5/$d" ] || die "missing required input: $REPO/p5/$d"
    cp -R "$REPO/p5/$d" "$OUT/$d"
done
chmod 755 "$OUT"/bin/*

# ---------------------------------------------------------------------------
# 6. PROVENANCE. Every field below is shape-checked by p5-install:206-213 and a
#    package that fails is an INTEGRITY failure, not a warning -- so the values
#    are derived, never defaulted. P5_GIT_DIRTY is carried and printed rather
#    than refused (CONTRACT.md:112): a hand-built package for a lab box is
#    legitimate, but it must be visible on the box rather than remembered.
# ---------------------------------------------------------------------------
git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1 \
    || die "missing required input: $REPO is not a git checkout, so PROVENANCE cannot tie this package to a commit"
COMMIT=$(git -C "$REPO" rev-parse HEAD)
BRANCH=$(git -C "$REPO" rev-parse --abbrev-ref HEAD)
[ "$BRANCH" != HEAD ] || BRANCH=detached
if [ -n "$(git -C "$REPO" status --porcelain)" ]; then DIRTY=yes; else DIRTY=no; fi
BUILT=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
{
    echo "# P5 package provenance, written by scripts/build-p5-package.sh."
    echo "# p5-install shape-checks every field below and copies them verbatim"
    echo "# into /usr/lib/p5/stamp, which is what p5-version prints."
    echo "P5_PRODUCT=p5"
    echo "P5_VERSION=0.0.0+g$(git -C "$REPO" rev-parse --short=12 HEAD)"
    echo "P5_GIT_COMMIT=$COMMIT"
    echo "P5_GIT_BRANCH=$BRANCH"
    echo "P5_GIT_DIRTY=$DIRTY"
    echo "P5_BUILT_UTC=$BUILT"
    echo "P5_BUILDER=$(uname -s -m | tr '\n' ' ')$(go version 2>/dev/null | sed 's/^go version //')"
} > "$OUT/PROVENANCE"
chmod 644 "$OUT/PROVENANCE"
log "stamp     $COMMIT ($BRANCH), dirty=$DIRTY, built $BUILT"

# ---------------------------------------------------------------------------
# 7. MANIFEST.sha256, in `sha256sum -c` format, over every file in the package
#    except itself. The relative paths are exactly what p5-install's
#    completeness walk compares against (:179-182), which splices the payload
#    path into a BRE -- so a `./` prefix or an absolute path here would pin
#    nothing that check can see.
# ---------------------------------------------------------------------------
( cd "$OUT" && find . -type f ! -name MANIFEST.sha256 -print \
    | sed 's|^\./||' | LC_ALL=C sort > "$WORK/manifest.list" )
[ -s "$WORK/manifest.list" ] || die "internal: the package is empty"
( cd "$OUT" && xargs -a "$WORK/manifest.list" sha256sum > MANIFEST.sha256 )
chmod 644 "$OUT/MANIFEST.sha256"

# ---------------------------------------------------------------------------
# 8. COMPLETENESS, both directions, and it is the whole point of this step.
#    A payload file with no filemap row rides onto the box unsigned-off and is
#    exactly what p5-install:179-182 exists to catch -- catching it here means
#    the build fails, not the install. A filemap row with no payload file is the
#    mirror defect and would abort the install with exit 4.
#    This is also the ONLY thing keeping GO_TARGETS above and the src column of
#    p5/payload/filemap from drifting apart.
# ---------------------------------------------------------------------------
( cd "$OUT/payload" && find . -type f -print | sed 's|^\./||' | LC_ALL=C sort ) \
    | grep -vx 'filemap' > "$WORK/have" || true
cut -d'|' -f3 "$WORK/rows" | LC_ALL=C sort -u > "$WORK/want"
if ! cmp -s "$WORK/have" "$WORK/want"; then
    log "the package's payload files and the filemap's src column DISAGREE."
    log "declared in the filemap but not in the package:"
    comm -13 "$WORK/have" "$WORK/want" | sed 's/^/    /' >&2
    log "in the package but declared by no filemap row:"
    comm -23 "$WORK/have" "$WORK/want" | sed 's/^/    /' >&2
    die "refusing to emit a package whose payload and filemap disagree"
fi

# Self-check the manifest with the same tool and the same invocation p5-install
# will use, so a package that cannot verify never leaves this script.
( cd "$OUT" && sha256sum -c MANIFEST.sha256 ) >/dev/null 2>&1 \
    || die "internal: the MANIFEST this build just wrote does not verify"

log "payload   $(wc -l < "$WORK/want" | tr -d ' ') file(s); manifest pins $(wc -l < "$OUT/MANIFEST.sha256" | tr -d ' ')"
printf '%s\n' "$OUT"
