#!/usr/bin/env bash
# Build the one-shot kit next to this script (no root needed):
#   nlzy-turing-unlock/      upstream checkout pinned to the tested commit
#   turing_unlock.ko         built for the running kernel
#   assets/*.bin             firmware generated from pinned NVIDIA 610.43.03 inputs
#   module.sha256 assets.sha256
# Nothing here touches the GPU or the boot configuration.
set -euo pipefail
KIT=$(cd "$(dirname "$0")" && pwd)
SRC=$KIT/nlzy-turing-unlock
COMMIT=1d379b724454d6fb7e8a7a8dd0ea359febc05ca3

[[ -d $SRC ]] || git clone https://github.com/nlzy/turing-unlock "$SRC"
git -C "$SRC" checkout -q "$COMMIT"

# Downloads the NVIDIA source + nvidia-utils package, checks their SHA-256 and
# generates the firmware; the generators re-check every output hash.
make -C "$SRC" assets
make -C "/lib/modules/$(uname -r)/build" M="$SRC/kernel/turing_unlock" modules

cp "$SRC/kernel/turing_unlock/turing_unlock.ko" "$KIT/"
mkdir -p "$KIT/assets"
cp ~/.cache/turing-unlock/assets/{booter_load_tu102,gsp_tu10x,gsp_boot_tu102,gsp_boot_desc_tu102,sec2_bl_tu102,v67-tu102-610.43.03}.bin "$KIT/assets/"
(cd "$KIT/assets" && sha256sum ./*.bin | sed 's| \./| |') > "$KIT/assets.sha256"
(cd "$KIT" && sha256sum turing_unlock.ko) > "$KIT/module.sha256"
cat "$KIT/assets.sha256" "$KIT/module.sha256"
