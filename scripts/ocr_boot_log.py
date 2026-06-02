#!/usr/bin/env python3
"""ocr_boot_log.py — turn a captured NUC boot-log video into text.

The kernel's /etc/log-slow page-pause (drivers/video/console/fb_text.ad)
holds each screenful of the boot log static for ~1 s and stamps a
delimiter line:

    ### HAMNIX-LOGPAGE NNNN ###

That gives a capture card a full second of a MOTIONLESS, content-rich
frame per page. This script exploits exactly that:

  1. Walk every frame, scoring MOTION (mean abs diff vs the previous
     frame, on a downscaled gray copy) and CONTENT (fraction of bright
     "text" pixels — so we skip near-BLACK / blank frames).
  2. A page pause is a run of LOW-MOTION, NON-BLACK frames. A *real*
     1 s freeze always contains at least one pair of (near-)IDENTICAL
     consecutive frames (the framebuffer is byte-stable) — we require
     that twin before trusting a run, which rejects slowly-drifting or
     motion-blurred runs that never actually froze. The chosen shot is
     the crispest twin-confirmed frame past a short settle skip.
  3. OCR only those clean frames (tesseract, psm 6, on an upscaled
     inverted-Otsu binarisation — white-on-black console → dark-on-light).
  4. Read the HAMNIX-LOGPAGE number off the banner row with a DIGIT-ONLY
     whitelist (the zero-padded field gets mangled by the surrounding
     '###' in full-frame OCR), falling back to a noise-tolerant regex.

Output: one text file with every captured page in CAPTURE ORDER (the
authoritative ordering — OCR'd page numbers are only a label/gap-report
aid), each under a `===== PAGE NNNN  (frame F) =====` header.

Usage:
    python3 scripts/ocr_boot_log.py "debug/clip.mp4" [-o out.txt]
        [--motion 1.2] [--content 0.004] [--min-stable 18] [--settle 6]
        [--identical 0.1] [--debug-frames DIR]
"""

import argparse
import os
import re
import sys

import cv2
import numpy as np
import pytesseract

# Locate just the marker; the number is parsed separately so we can
# repair OCR letter/digit confusions in the 4-digit field (the '#' frame
# bleeds 'O'/'D' into the zero-padded digits — e.g. 0009 -> O0O09).
# Tolerant of the hyphen reading as an em-dash and stray glyphs.
MARK_RE = re.compile(r"HAMNIX\W{0,4}LOGPAGE", re.IGNORECASE)

# Glyphs tesseract commonly emits for digits in the console font.
_OCR_DIGITS = str.maketrans({
    "O": "0", "o": "0", "D": "0", "Q": "0",
    "I": "1", "l": "1", "i": "1", "|": "1", "!": "1",
    "Z": "2", "z": "2",
    "E": "3",
    "A": "4",
    "S": "5", "s": "5",
    "G": "6", "b": "6",
    "T": "7",
    "B": "8",
    "g": "9", "q": "9",
})


def _binarize(gray):
    _, th = cv2.threshold(gray, 0, 255,
                          cv2.THRESH_BINARY_INV + cv2.THRESH_OTSU)
    return th


def ocr_frame(bgr):
    """OCR a full BGR frame of white-on-black console text."""
    gray = cv2.cvtColor(bgr, cv2.COLOR_BGR2GRAY)
    gray = cv2.resize(gray, None, fx=2, fy=2, interpolation=cv2.INTER_CUBIC)
    return pytesseract.image_to_string(_binarize(gray), config="--psm 6")


def ocr_page_number(bgr):
    """Read the HAMNIX-LOGPAGE number with a DIGIT-ONLY whitelist on a
    tight crop of JUST the number field. Full-frame OCR mangles the
    zero-padded digits (the surrounding '###' bleeds 'O'/'D' into them),
    and a whole-row whitelist pass instead reads the closing '###' AS
    digits ('#' -> 8/1). So we locate the 'LOGPAGE' word via
    image_to_data and crop from just past its right edge for a bounded
    width (~the 4-digit field), excluding both '###' runs. Returns an
    int, or None if no banner row is found."""
    gray = cv2.cvtColor(bgr, cv2.COLOR_BGR2GRAY)
    gray = cv2.resize(gray, None, fx=2, fy=2, interpolation=cv2.INTER_CUBIC)
    th = _binarize(gray)
    data = pytesseract.image_to_data(th, config="--psm 6",
                                     output_type=pytesseract.Output.DICT)
    n = len(data["text"])
    for i in range(n):
        if "GPAGE" not in data["text"][i].upper():
            continue
        x = data["left"][i]
        w = data["width"][i]
        y = data["top"][i]
        h = data["height"][i]
        pad = int(0.35 * h) + 2
        # Number sits immediately right of "LOGPAGE"; a 4-digit field
        # plus margins is ~5 glyph-widths (glyph width ~= h/2). Stop well
        # before the trailing "###".
        x0 = x + w + int(0.2 * h)
        x1 = min(th.shape[1], x0 + int(5.0 * h))
        y0 = max(0, y - pad)
        y1 = min(th.shape[0], y + h + pad)
        crop = th[y0:y1, x0:x1]
        if crop.size == 0:
            continue
        crop = cv2.resize(crop, None, fx=2, fy=2,
                          interpolation=cv2.INTER_CUBIC)
        txt = pytesseract.image_to_string(
            crop, config="--psm 7 -c tessedit_char_whitelist=0123456789")
        m = re.search(r"\d{1,5}", txt)
        if m:
            return int(m.group(0))
    return None


def sharpness(gray):
    """Variance of the Laplacian — higher means crisper, less blur."""
    return float(cv2.Laplacian(gray, cv2.CV_64F).var())


def find_page_number(*texts):
    for text in texts:
        for m in MARK_RE.finditer(text):
            # The number sits between LOGPAGE and the closing '###'
            # (which OCRs as '#'/'H' runs). Grab the short tail, repair
            # letter->digit confusions, then take the first digit run.
            tail = text[m.end():m.end() + 12]
            tail = re.split(r"[#]|H{2,}", tail, maxsplit=1)[0]
            dm = re.search(r"\d{1,5}", tail.translate(_OCR_DIGITS))
            if dm:
                return int(dm.group(0))
    return None


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("video")
    ap.add_argument("-o", "--out", default=None,
                    help="output text file (default: <video>.ocr.txt)")
    ap.add_argument("--motion", type=float, default=1.2,
                    help="max mean abs frame diff (0-255) to count as static")
    ap.add_argument("--content", type=float, default=0.004,
                    help="min fraction of bright pixels to count as non-black")
    ap.add_argument("--min-stable", type=int, default=18,
                    help="min consecutive static frames to accept a page")
    ap.add_argument("--settle", type=int, default=6,
                    help="leading static frames to skip before trusting one")
    ap.add_argument("--identical", type=float, default=0.1,
                    help="max mean abs diff between two consecutive frames "
                         "to count them as an IDENTICAL twin (a real 1s "
                         "freeze always has one; required to accept a page)")
    ap.add_argument("--bright", type=int, default=110,
                    help="gray value above which a pixel counts as text")
    ap.add_argument("--debug-frames", default=None,
                    help="dir to dump the chosen clean frames as PNGs")
    args = ap.parse_args()

    out = args.out or (os.path.splitext(args.video)[0] + ".ocr.txt")
    if args.debug_frames:
        os.makedirs(args.debug_frames, exist_ok=True)

    cap = cv2.VideoCapture(args.video)
    if not cap.isOpened():
        print(f"ERROR: cannot open {args.video}", file=sys.stderr)
        return 2
    total = int(cap.get(cv2.CAP_PROP_FRAME_COUNT)) or -1

    prev_small = None
    in_stable = False
    seg_len = 0
    best_frame = None
    best_sharp = -1.0
    best_idx = -1
    has_twin = False
    last_frame = None
    last_idx = -1
    segments = []          # list of (rep_idx, rep_frame)

    def finalize(force=False):
        nonlocal best_frame, best_idx
        # A hang freezes the screen on its final page, so the last run
        # may never reach min-stable (and its banner may never print).
        # When `force`, accept it regardless — falling back to the very
        # last decoded frame if no settled frame was picked.
        if best_frame is None and force and last_frame is not None:
            best_frame = last_frame
            best_idx = last_idx
        # Require a confirmed twin: a genuine 1s pause always produced
        # two (near-)identical consecutive frames. Runs that stayed
        # low-motion but never truly froze (capture-card blur) are
        # rejected — they have no twin.
        if best_frame is not None and (force or
                (seg_len >= args.min_stable and has_twin)):
            segments.append((best_idx, best_frame))

    idx = -1
    while True:
        ok, frame = cap.read()
        if not ok:
            break
        idx += 1
        last_frame = frame
        last_idx = idx
        small = cv2.cvtColor(cv2.resize(frame, (480, 270)), cv2.COLOR_BGR2GRAY)
        content = float(np.mean(small > args.bright))
        if prev_small is None:
            motion = 1e9
        else:
            motion = float(np.mean(cv2.absdiff(small, prev_small)))
        prev_small = small

        is_static = motion < args.motion and content > args.content
        if is_static:
            if not in_stable:
                in_stable = True
                seg_len = 1
                best_frame = None
                best_sharp = -1.0
                best_idx = -1
                has_twin = False
            else:
                seg_len += 1
                # A twin = this frame is (near-)identical to its
                # predecessor, i.e. the framebuffer truly froze. Only
                # twin-confirmed frames are eligible: that both proves
                # the pause is real (not capture-card blur) and
                # guarantees the chosen frame is crisp. Skip the first
                # `settle` frames (settling blur), then keep the
                # sharpest twin (max Laplacian variance).
                if motion < args.identical:
                    has_twin = True
                    if seg_len > args.settle:
                        sharp = sharpness(small)
                        if sharp > best_sharp:
                            best_sharp = sharp
                            best_frame = frame.copy()
                            best_idx = idx
        else:
            if in_stable:
                finalize()
            in_stable = False
            seg_len = 0
        if total > 0 and idx % 200 == 0:
            print(f"  scan {idx}/{total} ({100*idx//total}%)", file=sys.stderr)
    if in_stable:
        finalize(force=True)
    elif last_frame is not None:
        # Video ended outside a stable run — still keep the final frame
        # (the hang screen) so the last page is never dropped.
        segments.append((last_idx, last_frame))
    cap.release()

    print(f"[ocr] {len(segments)} stable page candidates "
          f"(low-motion, non-black runs >= {args.min_stable} frames)",
          file=sys.stderr)

    # OCR each clean frame IN CAPTURE ORDER (the authoritative ordering;
    # OCR'd page numbers are only a label/gap-report aid).
    results = []           # list of [frame_idx, page_no_or_None, text]
    for rep_idx, rep in segments:
        text = ocr_frame(rep).rstrip()
        # Digit-whitelist banner read first; noise-tolerant full-frame
        # regex as a fallback.
        pno = ocr_page_number(rep)
        if pno is None:
            pno = find_page_number(text)
        if args.debug_frames:
            label = f"page_{pno:04d}" if pno is not None else f"frame_{rep_idx:06d}"
            cv2.imwrite(os.path.join(args.debug_frames, label + ".png"), rep)
        # Dedupe a page captured twice back-to-back (a brief motion blip
        # can split one pause into two runs): keep the longer OCR.
        if results and pno is not None and results[-1][1] == pno:
            if len(text) > len(results[-1][2]):
                results[-1] = [rep_idx, pno, text]
        else:
            results.append([rep_idx, pno, text])
        tag = f"page {pno:04d}" if pno is not None else "(no page tag)"
        print(f"  frame {rep_idx}: {tag}", file=sys.stderr)

    # The consolidated text is the deliverable: write it to the file AND
    # stream it to stdout, so one run yields processable text directly
    # (no need to re-OCR the frames). Progress/health goes to stderr, so
    # stdout stays pure text and is safe to redirect.
    with open(out, "w") as f:
        for fidx, pno, text in results:
            hdr = (f"PAGE {pno:04d}  (frame {fidx})" if pno is not None
                   else f"UNTAGGED  (frame {fidx})")
            block = f"===== {hdr} =====\n{text}\n"
            f.write(block + "\n")
            print(block)

    # Report capture health off the page numbers we did read.
    nums = [p for _, p, _ in results if p is not None]
    untagged = len(results) - len(nums)
    print(f"[ocr] wrote {out}: {len(results)} pages in capture order "
          f"({len(nums)} numbered, {untagged} untagged)", file=sys.stderr)
    if nums:
        lo, hi = min(nums), max(nums)
        have = set(nums)
        missing = [n for n in range(lo, hi + 1) if n not in have]
        print(f"[ocr] page-number range {lo:04d}..{hi:04d}", file=sys.stderr)
        inversions = [(nums[k - 1], nums[k]) for k in range(1, len(nums))
                      if nums[k] <= nums[k - 1]]
        if inversions:
            print(f"[ocr] WARN page numbers not strictly increasing "
                  f"(likely digit misreads; text/order still good): "
                  f"{inversions}", file=sys.stderr)
        if missing:
            print(f"[ocr] possible capture gaps: "
                  f"{', '.join('%04d' % n for n in missing)}", file=sys.stderr)
        else:
            print("[ocr] no gaps in page-number range.", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
