#!/usr/bin/env bash
# Idempotent Oracle Cloud "Always Free" grabber.
#   exit 0 = handled (won | no capacity | already own one).
#   exit 1 = misconfig (auth/image/shape) — surfaces loudly so it can't masquerade
#            as "no capacity".
# Preference order: ARM VM.Standard.A1.Flex (1 OCPU / 6 GB) across every AD, then
# AMD VM.Standard.E2.1.Micro across every AD.
set -uo pipefail

DN="${DISPLAY_NAME:-ftbc-prod}"
OUT="${GITHUB_OUTPUT:-/dev/null}"
log() { printf '%s %s\n' "$(date -u +%H:%M:%S)" "$*"; }

# 1) IDEMPOTENCY — re-derive truth from OCI every run, so a re-run / double-fire /
#    lost state can NEVER create a second VM.
existing=$(oci compute instance list --compartment-id "$COMPARTMENT_OCID" --all \
  --query "data[?\"display-name\"=='$DN' && \"lifecycle-state\"!='TERMINATED' && \"lifecycle-state\"!='TERMINATING'].id | [0]" \
  --raw-output 2>/dev/null || true)
if [ -n "${existing:-}" ] && [ "$existing" != "null" ]; then
  log "Already own $existing — nothing to do."
  { echo "launched=false"; echo "instance_ocid=$existing"; } >> "$OUT"
  exit 0
fi

# 2) Render cloud-init: inject the read-only SSH deploy key (base64, one line) and
#    the ntfy topic. The rendered file is only ever passed to OCI as instance
#    user-data — the private key is never committed to this (public) repo.
if [ -z "${VM_DEPLOY_KEY:-}" ]; then log "FATAL: VM_DEPLOY_KEY secret is empty"; exit 1; fi
DEPLOY_KEY_B64="$(printf '%s' "$VM_DEPLOY_KEY" | base64 -w0)"
sed -e "s|__DEPLOY_KEY_B64__|${DEPLOY_KEY_B64}|" \
    -e "s|__NTFY_TOPIC__|${NTFY_TOPIC}|" \
    scripts/cloud-init.yaml > rendered-cloud-init.yaml

# 3) Availability domains (capacity is per-AD, so iterate them all).
mapfile -t ADS < <(oci iam availability-domain list --compartment-id "$COMPARTMENT_OCID" \
                   --query 'data[].name' --raw-output 2>/dev/null | tr -d '[]," ' | grep -v '^$')
[ "${#ADS[@]}" -gt 0 ] || { log "FATAL: no availability domains (auth/region?)"; exit 1; }
log "ADs: ${ADS[*]}"

NEW_OCID=""
launch() {  # $1 shape  $2 image  $3 ad  [extra args…]
  local shape="$1" image="$2" ad="$3"; shift 3
  local out rc
  # No duplicate risk: the pre-launch instance-list guard (step 1) + the workflow's
  # `concurrency` group mean a re-run always reconciles against reality first, so a
  # second VM can never be created even if a reply is lost mid-launch.
  log "try $shape @ $ad"
  out=$(oci compute instance launch \
        --availability-domain "$ad" --compartment-id "$COMPARTMENT_OCID" \
        --shape "$shape" "$@" --image-id "$image" --subnet-id "$SUBNET_OCID" \
        --assign-public-ip true --ssh-authorized-keys-file vm_login.pub \
        --user-data-file rendered-cloud-init.yaml --display-name "$DN" \
        --query 'data.id' --raw-output 2>&1); rc=$?
  if [ $rc -eq 0 ] && [ -n "$out" ] && [[ "$out" == ocid1.instance* ]]; then
    NEW_OCID="$out"; return 0
  fi
  if grep -qiE 'Out of host capacity|InternalError|"status": 500|TooManyRequests|"status": 429|Too many requests' <<<"$out"; then
    log "  busy/throttled — retry next tick"; sleep 4; return 1
  fi
  if grep -qiE 'LimitExceeded|QuotaExceeded' <<<"$out"; then
    log "  at free quota (likely already have one) — stop"; return 3
  fi
  log "!! UNEXPECTED (misconfig — auth/image/shape?):"; printf '%s\n' "$out" >&2; return 2
}

# ARM A1.Flex (preferred) across all ADs, then AMD E2.1.Micro across all ADs.
for ad in "${ADS[@]}"; do
  launch "VM.Standard.A1.Flex" "$IMAGE_ARM" "$ad" --shape-config '{"ocpus":1,"memoryInGBs":6}'
  case $? in 0) break;; 2) exit 1;; 3) exit 0;; esac
done
if [ -z "$NEW_OCID" ]; then
  for ad in "${ADS[@]}"; do
    launch "VM.Standard.E2.1.Micro" "$IMAGE_AMD" "$ad"
    case $? in 0) break;; 2) exit 1;; 3) exit 0;; esac
  done
fi

if [ -n "$NEW_OCID" ]; then
  log "WON $NEW_OCID"
  { echo "launched=true"; echo "instance_ocid=$NEW_OCID"; } >> "$OUT"
else
  log "No capacity this round."
  echo "launched=false" >> "$OUT"
fi
exit 0
