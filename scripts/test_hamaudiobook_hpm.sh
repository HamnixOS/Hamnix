#!/usr/bin/env bash
# scripts/test_hamaudiobook_hpm.sh — end-to-end gate for the 255.one repo-ONLY
# install of the audiobook app (Task C of the repo-only-app pattern).
#
# Proves the FULL pull+install flow against a LOCAL mirror that mimics 255.one:
#   1. Build the REAL hamnix-hamaudiobook package with scripts/build_packages.py
#      (the exact tarball the .github/workflows/packages.yml Publish job ships to
#      255.one), and stand up a file:// mirror containing it (channel `main`).
#   2. Boot Hamnix, and BEFORE any install assert the binary + its .desktop
#      launcher are ABSENT under the target prefix (the app is NOT pre-installed).
#   3. `hpm refresh` the mirror, `hpm search audiobook` LISTS it.
#   4. `hpm install hamnix-hamaudiobook` (into a writable --target-prefix, the
#      same mechanism the installer uses) verifies the SHA-256 and lands
#      bin/hamaudiobook + etc/hamde/apps/hamaudiobook.desktop — so installing the
#      PACKAGE adds the Applications launcher.
#
# The mirror index lists ONLY hamnix-hamaudiobook with its depends stripped, so
# the install exercises the real published tarball without dragging in the whole
# desktop closure (the app's real depends on hamnix-desktop-core + snd-hda are a
# runtime concern, verified by the packaging metadata + test_package_de_coverage,
# not this focused install gate).

. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_qemu_drive.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
FIXDIR="$(mktemp -d /tmp/test-hamaudiobook-hpm.XXXXXX)"
trap 'rm -rf "$FIXDIR"' EXIT

echo "[ab-hpm] (1/4) Build userland (build/user/hamaudiobook.elf)"
bash scripts/build_user.sh >/dev/null
if [ ! -x build/user/hamaudiobook.elf ]; then
    echo "[ab-hpm] FAIL: build/user/hamaudiobook.elf missing after build"; exit 1
fi

echo "[ab-hpm] (2/4) Build the REAL package tree (SLIM boot/debian)"
HAMNIX_BOOTLOADER_SLIM=1 HAMNIX_LINUX_DEBIAN_SLIM=1 \
    python3 scripts/build_packages.py >/dev/null

# Stand up the file:// mirror: copy the real tarball, emit a trimmed main-channel
# index that lists only hamnix-hamaudiobook (depends stripped) with the REAL
# sha/size/url so hpm fetches + verifies the published artifact.
REPO="$FIXDIR/repo"
mkdir -p "$REPO/main/packages"
python3 - "$REPO" <<'PY'
import json, shutil, sys
from pathlib import Path
root = Path(".").resolve()
repo = Path(sys.argv[1])
src_idx = json.loads((root / "build/packages/main/index.json").read_text())
ab = next(p for p in src_idx["packages"] if p["name"] == "hamnix-hamaudiobook")
tar = root / "build/packages/main" / ab["url"]
shutil.copy(tar, repo / "main" / ab["url"])
entry = dict(ab)
entry["depends"] = []                     # focused install; skip DE closure
idx = {"schema": 1, "repo": "HamnixOS/packages", "channel": "main",
       "url": "file:///test-hpm-repo/main/", "updated": "2026-07-18",
       "description": "audiobook repo-only install fixture (255.one mirror)",
       "packages": [entry]}
(repo / "main" / "index.json").write_text(json.dumps(idx, indent=2) + "\n")
print("[ab-hpm] fixture mirror lists:", entry["name"], entry["version"],
      "sha", entry["sha256"][:16], "size", entry["size"])
PY

echo "[ab-hpm] (3/4) Build initramfs (mirror planted at /test-hpm-repo) + kernel"
bash scripts/build_modules.sh >/dev/null 2>&1 || true
HAMNIX_HPM_TEST_REPO="$REPO" python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal init/main.ad -o "$ELF" >/dev/null

LOG=$(mktemp /tmp/test-ab-hpm.XXXXXX.log)
trap 'rm -f "$LOG"; rm -rf "$FIXDIR"' EXIT

echo "[ab-hpm] (4/4) Boot QEMU + drive the repo-only install"
PFX=/tmp/abroot
set +e
qemu_drive "$LOG" "$ELF" "[hamsh] M16.35 shell ready" 180 \
    -- "echo AB_START"                                                              2 \
       "mkdir -p $PFX"                                                              2 \
       "echo AB_BEFORE_BIN; cat $PFX/bin/hamaudiobook"                              2 \
       "echo AB_BEFORE_DESKTOP; cat $PFX/etc/hamde/apps/hamaudiobook.desktop"       2 \
       "echo AB_BEFORE_DONE"                                                        2 \
       "hpm '--repo=file:///test-hpm-repo/' --allow-unsigned refresh"              5 \
       "echo AB_REFRESHED"                                                          2 \
       "hpm '--repo=file:///test-hpm-repo/' search audiobook"                       3 \
       "echo AB_SEARCHED"                                                           2 \
       "hpm '--repo=file:///test-hpm-repo/' --target-prefix=$PFX --allow-unsigned install hamnix-hamaudiobook"  8 \
       "echo AB_INSTALLED"                                                          2 \
       "ls -l $PFX/bin/hamaudiobook"                                                3 \
       "echo AB_AFTER_BIN_DONE"                                                     2 \
       "cat $PFX/etc/hamde/apps/hamaudiobook.desktop"                               3 \
       "echo AB_AFTER_DESKTOP_DONE"                                                 2 \
       "exit"                                                                       1
rc="$QEMU_DRIVE_RC"
set -e

echo "[ab-hpm] --- captured output ---"
cat "$LOG"
echo "[ab-hpm] --- end output ---"

fail=0
blk() { sed -n "/$1/,/$2/p" "$LOG"; }

# 0. No panic.
if grep -q "TRAP: vector" "$LOG"; then
    echo "[ab-hpm] FAIL: kernel trap during the run"; fail=1
fi
# 1. Shell came up.
if ! grep -F -q "[hamsh:stage-07] loop-enter" "$LOG"; then
    echo "[ab-hpm] FAIL: hamsh never reached the interactive loop"; exit 1
fi

# 2. NOT pre-installed: before install, both the binary and the launcher are
#    absent under the target prefix.
before=$(blk AB_BEFORE_BIN AB_BEFORE_DONE)
if echo "$before" | grep -Eqi "Exec=/bin/hamaudiobook|\[Desktop Entry\]"; then
    echo "[ab-hpm] FAIL: audiobook launcher present BEFORE install (should be repo-only)"; fail=1
else
    echo "[ab-hpm] OK: app absent before install (not pre-installed)"
fi

# 3. refresh + search list the repo-only package.
if blk AB_START AB_REFRESHED | grep -q "refreshed index from file:///test-hpm-repo/"; then
    echo "[ab-hpm] OK: hpm refreshed the mirror index"
else
    echo "[ab-hpm] MISS: refresh did not report success"; fail=1
fi
if blk AB_REFRESHED AB_SEARCHED | grep -q "hamnix-hamaudiobook"; then
    echo "[ab-hpm] OK: search lists hamnix-hamaudiobook"
else
    echo "[ab-hpm] MISS: search did not list the package"; fail=1
fi

# 4. install verified the SHA-256 + reported success.
ins=$(blk AB_SEARCHED AB_INSTALLED)
if echo "$ins" | grep -q "SHA-256 verified"; then
    echo "[ab-hpm] OK: install verified the published tarball SHA-256"
else
    echo "[ab-hpm] MISS: install did not verify SHA-256"; fail=1
fi
if echo "$ins" | grep -Eq "installed hamnix-hamaudiobook"; then
    echo "[ab-hpm] OK: install reported success"
else
    echo "[ab-hpm] MISS: install did not report success"; fail=1
fi

# 5. AFTER install: binary + launcher landed under the target prefix.
if blk AB_INSTALLED AB_AFTER_BIN_DONE | grep -q "hamaudiobook"; then
    echo "[ab-hpm] OK: bin/hamaudiobook present after install"
else
    echo "[ab-hpm] MISS: bin/hamaudiobook not found after install"; fail=1
fi
if blk AB_AFTER_BIN_DONE AB_AFTER_DESKTOP_DONE | grep -q "Exec=/bin/hamaudiobook"; then
    echo "[ab-hpm] OK: hamaudiobook.desktop launcher landed after install"
else
    echo "[ab-hpm] MISS: desktop launcher not found after install"; fail=1
fi

# The sequence must have run to completion. Under `-no-reboot` the guest does
# not self-power-off after `exit`, so qemu_drive tears QEMU down on its timeout
# AFTER every command has run — a benign rc=124 (exactly like test_hpm.sh, which
# ignores rc). We gate on the final marker instead, proving no mid-run hang.
if ! grep -F -q "AB_AFTER_DESKTOP_DONE" "$LOG"; then
    echo "[ab-hpm] FAIL: sequence did not complete (shell died / hang; rc=$rc)"
    fail=1
fi

if [ "$fail" -eq 0 ]; then
    echo "[ab-hpm] RESULT: PASS (qemu rc=$rc)"
    exit 0
else
    echo "[ab-hpm] RESULT: FAIL (fail=$fail rc=$rc)"
    exit 1
fi
