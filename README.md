# ftbc-oci-grabber

A **laptop-independent, $0** hunter that snags an Oracle Cloud **Always Free** VM for
[Faith Temple Baptist](https://github.com/RyanJamesIndangan/faithtemplebaptist) the
moment capacity opens in `ap-singapore-1`, then makes the church site go live by
itself — no personal machine involved.

## How it works

1. **`.github/workflows/oci-grab.yml`** runs on GitHub-hosted runners **every 30 min**
   (and on manual dispatch). It authenticates to Oracle with an API key held in
   encrypted Actions secrets and runs `scripts/grab.sh`.
2. **`scripts/grab.sh`** is idempotent: it first lists existing instances so it can
   **never create a second VM**, then tries to launch the free **ARM A1.Flex
   (1 OCPU / 6 GB)** across every availability domain, falling back to the **AMD
   E2.1.Micro (1 OCPU / 1 GB)**. "Out of host capacity" / rate-limit responses are
   expected no-ops — it just exits green and tries again next tick. Auth/image/shape
   errors exit **non-zero** so a real misconfiguration surfaces (ntfy + Actions email)
   instead of masquerading as "no capacity".
3. On a win, the VM boots **`scripts/cloud-init.yaml`**, which clones the app over SSH
   with a **read-only deploy key** and runs the app's own
   [`deploy/server-setup.sh`](https://github.com/RyanJamesIndangan/faithtemplebaptist/blob/main/deploy/server-setup.sh)
   (PHP 8.3, MySQL, Nginx, Composer, Node, the `queue:work` systemd worker, the
   scheduler cron, and the first deploy).
4. You get a **phone push** at every milestone via [ntfy.sh](https://ntfy.sh) —
   *VM acquired → provisioned → LIVE* — plus a failure alert if a run errors.
5. **`.github/workflows/keepalive.yml`** commits a heartbeat every ~25 days so GitHub
   never auto-disables the schedule.

## Why $0, guaranteed

- **This repo is public** → **unlimited** GitHub Actions minutes (no budget to blow).
- Oracle side is pinned to **Always Free** shapes/sizes only: A1.Flex 1 OCPU/6 GB
  (within the 4 OCPU / 24 GB free ARM aggregate), or E2.1.Micro; the default ~47 GB
  boot volume (< 200 GB free cap); an ephemeral public IP (free). No NAT gateway, load
  balancer, reserved IP, or extra block volume is ever requested. A non-upgraded Free
  Tier account **cannot be billed**. (Optional tripwire: set a $0.01 Budget alert in
  the OCI console.)

## The only manual step

**Subscribe to the notification topic on your phone.** Install the free **ntfy** app
([Android](https://play.google.com/store/apps/details?id=io.heckel.ntfy) /
[iOS](https://apps.apple.com/us/app/ntfy/id1625396347)), tap **+**, and subscribe to
the topic stored in the `NTFY_TOPIC` secret. That's where "VM ACQUIRED" and "FTBC LIVE"
land. (Everything else is automatic; the Actions log is a backup record.)

## Secrets (all set via `gh secret set`)

| Secret | Purpose |
|---|---|
| `OCI_USER_OCID`, `OCI_TENANCY_OCID`, `OCI_FINGERPRINT`, `OCI_KEY_PEM` | OCI API auth (key never touches disk) |
| `OCI_COMPARTMENT_OCID`, `OCI_SUBNET_OCID` | where/into-what to launch |
| `OCI_IMAGE_ARM`, `OCI_IMAGE_AMD` | Ubuntu images for each shape |
| `VM_SSH_PUBLIC_KEY`, `VM_SSH_PRIVATE_KEY` | VM login key (runner SSHes in to verify) |
| `VM_DEPLOY_KEY` | read-only SSH deploy key the VM uses to clone the private app repo |
| `NTFY_TOPIC` | private ntfy.sh push channel |

## Manual controls

- **Force a try now:** Actions → *oci-grab* → **Run workflow** (also proves auth).
- **Stop hunting:** disable the *oci-grab* workflow in the Actions tab.
- **After a win**, to enable push-to-deploy for future updates, set `SSH_HOST`
  (the VM IP), `SSH_USER=ubuntu`, `SSH_KEY` (the deploy/login key) and the
  `DEPLOY_ENABLED=true` variable on the app repo — its dormant `deploy.yml` then
  redeploys on every push to `main`.
