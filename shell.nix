{ pkgs ? import <nixpkgs> {} }:

let
  # Cross-compilation to aarch64 (reMarkable Paper Pro userspace)
  arm = pkgs.pkgsCross.aarch64-multiplatform;
in
pkgs.mkShell {
  name = "rm-key-cross-compile";

  nativeBuildInputs = [
    arm.buildPackages.gcc
  ];

  shellHook = ''
    export CC=aarch64-unknown-linux-gnu-gcc
    export CROSS_COMPILE=aarch64-unknown-linux-gnu-
    echo "ARM cross-compiler ready"
  '';
}
