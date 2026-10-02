#!/usr/bin/env bash
# vm-egress-status — print the guest's egress posture as a one-glyph
# status-bar segment, or nothing when run outside a vm-launcher guest.
#
# This is the single source of truth for the egress indicator the Claude
# status bar (and any other statusline) shows inside the VM. It is shipped
# on the guest PATH by nix/guest/_guest.nix; a host statusline calls it
# guarded (`command -v vm-egress-status && vm-egress-status`) so the segment
# renders inside the guest and is a silent no-op on the host.
#
# Posture only — matches the guest MOTD convention (red == unfenced). A
# constant cloud (☁) marks the segment as "egress"; a state glyph qualifies
# it (◉ closed/fenced, ○ wide open, ✈ airgap/no network, ⚠ fence broken).
# Glyphs use VS15 (U+FE0E) to force the small text form, not the big emoji.
set -u

# The vmcfg share mounts this in the guest and carries .egress.mode; it does
# NOT exist on the host, so outside a VM we print nothing and exit clean.
vm_policy="/etc/vm-launcher/microvm-loaded.json"
[ -f "$vm_policy" ] || exit 0

vm_mode=$(jq -r '.egress.mode // "allowlist"' "$vm_policy" 2>/dev/null)

glb=$(printf '\xe2\x98\x81\xef\xb8\x8f')   # ☁️ cloud, EMOJI presentation (VS16)

case "$vm_mode" in
  allowlist)
    # Fenced: the in-guest MITM proxy should be listening on :3128. Probe
    # the TCP bind directly (same readiness signal the unit's ExecStartPost
    # uses); flag with ⚠ if the proxy isn't up.
    if timeout 0.3 bash -c 'exec 3<>/dev/tcp/127.0.0.1/3128' 2>/dev/null; then
      printf "\033[32m%s \xf0\x9f\x9b\xa1\xef\xb8\x8f\033[0m" "$glb"   # ☁️ 🛡 fenced
    else
      printf "\033[31m%s \xe2\x9a\xa0\xef\xb8\x8f\033[0m" "$glb"   # ☁️ ⚠️ proxy down
    fi
    ;;
  block)   printf "\033[33m%s \xe2\x9b\x94\033[0m" "$glb" ;;  # ☁️ ⛔ airgap
  noblock) printf "\033[31m%s \xf0\x9f\x8c\x90\033[0m" "$glb" ;;  # ☁️ 🌐 unfenced
  *)       printf "\033[90m%s vm:%s\033[0m" "$glb" "$vm_mode" ;;
esac
