{ pkgs ? import <nixpkgs> { config.allowUnsupportedSystem = true; } }:

let
  arm = pkgs.pkgsCross.aarch64-multiplatform;
  linuxPkgs = import <nixpkgs> { system = "x86_64-linux"; };
  qtHeaders = linuxPkgs.qt6.qtbase;
  tabletSysroot = ./tablet-sysroot;
in
pkgs.stdenvNoCC.mkDerivation {
  name = "librmkey-qt-inject-aarch64";
  src = ./.;

  nativeBuildInputs = [ arm.buildPackages.gcc ];

  dontConfigure = true;

  buildPhase = ''
    set -eu

    SYSROOT="$src/tablet-sysroot"
    if [ ! -d "$SYSROOT/usr/lib" ]; then
      echo "ERROR: tablet-sysroot/usr/lib/ does not exist" >&2
      echo "Run ./scripts/fetch-qt-libs.sh <tablet-ip> first." >&2
      exit 1
    fi
    for lib in Core Gui; do
      if [ ! -e "$SYSROOT/usr/lib/libQt6$lib.so.6" ]; then
        echo "ERROR: missing $SYSROOT/usr/lib/libQt6$lib.so.6" >&2
        echo "Run ./scripts/fetch-qt-libs.sh <tablet-ip> first." >&2
        exit 1
      fi
    done

    mkdir -p qt-lib-links
    ln -sf "$SYSROOT/usr/lib/libQt6Core.so.6" qt-lib-links/libQt6Core.so
    ln -sf "$SYSROOT/usr/lib/libQt6Gui.so.6" qt-lib-links/libQt6Gui.so

    aarch64-unknown-linux-gnu-g++ \
      -shared -fPIC -std=c++17 -O2 \
      -I${qtHeaders}/include \
      -I${qtHeaders}/include/QtCore \
      -I${qtHeaders}/include/QtGui \
      -I${qtHeaders}/include/QtCore/${linuxPkgs.qt6.qtbase.version} \
      -I${qtHeaders}/include/QtGui/${linuxPkgs.qt6.qtbase.version} \
      -I${qtHeaders}/include/QtCore/${linuxPkgs.qt6.qtbase.version}/QtCore \
      -I${qtHeaders}/include/QtGui/${linuxPkgs.qt6.qtbase.version}/QtGui \
      -L$(pwd)/qt-lib-links \
      -L$SYSROOT/usr/lib \
      -Wl,-rpath,/usr/lib \
      -Wl,-rpath-link,$SYSROOT/usr/lib \
      -o librmkey_qt_inject.so \
      $src/daemon/rmkey-qt-inject.cpp \
      -lQt6Gui -lQt6Core -lpthread
  '';

  installPhase = ''
    mkdir -p $out
    cp librmkey_qt_inject.so $out/
  '';

  meta.platforms = [ "aarch64-linux" ];
}
