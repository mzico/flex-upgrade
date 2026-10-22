#!/usr/bin/env bash
# flex-k8s-upgrade.sh - upgrade a Gluu Flex Helm release (tested: gluu-flex/gluu-all-in-one, microk8s,
# PostgreSQL in the cluster, 6.4.0 -> 6.5.1). Backs up, bumps the image tag, upgrades, verifies, prints rollback.
set -euo pipefail

SCRIPT_VERSION=1.1.0
RELEASE=flex
NAMESPACE=gluu
CHART=gluu-flex/gluu-all-in-one
VERSION=""
VALUES=""
BACKUP_ROOT="$HOME/flex-upgrade-backups"
DB_USER=postgres
DB_NAME=gluu
DB_POD=""
SKIP_DB=0
DRY_RUN=0
ASSUME_YES=0
TIMEOUT=900s
FQDN=""
IMAGE_TAG=""
AGAMA=()
KUBECTL=(kubectl)
HELM=(helm)

usage() {
  cat <<EOF
Usage: $0 -v <chart-version> -f <values.yaml> [options]

  -v VERSION     target chart version, e.g. 6.5.1 (required)
  -f FILE        current Helm values file (required); a copy with the new image tag is written next to it
  -r RELEASE     Helm release name            (default: $RELEASE)
  -n NAMESPACE   Kubernetes namespace         (default: $NAMESPACE)
  -c CHART       chart reference              (default: $CHART)
  -t TAG         image tag to use             (default: the target chart's default image.tag)
  -b DIR         backup directory root        (default: $BACKUP_ROOT)
  -p POD         PostgreSQL pod name          (default: auto-detect a pod named *postgresql*)
  -U USER        PostgreSQL user              (default: $DB_USER)
  -D DB          PostgreSQL database          (default: $DB_NAME)
  -s             skip the database dump (external database: back it up yourself first)
  -a NAME=FILE   redeploy an Agama project after the upgrade (repeatable), e.g. agama-pw=agama-pw-gluu.gama
  -k KUBECONFIG  kubeconfig path (also used for helm)
  -w TIMEOUT     rollout timeout              (default: $TIMEOUT)
  -d             dry run: checks, backup, helm --dry-run only
  -y             do not ask for confirmation
  -V             print the script version
  -h             this help
EOF
}

log()  { printf '\033[1;34m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

while getopts "v:f:r:n:c:t:b:p:U:D:sa:k:w:dyhV" o; do
  case $o in
    v) VERSION=$OPTARG;; f) VALUES=$OPTARG;; r) RELEASE=$OPTARG;; n) NAMESPACE=$OPTARG;;
    c) CHART=$OPTARG;; t) IMAGE_TAG=$OPTARG;; b) BACKUP_ROOT=$OPTARG;; p) DB_POD=$OPTARG;;
    U) DB_USER=$OPTARG;; D) DB_NAME=$OPTARG;; s) SKIP_DB=1;; a) AGAMA+=("$OPTARG");;
    k) KUBECTL+=(--kubeconfig "$OPTARG"); HELM+=(--kubeconfig "$OPTARG");;
    w) TIMEOUT=$OPTARG;; d) DRY_RUN=1;; y) ASSUME_YES=1;; V) echo "flex-k8s-upgrade.sh $SCRIPT_VERSION"; exit 0;; h) usage; exit 0;; *) usage; exit 2;;
  esac
done
[[ -n $VERSION && -n $VALUES ]] || { usage; exit 2; }
[[ -f $VALUES ]] || die "values file not found: $VALUES"

k() { "${KUBECTL[@]}" -n "$NAMESPACE" "$@"; }
h() { "${HELM[@]}" "$@"; }

# ---------- preflight ----------
log "flex-k8s-upgrade.sh $SCRIPT_VERSION - preflight"
command -v kubectl >/dev/null || die "kubectl not found"
command -v helm    >/dev/null || die "helm not found"
command -v python3 >/dev/null || die "python3 not found"
h status "$RELEASE" -n "$NAMESPACE" >/dev/null 2>&1 || die "Helm release '$RELEASE' not found in namespace '$NAMESPACE'"

CUR_CHART=$(h list -n "$NAMESPACE" -f "^${RELEASE}\$" -o json | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d[0]["chart"] if d else "")')
CUR_REV=$(h history "$RELEASE" -n "$NAMESPACE" -o json | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d[-1]["revision"])')
log "Current release: $RELEASE ($CUR_CHART), revision $CUR_REV"

h repo update >/dev/null 2>&1 || warn "helm repo update failed (continuing with cached index)"
h search repo "$CHART" --version "$VERSION" -o json | python3 -c 'import json,sys; sys.exit(0 if json.load(sys.stdin) else 1)' \
  || die "chart $CHART version $VERSION not found in your repos"

if [[ -z $IMAGE_TAG ]]; then
  IMAGE_TAG=$(h show values "$CHART" --version "$VERSION" | python3 -c '
import re,sys
t=sys.stdin.read()
m=re.search(r"^image:\n(?:(?:  .*)?\n)*?  tag:\s*\"?([^\s\"#]+)", t, re.M)
print(m.group(1) if m else "")')
fi

# warn about files mounted over image files: they hide the new version of the file
MOUNTS=$(python3 - "$VALUES" <<'PY'
import re,sys
t=open(sys.argv[1]).read()
print("\n".join(re.findall(r"mountPath:\s*(\S+)", t)))
PY
)
if [[ -n $MOUNTS ]]; then
  warn "Your values mount files over the image (they will hide the new image's version of each file):"
  printf '         %s\n' $MOUNTS >&2
  warn "Compare each with the new image (run a temp pod from the new image and diff) before relying on them."
fi

# ---------- values copy with new image tag ----------
NEW_VALUES="${VALUES%.yaml}-${VERSION}.yaml"
if [[ -n $IMAGE_TAG ]] && grep -qE '^image:' "$VALUES"; then
  python3 - "$VALUES" "$NEW_VALUES" "$IMAGE_TAG" <<'PY'
import re,sys
src,dst,tag=sys.argv[1:4]
t=open(src).read()
new,n=re.subn(r"(^image:\n(?:(?:  .*)?\n)*?  tag:\s*)\"?[^\s\"#]+\"?", lambda m: m.group(1)+tag, t, count=1, flags=re.M)
if n==0:
    new=t
open(dst,"w").write(new)
PY
  log "Image tag set to $IMAGE_TAG in $NEW_VALUES (chart $VERSION)"
else
  cp "$VALUES" "$NEW_VALUES"
  warn "No top-level image.tag found in values (or none in the chart): image tags are NOT changed. Set them yourself if your chart needs it."
fi
diff -u "$VALUES" "$NEW_VALUES" || true

# ---------- backup ----------
STAMP=$(date +%Y%m%d-%H%M%S)
BK="$BACKUP_ROOT/$RELEASE-$STAMP"
mkdir -p "$BK"
log "Backup to $BK"
k get cm cn -o yaml     > "$BK/configmap-cn.yaml"  2>/dev/null || warn "configmap 'cn' not found"
k get secret cn -o yaml > "$BK/secret-cn.yaml"     2>/dev/null || warn "secret 'cn' not found"
chmod 600 "$BK"/secret-cn.yaml 2>/dev/null || true
h get values "$RELEASE" -n "$NAMESPACE" > "$BK/helm-values-live.yaml"
h history "$RELEASE" -n "$NAMESPACE" > "$BK/helm-history.txt"
cp "$VALUES" "$BK/values-before.yaml"
# custom ConfigMaps referenced by volumes
for cm in $(python3 - "$VALUES" <<'PY'
import re,sys
t=open(sys.argv[1]).read()
print(" ".join(sorted(set(re.findall(r"configMap:\s*\n\s*name:\s*(\S+)", t)))))
PY
); do
  k get cm "$cm" -o yaml > "$BK/cm-$cm.yaml" 2>/dev/null && log "  saved ConfigMap $cm"
done

COUNTS_BEFORE=""
psql_q() { k exec "$DB_POD" -- psql -U "$DB_USER" -d "$DB_NAME" -Atc "$1"; }
if (( SKIP_DB == 0 )); then
  [[ -n $DB_POD ]] || DB_POD=$(k get pods -o name | sed 's#pod/##' | grep -i postgresql | head -1 || true)
  [[ -n $DB_POD ]] || die "no PostgreSQL pod found; pass -p POD, or -s if the database is external (and back it up yourself)"
  log "Database dump from pod $DB_POD"
  k exec "$DB_POD" -- pg_dump -U "$DB_USER" -Fc "$DB_NAME" > "$BK/db-${DB_NAME}.dump"
  [[ -s $BK/db-${DB_NAME}.dump ]] || die "database dump is empty"
  log "  dump size: $(du -h "$BK/db-${DB_NAME}.dump" | cut -f1)"
  COUNTS_BEFORE=$(psql_q 'select (select count(*) from "jansPerson"), (select count(*) from "jansClnt"), (select count(*) from "jansScope")' || true)
  log "  rows before (persons|clients|scopes): $COUNTS_BEFORE"
else
  warn "Database dump skipped (-s)."
fi

# ---------- helm dry run ----------
log "Helm dry run"
h upgrade "$RELEASE" "$CHART" -n "$NAMESPACE" -f "$NEW_VALUES" --version "$VERSION" --dry-run >/dev/null
log "  dry run OK"
if (( DRY_RUN )); then
  log "Dry run finished. Backup: $BK ; new values: $NEW_VALUES"
  exit 0
fi

if (( ASSUME_YES == 0 )); then
  read -rp "Upgrade $RELEASE from $CUR_CHART to $CHART $VERSION now? [y/N] " a
  [[ $a == y || $a == Y ]] || die "aborted"
fi

# ---------- upgrade ----------
log "Upgrading (this restarts the pods)"
h upgrade "$RELEASE" "$CHART" -n "$NAMESPACE" -f "$NEW_VALUES" --version "$VERSION" --wait --timeout "$TIMEOUT" --atomic

DEPLOYS=$(k get deploy -o name | grep -E "/${RELEASE}-" || true)
for d in $DEPLOYS; do k rollout status "$d" --timeout "$TIMEOUT"; done

# ---------- agama redeploy ----------
if (( ${#AGAMA[@]} )); then
  FQDN=$(awk '/^fqdn:/{print $2; exit}' "$NEW_VALUES" || true)
  [[ -n $FQDN ]] || warn "fqdn not found in values; skipping Agama redeploy"
  if [[ -n $FQDN ]]; then
    POD=$(k get pods -o name | grep -E "/${RELEASE}-" | grep -v cleanup | head -1)
    CID=$(k get cm cn -o jsonpath='{.data.jca_client_id}')
    CPW=$(k get secret cn -o jsonpath='{.data.jca_client_pw}' | base64 -d)
    TOK=$(k exec "$POD" -- curl -sk -u "$CID:$CPW" -d grant_type=client_credentials \
          --data-urlencode "scope=https://jans.io/oauth/config/agama.readonly https://jans.io/oauth/config/agama.write" \
          "https://$FQDN/jans-auth/restv1/token" | python3 -c 'import json,sys; print(json.load(sys.stdin)["access_token"])')
    for spec in "${AGAMA[@]}"; do
      name=${spec%%=*}; file=${spec#*=}
      [[ -f $file ]] || { warn "Agama archive not found: $file"; continue; }
      log "Redeploying Agama project $name from $file"
      k exec -i "$POD" -- curl -sk -H "Authorization: Bearer $TOK" -H "Content-Type: application/zip" \
        --data-binary @- -w '  HTTP %{http_code}\n' -o /dev/null \
        "https://$FQDN/jans-config-api/api/v1/agama-deployment/$name?autoconfigure=false" < "$file"
    done
    log "Agama deployments are asynchronous; wait ~30 s before testing."
  fi
fi

# ---------- verification ----------
log "Verification"
FQDN=${FQDN:-$(awk '/^fqdn:/{print $2; exit}' "$NEW_VALUES" || true)}
POD=$(k get pods -o name | grep -E "/${RELEASE}-" | grep -v cleanup | head -1 || true)
if [[ -n $POD && -n $FQDN ]]; then
  for p in /.well-known/openid-configuration /admin/ /admin/home/dashboard; do
    ok=0
    for _ in $(seq 1 30); do
      code=$(k exec "$POD" -- curl -sk -o /dev/null -w '%{http_code}' "https://$FQDN$p" || echo 000)
      [[ $code == 200 ]] && { ok=1; break; }; sleep 10
    done
    (( ok )) && log "  $p -> 200" || warn "  $p -> $code"
  done
  k exec "$POD" -- sh -c 'for s in jans-auth jans-config-api jans-scim jans-fido2; do printf "  %s " $s; unzip -p /opt/jans/jetty/$s/webapps/$s.war META-INF/MANIFEST.MF 2>/dev/null | grep -m1 Implementation-Version || echo n/a; done' || true
fi
if (( SKIP_DB == 0 )); then
  COUNTS_AFTER=$(psql_q 'select (select count(*) from "jansPerson"), (select count(*) from "jansClnt"), (select count(*) from "jansScope")' || true)
  log "  rows after  (persons|clients|scopes): $COUNTS_AFTER"
  [[ $COUNTS_BEFORE == "$COUNTS_AFTER" ]] && log "  row counts match" || warn "  row counts differ (new scopes/clients can be legitimate; review)"
fi

cat <<EOF

Done. Backup: $BK
Checks left for you: sign in to the Admin UI as a user with jansAdminUIRole; test an authorization-code flow
(Flex 6.5.x requires a PKCE code_challenge); re-check any custom pages, scripts and Agama flows.

Rollback:
  helm rollback $RELEASE $CUR_REV -n $NAMESPACE --wait
  # only if the database changed and must be restored (stop the app first):
  kubectl -n $NAMESPACE exec -i ${DB_POD:-<postgresql-pod>} -- pg_restore -U $DB_USER -d $DB_NAME --clean --if-exists < $BK/db-${DB_NAME}.dump
EOF
