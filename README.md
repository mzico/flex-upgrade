# flex-upgrade

Notes and tooling for upgrading Gluu Flex (Janssen + Admin UI) from an older release to a newer one with data kept.

- [`docs/flex-upgrade-guide.md`](docs/flex-upgrade-guide.md): the upgrade guide (VM in-place and side-by-side, Admin UI only, Kubernetes), with the steps and findings from tests of Flex 6.4.0 to 6.5.1.
- [`flex-k8s-upgrade.sh`](flex-k8s-upgrade.sh): script for the Helm upgrade (details below).

Script version: 1.1.0 (`./flex-k8s-upgrade.sh -V`).

Status: the guide and script come from a test environment (microk8s all-in-one chart, PostgreSQL; Ubuntu 24.04 VM). Read the "not tested" notes before using them on production.

# flex-k8s-upgrade.sh

Automates the Kubernetes (Helm) upgrade tested in the guide, section E: preflight, backup, image-tag bump, helm upgrade (atomic), optional Agama redeploy, verification, rollback hints.

    sudo bash flex-k8s-upgrade.sh -v 6.5.1 -f override-6.4.0.yaml -k /root/.kube/config -d      # dry run first
    sudo bash flex-k8s-upgrade.sh -v 6.5.1 -f override-6.4.0.yaml -k /root/.kube/config \
         -a agama-pw=agama-pw-gluu.gama -y                                                       # real run

What it does: checks release/chart exist, writes `<values>-<version>.yaml` with the new `image.tag` (chart default), backs up cm/secret `cn`, helm values/history, referenced custom ConfigMaps and a `pg_dump`, runs `helm upgrade --dry-run`, then `helm upgrade --wait --atomic`, redeploys the listed Agama projects, checks `/.well-known/openid-configuration`, `/admin/`, `/admin/home/dashboard`, WAR versions and row counts, and prints the rollback commands.

Tested: dry run and a same-version run on the microk8s test server (chart gluu-all-in-one 6.5.1, PostgreSQL pod). The real 6.4.0 -> 6.5.1 upgrade was done by hand with the same steps. Not tested: external databases (use `-s` and back up yourself), MySQL (dump is PostgreSQL only), the production `gluu-flex/gluu` chart (it has per-service image tags; the script only edits a top-level `image.tag`), VM installs.

Limits: files mounted over image files (shown as a warning) are not compared automatically; PKCE is required by 6.5.x for authorization-code clients.
