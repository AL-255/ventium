#!/usr/bin/env bash
# Assemble only; exact ROM hashes bind these sources to the closed measurements.
set -euo pipefail
test "$#" = 1 || { echo 'usage: bash build_cold.sh EXISTING_EMPTY_OUTPUT_DIRECTORY' >&2; exit 2; }
source_dir=$(cd -- "$(dirname -- "$0")" && pwd)
out=$(realpath -- "$1")
test -d "$out"
test -z "$(find "$out" -mindepth 1 -maxdepth 1 -print -quit)"
as --32 --defsym COLD_LAYOUT=1 -o "$out/bootstrap.o" "$source_dir/bootstrap_legacy.S"
for variant in 0 1 2 3; do
    as --32 --defsym SUB_VARIANT="$variant" -o "$out/sub$variant.o" "$source_dir/subjne_cold.S"
    ld -m elf_i386 -T "$source_dir/micro.ld" -o "$out/sub$variant.elf" "$out/bootstrap.o" "$out/sub$variant.o"
    objcopy -O binary --gap-fill 0x90 --pad-to 0x100000 "$out/sub$variant.elf" "$out/sub$variant.bin"
    nm -n --defined-only "$out/sub$variant.elf" > "$out/sub$variant.symbols.txt"
done
cd "$out"
sha256sum -c "$source_dir/cold_roms.sha256"
