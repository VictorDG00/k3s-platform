# Restore runbook

What the `k3s-backup` CronJob (`terraform/10-platform/backup.tf`) writes, and how
to bring a node back from it. Written from what the job actually does.

## What is backed up

Every day at 04:10 UTC the job uploads one directory,
`offsite:example-backups/k3s/<UTC timestamp>/`, containing:

| File | What it is | Why it matters |
|---|---|---|
| `sealed-secrets-keys.json` | All sealed-secrets master keys (a Secret list, JSON) | Without them no SealedSecret in git can be opened |
| `state.db` | Consistent online copy of the k3s sqlite datastore (`.backup`, `integrity_check` must return `ok`) | Cluster state |
| `token` | k3s server token | Must match the `state.db` it was saved with |
| `encryption-config.json` | Secrets-at-rest encryption config | `secrets-encryption` is on: without it a restored `state.db` cannot decrypt Secrets |
| `tls.tgz` | `server/tls` (cluster CA, ServiceAccount signing key) | Without it a restore creates a new CA and invalidates kubeconfigs and pod tokens |

Not in this backup: PVC data of the monitoring stack (observability only,
rebuilt from scratch) and application data. Back up application databases
separately (e.g. `pg_dump` to the same encrypted remote).

## How the backup is protected

- Client-side encryption: the remote `offsite` is an rclone `crypt` remote over
  the S3-compatible bucket. The bucket only ever sees ciphertext.
- `rclone copy --immutable`, never `sync`: an existing object is never
  overwritten, and nothing in the job deletes anything remotely.
- The bucket has object lock (30-day retention), so even leaked write
  credentials cannot remove recent backups.
- `rclone cryptcheck --one-way` after upload verifies content, not just size.
- A torn sqlite copy fails `PRAGMA integrity_check` and fails the job.
- The job runs with all k3s hostPaths read-only, no capabilities, and the
  upload container non-root.

## One-time setup (outside Terraform)

The rclone config holds the crypt passwords, so it must never enter Terraform
state. Create the Secret by hand:

```bash
# 1. on the operator machine: configure an S3 remote (`remote`) and a crypt
#    remote named `offsite` layered over remote:example-backups
rclone config
# 2. load the resulting file as the Secret the CronJob mounts
kubectl -n backup create secret generic rclone-offsite --from-file=rclone.conf=$HOME/.config/rclone/rclone.conf
# 3. run the job once and check it ends with "k3s-backup: ok <dest>"
kubectl -n backup create job k3s-backup-manual --from=cronjob/k3s-backup
kubectl -n backup logs job/k3s-backup-manual -c upload
```

Keep an offline copy of the rclone crypt passwords: without them the backup is
unreadable. Store them somewhere that is not on the node.

## Restore the sealed-secrets keys

Needed on a new cluster, or when the controller was reinstalled, before
applying any SealedSecret.

```bash
rclone copy offsite:example-backups/k3s/<timestamp>/sealed-secrets-keys.json .
# drop the fields `kubectl apply` does not accept, then apply
jq '.items | map(del(.metadata.resourceVersion,.metadata.uid,.metadata.creationTimestamp,.metadata.managedFields)) | {apiVersion:"v1",kind:"List",items:.}' sealed-secrets-keys.json | kubectl apply -f -
kubectl -n sealed-secrets rollout restart deploy/sealed-secrets-controller
```

Expected: one `secret/sealed-secrets-key... created` per key; the controller
logs show the restored keys being registered.

## Restore the k3s datastore

For a fresh node, or a corrupted `state.db`. Use the same k3s version and the
same `/etc/rancher/k3s/config.yaml` (`host/k3s/`), and the `token`,
`encryption-config.json` and `tls.tgz` from the same timestamp as `state.db`.
With k3s stopped:

```bash
sudo systemctl stop k3s
rclone copy offsite:example-backups/k3s/<timestamp>/ /tmp/k3s-restore/
S=/var/lib/rancher/k3s/server
sudo mkdir -p $S/db $S/cred
sudo mv $S/db/state.db $S/db/state.db.bad 2>/dev/null; sudo rm -f $S/db/state.db-wal $S/db/state.db-shm
sudo install -m 600 /tmp/k3s-restore/state.db $S/db/state.db
sudo install -m 600 /tmp/k3s-restore/token $S/token
sudo install -m 600 /tmp/k3s-restore/encryption-config.json $S/cred/encryption-config.json
sudo tar xzf /tmp/k3s-restore/tls.tgz -C $S
sudo systemctl start k3s
```

If `state.db` and `tls.tgz` are restored together, existing kubeconfigs stay
valid. Then check `kubectl get nodes` and `kubectl get pods -A`, and clean up
`/tmp/k3s-restore/` (it holds the datastore and keys in clear text).

## Order for a full rebuild

1. `host/k3s/install.sh` (pinned version, same config).
2. Restore the datastore (above), or start empty and restore only the
   sealed-secrets keys.
3. `terraform apply` in `10-platform`, then `20-apps`.
4. Restore application data from its own backups.
