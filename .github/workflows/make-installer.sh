#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# make-installer.sh -- wrap a built CREST binary into a self-extracting .run
#
#   ./ci/make-installer.sh --bin _dist/bin/crest --version 3.0.2 --out dist
#
# Result: dist/crest-<version>-x86_64-linux.run (+ .sha256)
#   sh crest-3.0.2-x86_64-linux.run              # -> /usr/local (or ~/.local)
#   sh crest-3.0.2-x86_64-linux.run --prefix=~/opt
#   sh crest-3.0.2-x86_64-linux.run --uninstall
# ---------------------------------------------------------------------------
set -euo pipefail

BIN=""
VERSION="dev"
OUT="dist"
ARCH="x86_64"
DO_STRIP=0

while [ $# -gt 0 ]; do
   case "$1" in
      --bin)      BIN="$2"; shift 2 ;;
      --version)  VERSION="$2"; shift 2 ;;
      --out)      OUT="$2"; shift 2 ;;
      --arch)     ARCH="$2"; shift 2 ;;
      --strip)    DO_STRIP=1; shift ;;
      -h|--help)  sed -n '2,12p' "$0"; exit 0 ;;
      *) echo "unknown argument: $1" >&2; exit 2 ;;
   esac
done

if [ -z "$BIN" ] || [ ! -x "$BIN" ]; then
   echo "error: --bin must point at the crest executable" >&2
   exit 2
fi

mkdir -p "$OUT"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# --- stage the payload ------------------------------------------------------
stage="$work/stage"
mkdir -p "$stage"

if [ "$DO_STRIP" -eq 1 ]; then
   strip --strip-unneeded -o "$stage/crest" "$BIN"
else
   cp "$BIN" "$stage/crest"
fi
chmod 755 "$stage/crest"

# licence files sit next to the sources, not next to the build dir
for f in COPYING COPYING.LESSER; do
   if [ -f "$f" ]; then cp "$f" "$stage/"; fi
done

payload_sha="$(sha256sum "$stage/crest" | cut -d' ' -f1)"
name="crest-${VERSION}-${ARCH}-linux.run"

# --- compress ---------------------------------------------------------------
echo ">> compressing payload ($(du -h "$stage/crest" | cut -f1))" >&2
members="crest"
for f in COPYING COPYING.LESSER; do
   if [ -f "$stage/$f" ]; then members="$members $f"; fi
done
# shellcheck disable=SC2086
tar -C "$stage" -cf - $members | xz -9 -T0 -c > "$work/payload.tar.xz"

# --- emit the self-extracting script ---------------------------------------
out_file="$OUT/$name"
cat > "$out_file" <<HEADER
#!/bin/sh
# ---------------------------------------------------------------------------
# CREST ${VERSION} installer for ${ARCH} Linux (self-extracting)
#
#   sh ${name}
#   sh ${name} --prefix="\$HOME/.local"    # unprivileged install
#   sh ${name} --uninstall --prefix=DIR
#
# CREST is a single statically linked executable here: no runtime
# dependencies and no root needed if you choose a writable prefix.
# ---------------------------------------------------------------------------
set -eu

VERSION='${VERSION}'
PAYLOAD_SHA256='${payload_sha}'
DEFAULT_PREFIX='/usr/local'

PREFIX=''
ASSUME_YES=0
UNINSTALL=0

usage() {
   cat <<EOF
CREST \${VERSION} installer for ${ARCH} Linux

Usage: sh \$0 [options]

  -p, --prefix DIR   install under DIR (default: /usr/local, or \\\$HOME/.local
                     when /usr/local is not writable)
  -y, --yes          do not ask for confirmation
  -u, --uninstall    remove a previously installed copy
  -h, --help         show this help
EOF
}

while [ \$# -gt 0 ]; do
   case "\$1" in
      -p|--prefix)    PREFIX="\$2"; shift 2 ;;
      --prefix=*)     PREFIX="\${1#*=}"; shift ;;
      -y|--yes)       ASSUME_YES=1; shift ;;
      -u|--uninstall) UNINSTALL=1; shift ;;
      -h|--help)      usage; exit 0 ;;
      *) echo "error: unknown option '\$1'" >&2; usage >&2; exit 2 ;;
   esac
done

# --- sanity checks ----------------------------------------------------------
case "\$(uname -m)" in
   x86_64|amd64) : ;;
   *) echo "error: this installer is for ${ARCH}, but this machine is \$(uname -m)" >&2
      exit 1 ;;
esac

if [ "\$(id -u)" -eq 0 ]; then IS_ROOT=1; else IS_ROOT=0; fi

if [ -z "\$PREFIX" ]; then
   if [ "\$IS_ROOT" -eq 1 ] || [ -w /usr/local ] || [ -w /usr/local/bin ] 2>/dev/null; then
      PREFIX="\$DEFAULT_PREFIX"
   else
      PREFIX="\$HOME/.local"
   fi
fi
case "\$PREFIX" in
   "~"|"~/"*) PREFIX="\$HOME\${PREFIX#\~}" ;;
esac

BINDIR="\$PREFIX/bin"
LICENSEDIR="\$PREFIX/share/licenses/crest"

if [ "\$UNINSTALL" -eq 1 ]; then
   echo ">> removing \$BINDIR/crest and \$LICENSEDIR"
   rm -f  "\$BINDIR/crest"
   rm -rf "\$LICENSEDIR"
   echo "   done."
   exit 0
fi

if [ "\$ASSUME_YES" -eq 0 ] && [ -t 0 ]; then
   echo "CREST \${VERSION} will be installed into \$BINDIR"
   printf "Continue? [Y/n] "
   read -r answer
   case "\$answer" in
      n|N|no|NO) echo "aborted."; exit 1 ;;
   esac
fi

if ! mkdir -p "\$BINDIR" 2>/dev/null; then
   echo "error: cannot create \$BINDIR" >&2
   echo "       retry with --prefix=\\\$HOME/.local or run as root" >&2
   exit 1
fi

# --- extract ----------------------------------------------------------------
TMPDIR_INSTALL="\$(mktemp -d "\${TMPDIR:-/tmp}/crest-install.XXXXXX")"
trap 'rm -rf "\$TMPDIR_INSTALL"' EXIT INT TERM

echo ">> extracting"
start_line="\$(awk '/^__PAYLOAD_BELOW__\$/ { print NR + 1; exit }' "\$0")"
if [ -z "\$start_line" ]; then
   echo "error: installer is truncated (payload marker not found)" >&2
   exit 1
fi
if ! tail -n +"\$start_line" "\$0" | tar -xJ -C "\$TMPDIR_INSTALL"; then
   echo "error: could not unpack the payload -- is 'xz' installed?" >&2
   exit 1
fi

if command -v sha256sum >/dev/null 2>&1; then
   actual="\$(sha256sum "\$TMPDIR_INSTALL/crest" | cut -d' ' -f1)"
   if [ "\$actual" != "\$PAYLOAD_SHA256" ]; then
      echo "error: checksum mismatch (incomplete download?)" >&2
      echo "  expected \$PAYLOAD_SHA256" >&2
      echo "  actual   \$actual" >&2
      exit 1
   fi
fi

# --- install ----------------------------------------------------------------
echo ">> installing to \$BINDIR/crest"
if ! install -m 755 "\$TMPDIR_INSTALL/crest" "\$BINDIR/crest" 2>/dev/null; then
   cp "\$TMPDIR_INSTALL/crest" "\$BINDIR/crest"
   chmod 755 "\$BINDIR/crest"
fi

mkdir -p "\$LICENSEDIR"
for f in COPYING COPYING.LESSER; do
   if [ -f "\$TMPDIR_INSTALL/\$f" ]; then
      cp "\$TMPDIR_INSTALL/\$f" "\$LICENSEDIR/\$f"
   fi
done

# --- verify -----------------------------------------------------------------
if "\$BINDIR/crest" --version >/dev/null 2>&1; then
   echo ">> verification: \$("\$BINDIR/crest" --version 2>/dev/null | tail -n 1 | tr -s ' ')"
else
   echo "warning: '\$BINDIR/crest --version' did not run cleanly" >&2
fi

echo ""
echo "CREST \${VERSION} installed successfully."
case ":\$PATH:" in
   *":\$BINDIR:"*) : ;;
   *) echo "note: add \$BINDIR to PATH, e.g."
      echo "      echo 'export PATH=\"\$BINDIR:\\\$PATH\"' >> ~/.profile" ;;
esac
echo "note: CREST handles xTB methods itself, but some runtypes (e.g. QCG) still"
echo "      need xtb on PATH: https://github.com/grimme-lab/xtb"
exit 0
__PAYLOAD_BELOW__
HEADER

cat "$work/payload.tar.xz" >> "$out_file"
chmod 755 "$out_file"

# --- checksums --------------------------------------------------------------
( cd "$OUT" && sha256sum "$name" > "$name.sha256" )

echo ">> wrote $out_file ($(du -h "$out_file" | cut -f1))"
