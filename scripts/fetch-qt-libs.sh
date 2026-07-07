#!/usr/bin/env bash
set -euo pipefail

host="${1:-10.11.99.1}"
out_dir="tablet-sysroot/usr/lib"

mkdir -p "$out_dir"

echo "Fetching Qt libraries from root@$host into $out_dir"
echo "You may be prompted for the tablet root password."

scp "root@$host:/usr/lib/libQt6Core.so*" "$out_dir/"
scp "root@$host:/usr/lib/libQt6Gui.so*" "$out_dir/"

echo "Done."
