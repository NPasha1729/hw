#!/bin/bash
# hw - used machine inspection kit, macOS + Linux BASIC version (Phase A facts + optional LLM bench).
# Run:  bash <(curl -sL https://raw.githubusercontent.com/NPasha1729/hw/main/go.sh)
#   or from the USB stick:  bash /Volumes/HW/go.sh   (Linux: bash /media/$USER/HW/go.sh)
# bash 3.2 compatible (macOS default). Prompts read from /dev/tty so curl | bash still works.
# STATUS: macOS path UNTESTED on real hardware. Linux path tested under WSL.

KIT_VERSION="1.0.0"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
OS="$(uname -s)"
NOW="$(date +%Y%m%d-%H%M)"
TTY=/dev/tty
[ -r "$TTY" ] || TTY=/dev/null
AUTO="${HW_AUTO:-0}"

ask() { # ask "prompt" default
  local a=""
  if [ "$AUTO" = "1" ]; then echo "$2"; return; fi
  printf "%s [%s]: " "$1" "$2" > /dev/tty 2>/dev/null || printf "%s: " "$1"
  read -r a < "$TTY" || a=""
  [ -z "$a" ] && a="$2"
  echo "$a"
}
clean() { printf "%s" "$1" | tr -cd '\40-\176' | cut -c1-120; }

echo ""
echo "=============================================="
echo "  hw - used machine inspection kit v$KIT_VERSION ($OS, basic)"
echo "=============================================="
echo "Nothing is uploaded. This reads the machine and writes a report."
echo ""

LABEL="$(ask '  Shop / stall name' unnamed)"
PRICE="$(ask '  Asking price (INR)' '')"
C_MODEL="$(ask '  Model the seller claims' '')"
C_CHIP="$(ask '  CPU / chip claimed (e.g. M1 Pro, i7-11800H)' '')"
C_RAM="$(ask '  RAM GB claimed' '')"
C_SSD="$(ask '  Storage GB claimed' '')"
C_AGE="$(ask '  Age in years claimed' '')"

OUTBASE="${HW_OUT:-}"
if [ -z "$OUTBASE" ]; then
  if [ -n "$HERE" ] && [ -w "$HERE" ] && [ -d "$HERE/lib" ]; then OUTBASE="$HERE/reports"; else OUTBASE="$HOME/Desktop/hw-reports"; fi
fi

FLAGS=""
flag() { FLAGS="$FLAGS
- [$1] $2"; }

if [ "$OS" = "Darwin" ]; then
  HW="$(system_profiler SPHardwareDataType 2>/dev/null)"
  pick() { printf "%s\n" "$HW" | awk -F': ' -v k="$1" '$0 ~ k {print $2; exit}'; }
  MODEL="$(clean "$(pick 'Model Name')")"
  MODEL_ID="$(clean "$(pick 'Model Identifier')")"
  CHIP="$(clean "$(pick 'Chip')")"; [ -z "$CHIP" ] && CHIP="$(clean "$(pick 'Processor Name')")"
  CORES="$(clean "$(pick 'Total Number of Cores')")"
  RAM="$(clean "$(pick 'Memory')")"
  SERIAL="$(clean "$(pick 'Serial Number')")"
  ALOCK="$(clean "$(pick 'Activation Lock Status')")"
  POWER="$(system_profiler SPPowerDataType 2>/dev/null)"
  CYCLES="$(printf "%s\n" "$POWER" | awk -F': ' '/Cycle Count/ {print $2; exit}')"
  CONDITION="$(printf "%s\n" "$POWER" | awk -F': ' '/Condition/ {print $2; exit}')"
  MAXCAP="$(printf "%s\n" "$POWER" | awk -F': ' '/Maximum Capacity/ {print $2; exit}')"
  NVME="$(system_profiler SPNVMeDataType 2>/dev/null | awk -F': ' '/Model|Capacity|S.M.A.R.T./ {printf "%s; ", $0}')"
  [ -z "$NVME" ] && NVME="$(system_profiler SPStorageDataType 2>/dev/null | awk -F': ' '/Device Name|Capacity|S.M.A.R.T./ {printf "%s; ", $0}')"
  MDM="$(profiles status -type enrollment 2>/dev/null | tr '\n' ' ')"
  OSVER="$(sw_vers -productVersion 2>/dev/null)"
  GPU="$(system_profiler SPDisplaysDataType 2>/dev/null | awk -F': ' '/Chipset Model|Total Number of Cores|VRAM/ {printf "%s; ", $0}')"
  USERS="$(dscl . list /Users 2>/dev/null | grep -v '^_' | grep -vE '^(daemon|nobody|root|Guest)$' | wc -l | tr -d ' ')"
  case "$ALOCK" in *Enabled*) flag RED "Activation Lock is ENABLED: the seller must sign out of iCloud/Find My in front of you";; esac
  case "$MDM" in *"MDM enrollment: Yes"*|*"Enrolled via DEP: Yes"*) flag RED "Mac is enrolled in company device management (MDM/DEP)";; esac
  case "$CONDITION" in *Service*|*Replace*) flag AMBER "Battery condition: $CONDITION";; esac
  if [ -n "$CYCLES" ] && [ "$CYCLES" -gt 800 ] 2>/dev/null; then flag AMBER "Battery has $CYCLES cycles (Apple rates ~1000)"; fi
  [ "$USERS" -gt 2 ] 2>/dev/null && flag AMBER "$USERS user accounts on this Mac"
  case "$CHIP" in *Intel*) flag AMBER "Intel Mac: near the end of macOS support, weak for local AI";; esac
  if [ -n "$C_CHIP" ] && ! printf "%s" "$CHIP" | grep -qi "$(printf "%s" "$C_CHIP" | sed 's/[^A-Za-z0-9 ]//g')"; then flag RED "Chip is '$CHIP', not '$C_CHIP'"; fi
  ARCH="$(uname -m)"
  LLAMA_DIR="$HERE/assets/mac/llama-arm64"; [ "$ARCH" = "x86_64" ] && LLAMA_DIR="$HERE/assets/mac/llama-x64"
else
  MODEL="$(clean "$(cat /sys/class/dmi/id/product_name 2>/dev/null)")"
  MODEL_ID="$(clean "$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null)")"
  CHIP="$(clean "$(awk -F': ' '/model name/ {print $2; exit}' /proc/cpuinfo 2>/dev/null)")"
  CORES="$(nproc 2>/dev/null)"
  RAM="$(awk '/MemTotal/ {printf "%.0f GB", $2/1048576}' /proc/meminfo 2>/dev/null)"
  SERIAL="$(clean "$(cat /sys/class/dmi/id/product_serial 2>/dev/null)")"; [ -z "$SERIAL" ] && SERIAL="UNKNOWN(needs root)"
  ALOCK="n/a"; MDM="n/a"
  BAT="$(ls -d /sys/class/power_supply/BAT* 2>/dev/null | head -1)"
  if [ -n "$BAT" ]; then
    CYCLES="$(cat "$BAT/cycle_count" 2>/dev/null)"
    F="$(cat "$BAT/energy_full" 2>/dev/null || cat "$BAT/charge_full" 2>/dev/null)"
    D="$(cat "$BAT/energy_full_design" 2>/dev/null || cat "$BAT/charge_full_design" 2>/dev/null)"
    if [ -n "$F" ] && [ -n "$D" ] && [ "$D" -gt 0 ] 2>/dev/null; then MAXCAP="$((100 * F / D))%"; fi
  fi
  NVME="$(lsblk -d -o NAME,MODEL,SIZE,ROTA 2>/dev/null | tr '\n' ';')"
  OSVER="$(. /etc/os-release 2>/dev/null; echo "$PRETTY_NAME")"
  GPU="$(lspci 2>/dev/null | grep -iE 'vga|3d|display' | tr '\n' ';')"
  USERS="$(awk -F: '$3>=1000 && $3<60000' /etc/passwd 2>/dev/null | wc -l | tr -d ' ')"
  LLAMA_DIR=""
fi

MAXNUM="$(printf "%s" "$MAXCAP" | tr -cd '0-9')"
if [ -n "$MAXNUM" ]; then
  if [ "$MAXNUM" -lt 60 ]; then flag RED "Battery holds $MAXCAP of original capacity"; elif [ "$MAXNUM" -lt 80 ]; then flag AMBER "Battery holds $MAXCAP of original capacity"; fi
fi
RAMNUM="$(printf "%s" "$RAM" | tr -cd '0-9')"
if [ -n "$C_RAM" ] && [ -n "$RAMNUM" ] && [ "$RAMNUM" != "$C_RAM" ]; then flag RED "RAM is $RAM, not $C_RAM GB"; fi

# Optional LLM bench (Mac only, needs the USB assets)
LLM="not run"
MODEL_FILE="$HERE/assets/model/qwen2.5-0.5b-q4km.gguf"
if [ -n "$LLAMA_DIR" ] && [ -f "$MODEL_FILE" ]; then
  LB="$(find "$LLAMA_DIR" -name llama-bench -type f 2>/dev/null | head -1)"
  if [ -n "$LB" ] && [ "$(ask '  Run the 2-minute local AI benchmark? (y/n)' y)" = "y" ]; then
    T="$(mktemp -d)"; cp -R "$(dirname "$LB")/." "$T/"
    xattr -dr com.apple.quarantine "$T" 2>/dev/null; codesign -s - --force "$T/llama-bench" 2>/dev/null
    for f in "$T"/*.dylib; do [ -f "$f" ] && codesign -s - --force "$f" 2>/dev/null; done
    LLM="$("$T/llama-bench" -m "$MODEL_FILE" -p 256 -n 64 -r 2 -o md 2>/dev/null | grep -E '^\|' | tail -2 | tr '\n' ' ')"
    [ -z "$LLM" ] && LLM="failed (Gatekeeper may have blocked it)"
    rm -rf "$T"
  fi
fi

VERDICT="GREEN"
case "$FLAGS" in *"[AMBER]"*) VERDICT="AMBER";; esac
case "$FLAGS" in *"[RED]"*) VERDICT="RED";; esac
case "$SERIAL" in UNKNOWN*|"") [ "$VERDICT" = "GREEN" ] && VERDICT="INCOMPLETE";; esac

S4="$(printf "%s" "$SERIAL" | tail -c 4)"; case "$SERIAL" in UNKNOWN*|"") S4="UNKNOWN";; esac
M4="$MODEL"; [ -z "$M4" ] && M4="UNKNOWN"
SAFE="$(printf "%s-%s" "$M4" "$S4" | tr -c 'A-Za-z0-9' '-' | cut -c1-40)"
DIR="$OUTBASE/hw-$SAFE-$NOW"
mkdir -p "$DIR" 2>/dev/null || { DIR="/tmp/hw-$SAFE-$NOW"; mkdir -p "$DIR"; }
R="$DIR/REPORT.md"
{
  echo "# hw inspection report (basic, $OS)"
  echo ""
  echo "Machine: $MODEL ($MODEL_ID) | label: $LABEL | asking price: $PRICE | kit v$KIT_VERSION | $(date)"
  echo ""
  echo "## Stall summary"
  echo ""
  echo "**VERDICT: $VERDICT** (basic checks only: no disk-wear or load tests on this OS)"
  echo "$FLAGS"
  [ -z "$FLAGS" ] && echo "- no red or amber findings from the basic checks"
  echo ""
  echo "Stall rule if you cannot reach Claude: RED = walk. AMBER/INCOMPLETE = ask for a written 3-day return window, else walk. GREEN = negotiate."
  echo ""
  echo "## Claims vs facts"
  echo ""
  echo "| What | Seller said | Measured |"
  echo "|---|---|---|"
  echo "| Model | $C_MODEL | $MODEL ($MODEL_ID) |"
  echo "| Chip | $C_CHIP | $CHIP ($CORES cores) |"
  echo "| RAM | $C_RAM GB | $RAM |"
  echo "| Storage | $C_SSD GB | $NVME |"
  echo "| Age | $C_AGE years | look up the model identifier's release year |"
  echo ""
  echo "## Key facts"
  echo ""
  echo "- Serial: $SERIAL (check it on checkcoverage.apple.com / the maker's site; compare with the sticker)"
  echo "- OS: $OSVER"
  echo "- GPU: $GPU"
  echo "- Activation Lock: $ALOCK"
  echo "- MDM: $MDM"
  echo "- Battery: cycles $CYCLES, condition $CONDITION, max capacity $MAXCAP"
  echo "- User accounts: $USERS"
  echo "- LLM bench: $LLM"
  echo ""
  echo "## Instructions for Claude"
  echo ""
  [ -f "$HERE/PROMPT.md" ] && cat "$HERE/PROMPT.md"
} > "$R"

echo ""
echo "  VERDICT: $VERDICT"
printf "%s\n" "$FLAGS"
echo ""
echo "Report saved: $R"
