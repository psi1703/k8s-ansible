# Repo sync and operator workflow

This document explains how repository updates move from GitHub to the OTP Relay Kubernetes build/control host.

The repository sync layer is intentionally separate from deployment. It updates local source files only. It does not install Kubernetes, run Ansible, apply manifests, restart pods, install Helm charts, or deploy OTP Relay automatically.

---

## Layer purpose

The repo-sync layer keeps the server checkout aligned with GitHub while preserving local runtime and generated artifacts.

It supports the current operator workflow:

```text
edit files in GitHub
  -> run or schedule scripts/sync-repo.sh on the server
  -> review changed files if needed
  -> run setup.sh or install-otp-relay-k8s.sh deliberately
```

This is different from a GitHub Actions deployment runner model.

In this repository, syncing code and deploying code are separate actions.

---

## Why this exists

The project previously used a GitHub Actions self-hosted runner model for deployment.

The current model avoids automatic deployment from every repository change. This is safer for the multi-node Kubernetes environment because documentation updates, generated-file cleanup, observability changes, and infrastructure edits should not silently mutate the live cluster.

The repo-sync model gives the operator a controlled sequence:

```text
1. Update source of truth in GitHub.
2. Sync the local checkout.
3. Inspect or validate if needed.
4. Run the installer/deployer intentionally.
```

---

## Main files

```text
scripts/sync-repo.sh
  Performs the local checkout sync.

scripts/install-repo-sync-timer.sh
  Installs or updates the optional systemd timer that runs repo sync.

systemd/README-repo-sync-timer
  Explains the timer model and safety boundary.

setup.sh
  Operator entrypoint for setup/deploy after sync.

install-otp-relay-k8s.sh
  Local Kubernetes deployment entrypoint used by setup.sh.
```

---

## Safety boundary

The sync script may:

```text
fetch origin/main
reset the local checkout to origin/main
clean untracked repository files
preserve configured runtime/generated paths
restore executable bits for repository shell scripts
write sync state markers
mark generated help docs for rebuild when help source changed
```

The sync script must not:

```text
run setup.sh
run install-otp-relay-k8s.sh
run Ansible playbooks
install or remove K3s
run Helm install/upgrade
run kubectl apply
restart pods or deployments
build or import container images
install GitHub runners
change live Kubernetes state
```

This boundary is deliberate. Repository sync is not deployment.

---

## Preserved local paths

The sync script must preserve local runtime and generated paths that are not normal source edits.

Expected preserved paths include:

```text
.env
automation/ansible/inventory.generated.ini
automation/libvirt/build/
dist/
release/
.sync-state/
.venv/
venv/
node_modules/
frontend/help/
frontend/app.js
install-report.txt
```

These paths exist for different reasons:

```text
.env
  Local operator/runtime configuration. It must not be overwritten by sync.

automation/ansible/inventory.generated.ini
  Generated inventory from the VM provisioner.

automation/libvirt/build/
  Generated VM/provisioning artifacts.

dist/ and release/
  Build and release output.

.sync-state/
  Repo-sync bookkeeping.

.venv/ and venv/
  Local Python environments.

node_modules/
  Local npm dependency tree.

frontend/help/
  Generated portal help output from docs/help.

frontend/app.js
  Generated production frontend bundle from frontend/app.jsx.

install-report.txt
  Local install summary/report output.
```

---

## Source versus generated files

Repo sync must respect the project source/generated split.

```text
frontend/app.jsx
  Source file edited by developers.

frontend/app.js
  Generated production bundle. Do not treat it as normal source.

docs/help/
  Source markdown for portal help.

frontend/help/
  Generated portal help output.

k8s/observability/grafana-dashboard.json
  Source dashboard model.

k8s/observability/grafana-dashboard-configmap.yaml
  Generated dashboard ConfigMap output.
```

If a source file changes, the installer/build stage should regenerate the generated output during the next deliberate build/deploy path.

Repo sync should not delete generated output just because it is untracked locally.

---

## Manual sync command

Run from the repository root:

```bash
cd /opt/k8s-ansible
bash scripts/sync-repo.sh
```

Expected safe output:

```text
Using existing git checkout: /opt/k8s-ansible
Fetching origin/main
Repository already matches origin/main
Restoring executable bits for repository shell scripts
Repo sync completed with no code changes
```

When GitHub has a new commit, expected output includes:

```text
Repository update detected. Resetting local checkout to origin/main.
Cleaning untracked files while preserving runtime/generated artifacts
Repo sync completed: <commit>
```

---

## Validation after sync

After syncing, run basic checks:

```bash
cd /opt/k8s-ansible

git status --short
bash -n scripts/sync-repo.sh
bash -n setup.sh
bash -n install-otp-relay-k8s.sh
```

A non-empty `git status --short` is not always a failure. Generated or runtime files may be intentionally preserved locally. Investigate before cleaning manually.

---

## Optional systemd timer

The optional timer runs repo sync on a schedule.

Install or update it with:

```bash
cd /opt/k8s-ansible
sudo bash scripts/install-repo-sync-timer.sh
```

Check status with:

```bash
systemctl list-timers | grep otp-relay-repo-sync || true
systemctl status otp-relay-repo-sync.timer --no-pager
systemctl status otp-relay-repo-sync.service --no-pager
```

View logs with:

```bash
journalctl -u otp-relay-repo-sync.service --no-pager -n 100
```

The timer must run only `scripts/sync-repo.sh`.

It must not run deployment commands.

---

## Operator-controlled deployment after sync

After sync, deployment remains a separate operator decision.

Typical entrypoint:

```bash
cd /opt/k8s-ansible
./setup.sh
```

For the local Kubernetes installer path:

```bash
cd /opt/k8s-ansible
sudo -E bash install-otp-relay-k8s.sh
```

Do not make repo sync call these commands automatically.

---

## Help-doc rebuild marker

When source help docs change, repo sync may mark that generated help output should be rebuilt.

Source paths:

```text
docs/help/
scripts/build_help_docs.py
```

Generated path:

```text
frontend/help/
```

The sync layer can create a marker under `.sync-state/` so the build/deploy path knows regeneration is needed.

The sync layer should not delete `frontend/help/` during normal repository cleanup.

---

## Common troubleshooting

### node_modules chmod warning

If sync prints a warning like:

```text
chmod: changing permissions of './node_modules/...': Operation not permitted
```

then the sync script is traversing generated dependency output incorrectly.

Verify the script preserves and prunes `node_modules`:

```bash
grep -n 'node_modules' /opt/k8s-ansible/scripts/sync-repo.sh
sed -n '/restore_executable_bits()/,/^}/p' /opt/k8s-ansible/scripts/sync-repo.sh
```

`node_modules` should appear in both the preserve list and the `find` prune block.

---

### Local edits disappear after sync

This is expected if the edits were only local.

Repo sync hard-resets the checkout to GitHub:

```text
git reset --hard origin/main
```

Correct workflow:

```text
1. Edit the file in GitHub.
2. Confirm GitHub raw file has the change if needed.
3. Run scripts/sync-repo.sh locally.
```

Do not rely on local-only edits surviving repo sync unless the path is explicitly preserved.

---

### Generated help files disappear or change unexpectedly

Generated help output should be preserved by sync.

Check:

```bash
grep -n 'frontend/help' /opt/k8s-ansible/scripts/sync-repo.sh
```

If `frontend/help` is missing from the preserve list, fix the sync script before running more syncs.

---

### Sync succeeds but live cluster does not change

That is correct.

Repo sync only updates local files. To change the live cluster, the operator must run the setup/deployment path intentionally.

---

## SCH comparison

SCH’s Kubernetes branch uses a GitHub Actions deployment workflow as the primary update mechanism.

This repository uses a more controlled operator workflow:

```text
GitHub is source of truth.
Repo sync updates local files.
Operator deploys deliberately.
```

This is an intentional divergence from the SCH baseline.

The goal is to avoid accidental live-cluster mutation while still keeping GitHub as the editable source of truth.

---

## Design rule

Keep this rule strict:

```text
repo sync updates files only
setup/deploy changes the cluster
```

Do not blur those layers.
