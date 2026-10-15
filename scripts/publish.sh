#!/usr/bin/env bash
# Sanitise the latest Oxidized configs into the repo and push.
# Handles the whole chain: bare Oxidized store -> readable clone -> sanitise -> commit.
# Configs from the ENARSI lab routers (LAB_NET) go to their own folder (LAB_DIR).
# Refuses to push if a secret survives the audit.
set -euo pipefail
# your personal sanitiser rules must be present, or your own names could be published
[[ -f "$(dirname "$0")/.sanitize-private" ]] || { echo "scripts/.sanitize-private is missing - refusing to publish" >&2; exit 1; }

# --- where things live (override any of these from the environment if needed) ---
OXI_STORE="${OXI_STORE:-/opt/oxidized/output}"   # Oxidized's bare git repo
PLAIN="${PLAIN:-/tmp/oxidized-plain}"            # temporary readable copy
PUB="${PUB:-$(cd "$(dirname "$0")/.." && pwd)}"  # repo root (this script is in scripts/)
DEST="$PUB/configs"
LAB_NET="${LAB_NET:-10.99.99.}"                  # ENARSI routers' management subnet (prefix)
LAB_DIR="${LAB_DIR:-enarsi/configs}"             # their folder, relative to the repo root;
                                                 # it is wiped and rebuilt every run, so keep it for configs only
case "$LAB_DIR" in .|./|..*|/*|*/..*) echo "refusing LAB_DIR=$LAB_DIR" >&2; exit 64 ;; esac
LAB_DEST="$PUB/$LAB_DIR"

echo ">> cloning Oxidized store into a readable copy"
git config --global --add safe.directory "$OXI_STORE" 2>/dev/null || true
rm -rf "$PLAIN"
git clone --quiet "$OXI_STORE" "$PLAIN"

echo ">> sanitising into $DEST"
rm -rf "$DEST"
mkdir -p "$DEST"
"$PUB/scripts/sanitize-configs.sh" -i "$PLAIN" -o "$DEST" --audit

echo ">> moving ENARSI lab configs (${LAB_NET}*) into $LAB_DIR"
rm -rf "$LAB_DEST"
mkdir -p "$LAB_DEST"
moved=0
while IFS= read -r -d '' f; do
  name="$(basename "$f")"
  # a lab router's file is named after its management IP, or its config carries one
  if [[ "$name" == "$LAB_NET"* ]] || grep -qF "ip address $LAB_NET" "$f"; then
    if [[ -e "$LAB_DEST/$name" ]]; then
      echo "   !! two copies of $name in the Oxidized store - check it" >&2
    fi
    mv -f "$f" "$LAB_DEST/$name"
    moved=$((moved+1))
  fi
done < <(find "$DEST" -type f ! -path "$LAB_DEST/*" -print0)
find "$DEST" -mindepth 1 -type d -empty ! -path "$LAB_DEST" -delete
echo "   moved $moved file(s)"

# Oxidized saves each group in its own repo next to output/, so the ENARSI group's
# current configs are in ENARSI.git. They replace any older copies moved in above.
LAB_STORE="${LAB_STORE:-/opt/oxidized/ENARSI.git}"
if [[ -d "$LAB_STORE" ]]; then
  echo ">> adding the ENARSI group's own Oxidized repo ($LAB_STORE)"
  git config --global --get-all safe.directory 2>/dev/null | grep -qxF "$LAB_STORE" || \
    git config --global --add safe.directory "$LAB_STORE"
  rm -rf "$PLAIN-lab" "$PLAIN-lab-clean"
  git clone --quiet "$LAB_STORE" "$PLAIN-lab"
  "$PUB/scripts/sanitize-configs.sh" -i "$PLAIN-lab" -o "$PLAIN-lab-clean" --audit
  took=0
  while IFS= read -r -d '' f; do
    mv -f "$f" "$LAB_DEST/$(basename "$f")"
    took=$((took+1))
  done < <(find "$PLAIN-lab-clean" -type f -print0)
  rm -rf "$PLAIN-lab" "$PLAIN-lab-clean"
  echo "   took $took current file(s) from $LAB_STORE"
fi

echo ">> committing"
cd "$PUB"
git add -A configs/ "$LAB_DIR"
if git diff --cached --quiet -- configs/ "$LAB_DIR"; then
  echo "no changes"
else
  git commit -m "config sync $(date -u +%Y-%m-%dT%H:%MZ)"
  git push origin main
  echo "published"
fi
