#!/bin/bash
# ============================================================================
#  Footage Indexer — double-click to run
#  Indexes a folder of footage, finds exact duplicates (full SHA-256
#  checksum), detects missing numbers in clip sequences, and opens an
#  interactive HTML report (sizes to the byte, created/modified dates,
#  duration, resolution, codec, filters, CSV export).
#
#  Usage:  double-click  (folder picker appears)
#     or:  "./Footage Indexer.command" /path/to/folder
# ============================================================================

export PATH="/usr/local/bin:/opt/homebrew/bin:$PATH"

# --- one-time dependency check (Apple's command line tools provide python3)
if ! python3 -c 'pass' >/dev/null 2>&1; then
  osascript -e 'display dialog "One-time setup needed: this tool uses Apple'\''s free command line tools.\n\nClick OK and macOS will offer to install them (a few minutes). Then double-click Footage Indexer again." buttons {"OK"} default button 1 with title "Footage Indexer"' >/dev/null 2>&1
  xcode-select --install >/dev/null 2>&1
  exit 1
fi

# --- pick the folder
TARGET="${1:-}"
if [ -z "$TARGET" ]; then
  TARGET="$(osascript -e 'POSIX path of (choose folder with prompt "Pick the footage folder to index:")' 2>/dev/null)" || exit 0
fi
if [ -z "$TARGET" ] || [ ! -d "$TARGET" ]; then
  echo "No folder selected — nothing to do."
  exit 0
fi

exec python3 - "$TARGET" <<'PYEOF'
# ===================== PYTHON BEGIN =====================
import sys, os, re, json, hashlib, struct, subprocess, shutil, datetime, time
from collections import defaultdict

ROOT = os.path.abspath(sys.argv[1])
IS_MAC = sys.platform == "darwin"

VIDEO_EXTS = {".mp4",".mov",".m4v",".mxf",".avi",".mkv",".mts",".m2ts",".mpg",
              ".mpeg",".wmv",".flv",".webm",".3gp",".braw",".r3d",".crm",".insv",".360"}
MP4_FAMILY = {".mp4",".mov",".m4v",".3gp",".insv",".360",".crm"}

CODEC_NAMES = {
    "avc1":"H.264","avc3":"H.264","hvc1":"HEVC (H.265)","hev1":"HEVC (H.265)",
    "ap4x":"ProRes 4444 XQ","ap4h":"ProRes 4444","apch":"ProRes 422 HQ",
    "apcn":"ProRes 422","apcs":"ProRes 422 LT","apco":"ProRes 422 Proxy",
    "aprh":"ProRes RAW HQ","aprn":"ProRes RAW",
    "mp4v":"MPEG-4","mjp2":"Motion JPEG 2000","jpeg":"Motion JPEG",
    "av01":"AV1","vp09":"VP9","vp08":"VP8","dvhe":"Dolby Vision","dvh1":"Dolby Vision",
    "xd5a":"XDCAM HD422","xd5b":"XDCAM HD422","xd5c":"XDCAM HD422",
    "xdvc":"XDCAM","dvc ":"DV","dvcp":"DVCPRO","dvpp":"DVCPRO","mpg2":"MPEG-2",
}
AUDIO_FOURCC = {"mp4a","lpcm","twos","sowt","alac","ac-3","ec-3","samr","ipcm"}

# ---------------------------------------------------------------- helpers
def human(n):
    # decimal units, same convention Finder uses
    if n is None: return ""
    f = float(n)
    for unit in ("bytes","KB","MB","GB","TB","PB"):
        if f < 1000 or unit == "PB":
            return ("%d %s" % (n, unit)) if unit == "bytes" else ("%.2f %s" % (f, unit))
        f /= 1000.0
    return str(n)

def progress(msg):
    sys.stdout.write("\r\033[K" + msg)
    sys.stdout.flush()

# ------------------------------------------------- MP4/MOV box parser
# Reads duration / resolution / codec straight out of the file, so it works
# even on drives where Spotlight metadata is unavailable.
def _iter_boxes(f, start, end):
    pos = start
    while pos + 8 <= end:
        f.seek(pos)
        hdr = f.read(8)
        if len(hdr) < 8: return
        size, typ = struct.unpack(">I4s", hdr)
        hdrlen = 8
        if size == 1:
            big = f.read(8)
            if len(big) < 8: return
            size = struct.unpack(">Q", big)[0]; hdrlen = 16
        elif size == 0:
            size = end - pos
        if size < hdrlen: return
        yield typ, pos + hdrlen, min(pos + size, end)
        pos += size

def _find_box(f, start, end, name):
    for typ, s, e in _iter_boxes(f, start, end):
        if typ == name: return s, e
    return None

def parse_mp4(path, fsize):
    """Return (duration_seconds, width, height, codec) — any may be None."""
    dur = w = h = codec = None
    try:
        with open(path, "rb") as f:
            moov = _find_box(f, 0, fsize, b"moov")
            if not moov: return None, None, None, None
            ms, me = moov
            # mvhd → duration
            r = _find_box(f, ms, me, b"mvhd")
            if r:
                f.seek(r[0]); payload = f.read(min(36, r[1]-r[0]))
                if payload:
                    ver = payload[0]
                    try:
                        if ver == 1:
                            ts  = struct.unpack(">I", payload[20:24])[0]
                            d   = struct.unpack(">Q", payload[24:32])[0]
                        else:
                            ts  = struct.unpack(">I", payload[12:16])[0]
                            d   = struct.unpack(">I", payload[16:20])[0]
                        if ts: dur = d / float(ts)
                    except struct.error:
                        pass
            # traks → resolution + codec (pick the video trak)
            for typ, ts_, te_ in _iter_boxes(f, ms, me):
                if typ != b"trak": continue
                tw = th = None; tcodec = None
                r = _find_box(f, ts_, te_, b"tkhd")
                if r:
                    f.seek(r[0]); p = f.read(min(96, r[1]-r[0]))
                    if p:
                        off = 88 if p[0] == 1 else 76
                        if len(p) >= off + 8:
                            try:
                                tw = struct.unpack(">I", p[off:off+4])[0] >> 16
                                th = struct.unpack(">I", p[off+4:off+8])[0] >> 16
                            except struct.error:
                                tw = th = None
                # stsd → codec fourcc
                box = _find_box(f, ts_, te_, b"mdia")
                if box: box = _find_box(f, box[0], box[1], b"minf")
                if box: box = _find_box(f, box[0], box[1], b"stbl")
                if box: box = _find_box(f, box[0], box[1], b"stsd")
                if box:
                    f.seek(box[0]); p = f.read(min(16, box[1]-box[0]))
                    if len(p) >= 16:
                        fourcc = p[12:16].decode("latin1").strip().lower()
                        if fourcc and fourcc not in AUDIO_FOURCC:
                            tcodec = CODEC_NAMES.get(fourcc, fourcc.upper())
                if tw and th:                      # video track wins
                    w, h = tw, th
                    if tcodec: codec = tcodec
                elif tcodec and not codec and tcodec not in ("TMCD","TEXT"):
                    if codec is None and not (w and h): codec = tcodec
    except (OSError, IOError):
        return None, None, None, None
    if codec in ("TMCD",): codec = None
    return dur, w, h, codec

# ------------------------------------------------- Spotlight fallback
def mdls_meta(path):
    try:
        out = subprocess.run(
            ["mdls","-name","kMDItemDurationSeconds","-name","kMDItemPixelWidth",
             "-name","kMDItemPixelHeight","-name","kMDItemCodecs", path],
            capture_output=True, text=True, timeout=15).stdout
    except Exception:
        return None, None, None, None
    def grab(key):
        m = re.search(re.escape(key) + r"\s*=\s*(.+)", out)
        return m.group(1).strip() if m else None
    def num(v):
        try: return float(v)
        except (TypeError, ValueError): return None
    dur = num(grab("kMDItemDurationSeconds"))
    w = num(grab("kMDItemPixelWidth")); h = num(grab("kMDItemPixelHeight"))
    codec = None
    m = re.search(r"kMDItemCodecs\s*=\s*\((.*?)\)", out, re.S)
    if m:
        names = re.findall(r'"([^"]+)"', m.group(1))
        vids = [n for n in names if not re.search(r"aac|pcm|audio|ac-?3|alac|timecode", n, re.I)]
        if vids: codec = vids[0]
    return dur, int(w) if w else None, int(h) if h else None, codec

# =================================================================== scan
print("Footage Indexer")
print("Folder: %s" % ROOT)
print("-" * 60)

files = []          # list of dicts
dir_stats = {}      # rel dir -> [cum_size, cum_count]
skipped = []
birth_fallback_used = False

def add_dir_chain(rel_dir, size):
    d = rel_dir
    while True:
        st = dir_stats.setdefault(d, [0, 0])
        st[0] += size; st[1] += 1
        if d == ".": break
        d = os.path.dirname(d) or "."

t0 = time.time()
for dirpath, dirnames, filenames in os.walk(ROOT, onerror=lambda e: skipped.append("%s (%s)" % (getattr(e, 'filename', '?'), e.strerror))):
    dirnames[:] = sorted(d for d in dirnames if not d.startswith("."))
    rel_dir = os.path.relpath(dirpath, ROOT)
    dir_stats.setdefault(rel_dir, [0, 0])
    for name in sorted(filenames):
        if name.startswith("."): continue
        full = os.path.join(dirpath, name)
        if os.path.islink(full):
            skipped.append(os.path.relpath(full, ROOT) + " (symlink)")
            continue
        try:
            st = os.stat(full)
        except OSError as e:
            skipped.append(os.path.relpath(full, ROOT) + " (%s)" % e.strerror)
            continue
        birth = getattr(st, "st_birthtime", None)
        if birth is None:
            birth = st.st_ctime; birth_fb = True; birth_fallback_used = True
        else:
            birth_fb = False
        ext = os.path.splitext(name)[1].lower()
        files.append({
            "n": name, "d": rel_dir, "full": full, "s": st.st_size,
            "b": round(birth, 3), "m": round(st.st_mtime, 3), "e": ext,
            "bf": birth_fb, "du": None, "w": None, "h": None, "c": None, "g": None,
        })
        add_dir_chain(rel_dir, st.st_size)
        if len(files) % 200 == 0:
            progress("Indexing… %d files" % len(files))

progress("Indexed %d files in %.1fs\n" % (len(files), time.time() - t0))

if not files:
    print("This folder contains no (non-hidden) files. No report generated.")
    sys.exit(0)

# ------------------------------------------------- video metadata pass
vid_files = [fobj for fobj in files if fobj["e"] in VIDEO_EXTS]
if vid_files:
    print("Reading video metadata for %d clips…" % len(vid_files))
    need_mdls = []
    for i, fo in enumerate(vid_files):
        if fo["e"] in MP4_FAMILY:
            du, w, h, c = parse_mp4(fo["full"], fo["s"])
            fo["du"], fo["w"], fo["h"], fo["c"] = du, w, h, c
            if du is None and IS_MAC: need_mdls.append(fo)
        elif IS_MAC:
            need_mdls.append(fo)
        if (i + 1) % 50 == 0:
            progress("  metadata %d/%d" % (i + 1, len(vid_files)))
    progress("")
    if need_mdls and IS_MAC and shutil.which("mdls"):
        from concurrent.futures import ThreadPoolExecutor
        def fill(fo):
            du, w, h, c = mdls_meta(fo["full"])
            if fo["du"] is None: fo["du"] = du
            if fo["w"] is None: fo["w"], fo["h"] = w, h
            if fo["c"] is None: fo["c"] = c
        with ThreadPoolExecutor(max_workers=8) as ex:
            list(ex.map(fill, need_mdls))

# ------------------------------------------------- duplicate detection
# Files can only be identical if their sizes match, so we only checksum
# size-matched candidates — the result is identical to hashing everything.
by_size = defaultdict(list)
for idx, fo in enumerate(files):
    if fo["s"] > 0: by_size[fo["s"]].append(idx)

candidates = [idxs for idxs in by_size.values() if len(idxs) > 1]
n_cand = sum(len(c) for c in candidates)
bytes_to_hash = sum(files[i]["s"] for c in candidates for i in c)
dupe_groups = []

if candidates:
    print("Checksumming %d size-matched candidates (%s)…" % (n_cand, human(bytes_to_hash)))
    done_bytes = 0; ht0 = time.time(); k = 0
    by_hash = defaultdict(list)
    for idxs in candidates:
        for i in idxs:
            fo = files[i]; k += 1
            hsh = hashlib.sha256()
            try:
                with open(fo["full"], "rb") as f:
                    while True:
                        chunk = f.read(8 * 1024 * 1024)
                        if not chunk: break
                        hsh.update(chunk); done_bytes += len(chunk)
                        el = time.time() - ht0
                        spd = done_bytes / el / 1e6 if el > 0.2 else 0
                        progress("  [%d/%d] %s  (%s / %s, %.0f MB/s)" %
                                 (k, n_cand, fo["n"][:40], human(done_bytes), human(bytes_to_hash), spd))
            except OSError as e:
                skipped.append(os.path.join(fo["d"], fo["n"]) + " (hash failed: %s)" % e.strerror)
                continue
            by_hash[(fo["s"], hsh.hexdigest())].append(i)
    progress("Checksums done (%s in %.1fs)\n" % (human(done_bytes), time.time() - ht0))
    gid = 0
    for (size, digest), idxs in sorted(by_hash.items(), key=lambda kv: -kv[0][0] * (len(kv[1]) - 1)):
        if len(idxs) < 2: continue
        gid += 1
        for i in idxs: files[i]["g"] = gid
        dupe_groups.append({"id": gid, "size": size, "hash": digest[:16],
                            "files": idxs, "wasted": size * (len(idxs) - 1)})

wasted_total = sum(g["wasted"] for g in dupe_groups)

# ------------------------------------------------- sequence gap detection
# Group by (folder, name-pattern around the LAST number in the name, ext);
# report any missing numbers between the lowest and highest found.
seq_groups = defaultdict(list)
for idx, fo in enumerate(files):
    stem = os.path.splitext(fo["n"])[0]
    runs = list(re.finditer(r"\d+", stem))
    if not runs: continue
    m = runs[-1]
    key = (fo["d"], stem[:m.start()].lower(), stem[m.end():].lower(), fo["e"])
    seq_groups[key].append((int(m.group()), len(m.group()), idx, stem[:m.start()], stem[m.end():]))

sequences = []
for (d, _pre, _suf, ext), items in seq_groups.items():
    nums = sorted(set(n for n, _, _, _, _ in items))
    if len(nums) < 2: continue
    lo, hi = nums[0], nums[-1]
    span = hi - lo + 1
    missing = sorted(set(range(lo, hi + 1)) - set(nums))
    if not missing: continue
    # ignore number-ish names that clearly aren't sequences (timestamps etc.)
    if span > 50 and len(nums) / span < 0.2: continue
    width = max(set(wd for _, wd, _, _, _ in items), key=lambda w: sum(1 for _, wd, _, _, _ in items if wd == w))
    pre = items[0][3]; suf = items[0][4]
    ext = os.path.splitext(files[items[0][2]]["n"])[1]   # original capitalization
    sequences.append({
        "d": d, "pat": "%s%s%s%s" % (pre, "#" * width, suf, ext),
        "lo": lo, "hi": hi, "present": len(nums),
        "missing": missing[:500], "total_missing": len(missing),
        "ex": "%s%0*d%s%s" % (pre, width, missing[0], suf, ext),
    })
sequences.sort(key=lambda s: (-s["total_missing"], s["d"]))
missing_total = sum(s["total_missing"] for s in sequences)

# ------------------------------------------------- report data
total_size = sum(fo["s"] for fo in files)
total_dur = sum(fo["du"] for fo in files if fo["du"])
dirs_list = [{"p": p, "s": st[0], "c": st[1]} for p, st in sorted(dir_stats.items())]
for fo in files: fo.pop("full")

data = {
    "root": ROOT, "rootName": os.path.basename(ROOT.rstrip("/")) or ROOT,
    "generated": datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
    "files": files, "dirs": dirs_list, "dupes": dupe_groups, "seqs": sequences,
    "summary": {"count": len(files), "size": total_size, "folders": len(dirs_list),
                "dupeGroups": len(dupe_groups), "wasted": wasted_total,
                "missing": missing_total, "videoCount": len(vid_files),
                "videoDur": total_dur, "birthFallback": birth_fallback_used},
    "skipped": skipped,
}

HTML = r"""<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Footage Report</title>
<style>
:root{--bg:#f4f5f7;--card:#fff;--ink:#1a1d21;--mut:#6b7280;--line:#e5e7eb;
--acc:#2563eb;--accbg:#eff6ff;--warn:#b45309;--warnbg:#fef3c7;--bad:#b91c1c;--badbg:#fee2e2;
--ok:#047857;--okbg:#d1fae5;--mono:ui-monospace,SFMono-Regular,Menlo,monospace}
*{box-sizing:border-box}
body{margin:0;font:14px/1.45 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;background:var(--bg);color:var(--ink)}
header{background:var(--card);border-bottom:1px solid var(--line);padding:14px 22px;position:sticky;top:0;z-index:30}
header h1{margin:0;font-size:17px}
header .sub{color:var(--mut);font-size:12px;margin-top:2px;word-break:break-all}
.wrap{display:flex;gap:16px;padding:16px 22px;align-items:flex-start}
.tree{width:300px;flex:none;background:var(--card);border:1px solid var(--line);border-radius:10px;
padding:10px;max-height:calc(100vh - 130px);overflow:auto;position:sticky;top:78px}
.tree h3{margin:2px 6px 8px;font-size:12px;text-transform:uppercase;letter-spacing:.05em;color:var(--mut)}
.tree details{margin-left:10px}
.tree>details{margin-left:0}
.tree summary{cursor:pointer;padding:2px 4px;border-radius:6px;list-style:none;display:flex;gap:6px;align-items:baseline}
.tree summary::before{content:"▸";font-size:10px;color:var(--mut);transition:transform .1s}
.tree details[open]>summary::before{transform:rotate(90deg)}
.tree summary:hover{background:var(--accbg)}
.tree .leaf summary::before{content:"·"}
.tree .fname{flex:1;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.tree .fname.scoped{color:var(--acc);font-weight:600}
.tree .fsize{color:var(--mut);font-size:11px;white-space:nowrap}
.main{flex:1;min-width:0}
.cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:10px;margin-bottom:14px}
.card{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:10px 14px}
.card .k{font-size:11px;color:var(--mut);text-transform:uppercase;letter-spacing:.04em}
.card .v{font-size:19px;font-weight:650;margin-top:2px}
.card .v2{font-size:11px;color:var(--mut);font-family:var(--mono);margin-top:1px;word-break:break-all}
.card.warn .v{color:var(--warn)}.card.bad .v{color:var(--bad)}.card.ok .v{color:var(--ok)}
.tabs{display:flex;gap:6px;margin-bottom:12px;flex-wrap:wrap}
.tab{padding:7px 14px;border-radius:8px;border:1px solid var(--line);background:var(--card);cursor:pointer;font-weight:550;font-size:13px}
.tab.active{background:var(--acc);border-color:var(--acc);color:#fff}
.tab .n{background:rgba(0,0,0,.08);border-radius:99px;padding:0 7px;font-size:11px;margin-left:4px}
.tab.active .n{background:rgba(255,255,255,.25)}
.panel{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:14px}
.filters{display:flex;flex-wrap:wrap;gap:8px;align-items:center;margin-bottom:12px}
.filters input,.filters select{padding:6px 8px;border:1px solid var(--line);border-radius:7px;font:inherit;background:#fff}
.filters input[type=text]{width:200px}
.filters input[type=number]{width:78px}
.filters input[type=date]{width:140px}
.filters label{font-size:12px;color:var(--mut);display:flex;gap:5px;align-items:center}
.btn{padding:6px 12px;border-radius:7px;border:1px solid var(--line);background:#fff;cursor:pointer;font:inherit;font-size:13px}
.btn:hover{background:var(--accbg);border-color:var(--acc);color:var(--acc)}
.chip{display:inline-flex;align-items:center;gap:6px;background:var(--accbg);color:var(--acc);
border:1px solid var(--acc);border-radius:99px;padding:3px 10px;font-size:12px;cursor:pointer}
table{width:100%;border-collapse:collapse;font-size:13px}
th{position:sticky;top:60px;background:var(--card);text-align:left;padding:7px 8px;border-bottom:2px solid var(--line);
cursor:pointer;user-select:none;white-space:nowrap;font-size:12px;color:var(--mut)}
th:hover{color:var(--acc)}
th .arr{font-size:9px}
td{padding:6px 8px;border-bottom:1px solid var(--line);vertical-align:top}
tr:hover td{background:#fafbfc}
td.num,th.num{text-align:right;font-variant-numeric:tabular-nums}
.mono{font-family:var(--mono);font-size:11.5px}
.dim{color:var(--mut)}
.b{font-weight:600}
.badge{display:inline-block;border-radius:5px;padding:1px 7px;font-size:11px;font-weight:600;cursor:pointer}
.badge.dup{background:var(--badbg);color:var(--bad)}
.badge.gap{background:var(--warnbg);color:var(--warn)}
.group{border:1px solid var(--line);border-radius:10px;padding:12px 14px;margin-bottom:10px}
.group.flash{outline:2px solid var(--acc)}
.group h4{margin:0 0 8px;font-size:13.5px;display:flex;gap:10px;flex-wrap:wrap;align-items:baseline}
.group .meta{color:var(--mut);font-weight:400;font-size:12px}
.copy{display:flex;gap:10px;padding:5px 0;border-top:1px dashed var(--line);font-size:12.5px;align-items:baseline;flex-wrap:wrap}
.copy .path{font-family:var(--mono);font-size:11.5px;word-break:break-all;flex:1;min-width:220px}
.missing-nums{font-family:var(--mono);font-size:12px;background:var(--warnbg);border-radius:7px;padding:8px 10px;margin-top:6px;word-break:break-word}
.empty{color:var(--mut);text-align:center;padding:30px 0}
.note{font-size:12px;color:var(--mut);margin-top:10px}
.showmore{display:block;margin:12px auto}
footer{padding:10px 22px 26px;color:var(--mut);font-size:12px}
@media (max-width:900px){.wrap{flex-direction:column}.tree{width:100%;position:static;max-height:300px}}
</style></head><body>
<header>
  <h1>📦 Footage Report — <span id="hRoot"></span></h1>
  <div class="sub" id="hSub"></div>
</header>
<div class="wrap">
  <nav class="tree" id="tree"><h3>Folders</h3><div id="treeBody"></div></nav>
  <div class="main">
    <div class="cards" id="cards"></div>
    <div class="tabs">
      <button class="tab active" data-tab="files">Files <span class="n" id="nFiles"></span></button>
      <button class="tab" data-tab="dupes">Duplicates <span class="n" id="nDupes"></span></button>
      <button class="tab" data-tab="gaps">Missing numbers <span class="n" id="nGaps"></span></button>
    </div>

    <div class="panel" id="panel-files">
      <div class="filters">
        <input type="text" id="fSearch" placeholder="Search name / folder…">
        <select id="fExt"><option value="">All types</option></select>
        <label>Size <input type="number" id="fMin" min="0" placeholder="min">–<input type="number" id="fMax" min="0" placeholder="max">
          <select id="fUnit"><option value="1">B</option><option value="1000">KB</option><option value="1000000" selected>MB</option><option value="1000000000">GB</option></select></label>
        <label><select id="fDateField"><option value="b">Created</option><option value="m">Modified</option></select>
          <input type="date" id="fFrom">–<input type="date" id="fTo"></label>
        <label><input type="checkbox" id="fDup"> duplicates only</label>
        <button class="btn" id="fReset">Reset</button>
        <button class="btn" id="fCsv">⬇ Export CSV</button>
        <span id="scopeChip"></span>
      </div>
      <div id="matchInfo" class="note" style="margin:0 0 8px"></div>
      <div style="overflow-x:auto">
      <table id="tbl"><thead><tr>
        <th data-k="n">Name <span class="arr"></span></th>
        <th data-k="d">Folder <span class="arr"></span></th>
        <th data-k="s" class="num">Size <span class="arr"></span></th>
        <th data-k="b">Created <span class="arr"></span></th>
        <th data-k="m">Modified <span class="arr"></span></th>
        <th data-k="du" class="num">Duration <span class="arr"></span></th>
        <th data-k="px" class="num">Dimensions <span class="arr"></span></th>
        <th data-k="c">Codec <span class="arr"></span></th>
        <th>Flags</th>
      </tr></thead><tbody id="tbody"></tbody></table>
      </div>
      <button class="btn showmore" id="more" style="display:none"></button>
      <div class="note" id="skippedNote"></div>
    </div>

    <div class="panel" id="panel-dupes" style="display:none">
      <div class="note" style="margin:0 0 10px">Groups of files with <b>identical full SHA-256 checksums</b> — byte-for-byte copies, even if renamed. Keep one per group; the rest is reclaimable space.</div>
      <div id="dupeBody"></div>
    </div>

    <div class="panel" id="panel-gaps" style="display:none">
      <div class="note" style="margin:0 0 10px">Numbered groups of files (per folder) where numbers between the lowest and highest are <b>absent</b>. A missing number can mean a clip was never copied over.</div>
      <div id="gapBody"></div>
    </div>
  </div>
</div>
<footer>Generated by Footage Indexer · sizes use decimal units (1 GB = 1,000,000,000 bytes), matching Finder · exact byte counts shown beneath each size</footer>
<script>
const DATA = __DATA__;
const $ = s => document.querySelector(s);
const esc = s => String(s).replace(/[&<>"']/g, c => ({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]));
const fmtB = n => n.toLocaleString("en-US") + " bytes";
function fmtH(n){ if(n==null) return ""; let f=n; const u=["bytes","KB","MB","GB","TB","PB"];
  for(let i=0;i<u.length;i++){ if(f<1000||i===u.length-1) return i===0? n+" bytes" : f.toFixed(2)+" "+u[i]; f/=1000; } }
const fmtD = t => { const d=new Date(t*1000), p=x=>String(x).padStart(2,"0");
  return d.getFullYear()+"-"+p(d.getMonth()+1)+"-"+p(d.getDate())+" "+p(d.getHours())+":"+p(d.getMinutes())+":"+p(d.getSeconds()); };
function fmtDur(s){ if(s==null) return ""; s=Math.round(s); const h=Math.floor(s/3600),m=Math.floor(s%3600/60),x=s%60;
  return (h? h+":"+String(m).padStart(2,"0") : m) + ":" + String(x).padStart(2,"0"); }
DATA.files.forEach((f,i)=>{ f.i=i; f.px=(f.w&&f.h)? f.w*f.h : null; });

/* ---------- summary cards ---------- */
const S = DATA.summary;
let cards = [
  ["Files", S.count.toLocaleString(), S.videoCount.toLocaleString()+" video clips", ""],
  ["Total size", fmtH(S.size), fmtB(S.size), ""],
  ["Folders", S.folders.toLocaleString(), "", ""],
  ["Duplicate groups", S.dupeGroups.toLocaleString(), S.dupeGroups? fmtH(S.wasted)+" reclaimable":"no exact duplicates", S.dupeGroups? "bad":"ok"],
  ["Missing numbers", S.missing.toLocaleString(), S.missing? "across "+DATA.seqs.length+" sequence(s)":"no gaps detected", S.missing? "warn":"ok"],
];
if (S.videoDur) cards.splice(2,0,["Total footage", fmtDur(S.videoDur), "sum of clip durations", ""]);
$("#cards").innerHTML = cards.map(c=>'<div class="card '+c[3]+'"><div class="k">'+c[0]+'</div><div class="v">'+c[1]+'</div>'+(c[2]?'<div class="v2">'+c[2]+'</div>':"")+'</div>').join("");
$("#hRoot").textContent = DATA.rootName;
$("#hSub").textContent = DATA.root + "  ·  scanned " + DATA.generated;
$("#nFiles").textContent = S.count.toLocaleString();
$("#nDupes").textContent = S.dupeGroups;
$("#nGaps").textContent = S.missing;

/* ---------- tabs ---------- */
document.querySelectorAll(".tab").forEach(t=>t.onclick=()=>showTab(t.dataset.tab));
function showTab(name){
  document.querySelectorAll(".tab").forEach(x=>x.classList.toggle("active",x.dataset.tab===name));
  ["files","dupes","gaps"].forEach(p=>$("#panel-"+p).style.display = p===name? "":"none");
}

/* ---------- folder tree ---------- */
const kids = {};
DATA.dirs.forEach(d=>{ if(d.p!=="."){ const par=d.p.includes("/")? d.p.slice(0,d.p.lastIndexOf("/")) : "."; (kids[par]=kids[par]||[]).push(d);} });
const dirMap = {}; DATA.dirs.forEach(d=>dirMap[d.p]=d);
let scope = null;
function treeNode(d, depth){
  const ch = kids[d.p]||[];
  const label = d.p==="." ? DATA.rootName : d.p.split("/").pop();
  let h = '<details class="'+(ch.length? "":"leaf")+'"'+(depth<2? " open":"")+'><summary>'+
    '<span class="fname" data-p="'+esc(d.p)+'" title="filter to this folder">'+esc(label)+'</span>'+
    '<span class="fsize">'+fmtH(d.s)+' · '+d.c.toLocaleString()+'</span></summary>';
  ch.forEach(c=>h+=treeNode(c, depth+1));
  return h+"</details>";
}
$("#treeBody").innerHTML = dirMap["."] ? treeNode(dirMap["."],0) : "";
$("#treeBody").addEventListener("click", e=>{
  const el = e.target.closest(".fname"); if(!el) return;
  e.preventDefault();
  scope = scope===el.dataset.p ? null : el.dataset.p;
  document.querySelectorAll(".fname").forEach(x=>x.classList.toggle("scoped", x.dataset.p===scope));
  showTab("files"); render();
});

/* ---------- filters / sort / render ---------- */
const exts = [...new Set(DATA.files.map(f=>f.e||"(none)"))].sort();
exts.forEach(x=>{ const o=document.createElement("option"); o.value=x; o.textContent=x; $("#fExt").appendChild(o); });
let sortK="n", sortDir=1, shown=400;
["fSearch","fExt","fMin","fMax","fUnit","fDateField","fFrom","fTo","fDup"].forEach(id=>{
  $("#"+id).addEventListener("input", ()=>{shown=400; render();});
});
$("#fReset").onclick=()=>{ ["fSearch","fMin","fMax","fFrom","fTo"].forEach(id=>$("#"+id).value="");
  $("#fExt").value=""; $("#fDup").checked=false; $("#fUnit").value="1000000"; scope=null;
  document.querySelectorAll(".fname").forEach(x=>x.classList.remove("scoped")); shown=400; render(); };
document.querySelectorAll("#tbl th[data-k]").forEach(th=>th.onclick=()=>{
  const k=th.dataset.k; if(sortK===k) sortDir*=-1; else {sortK=k; sortDir=1;} render(); });

function filtered(){
  const q=$("#fSearch").value.toLowerCase(), ext=$("#fExt").value, unit=+$("#fUnit").value;
  const mn=$("#fMin").value===""? null : +$("#fMin").value*unit;
  const mx=$("#fMax").value===""? null : +$("#fMax").value*unit;
  const df=$("#fDateField").value;
  const from=$("#fFrom").value? new Date($("#fFrom").value+"T00:00:00").getTime()/1000 : null;
  const to=$("#fTo").value? new Date($("#fTo").value+"T00:00:00").getTime()/1000+86400 : null;
  const dup=$("#fDup").checked;
  return DATA.files.filter(f=>{
    if(scope && f.d!==scope && !(f.d+"/").startsWith(scope+"/") ) return false;
    if(q && !(f.n.toLowerCase().includes(q)||f.d.toLowerCase().includes(q))) return false;
    if(ext && (f.e||"(none)")!==ext) return false;
    if(mn!=null && f.s<mn) return false;
    if(mx!=null && f.s>mx) return false;
    if(from!=null && f[df]<from) return false;
    if(to!=null && f[df]>=to) return false;
    if(dup && !f.g) return false;
    return true;
  });
}
function render(){
  const rows = filtered();
  const k=sortK;
  rows.sort((a,b)=>{
    let va=a[k], vb=b[k];
    if(va==null && vb==null) return 0; if(va==null) return 1; if(vb==null) return -1;
    if(typeof va==="string") return va.localeCompare(vb,undefined,{numeric:true})*sortDir;
    return (va-vb)*sortDir;
  });
  document.querySelectorAll("#tbl th .arr").forEach(a=>a.textContent="");
  const th=document.querySelector('#tbl th[data-k="'+k+'"] .arr'); if(th) th.textContent = sortDir>0? "▲":"▼";
  $("#matchInfo").textContent = rows.length.toLocaleString()+" of "+DATA.files.length.toLocaleString()+
    " files  ·  "+fmtH(rows.reduce((t,f)=>t+f.s,0))+" ("+fmtB(rows.reduce((t,f)=>t+f.s,0))+")"+(scope? "  ·  in “"+scope+"”":"");
  $("#scopeChip").innerHTML = scope? '<span class="chip" id="clearScope">📁 '+esc(scope)+' ✕</span>':"";
  if(scope) $("#clearScope").onclick=()=>{scope=null;document.querySelectorAll(".fname").forEach(x=>x.classList.remove("scoped"));render();};
  const slice = rows.slice(0, shown);
  $("#tbody").innerHTML = slice.map(f=>'<tr>'+
    '<td class="b">'+esc(f.n)+'</td>'+
    '<td class="dim mono">'+esc(f.d==="."? "/" : f.d)+'</td>'+
    '<td class="num">'+fmtH(f.s)+'<div class="dim mono">'+fmtB(f.s)+'</div></td>'+
    '<td class="mono">'+fmtD(f.b)+(f.bf? ' <span class="dim" title="true creation date unavailable on this volume; showing metadata-change time">*</span>':"")+'</td>'+
    '<td class="mono">'+fmtD(f.m)+'</td>'+
    '<td class="num">'+fmtDur(f.du)+'</td>'+
    '<td class="num">'+(f.w&&f.h? f.w+"×"+f.h : "")+'</td>'+
    '<td>'+(f.c? esc(f.c):"")+'</td>'+
    '<td>'+(f.g? '<span class="badge dup" data-g="'+f.g+'">DUP #'+f.g+'</span>':"")+'</td>'+
  '</tr>').join("");
  const more=$("#more");
  if(rows.length>shown){ more.style.display=""; more.textContent="Show "+Math.min(400,rows.length-shown)+" more ("+(rows.length-shown)+" hidden)"; more.onclick=()=>{shown+=400;render();}; }
  else more.style.display="none";
  window._rows = rows;
}
$("#tbody").addEventListener("click", e=>{
  const b=e.target.closest(".badge.dup"); if(!b) return;
  showTab("dupes");
  const el=document.getElementById("dg"+b.dataset.g);
  if(el){ el.scrollIntoView({behavior:"smooth",block:"center"}); el.classList.add("flash"); setTimeout(()=>el.classList.remove("flash"),1600); }
});

/* ---------- CSV ---------- */
$("#fCsv").onclick=()=>{
  const rows=window._rows||filtered();
  const head=["name","folder","bytes","size","created","modified","duration_s","width","height","codec","duplicate_group"];
  const csv=[head.join(",")].concat(rows.map(f=>[f.n,f.d,f.s,fmtH(f.s),fmtD(f.b),fmtD(f.m),f.du??"",f.w??"",f.h??"",f.c??"",f.g??""]
    .map(v=>'"'+String(v).replace(/"/g,'""')+'"').join(","))).join("\n");
  const a=document.createElement("a");
  a.href=URL.createObjectURL(new Blob([csv],{type:"text/csv"}));
  a.download="footage-index.csv"; a.click();
};

/* ---------- duplicates panel ---------- */
function dupePanel(){
  if(!DATA.dupes.length){ $("#dupeBody").innerHTML='<div class="empty">🎉 No exact duplicates found.</div>'; return; }
  $("#dupeBody").innerHTML = DATA.dupes.map(g=>{
    const fs=g.files.map(i=>DATA.files[i]);
    return '<div class="group" id="dg'+g.id+'"><h4>Group #'+g.id+' — '+fs.length+' identical copies of '+fmtH(g.size)+
      ' <span class="meta">'+fmtB(g.size)+' each · '+fmtH(g.wasted)+' reclaimable · sha256 '+g.hash+'…</span></h4>'+
      fs.map(f=>'<div class="copy"><span class="path">'+esc((f.d==="."?"":f.d+"/")+f.n)+'</span>'+
        '<span class="dim mono">created '+fmtD(f.b)+'</span><span class="dim mono">modified '+fmtD(f.m)+'</span></div>').join("")+
    '</div>';
  }).join("");
}
/* ---------- gaps panel ---------- */
function gapPanel(){
  if(!DATA.seqs.length){ $("#gapBody").innerHTML='<div class="empty">🎉 No gaps in any numbered sequence.</div>'; return; }
  $("#gapBody").innerHTML = DATA.seqs.map(s=>{
    const miss = s.missing.slice(0,80).join(", ") + (s.total_missing>80? "  … +"+(s.total_missing-80)+" more":"");
    return '<div class="group"><h4>'+esc(s.pat)+' <span class="meta">in '+esc(s.d==="."?"/":s.d)+
      ' · '+s.present+' files present, numbered '+s.lo+'–'+s.hi+'</span></h4>'+
      '<div><span class="badge gap">'+s.total_missing+' missing</span> e.g. expected “'+esc(s.ex)+'”</div>'+
      '<div class="missing-nums">missing: '+miss+'</div></div>';
  }).join("");
}
/* ---------- skipped ---------- */
$("#skippedNote").innerHTML = (S.birthFallback? "* on this volume the true creation date wasn’t available for some files; the metadata-change time is shown instead.<br>":"") +
  (DATA.skipped.length? "⚠ "+DATA.skipped.length+" item(s) skipped: "+DATA.skipped.slice(0,20).map(esc).join(" · ")+(DATA.skipped.length>20? " …":""):"");

dupePanel(); gapPanel(); render();
</script>
</body></html>"""

payload = json.dumps(data, separators=(",", ":")).replace("</", "<\\/")
html_out = HTML.replace("__DATA__", payload)

desk = os.path.expanduser("~/Desktop")
out_dir = desk if os.path.isdir(desk) else os.path.expanduser("~")
stamp = datetime.datetime.now().strftime("%Y-%m-%d %H.%M")
base = os.path.basename(ROOT.rstrip("/")) or "folder"
out_path = os.path.join(out_dir, "Footage Report — %s — %s.html" % (base, stamp))
with open(out_path, "w", encoding="utf-8") as f:
    f.write(html_out)

print("-" * 60)
print("Files indexed : %s  (%s / %s bytes)" % (len(files), human(total_size), format(total_size, ",")))
print("Duplicates    : %d group(s), %s reclaimable" % (len(dupe_groups), human(wasted_total)))
print("Missing nums  : %d across %d sequence(s)" % (missing_total, len(sequences)))
if skipped: print("Skipped       : %d item(s) — listed in the report" % len(skipped))
print("Report        : %s" % out_path)
if IS_MAC:
    subprocess.run(["open", out_path])
print("\nDone — you can close this window.")
# ===================== PYTHON END =====================
PYEOF
