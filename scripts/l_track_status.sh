#!/usr/bin/env bash
# scripts/l_track_status.sh — informational L-track readiness report.
#
# For each fixture in tests/linux-modules/src/<NAME>/, summarise:
#
#   * does <NAME>.c exist (or is the dir a placeholder for future work)
#   * does tests/linux-modules/<NAME>.ko exist (built + staged for CI)
#   * which Linux symbols does <NAME>.c reference, and is each of them
#     in linux_abi/exports.ad's _add_export() table (across exports.ad
#     itself + every api_*.ad it pulls in via linux_abi_register_*)
#
# Output is a one-line-per-fixture status table, followed by a
# per-fixture detail block for anything not in the READY state.
#
# This script is read-only. It does not build anything. Use
# scripts/build_linux_modules.sh for the build step.

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

LKM_DIR="tests/linux-modules"
SRC_DIR="$LKM_DIR/src"
ABI_DIR="linux_abi"

# --- Collect every exported symbol from linux_abi/*.ad ---------------
#
# The export table is split: linux_abi/exports.ad has the top-level
# entries (printk, kmalloc, ...) plus a chain of linux_abi_register_*
# calls into api_<group>.ad, each of which has its own _add_export
# calls. The union across all those files is what's actually visible
# to a loaded .ko, so we grep across all of them.
EXPORTS_TMP=$(mktemp)
trap 'rm -f "$EXPORTS_TMP"' EXIT

grep -h "_add_export" "$ABI_DIR/exports.ad" "$ABI_DIR"/api_*.ad 2>/dev/null \
    | grep -oE '_add_export\("[^"]+"' \
    | sed -E 's/^_add_export\("//; s/"$//' \
    | sort -u > "$EXPORTS_TMP"

export_count=$(wc -l < "$EXPORTS_TMP")

# --- Reverse map: which milestone does each fixture belong to? -------
#
# The marker string the L1 loader stamps into each module starts with
# "L<N>: <name>.ko module_init". We parse the L-number out of that
# string in the fixture's own .c source. Fixtures whose .c has no
# marker (e.g. proc which uses a slightly different L5 wording) fall
# back to "L?".
fixture_milestone() {
    local cfile="$1"
    local marker
    marker=$(grep -oE '"L[0-9]+: [a-z_]+\.ko module_init' "$cfile" 2>/dev/null | head -1)
    if [ -n "$marker" ]; then
        echo "$marker" | grep -oE 'L[0-9]+'
        return
    fi
    # Fallback: look for any "L<N>:" inside printk strings.
    marker=$(grep -oE '"L[0-9]+:' "$cfile" 2>/dev/null | head -1)
    if [ -n "$marker" ]; then
        echo "$marker" | grep -oE 'L[0-9]+'
        return
    fi
    echo "L?"
}

# --- Extract Linux symbols referenced by a fixture -------------------
#
# A "referenced symbol" is any identifier the .c file calls or takes
# the address of that is also exported by the kernel. We can't run
# the real loader's UND-symbol walk without a built .ko, so we use a
# pragmatic source-level proxy: grep for any token in the fixture
# source that appears in our export table. This over-approximates (it
# will list e.g. "printk" even when the source only uses pr_info,
# because pr_info expands to _printk), but that's the right
# direction for a status report — false positives are harmless,
# false negatives would let an unresolved symbol slip through.
referenced_symbols() {
    local cfile="$1"
    # Pull all identifier-like tokens out of the .c file.
    local toks
    toks=$(tr -c 'A-Za-z0-9_' '\n' < "$cfile" | sort -u)
    # Intersect with the export table.
    comm -12 <(echo "$toks") "$EXPORTS_TMP"
}

# --- Per-fixture status row ------------------------------------------
printf '%-4s %-12s %-9s %-13s %s\n' "L#" "FIXTURE" ".ko" "EXPORTS" "STATUS"
printf -- '-------------------------------------------------------------------\n'

# Non-READY fixtures get a follow-up detail block; collect them here.
detail_lines=""

total=0
ready=0
no_src=0
no_ko=0
missing_exp=0

for d in "$SRC_DIR"/*/; do
    name=$(basename "$d")
    cfile="$d${name}.c"
    ko="$LKM_DIR/${name}.ko"
    total=$((total + 1))

    if [ ! -f "$cfile" ]; then
        printf '%-4s %-12s %-9s %-13s %s\n' "L?" "$name" "no-src" "n/a" "PLACEHOLDER"
        no_src=$((no_src + 1))
        continue
    fi

    milestone=$(fixture_milestone "$cfile")

    if [ -f "$ko" ]; then ko_col="YES"; else ko_col="NO"; fi

    # Find symbols referenced by the fixture and check coverage.
    refs=$(referenced_symbols "$cfile")
    ref_count=$(echo "$refs" | grep -c . || true)
    # "Missing" means a symbol the fixture references that ISN'T in
    # the export table. Since referenced_symbols() already intersected
    # with the table, we can't compute missing exports cheaply that
    # way — instead, grep the fixture for the obvious Linux API names
    # that exports.ad's comments call out as "things the L1 loader
    # has to resolve" and check those.
    # Heuristic: any token in the .c that looks like a kernel-style
    # function call (foo_bar, alloc_*, register_*, kmalloc, printk,
    # ...) and isn't in the export table.
    miss=$(tr -c 'A-Za-z0-9_' '\n' < "$cfile" \
        | grep -E '^(printk|pr_info|pr_err|kmalloc|kzalloc|kfree|krealloc|register_[a-z_]+|alloc_[a-z_]+|unregister_[a-z_]+|kmem_cache_[a-z_]+|proc_[a-z_]+|cdev_[a-z_]+|mutex_[a-z_]+|complete[a-z_]*|init_[a-z_]+|wait_[a-z_]+|kthread_[a-z_]+|queue_[a-z_]+|schedule_[a-z_]+|debugfs_[a-z_]+|crypto_[a-z_]+|sysfs_[a-z_]+|nf_[a-z_]+|pci_[a-z_]+|virtio_[a-z_]+|blk_[a-z_]+|netif_[a-z_]+|kernel_[a-z_]+|sock_[a-z_]+|dma_[a-z_]+|hrtimer_[a-z_]+|mod_timer|del_timer_sync|atomic_[a-z_]+|get_random_[a-z_]+|copy_(to|from)_user|_copy_(to|from)_user)$' \
        | sort -u | comm -23 - "$EXPORTS_TMP")
    miss_count=$(echo "$miss" | grep -c . || true)

    if [ "$miss_count" -eq 0 ]; then
        exp_col="YES"
    else
        exp_col="MISSING($miss_count)"
    fi

    # Final status.
    if [ "$ko_col" = "YES" ] && [ "$exp_col" = "YES" ]; then
        status="READY"
        ready=$((ready + 1))
    elif [ "$ko_col" = "NO" ] && [ "$exp_col" = "YES" ]; then
        status="NEEDS-BUILD"
        no_ko=$((no_ko + 1))
    elif [ "$ko_col" = "YES" ] && [ "$exp_col" != "YES" ]; then
        status="NEEDS-EXPORTS"
        missing_exp=$((missing_exp + 1))
    else
        status="NEEDS-BUILD+EXPORTS"
        no_ko=$((no_ko + 1))
        missing_exp=$((missing_exp + 1))
    fi

    printf '%-4s %-12s .ko=%-5s exports=%-7s status=%s\n' \
        "$milestone" "$name" "$ko_col" "$exp_col" "$status"

    if [ "$status" != "READY" ] && [ -n "$miss" ]; then
        detail_lines+="  [$name] symbols not in exports.ad: $(echo $miss | tr '\n' ' ')"$'\n'
    fi
done

echo
echo "Summary: total=$total ready=$ready needs-build=$no_ko needs-exports=$missing_exp placeholder=$no_src"
echo "Export table: $export_count symbols across $ABI_DIR/exports.ad + api_*.ad"

if [ -n "$detail_lines" ]; then
    echo
    echo "Detail (unresolved symbols per fixture):"
    printf '%s' "$detail_lines"
fi
