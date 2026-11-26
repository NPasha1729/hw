"""Download pinned benchmark/inspection binaries into assets/ (gitignored).

Run on Noor's own PC when preparing the USB stick or a release:
    python tools/fetch_assets.py            # download + extract + write assets/MANIFEST.txt
    python tools/fetch_assets.py --verify   # re-hash and compare to MANIFEST.txt
Then copy the whole kit folder (including assets/) to the USB root.
"""
import argparse, hashlib, io, os, shutil, subprocess, sys, tarfile, urllib.request, zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ASSETS = os.path.join(ROOT, "assets")
SEVENZIP = r"C:\Program Files\7-Zip\7z.exe"

LLAMA = "b12776"
FFMPEG_PATTERN = r"^ffmpeg-n8\.1[.0-9a-g-]*-win64-gpl-shared-8\.1\.zip$"  # stable 8.1 branch, GPL (x264 inside), shared DLLs
SMART = "7.4-1"

ITEMS = [
    # name, url, kind, dest
    ("smartctl", f"https://downloads.sourceforge.net/project/smartmontools/smartmontools/{SMART[:-2]}/smartmontools-{SMART}.win32-setup.exe", "nsis", "win/smartctl"),
    ("ffmpeg", "btbn:" + FFMPEG_PATTERN, "zip-strip", "win/ffmpeg"),
    ("llama-vulkan", f"https://github.com/ggml-org/llama.cpp/releases/download/{LLAMA}/llama-{LLAMA}-bin-win-vulkan-x64.zip", "zip", "win/llama-vulkan"),
    ("llama-cpu", f"https://github.com/ggml-org/llama.cpp/releases/download/{LLAMA}/llama-{LLAMA}-bin-win-cpu-x64.zip", "zip", "win/llama-cpu"),
    ("llama-mac-arm64", f"https://github.com/ggml-org/llama.cpp/releases/download/{LLAMA}/llama-{LLAMA}-bin-macos-arm64.tar.gz", "tgz", "mac/llama-arm64"),
    ("llama-mac-x64", f"https://github.com/ggml-org/llama.cpp/releases/download/{LLAMA}/llama-{LLAMA}-bin-macos-x64.tar.gz", "tgz", "mac/llama-x64"),
    ("model", "https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF/resolve/main/qwen2.5-0.5b-instruct-q4_k_m.gguf", "file", "model/qwen2.5-0.5b-q4km.gguf"),
]


def get(url):
    if url.startswith("btbn:"):
        url = resolve_btbn(url[5:])
    req = urllib.request.Request(url, headers={"User-Agent": "hw-kit-fetch"})
    with urllib.request.urlopen(req, timeout=600) as r:
        return r.read()


def resolve_btbn(pattern):
    import json, re
    rel = json.loads(get("https://api.github.com/repos/BtbN/FFmpeg-Builds/releases/latest"))
    for a in rel["assets"]:
        if re.match(pattern, a["name"]):
            print("     ffmpeg asset:", a["name"])
            return a["browser_download_url"]
    raise SystemExit("no ffmpeg asset matches " + pattern)


def sha(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()


def fetch():
    os.makedirs(ASSETS, exist_ok=True)
    for name, url, kind, dest in ITEMS:
        out = os.path.join(ASSETS, dest)
        if os.path.exists(out):
            print(f"skip {name} (exists)")
            continue
        print(f"get  {name} ...", flush=True)
        data = get(url)
        if kind == "file":
            os.makedirs(os.path.dirname(out), exist_ok=True)
            open(out, "wb").write(data)
        elif kind in ("zip", "zip-strip"):
            z = zipfile.ZipFile(io.BytesIO(data))
            os.makedirs(out, exist_ok=True)
            for m in z.infolist():
                if m.is_dir():
                    continue
                parts = m.filename.split("/")
                if kind == "zip-strip":  # ffmpeg: keep only bin/*
                    if len(parts) < 3 or parts[1] != "bin":
                        continue
                    rel = parts[-1]
                else:
                    rel = "/".join(parts)
                p = os.path.join(out, rel)
                os.makedirs(os.path.dirname(p), exist_ok=True)
                open(p, "wb").write(z.read(m))
        elif kind == "tgz":
            os.makedirs(out, exist_ok=True)
            with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as t:
                t.extractall(out, filter="data")
        elif kind == "nsis":
            tmp = os.path.join(ASSETS, "_smart.exe")
            open(tmp, "wb").write(data)
            os.makedirs(out, exist_ok=True)
            subprocess.run([SEVENZIP, "e", "-y", f"-o{out}", tmp, "bin/smartctl.exe", "doc/COPYING.txt", "-r"],
                           check=True, stdout=subprocess.DEVNULL)
            os.remove(tmp)
        print(f"ok   {name}")
    write_manifest()


def walk():
    for d, _, fs in os.walk(ASSETS):
        for f in sorted(fs):
            p = os.path.join(d, f)
            rel = os.path.relpath(p, ASSETS).replace("\\", "/")
            if rel != "MANIFEST.txt":
                yield rel, p


def write_manifest():
    lines = [f"{sha(p)}  {rel}" for rel, p in sorted(walk())]
    open(os.path.join(ASSETS, "MANIFEST.txt"), "w", newline="\n").write("\n".join(lines) + "\n")
    total = sum(os.path.getsize(p) for _, p in walk())
    print(f"MANIFEST.txt: {len(lines)} files, {total/1e6:.0f} MB")


def verify():
    want = dict(l.split("  ", 1)[::-1] for l in open(os.path.join(ASSETS, "MANIFEST.txt")).read().split("\n") if l)
    bad = [rel for rel, p in walk() if want.get(rel) != sha(p)]
    missing = [r for r in want if not os.path.exists(os.path.join(ASSETS, r))]
    print(f"verify: {len(want)} listed, {len(bad)} bad, {len(missing)} missing")
    return 0 if not bad and not missing else 1


PACKS = {"win-smartctl": "win/smartctl", "win-ffmpeg": "win/ffmpeg", "win-llama-vulkan": "win/llama-vulkan",
         "win-llama-cpu": "win/llama-cpu", "model": "model"}


def packs():
    """Zip each asset folder for the GitHub release (download mode) and write packs.json (committed)."""
    import json
    dist = os.path.join(ROOT, "dist")
    os.makedirs(dist, exist_ok=True)
    meta = {}
    for name, rel in PACKS.items():
        src = os.path.join(ASSETS, rel)
        out = os.path.join(dist, name + ".zip")
        with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
            for d, _, fs in os.walk(src):
                for f in sorted(fs):
                    p = os.path.join(d, f)
                    z.write(p, os.path.relpath(p, ASSETS).replace("\\", "/"))
        meta[name] = {"file": name + ".zip", "size": os.path.getsize(out), "sha256": sha(out)}
        print(f"pack {name}: {meta[name]['size']/1e6:.0f} MB")
    open(os.path.join(ROOT, "packs.json"), "w", newline=chr(10)).write(json.dumps(meta, indent=2) + chr(10))
    print("packs.json written; upload dist/*.zip to the release 'v1'")


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--verify", action="store_true")
    ap.add_argument("--packs", action="store_true")
    a = ap.parse_args()
    if a.packs:
        sys.exit(packs() or 0)
    sys.exit(verify() if a.verify else (fetch() or 0))
