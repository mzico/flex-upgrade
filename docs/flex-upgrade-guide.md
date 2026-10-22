# Gluu Flex Upgrade Guide (Flex + Janssen + Admin UI)

Last updated: 2026-10-23 · Author: Zico, Gluu Support

## Overview

On a VM, an in-place upgrade (section D) was tested from Flex 6.4.0 to 6.5.1 and keeps the existing database; the officially documented route is a side-by-side migration (section A), which is safer for production because the old server stays untouched. On Kubernetes you run `helm upgrade`. Admin UI can additionally be refreshed on its own with `flex_setup.py`.

| Deployment | Upgrade method | Source |
| --- | --- | --- |
| VM (Ubuntu, RHEL, SUSE) | In-place (section D, tested) or side-by-side: new VM, import config with Terraform, restore data, shift traffic (section A, not tested) | [Janssen VM upgrade](https://docs.jans.io/head/janssen-server/vm-ops/upgrade/) |
| VM, Admin UI only | `flex_setup.py --update-admin-ui` | `flex_setup.py` source; Gluu support forum |
| Kubernetes | `helm upgrade` with the `gluu-flex/gluu` chart | [Flex Helm upgrade](https://gluu.org/docs/flex/nightly/admin/kubernetes-ops/upgrade) |

Components covered: Janssen Server (auth-server, config-api, fido2, scim), Flex (Admin UI, Casa) and the persistence layer (MySQL or PostgreSQL). Treat the target version's release notes as the authority on breaking changes.

## Prerequisites

- [ ] Source and target versions identified; release notes read for every version in between.
- [ ] Staging environment on the same OS, database and version as production; the full procedure rehearsed there first.
- [ ] Maintenance window agreed; the cutover is a traffic shift, so downtime can be near zero.
- [ ] Inventory of customizations: custom Jython/Agama scripts, Agama projects, custom pages, `jans-auth` properties, Admin UI roles and custom plugins. Custom scripts are external configuration and are **not** updated by an upgrade; review each against the new version.
- [ ] Inventory of clients, scopes, trusted IdPs, SAML trust relationships, and keys (JWKS) that external parties depend on.
- [ ] Admin credentials, database credentials and a Terraform client ID/secret ready (the new server can create one with `setup.py -test-client-id` / `-test-client-pw`).
- [ ] Database admin access and enough disk for a full dump.
- [ ] Ports, FQDN and certificates for the new node; DNS TTL lowered before cutover.

## Backup

Take all of these before touching anything. A VM snapshot is the best single backup; the rest protects against a bad snapshot. Take at least one daily and one weekly backup.

**VM**

1. Snapshot the VM (VMware, DigitalOcean, cloud provider).
2. Stop Janssen services, archive, restart. The [Janssen backup page](https://docs.jans.io/head/janssen-server/vm-ops/backup/) lists `/opt`, `/etc/jans`, `/etc/apache2` and `/var/jans`:

```bash
sudo systemctl stop 'jans*'
sudo tar cvf jans-backup.tar /opt/jans /etc/jans /etc/apache2 /var/jans
sudo systemctl start 'jans*'
```

The docs print the stop/start commands as `systemctl stop list-units --all "jans*"`, which is not valid as written; verify that services actually stop.

3. Dump the database (the docs do not cover this; use the native tool):

```bash
# MySQL
mysqldump --single-transaction --routines -u <user> -p jans > jans-$(date +%F).sql
# PostgreSQL
pg_dump -U <user> -Fc jans > jans-$(date +%F).dump
```

4. Save the Admin UI directory (`<apache root>/admin`) and `/var/log/adminui`.

**Kubernetes** (from the [Janssen backup guide](https://docs.jans.io/head/janssen-server/kubernetes-ops/backup-restore/))

```bash
kubectl get configmap cn -n <namespace> -o yaml > configmap-backup.yaml
kubectl get secret cn -n <namespace> -o yaml > secret-backup.yaml
helm get values <release> -n <namespace> > values.yaml
helm list -n <namespace>   # record chart version
```

Also dump the external database as above. Keep backups off the host, and never put the secret backup in a ticket or repo.

## Upgrade procedure

The official docs describe the side-by-side flow and the Helm command but not data migration itself; the data steps below are the standard database approach and must be proven on staging first.

### A. VM: Janssen + Flex + Admin UI (side-by-side, documented, not tested)

1. Keep the old VM running; do not decommission it.
2. Provision a new VM on the supported OS and install Janssen at the target version from the VM install guide, then install Flex (Admin UI, Casa if used) at the matching Flex version using `flex_setup.py`. Create a Terraform test client during setup:

```bash
sudo python3 /opt/jans/jans-setup/setup.py -test-client-id <client-id> -test-client-pw <client-pw>
```

3. Carry configuration over with Terraform: `terraform import` the global configuration from the new server, then define and `terraform apply` your custom IdP configurations.
4. Carry data over: stop writes on the old server (or schedule the window), take a fresh database dump, and restore it into the new server's database. Use the same engine (MySQL or PostgreSQL) and a database version supported by the target release. Restore users, clients, scopes, sessions you need to keep, and the Admin UI role/permission entries. Re-check that the keystore and `/etc/certs` material the old server used (signing keys, `jans-auth` JWKS) is copied if existing tokens and client trust must keep working.
5. Review and port custom scripts and Agama projects to the new version; they are not upgraded automatically.
6. Start both servers. Run the validation checks below against the new server using a hosts-file override of the production FQDN.
7. Shift traffic gradually at the load balancer or DNS. When confident, drain and retire the old VM; keep its snapshot and dump for the rollback window.

### B. Admin UI only (existing VM)

Use this when only the Admin UI changes. Run as root on the Flex host:

```bash
# download flex_setup.py from the GluuFederation/flex repo for the target release
sudo python3 flex_setup.py --update-admin-ui
```

What the script does (read from its source): checks that `<apache root>/admin` exists, re-downloads the Flex and Admin UI artifacts, replaces `admin-ui-plugin.jar` in Config API, renames the current admin directory to a timestamped `...back-<timestamp>` copy, unpacks the new build, then restarts Apache, `jans-auth` and Config API. The timestamped copy is your quick Admin UI rollback. The flag is documented in the \[VM install guide\](https://gluu.org/head/install/vm-install/ubuntu); the script lives at \`/opt/jans/jans-setup/flex/flex-linux-setup/flex\_setup.py\`. See also a [support forum reply](https://support.gluu.org/upgrade/11365/flex-upgrade-from-500-4-to-50014).

### C. Kubernetes (Helm, not tested)

```bash
helm ls -n <namespace>                      # find the release name and current chart version
helm get values <release> -n <namespace> > override.yaml   # start from your current values
# edit override.yaml: image tags / chart-specific changes for the target version
helm upgrade <release> gluu-flex/gluu -n <namespace> -f override.yaml --version=<target-chart-version>
```

The chart repo `gluu-flex` must already be added (`helm repo update` first). Use the Flex chart (`gluu-flex/gluu`), not `janssen/janssen`, so Janssen and Flex move together. Persistence is external (MySQL/PostgreSQL), so data is retained; back up before the upgrade.

### D. Tested: in-place VM upgrade, Flex 6.4.0 to 6.5.1 (Ubuntu 24.04, PostgreSQL)

Tested 2026-10-21 on a single VM with Janssen 2.4.0 / Flex 6.4.0 and Admin UI, seeded with 10 users, 3 clients and 2 scopes. Result: services, data, Admin UI and token issuance all worked after the upgrade, with no database restore needed. The database was not touched by any step, so the schema was unchanged between these two releases; check release notes before relying on this for other version pairs.

1. **Back up** (before anything else):

```bash
sudo -u postgres pg_dump -Fc jansdb > jansdb-6.4.0.dump
sudo systemctl stop 'jans*' apache2
sudo tar czf jans-6.4.0-files.tgz /opt/jans /etc/jans /etc/apache2 /var/jans /var/www/html/admin /etc/certs
sudo systemctl start apache2 jans-auth jans-config-api jans-scim jans-fido2
```

2. **Install the new Flex package** over the old one. Download the `.deb` for your OS from the Flex release page and verify its SHA-256. The package's `prerm` stops the Janssen services on upgrade; it replaces the setup scripts and `app_info.json` (here Janssen 2.4.0 to 2.5.0) but does not replace the running Janssen applications:

```bash
sudo apt-get install -y ./flex_6.5.1-stable.ubuntu24.04_amd64.deb
```

3. **Stage the new Janssen artifacts.** `install.py -upgrade` only copies the files already in `/opt/dist/jans`; if those are still the old version it silently re-installs the old WARs. In our test `setup.py --download-exit` did not fetch the core WARs and aborted on a 404 for the Shibboleth WAR, so download them from the Janssen GitHub release and check the manifest version:

```bash
cd /opt/dist/jans
V=2.5.0; B=https://github.com/JanssenProject/jans/releases/download/v$V
for p in jans-auth-server:jans-auth jans-scim-server:jans-scim jans-fido2-server:jans-fido2 jans-config-api-server:jans-config-api; do
  sudo wget -O ${p#*:}.war $B/${p%:*}-$V.war
  unzip -p ${p#*:}.war META-INF/MANIFEST.MF | grep Implementation-Version
done
```

4. **Replace the applications.** Existing WARs are kept as `*.war-back.<date>` for rollback:

```bash
cd /opt/jans/jans-setup && sudo python3 install.py -upgrade -use-downloaded -yes
```

5. **Update Admin UI:**

```bash
sudo python3 /opt/jans/jans-setup/flex/flex-linux-setup/flex_setup.py --update-admin-ui
```

The old Admin UI directory is kept as `/var/www/html/admin.back-<timestamp>`.

6. **Validate:** all five services active; `Implementation-Version` of each WAR equals the target; discovery, JWKS and `/admin/` return 200; a `client_credentials` token is issued for a seeded client; the Config API still lists the seeded users.

Not covered by `-upgrade`: components installed from other packages (Jetty, Jython, Java) and any Janssen services not listed above (for example Casa, Lock, Link); upgrade those separately. Custom scripts are not changed.

### E. Tested: Kubernetes (microk8s, all-in-one chart), Flex 6.4.0 to 6.5.1

Tested 2026-10-22 on a 4 vCPU / 16 GB Ubuntu 24.04 VM with PostgreSQL. Result: data (12 users, 10 clients, 195 scopes) was unchanged, all four Janssen components moved to 2.5.0, and the Admin UI, login pages and a custom Agama flow worked afterward. The upgrade itself took about 2 minutes of downtime (Recreate strategy). This test used the quickstart chart `gluu-flex/gluu-all-in-one`, release `flex`, namespace `gluu`; the production chart `gluu-flex/gluu` (section C) was not tested.

1. **Back up first.** ConfigMap and Secret `cn`, the Helm values, and the database (here the PostgreSQL pod):

```bash
kubectl -n gluu get cm cn -o yaml > configmap-backup.yaml
kubectl -n gluu get secret cn -o yaml > secret-backup.yaml
helm get values flex -n gluu > values-live.yaml
kubectl -n gluu exec <postgresql-pod> -- pg_dump -U postgres -Fc gluu > gluu-pre-upgrade.dump
```

2. **Update the image tag in your values file.** The chart version and the image tag differ (chart `6.5.1`, image `6.5.1-1`). If your values pin `image.tag: 6.4.0-1`, the upgrade keeps running the old image. Find the default with `helm show values gluu-flex/gluu-all-in-one --version 6.5.1 | grep -A6 '^image:'`.
3. **Review your customizations against the new image.** Every file you mount over an image file hides the new version of that file. Compare each one before upgrading (run a temporary pod from the new image and `cat` the file): in our case the `login.xhtml` override was identical upstream, the nginx file still needed our Admin UI fix, and the status script was fixed upstream, so we dropped that mount.
4. **Upgrade the release:**

```bash
helm repo update
helm upgrade flex gluu-flex/gluu-all-in-one -n gluu -f override-6.5.1.yaml --version=6.5.1
kubectl -n gluu rollout status deploy/flex-gluu-all-in-one
```

5. **Redeploy customized Agama projects.** The upgrade redeploys the stock `agama-pw` (and Casa), which overwrites custom branding in `agama-pw`. Deploy your project archive again with `POST /jans-config-api/api/v1/agama-deployment/agama-pw?autoconfigure=false` (`Content-Type: application/zip`). A separate project such as `gluu-terms` is kept.
6. **Validate** as in section D, plus: sign in to the Admin UI and confirm the sidebar, and run an authorization-code request with a PKCE `code_challenge`.

**Findings that affect other installs**

- **Fixed upstream in 6.5.1:** the status script warning (6.4.0 returned an empty `/api/v1/health/service-status`, which left the Admin UI sidebar empty). On 6.4.0 patch `jans_services_status.py` to ignore warnings.
- **Still present in 6.5.1:** the image's nginx serves the Admin UI with `try_files ... =404`, so the post-login URL `/admin/home/dashboard` returns 404. Mount a corrected `/etc/nginx/jans-aio/admin-ui-location.conf` with `try_files $uri $uri/ /admin/index.html;`.
- **Behavior change in 6.5.1:** authorization requests without `code_challenge` fail with "PKCE is required but code\_challenge is missing". Update clients and test URLs.
- **Install script (quickstart):** passes the image tag `6.4.0-1` as the chart version, which does not exist; use `--version=6.4.0`. The ingress-nginx it installs has gzip off, which makes the Admin UI slow on long network paths. Enable `use-gzip` and brotli.
- **Resources:** a 4 vCPU VM cannot run two all-in-one pods during a rolling update, so set the deployment strategy to `Recreate`.

**Script.** `flex-k8s-upgrade.sh` runs steps 1, 2, 4, 5 and 6 above: backup, image-tag bump, atomic `helm upgrade`, Agama redeploy and checks, then prints rollback commands. Try `-d` (dry run) first:

```bash
sudo bash flex-k8s-upgrade.sh -v 6.5.1 -f override-6.4.0.yaml -k /root/.kube/config -d
sudo bash flex-k8s-upgrade.sh -v 6.5.1 -f override-6.4.0.yaml -k /root/.kube/config -a agama-pw=agama-pw-gluu.gama -y
```

It was tested with a dry run and a same-version run on the test server. It does not do step 3 (comparing mounted files with the new image), so review the warning it prints. External databases need `-s` and your own dump.

## Post-upgrade validation

- [ ] All services up: `systemctl status 'jans*' apache2` (VM) or `kubectl get pods -n <namespace>` (K8s).
- [ ] OpenID discovery responds: `curl -s https://<fqdn>/.well-known/openid-configuration`, and the JWKS endpoint returns the expected keys.
- [ ] Admin UI loads, you can log in, and roles, clients and scopes match the old server.
- [ ] Authorization code flow with a real client completes, including token and userinfo calls.
- [ ] Existing users can authenticate; a sample of migrated users and clients exists.
- [ ] Custom scripts and Agama flows run; no errors in `/opt/jans/jetty/jans-auth/logs` and `/var/log/adminui`.
- [ ] Casa, SCIM and FIDO2 work if used.
- [ ] Certificates, FQDN and external integrations (SPs, load balancer health checks) are correct.

## Rollback

The side-by-side design is the rollback: the old server stays untouched until you retire it.

- **VM:** point traffic back to the old VM. If it was stopped, start its services; restore the VM snapshot if its files changed. Do not restore the old database dump over data created on the new server without deciding what to do with the changes in between.
- **Admin UI only:** stop Apache, move the new admin directory aside, rename the `...back-<timestamp>` directory back to the admin path, restore the previous `admin-ui-plugin.jar`, restart Apache, `jans-auth` and Config API.
- **Kubernetes:** `helm rollback <release> <revision> -n <namespace>` (find the revision with `helm history`). If the database was changed by the new version, restore the pre-upgrade dump, then the saved ConfigMap and Secret.
- Keep snapshots, dumps and the old VM for an agreed window (suggest at least one week) before deleting.

## Troubleshooting

| Symptom | Likely cause | Action |
| --- | --- | --- |
| `Gluu Flex Admin UI was not installed on this system. Update not possible.` | `<apache root>/admin` missing | Install Admin UI with `flex_setup.py --install-admin-ui` instead of updating |
| Admin UI shows old version after update | Browser cache, or Apache not restarted | Hard refresh; restart Apache, `jans-auth`, Config API |
| Admin login fails after data restore | Missing Admin UI role/permission entries or mismatched FQDN/client in config | Compare Admin UI entries in the database with the old server; re-check the Config API client |
| Tokens or ID tokens rejected by clients | Signing keys differ from the old server | Copy the key material across or have clients refresh JWKS |
| Custom login/script errors | Scripts not upgraded with the server | Review against the new version's APIs; check auth-server logs |
| Helm upgrade fails or pods crash-loop | Values file out of date for the new chart | Diff the chart defaults against `override.yaml`; `helm rollback` |

Collect logs from `/opt/jans/jetty/*/logs`, `/var/log/adminui` and `kubectl logs` before asking support.

## Sources

- [Janssen VM upgrade](https://docs.jans.io/head/janssen-server/vm-ops/upgrade/)
- [Janssen VM backup](https://docs.jans.io/head/janssen-server/vm-ops/backup/)
- [Janssen Kubernetes backup and restore](https://docs.jans.io/head/janssen-server/kubernetes-ops/backup-restore/)
- [Flex Helm upgrade (nightly)](https://gluu.org/docs/flex/nightly/admin/kubernetes-ops/upgrade)
- [Support forum: Flex upgrade, Admin UI update](https://support.gluu.org/upgrade/11365/flex-upgrade-from-500-4-to-50014)
- `flex_setup.py` in the GluuFederation/flex repo (`--update-admin-ui` behavior)
