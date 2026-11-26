"""hw kit lint. Exit 0 = clean.
Checks: ASCII-only scripts, CRLF for .cmd, PowerShell parse errors, PowerShell case-clashing variable
names ($f vs $F are the SAME variable - this bit us twice), bash -n for go.sh, no reports/assets tracked.
"""
import os, re, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
AUTO = {"_", "null", "true", "false", "args", "input", "env", "error", "host", "matches", "pscmdlet", "psscriptroot",
        "executioncontext", "lastexitcode", "pscommandpath", "myinvocation", "home", "pwd", "profile", "this"}
fails = []


def files(exts):
    for d, dirs, fs in os.walk(ROOT):
        dirs[:] = [x for x in dirs if x not in (".git", "assets", "reports", "__pycache__")]
        for f in fs:
            if os.path.splitext(f)[1].lower() in exts:
                yield os.path.join(d, f)


for p in files({".ps1", ".cmd", ".sh", ".html", ".md"}):
    b = open(p, "rb").read()
    rel = os.path.relpath(p, ROOT)
    bad = [i for i, c in enumerate(b) if c > 126 or (c < 32 and c not in (9, 10, 13))]
    if bad:
        line = b[: bad[0]].count(b"\n") + 1
        fails.append(f"{rel}:{line}: non-ASCII byte 0x{b[bad[0]]:02x}")
    if p.endswith(".cmd") and b"\n" in b.replace(b"\r\n", b""):
        fails.append(f"{rel}: .cmd must use CRLF line endings")

for p in files({".ps1"}):
    rel = os.path.relpath(p, ROOT)
    src = open(p, encoding="ascii", errors="replace").read()
    code = re.sub(r"#.*", "", src)
    names = {}
    for m in re.finditer(r"\$(?:script:|global:)?([A-Za-z_][A-Za-z0-9_]*)", code):
        n = m.group(1)
        if n.lower() in AUTO:
            continue
        names.setdefault(n.lower(), set()).add(n)
    for k, v in sorted(names.items()):
        if len(v) > 1:
            fails.append(f"{rel}: case-clashing variables {sorted(v)} are ONE variable in PowerShell")
    cmd = ["powershell", "-NoProfile", "-Command",
           "$e=$null;[void][System.Management.Automation.Language.Parser]::ParseFile('%s',[ref]$null,[ref]$e);$e|%%{$_.Extent.StartLineNumber.ToString()+': '+$_.Message}" % p]
    out = subprocess.run(cmd, capture_output=True, text=True).stdout.strip()
    if out:
        fails.append(f"{rel}: parse errors:\n{out}")

sh = os.path.join(ROOT, "go.sh")
if os.path.exists(sh):
    gb = os.path.join(os.environ.get("ProgramFiles", "C:/Program Files"), "Git", "bin", "bash.exe")
    bash = gb if os.path.exists(gb) else "bash"  # System32 bash.exe is WSL, not Git Bash
    r = subprocess.run([bash, "-n", sh], capture_output=True, text=True)
    if r.returncode:
        fails.append("go.sh: bash -n: " + r.stderr.strip())

r = subprocess.run(["git", "-C", ROOT, "ls-files"], capture_output=True, text=True)
for f in r.stdout.split():
    if f.startswith(("assets/", "reports/")) or "hw-report" in f or f.endswith((".exe", ".dll", ".gguf", ".zip")):
        fails.append(f"tracked file must not be committed: {f}")

for f in fails:
    print("FAIL", f)
print(f"lint: {len(fails)} problem(s)")
sys.exit(1 if fails else 0)
