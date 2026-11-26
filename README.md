# hw - check a used laptop or PC before you buy it

Run one command on the seller's machine. It reads the hardware, checks for fakes, locks, wear and
previous owners, runs optional load tests, and writes a report you paste into Claude.
Nothing is uploaded anywhere.

## Run it

**Windows, from the USB stick (best, works offline):** open the stick, double-click `go.cmd`.

**Windows, over your phone hotspot:** press Win+R, type `powershell`, Enter, then type:

    [Net.ServicePointManager]::SecurityProtocol='Tls12'; irm https://raw.githubusercontent.com/NPasha1729/hw/main/go.ps1 | iex

**Mac (basic checks):** open Terminal and type:

    bash <(curl -sL https://raw.githubusercontent.com/NPasha1729/hw/main/go.sh)

From the stick on a Mac: `bash /Volumes/HW/go.sh`

## What happens (Windows)

1. **Intake (1 min):** type what the seller claims: model, CPU, GPU, RAM, storage, age, price. Enter skips.
2. **Phase A (1 min, read-only, cannot break anything):** Windows asks for admin. Say yes (the seller may
   need to type the password) so disk wear can be read. The report is SAVED at the end of this step.
3. **Phase B (optional load tests, each one asks first):** disk speed, render benchmark, local AI
   benchmark, CPU stress (5 min), GPU stress (7 min, last because it is the one most likely to crash a bad
   machine). Answer `y` run, `s` skip, `q` stop. If the machine crashes, run the kit again: it reports the crash.
4. **Phase C (manual):** screen, keyboard, speakers, ports, charger, hinge, sticker serial, paperwork.

The screen ends with **GREEN / AMBER / RED / INCOMPLETE** and the top reasons.

## After it finishes

- The report is in `reports\` on the USB stick (or `hw-reports` on the Desktop). Copy the folder to your
  phone (USB OTG cable) and paste `REPORT.md` into Claude. **Never log into Claude on the seller's machine.**
- Several machines? Paste all reports in one chat; Claude makes a comparison table.
- Can't reach Claude at the stall: **RED = walk. AMBER or INCOMPLETE = ask for a written 3-day return
  window, else walk. GREEN = negotiate** using the "Negotiate" lines.
- If you joined the seller's PC to your hotspot: forget that Wi-Fi network on their PC before leaving.

## If something fails

The kit already falls back on its own. This is what it does, and what you do when it cannot.

| What fails | What the kit does next (automatic) | Tested |
|---|---|---|
| Script files blocked by policy (company PC) | Loads the kit into memory instead and carries on | yes (S2, S18) |
| PowerShell missing or broken | Runs `fallback.cmd`: basic facts + serial to `hw-basic-*.txt` on the Desktop | yes (S3) |
| PowerShell locked down (Constrained Language) | Runs `fallback.cmd` | simulated (S4) |
| Very old PowerShell (Windows 7/8) | Runs `fallback.cmd` | logic only |
| You opened `go.cmd` inside a ZIP | Tells you to "Extract All" first | yes (S5) |
| Folder name has spaces or ( ) | Works | yes (S6) |
| Can't write the report to the stick | Saves to Desktop\hw-reports, then %TEMP%\hw-reports, and says where | yes (S7) |
| Machine check hangs (broken WMI) | Stops after 4 min, keeps everything found so far, marks INCOMPLETE | yes (S8) |
| Admin prompt refused | Carries on without admin; disk wear = INCOMPLETE | logic only |
| One-liner: no internet / GitHub blocked | Says "use the USB stick" | yes (S12) |
| One-liner: a benchmark download fails | Skips that test, report still made | yes (S11) |
| A download or a file on the stick was altered | Refuses to run it (SHA256 check) | yes (S10, S17) |
| Window closed / killed mid-test | Next run kills leftover processes, puts sleep settings back, says which test it stopped in | yes (S13) |
| Machine reboots or dies during a load test | Next run reports it: RED, or AMBER if it was on battery | yes (S15, S16) |
| Edge will not open the GPU test | Tries Chrome, then Brave | yes (S14) |
| GPU test window covered by another window | Keeps rendering; warns if it really goes hidden | yes |
| Tool blocked by Smart App Control / antivirus | That test reports why; Phase A still complete | logic only |

When the kit itself cannot help:

| Problem | Do this |
|---|---|
| `go.cmd` flashes and closes | Open PowerShell, run `powershell -ep bypass -f D:\go.ps1` (D: = the stick) |
| One-liner: "underlying connection was closed" | You missed the `[Net.ServicePointManager]...` part; type the whole line |
| Machine won't boot / login unknown / freshly reset | No history to check = AMBER at best. BIOS screen (F2/F10/Del): CPU, RAM, serial; photo it |
| Mac at the setup screen asking for an Apple ID | Activation Lock: **RED, do not buy** until the seller removes it in front of you |

Battle test (developers): `powershell -ep bypass -f tests\scenarios.ps1` forces every row marked "yes" above and checks the fallback.

## Say this to the seller (if they ask)

- EN: "This is a read-only check of the hardware. Nothing is installed or uploaded. The speed test makes a
  temporary file and deletes it."
- HI: "Yeh sirf hardware check karta hai. Kuch install ya upload nahi hota. Speed test ek temporary file
  banata hai aur delete kar deta hai."
- KN: "Idu hardware check maatra maadutte. Enu install athava upload aagalla. Speed test ondu temporary file
  maadi delete maadutte."

## Before you pay

- Get a bill or a handwritten receipt with the serial number and a 3-day return promise.
- After buying: run the kit again at home on day 1 and day 7 and compare with the stall report.

## The USB stick

Make it once on your own PC: format the stick as **exFAT**, label `HW`, then copy this whole folder plus
`assets\` onto it (`python tools/fetch_assets.py` downloads the benchmark tools, about 1 GB).
The kit copies itself to the seller's temp folder before running, writes reports to `reports\`, and never
runs anything back on your own PC. Before reusing the stick on your PC, scan it with Windows Security and
copy out only the `reports` folder.

## For developers

- `python tools/lint.py` - ASCII, CRLF for .cmd, PowerShell parse, case-clashing variables, bash -n, nothing
  binary tracked.
- `python tools/fetch_assets.py [--verify]` - pinned downloads + `assets/MANIFEST.txt` SHA256 list.
- Test without prompts: `powershell -ep bypass -f go.ps1 -Auto -Use all -Tests disk,render,llm,cpu,gpu -Quick -OutRoot C:\tmp\out`
- SPEC.md is the probe/threshold table. LICENSES.md lists third-party licences.
