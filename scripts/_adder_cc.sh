# scripts/_adder_cc.sh — shared Adder-compiler backend selector for the
# build (Track-3 self-hosting cutover scaffolding).
#
# `source` this from a build script, then call `adder_cc_compile`:
#
#     source "$PROJ_ROOT/scripts/_adder_cc.sh"
#     adder_cc_compile --target=x86_64-adder-user in.ad -o out.elf
#
# Backend is chosen by the ADDER_CC env var:
#
#   ADDER_CC=python   (DEFAULT) — the frozen Python seed
#                     (`python3 -m compiler.adder compile ...`). This is the
#                     bootstrap/trust root and the equivalence oracle; it
#                     ALWAYS compiles 100% of the tree.
#
#   ADDER_CC=adder    — route the compile through the self-hosted `.ad`
#                     host compiler (build/cutover/host_ac.elf), built once
#                     by the seed via adder_cc_bootstrap.
#
# ====================================================================
# CUTOVER STATUS (2026-06-21): ADDER_CC=adder is NOT yet a viable default.
# The whole-tree differential (scripts/test_selfhost_wholetree_diff.sh)
# shows host_ac.elf compiles only 2/128 single-TU userland units and 0
# multi-TU units / the kernel, because codegen.ad/elf_emit.ad lack EXTERN
# LINKAGE (runtime.S / boot stubs), IMPORT RESOLUTION + module mangling,
# and a handful of constructs. See docs/subsystems/adder-compiler.md
# "Self-hosting cutover — WHOLE-TREE blocker". Until those land, ADDER_CC=
# adder will FAIL the build on any real unit; it is wired here so the flip
# is a one-line default change once the .ad compiler is capable, and so the
# escape hatch (fall back to python) exists from day one.
# ====================================================================

# Build build/cutover/host_ac.elf once (idempotent within a build) using
# the Python seed. Safe to call even when ADDER_CC=python (it just no-ops
# the bootstrap unless the .ad backend is actually selected).
adder_cc_bootstrap() {
    if [ "${ADDER_CC:-python}" != "adder" ]; then
        return 0
    fi
    if [ -n "${_ADDER_CC_BOOTSTRAPPED:-}" ]; then
        return 0
    fi
    local root="${PROJ_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
    echo "[adder_cc] bootstrap: building build/cutover/host_ac.elf via the Python seed"
    mkdir -p "$root/build/cutover"
    python3 - "$root" <<'PY' || { echo "[adder_cc] ERROR: concat host compiler failed" >&2; return 1; }
import sys, importlib.util, os
root = sys.argv[1]; os.chdir(root)
spec = importlib.util.spec_from_file_location("ccs", "scripts/concat_compiler_source.py")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
m.DRIVER_MAIN = "fused_driver_host_main.ad"
raise SystemExit(m.main(["concat", "-o", "build/cutover/host_compiler.ad", "--with-driver"]))
PY
    ( cd "$root" && python3 -m compiler.adder compile --target=x86_64-linux \
        build/cutover/host_compiler.ad -o build/cutover/host_ac.elf ) \
        || { echo "[adder_cc] ERROR: host_ac.elf failed to build" >&2; return 1; }
    [ -x "$root/build/cutover/host_ac.elf" ] \
        || { echo "[adder_cc] ERROR: no host_ac.elf produced" >&2; return 1; }
    export _ADDER_CC_BOOTSTRAPPED=1
    echo "[adder_cc] bootstrap OK: $(stat -c%s "$root/build/cutover/host_ac.elf") bytes"
}

# adder_cc_compile <args...> — drop-in for `python3 -m compiler.adder compile`.
# Accepts the same CLI shape (`--target=T <in.ad> -o <out>`). Routes to the
# selected backend. For ADDER_CC=adder the args are translated to host_ac.elf's
# positional <in> <out> form. The seed `--target` is FORWARDED to host_ac so it
# selects the output ELF format (x86_64-bare-metal -> the higher-half kernel
# ELF; everything else -> the self-contained user ELF) — see elf_emit.ad
# elf_emit_image_target(). The kernel format is not yet emittable (cap#3b/cap#4,
# see docs/subsystems/adder-compiler.md); host_ac fails it with a precise
# diagnostic rather than silently emitting a user-shaped ELF.
adder_cc_compile() {
    local backend="${ADDER_CC:-python}"
    if [ "$backend" = "python" ]; then
        # Callers pass the full seed CLI verb (`compile ...`); forward as-is.
        python3 -m compiler.adder "$@"
        return $?
    fi
    if [ "$backend" = "adder" ]; then
        adder_cc_bootstrap || return 1
        local root="${PROJ_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
        # Parse the seed-style CLI to extract <in>, <out>, and the --target.
        local in_ad="" out_elf="" target="" a
        local -a rest=("$@")
        local i=0
        while [ $i -lt ${#rest[@]} ]; do
            a="${rest[$i]}"
            case "$a" in
                --target=*) target="${a#--target=}" ;;  # forwarded below
                -o) i=$((i+1)); out_elf="${rest[$i]}" ;;
                -o*) out_elf="${a#-o}" ;;
                compile) : ;;
                -*) : ;;                                # ignore other flags
                *) [ -z "$in_ad" ] && in_ad="$a" ;;
            esac
            i=$((i+1))
        done
        if [ -z "$in_ad" ] || [ -z "$out_elf" ]; then
            echo "[adder_cc] ERROR: could not parse in/out from: $*" >&2
            return 2
        fi
        # Forward the format selector (host_ac accepts the flag anywhere).
        local -a hc=()
        [ -n "$target" ] && hc+=("--target=$target")
        if [ "$target" = "x86_64-bare-metal" ]; then
            # KERNEL target: host_ac emits a RELOCATABLE .o (ET_REL); we then
            # `as`+`ld` it together with the hand-written boot stubs under
            # arch/x86/kernel/kernel.lds, EXACTLY as the seed's
            # assemble_and_link_x86_bare does. <out_elf> is the final kernel ELF.
            if adder_cc_link_kernel "$root" "$in_ad" "$out_elf"; then return 0; fi
            echo "[adder_cc] native kernel compile failed -> Python seed fallback: $in_ad" >&2
            python3 -m compiler.adder "$@"
            return $?
        fi
        if "$root/build/cutover/host_ac.elf" "${hc[@]}" "$in_ad" "$out_elf"; then return 0; fi
        echo "[adder_cc] native compile failed -> Python seed fallback: $in_ad" >&2
        python3 -m compiler.adder "$@"
        return $?
    fi
    echo "[adder_cc] ERROR: unknown ADDER_CC='$backend' (want python|adder)" >&2
    return 2
}

# adder_cc_link_kernel <root> <in.ad> <out.elf>
# Compile init/main.ad to a relocatable .o with host_ac, then assemble the
# hand-written boot stubs + all extra .S and `ld` them together under
# arch/x86/kernel/kernel.lds into the final higher-half kernel ELF — a
# byte-for-byte mirror of compiler/adder.py assemble_and_link_x86_bare's
# file list, flags, and link order (header.o, head_64.o, main.o, extras).
adder_cc_link_kernel() {
    local root="$1" in_ad="$2" out_elf="$3"
    local as_cmd="${AS:-as}" ld_cmd="${LD:-ld}"
    local boot_s="$root/arch/x86/boot/header.S"
    local head_s="$root/arch/x86/kernel/head_64.S"
    local lds="$root/arch/x86/kernel/kernel.lds"
    local f
    for f in "$boot_s" "$head_s" "$lds"; do
        [ -f "$f" ] || { echo "[adder_cc] ERROR: missing $f" >&2; return 1; }
    done
    local tmp; tmp="$(mktemp -d)" || return 1
    local main_o="$tmp/main.o"
    # 1) host_ac emits the relocatable Adder object.
    "$root/build/cutover/host_ac.elf" --target=x86_64-bare-metal "$in_ad" "$main_o" \
        || { echo "[adder_cc] ERROR: host_ac kernel .o emit failed" >&2; rm -rf "$tmp"; return 1; }
    # 2) Assemble the boot stubs + every other hand-written .S under arch/x86,
    #    fs, drivers (excluding the two boot stubs, which lead the link order).
    #    The initramfs override mirrors the seed's HAMNIX_INITRAMFS_BLOB path.
    "$as_cmd" --64 -o "$tmp/header.o" "$boot_s" \
        || { echo "[adder_cc] ERROR: as header.S failed" >&2; rm -rf "$tmp"; return 1; }
    "$as_cmd" --64 -o "$tmp/head_64.o" "$head_s" \
        || { echo "[adder_cc] ERROR: as head_64.S failed" >&2; rm -rf "$tmp"; return 1; }
    local blob_override="${HAMNIX_INITRAMFS_BLOB:-}"
    if [ -z "$blob_override" ] && [ -n "${HAMNIX_BUILD_DIR:-}" ]; then
        blob_override="$HAMNIX_BUILD_DIR/initramfs_blob.S"
    fi
    local -a extra_objs=()
    local s o n=0
    while IFS= read -r s; do
        [ "$s" = "$boot_s" ] && continue
        [ "$s" = "$head_s" ] && continue
        # Drop an in-source initramfs_blob.S when an override is provided.
        if [ -n "$blob_override" ] && [ "$(basename "$s")" = "initramfs_blob.S" ]; then
            continue
        fi
        o="$tmp/extra_$n.o"; n=$((n+1))
        "$as_cmd" --64 -o "$o" "$s" \
            || { echo "[adder_cc] ERROR: as $s failed" >&2; rm -rf "$tmp"; return 1; }
        extra_objs+=("$o")
    done < <(find "$root/arch/x86" "$root/fs" "$root/drivers" -name '*.S' 2>/dev/null | sort)
    if [ -n "$blob_override" ]; then
        [ -f "$blob_override" ] || { echo "[adder_cc] ERROR: HAMNIX initramfs blob $blob_override missing" >&2; rm -rf "$tmp"; return 1; }
        o="$tmp/extra_blob.o"
        "$as_cmd" --64 -o "$o" "$blob_override" \
            || { echo "[adder_cc] ERROR: as initramfs blob failed" >&2; rm -rf "$tmp"; return 1; }
        extra_objs+=("$o")
    fi
    # 3) Link: header.o first (multiboot magic at top of .head.text), then
    #    head_64.o, then the Adder main.o, then the extras — kernel.lds places
    #    everything. Same flags as the seed.
    "$ld_cmd" -m elf_x86_64 -nostdlib -static \
        -z noexecstack -z max-page-size=4096 \
        -T "$lds" -o "$out_elf" \
        "$tmp/header.o" "$tmp/head_64.o" "$main_o" "${extra_objs[@]}" \
        || { echo "[adder_cc] ERROR: ld kernel link failed" >&2; rm -rf "$tmp"; return 1; }
    rm -rf "$tmp"
    return 0
}
