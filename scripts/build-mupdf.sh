#!/bin/zsh
# Builds MuPDF (vendor/mupdf, a pinned git submodule) as static arm64 libraries in build/mupdf/lib.
# Skips the build when the libraries are already there. Only the library is built: no viewer, no
# X11/OpenGL, no curl, no OCR, no barcodes, and without the large Noto fonts (Stitch renders with
# PDFKit; MuPDF only edits).
set -euo pipefail
cd "${0:A:h}/.."
out=build/mupdf
if [[ -f $out/lib/libmupdf.a && -f $out/lib/libmupdf-third.a ]]; then exit 0; fi
if [[ ! -f vendor/mupdf/Makefile ]]; then
  echo "Fetching MuPDF (git submodule)…"
  git submodule update --init --recursive --depth 1 vendor/mupdf
fi
echo "Building MuPDF (first time only, a few minutes)…"
mkdir -p $out/lib
make -C vendor/mupdf -j"$(sysctl -n hw.ncpu)" libs \
  build=release OUT="${PWD}/$out/obj" \
  HAVE_X11=no HAVE_GLUT=no HAVE_CURL=no USE_TESSERACT=no USE_ZXINGCPP=no USE_LIBARCHIVE=no \
  XCFLAGS="-arch arm64 -mmacosx-version-min=14.0 -DTOFU -DTOFU_CJK -DTOFU_SIL -DFZ_ENABLE_JS=0" \
  XLDFLAGS="-arch arm64" >"$out/build.log" 2>&1 || { tail -30 "$out/build.log"; exit 1; }
cp "$out/obj/libmupdf.a" "$out/obj/libmupdf-third.a" "$out/lib/"
echo "MuPDF ready: $out/lib"
