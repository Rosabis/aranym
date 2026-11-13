#!/bin/sh
# Build ARAnyM for Windows inside an MSYS2 MINGW shell (MINGW32 or MINGW64)
# and package a self-contained zip with bundled runtime DLLs.
#
# This is a faithful port of the project's old .appveyor/build.sh (Cygwin) to
# MSYS2/MinGW-w64. It builds three variants of the emulator:
#   aranym.exe      - standard build
#   aranym-mmu.exe  - full 68040 MMU (--enable-fullmmu --enable-lilo)
#   aranym-jit.exe  - JIT compiler (--enable-jit-compiler --enable-jit-fpu)
#
# Env (optional):
#   ARANYM_SKIP_JIT = 1   skip the JIT build (useful if a new GCC breaks it)
#
# Outputs (written to $GITHUB_OUTPUT when running under GitHub Actions):
#   VERSION, ARCHIVE
set -e

cd "$(dirname "$0")/.."   # repo root

ARCH=$(uname -m)
case "$ARCH" in
  x86_64) ARCH_TAG=win64 ;;
  i686)   ARCH_TAG=win32 ;;
  *)      ARCH_TAG="win-$ARCH" ;;
esac

# ---------------------------------------------------------------------------
# 1. Generate the build system (autoreconf) and the generated version stamp
# ---------------------------------------------------------------------------
echo "==> Running autogen.sh"
NO_CONFIGURE=1 ./autogen.sh

echo "==> Generating version_date.h"
make -f Makefile.am top_srcdir=. version_date.h

if [ ! -f version_date.h ] || [ ! -f src/include/version.h ]; then
  echo "version files missing" >&2
  exit 1
fi

major=$(sed -n -e 's/#define[[:space:]]*VER_MAJOR[[:space:]]*\([0-9]*\)/\1/p' src/include/version.h)
minor=$(sed -n -e 's/#define[[:space:]]*VER_MINOR[[:space:]]*\([0-9]*\)/\1/p' src/include/version.h)
micro=$(sed -n -e 's/#define[[:space:]]*VER_MICRO[[:space:]]*\([0-9]*\)/\1/p' src/include/version.h)
VERSION="$major.$minor.$micro"
DATE=$(sed -n -e 's/#define[[:space:]]*VERSION_DATE[[:space:]]*"\([^"]*\)"/\1/p' version_date.h)
SHORT_ID=$(git log -n1 --format=%h 2>/dev/null || echo unknown)

echo "VERSION=$VERSION  DATE=$DATE  ARCH=$ARCH_TAG  COMMIT=$SHORT_ID"

CONFIGURE_ARGS="--prefix=/usr --enable-usbhost --enable-sdl2"

# Parallel build (ARAnyM is large; the 3 variants x 2 archs would otherwise be slow).
NPROC=$(nproc 2>/dev/null || echo 2)

# Staging directory for the finished executables. We copy each built exe here
# immediately after stripping and run `make clean` afterwards, so a later
# `make clean` can never delete a finished binary before packaging.
STAGE="${TMPDIR:-/tmp}/aranym-stage"
rm -rf "$STAGE"
mkdir -p "$STAGE"

build_one() {
  # $1 = extra configure flags, $2 = output exe name
  echo "==> configure $2 ($1)"
  ./configure $CONFIGURE_ARGS $1
  echo "==> make $2 (-j$NPROC)"
  make -j"$NPROC"
  strip aranym.exe
  cp aranym.exe "$STAGE/$2"
  echo "==> cleaning tree for next variant"
  make clean
}

# ---------------------------------------------------------------------------
# 2. Build the three variants
# ---------------------------------------------------------------------------
echo "==> Building aranym-mmu"
build_one "--enable-fullmmu --enable-lilo" aranym-mmu.exe

if [ "${ARANYM_SKIP_JIT:-0}" != "1" ]; then
  echo "==> Building aranym-jit"
  build_one "--enable-jit-compiler --enable-jit-fpu" aranym-jit.exe
else
  echo "==> Skipping JIT build (ARANYM_SKIP_JIT=1)"
fi

echo "==> Building aranym (default)"
build_one "" aranym.exe

# ---------------------------------------------------------------------------
# 3. Assemble the distribution directory
# ---------------------------------------------------------------------------
echo "==> Packaging"
tmpdir="${TMPDIR:-/tmp}"
distname="aranym-$VERSION-$ARCH_TAG"
distdir="$tmpdir/$distname"
rm -rf "$distdir"
mkdir -p "$distdir/doc" "$distdir/aranym"

cp -a COPYING "$distdir/COPYING.txt"
sed -e "s|@VERSION@|$VERSION|g" -e "s|@DATE@|$DATE|g" README-cygwin.in > "$distdir/README.txt"
for f in AUTHORS BUGS ChangeLog FAQ INSTALL NEWS TODO; do
  [ -f "$f" ] && cp -a "$f" "$distdir/doc/$f.txt"
done
cp -a README.md "$distdir/doc/README.txt"
[ -f doc/config ] && cp -a doc/config "$distdir/doc/config.txt"
for f in logo.bmp wm_icon.bmp; do
  [ -f "data/$f" ] && cp -a "data/$f" "$distdir/aranym/$f"
done

# Normalise text files to CRLF (Windows convention)
( cd "$distdir"
  for f in doc/* *.txt; do
    [ -f "$f" ] || continue
    sed -i 's/\r$//' "$f"
    sed -i 's/$/\r/' "$f"
  done
)

# ---------------------------------------------------------------------------
# 4. Copy the executables and bundle their runtime DLLs
#    (using the project's own tools/ldd.c, which prints full DLL paths)
# ---------------------------------------------------------------------------
# Collect runtime DLLs deterministically via objdump (reads the PE import
# table for each binary and resolves each imported DLL from the toolchain's
# bin directory, recursing into every DLL we copy). This is far more reliable
# than the old tools/ldd.c wrapper, which depended on SearchPathW + Windows
# path-format parsing and silently dropped indirect deps (e.g. libjpeg-8 via
# SDL2_image) and the GCC runtime (libgcc_s_seh-1) on UCRT64.
# Detect objdump without tripping set -e on a failed 'command -v' lookup.
# (Under set -e, VAR=$(command -v x) aborts silently when x is absent, because
#  the assignment inherits the non-zero exit status and any stderr is suppressed.)
OBJDUMP=""
for cand in objdump x86_64-w64-mingw32-objdump; do
  if command -v "$cand" >/dev/null 2>&1; then
    OBJDUMP=$(command -v "$cand" 2>/dev/null)
    break
  fi
done
[ -z "$OBJDUMP" ] && { echo "objdump not found; install the binutils package" >&2; exit 1; }

# Where the MinGW/UCRT64 runtime DLLs live. Derive from gcc's location and
# add the usual suspects so the resolver is robust regardless of msystem.
BIN_DIRS="$(dirname "$(command -v gcc 2>/dev/null)")"
BIN_DIRS="$BIN_DIRS /ucrt64/bin /mingw64/bin /clang64/bin /usr/bin"

collect_dlls() {
  # $1 = path to a PE binary (exe or already-collected dll)
  local f="$1" dep base found
  [ -f "$f" ] || return 0
  "$OBJDUMP" -p "$f" 2>/dev/null \
    | sed -n 's/.*DLL Name:[[:space:]]*//p' \
    | sort -u \
    | while read -r dep; do
        [ -z "$dep" ] && continue
        # Skip executables and Win32 API-set DLLs (resolved by the OS).
        case "$dep" in
          *.exe) continue ;;
          api-ms-* | ext-ms-* | *:* ) continue ;;
        esac
        base=$(basename "$dep")
        [ -e "$distdir/$base" ] && continue
        found=$(find $BIN_DIRS -iname "$base" 2>/dev/null | head -n1)
        if [ -z "$found" ]; then
          echo "  (skip $base: not found in toolchain bin)" >&2
          continue
        fi
        cp -a "$found" "$distdir"/ || echo "  (copy failed: $base)" >&2
        collect_dlls "$found"
      done
}

for f in aranym.exe aranym-jit.exe aranym-mmu.exe; do
  [ -f "$STAGE/$f" ] || continue
  cp -a "$STAGE/$f" "$distdir"/ || exit 1
  echo "==> collecting DLLs for $f"
  collect_dlls "$STAGE/$f"
done

echo "==> Distribution contents ($(ls "$distdir" | wc -l) entries):"
ls -la "$distdir" | sed 's/^/    /'

# ---------------------------------------------------------------------------
# 5. Zip it up and drop the archive in the repo root
# ---------------------------------------------------------------------------
ARCHIVE="$distname-$SHORT_ID.zip"
( cd "$tmpdir" && zip -r "$ARCHIVE" "$distname" )
mv "$tmpdir/$ARCHIVE" "$ARCHIVE"

echo "==> Created $ARCHIVE"
echo "VERSION=$VERSION"
echo "ARCHIVE=$ARCHIVE"

if [ -n "$GITHUB_OUTPUT" ]; then
  printf 'VERSION=%s\n' "$VERSION" >> "$GITHUB_OUTPUT"
  printf 'ARCHIVE=%s\n' "$ARCHIVE" >> "$GITHUB_OUTPUT"
fi
