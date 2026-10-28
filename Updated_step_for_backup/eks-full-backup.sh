#!/bin/bash
# ==============================================================================
# eks-full-backup.sh
# Full pre-upgrade backup for an AWS EKS cluster.
#
# Covers:
#   1. EKS control plane configuration (version, endpoint, logging, encryption,
#      OIDC, VPC/networking, cluster IAM role)
#   2. Access/auth settings (access entries, aws-auth, pod identity)
#   3. Add-ons, node groups, Fargate profiles
#   4. Upgrade insights (deprecated API usage, upgrade blockers)
#   5. All cluster-scoped Kubernetes objects (YAML)
#   6. All namespaced Kubernetes objects (YAML)
#   7. kube-system components (CoreDNS, kube-proxy, aws-node, etc.)
#
# NOTE: On EKS the control plane (API server, etcd, scheduler, controller
# manager) is managed by AWS. A direct etcd snapshot is not possible. This
# script saves everything that defines and fills the control plane instead.
#
# Usage:
#   ./eks-full-backup.sh                          # uses defaults below
#   ./eks-full-backup.sh my-eks-cluster us-east-1 # explicit cluster + region
#   ./eks-full-backup.sh my-eks-cluster us-east-1 1.35  # also set upgrade target
# ==============================================================================

CLUSTER="${1:-my-eks-cluster}"
REGION="${2:-us-east-1}"
STAMP=$(date +%Y%m%d-%H%M%S)
BASE="$HOME/eks-backups"
DIR="$BASE/eks-full-backup-$CLUSTER-$STAMP"
LOG="$DIR/backup.log"
WARNINGS=0

# ---------- helpers -----------------------------------------------------------
log()  { echo "$(date +%H:%M:%S) $*" | tee -a "$LOG"; }
warn() { WARNINGS=$((WARNINGS+1)); log "   [WARN] $*"; }

# save_cmd <output-file> <command...> : runs a command, saves stdout to file
save_cmd() {
  local out="$1"; shift
  if "$@" > "$out" 2>>"$LOG"; then
    return 0
  else
    warn "Failed: $* (see backup.log)"
    rm -f "$out"
    return 1
  fi
}

# ---------- pre-checks --------------------------------------------------------
for tool in aws kubectl tar; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "ERROR: '$tool' is not installed or not in PATH." >&2
    exit 1
  fi
done

if ! aws sts get-caller-identity >/dev/null 2>&1; then
  echo "ERROR: AWS credentials are not working. Run 'aws sts get-caller-identity' to debug." >&2
  exit 1
fi

mkdir -p "$DIR"/{eks,access,addons,nodegroups,fargate,iam,k8s/cluster-scoped,k8s/namespaced,k8s/kube-system}
chmod 700 "$DIR"   # backup contains Secrets, keep it private

log "=== EKS full backup started ==="
log "Cluster : $CLUSTER"
log "Region  : $REGION"
log "Output  : $DIR"

# Make sure kubectl points at the right cluster
log ">> Pointing kubectl at $CLUSTER..."
if ! aws eks update-kubeconfig --name "$CLUSTER" --region "$REGION" >>"$LOG" 2>&1; then
  echo "ERROR: Could not update kubeconfig for $CLUSTER in $REGION." >&2
  exit 1
fi
if ! kubectl get ns >/dev/null 2>&1; then
  echo "ERROR: kubectl cannot reach the cluster. Check VPN/endpoint access/IAM." >&2
  exit 1
fi

# ---------- 1. EKS control plane config --------------------------------------
log ">> [1/7] Saving EKS control plane configuration..."
save_cmd "$DIR/eks/cluster.json" aws eks describe-cluster --name "$CLUSTER" --region "$REGION"
save_cmd "$DIR/eks/cluster-version.txt" kubectl version
save_cmd "$DIR/eks/nodes.txt" kubectl get nodes -o wide
save_cmd "$DIR/eks/api-resources.txt" kubectl api-resources -o wide
save_cmd "$DIR/eks/api-versions.txt" kubectl api-versions

# Cluster IAM role (name taken from cluster.json)
if [ -f "$DIR/eks/cluster.json" ]; then
  ROLE_ARN=$(aws eks describe-cluster --name "$CLUSTER" --region "$REGION" --query 'cluster.roleArn' --output text 2>>"$LOG")
  ROLE_NAME="${ROLE_ARN##*/}"
  if [ -n "$ROLE_NAME" ] && [ "$ROLE_NAME" != "None" ]; then
    save_cmd "$DIR/iam/cluster-role.json" aws iam get-role --role-name "$ROLE_NAME"
    save_cmd "$DIR/iam/cluster-role-attached-policies.json" aws iam list-attached-role-policies --role-name "$ROLE_NAME"
  fi

  OIDC_URL=$(aws eks describe-cluster --name "$CLUSTER" --region "$REGION" --query 'cluster.identity.oidc.issuer' --output text 2>>"$LOG")
  echo "$OIDC_URL" > "$DIR/eks/oidc-issuer.txt"
fi

# ---------- 2. Access and auth -----------------------------------------------
log ">> [2/7] Saving access and auth settings..."
kubectl get configmap aws-auth -n kube-system -o yaml > "$DIR/access/aws-auth.yaml" 2>/dev/null \
  || { log "   (no aws-auth ConfigMap, cluster likely uses access entries)"; rm -f "$DIR/access/aws-auth.yaml"; }

save_cmd "$DIR/access/access-entries.json" aws eks list-access-entries --cluster-name "$CLUSTER" --region "$REGION"
if [ -f "$DIR/access/access-entries.json" ]; then
  for p in $(aws eks list-access-entries --cluster-name "$CLUSTER" --region "$REGION" --query 'accessEntries[]' --output text 2>>"$LOG"); do
    safe=$(echo "$p" | tr '/:' '__')
    save_cmd "$DIR/access/access-entry-$safe.json" \
      aws eks describe-access-entry --cluster-name "$CLUSTER" --region "$REGION" --principal-arn "$p"
  done
fi
save_cmd "$DIR/access/pod-identity-associations.json" \
  aws eks list-pod-identity-associations --cluster-name "$CLUSTER" --region "$REGION"

# ---------- 3. Add-ons, node groups, Fargate ----------------------------------
log ">> [3/7] Saving add-ons, node groups and Fargate profiles..."
for a in $(aws eks list-addons --cluster-name "$CLUSTER" --region "$REGION" --query 'addons[]' --output text 2>>"$LOG"); do
  save_cmd "$DIR/addons/addon-$a.json" \
    aws eks describe-addon --cluster-name "$CLUSTER" --region "$REGION" --addon-name "$a"
  log "   add-on: $a"
done

for n in $(aws eks list-nodegroups --cluster-name "$CLUSTER" --region "$REGION" --query 'nodegroups[]' --output text 2>>"$LOG"); do
  save_cmd "$DIR/nodegroups/nodegroup-$n.json" \
    aws eks describe-nodegroup --cluster-name "$CLUSTER" --region "$REGION" --nodegroup-name "$n"
  log "   node group: $n"
done

for f in $(aws eks list-fargate-profiles --cluster-name "$CLUSTER" --region "$REGION" --query 'fargateProfileNames[]' --output text 2>>"$LOG"); do
  save_cmd "$DIR/fargate/fargate-$f.json" \
    aws eks describe-fargate-profile --cluster-name "$CLUSTER" --region "$REGION" --fargate-profile-name "$f"
  log "   fargate profile: $f"
done

# ---------- 4. Upgrade insights ----------------------------------------------
log ">> [4/7] Saving upgrade insights (deprecated APIs, blockers)..."
CUR_VER=$(aws eks describe-cluster --name "$CLUSTER" --region "$REGION" --query 'cluster.version' --output text 2>/dev/null)
# Target version = 3rd argument, or the next minor version after the current one
TARGET="${3:-$(echo "$CUR_VER" | awk -F. '{printf "%s.%d", $1, $2+1}')}"
log "   current version: $CUR_VER, checking insights for target: $TARGET"
save_cmd "$DIR/eks/upgrade-insights.json" \
  aws eks list-insights --cluster-name "$CLUSTER" --region "$REGION" \
  --filter kubernetesVersions="$TARGET" \
  || warn "Upgrade insights not available (older AWS CLI or no permission), skipping"

# ---------- 5. Cluster-scoped Kubernetes objects -----------------------------
log ">> [5/7] Saving cluster-scoped Kubernetes objects..."
for r in $(kubectl api-resources --namespaced=false --verbs=list -o name 2>>"$LOG" \
           | grep -v -E '^(events|events.events.k8s.io|componentstatuses)$'); do
  if [ -n "$(kubectl get "$r" -o name 2>/dev/null)" ]; then
    kubectl get "$r" -o yaml > "$DIR/k8s/cluster-scoped/$r.yaml" 2>>"$LOG" \
      || warn "Could not export cluster-scoped resource: $r"
  fi
done

# ---------- 6. Namespaced Kubernetes objects ---------------------------------
log ">> [6/7] Saving namespaced Kubernetes objects (all namespaces)..."
NAMESPACED=$(kubectl api-resources --namespaced=true --verbs=list -o name 2>>"$LOG" \
             | grep -v -E '^(events|events.events.k8s.io|endpoints|endpointslices.discovery.k8s.io)$')
for ns in $(kubectl get ns -o jsonpath='{.items[*].metadata.name}'); do
  mkdir -p "$DIR/k8s/namespaced/$ns"
  for r in $NAMESPACED; do
    if [ -n "$(kubectl get "$r" -n "$ns" -o name 2>/dev/null)" ]; then
      kubectl get "$r" -n "$ns" -o yaml > "$DIR/k8s/namespaced/$ns/$r.yaml" 2>>"$LOG" \
        || warn "Could not export $r in namespace $ns"
    fi
  done
  log "   namespace $ns done"
done

# ---------- 7. kube-system components ----------------------------------------
log ">> [7/7] Saving kube-system components in one file..."
save_cmd "$DIR/k8s/kube-system/kube-system-core.yaml" \
  kubectl get deploy,ds,cm,sa,svc -n kube-system -o yaml

# ---------- Finish: summary, checksum, archive -------------------------------
log ">> Creating summary..."
{
  echo "EKS full backup summary"
  echo "Cluster       : $CLUSTER"
  echo "Region        : $REGION"
  echo "Created       : $(date)"
  echo "K8s version   : $(aws eks describe-cluster --name "$CLUSTER" --region "$REGION" --query 'cluster.version' --output text 2>/dev/null)"
  echo "Namespaces    : $(kubectl get ns --no-headers 2>/dev/null | wc -l)"
  echo "Nodes         : $(kubectl get nodes --no-headers 2>/dev/null | wc -l)"
  echo "Add-ons       : $(ls "$DIR/addons" 2>/dev/null | wc -l)"
  echo "Node groups   : $(ls "$DIR/nodegroups" 2>/dev/null | wc -l)"
  echo "YAML files    : $(find "$DIR/k8s" -name '*.yaml' | wc -l)"
  echo "Warnings      : $WARNINGS"
} > "$DIR/SUMMARY.txt"

find "$DIR" -type f -exec chmod 600 {} \;

ARCHIVE="$DIR.tar.gz"
tar -czf "$ARCHIVE" -C "$BASE" "$(basename "$DIR")"
chmod 600 "$ARCHIVE"
( cd "$BASE" && sha256sum "$(basename "$ARCHIVE")" > "$(basename "$ARCHIVE").sha256" )

echo
cat "$DIR/SUMMARY.txt"
echo
log "=== DONE ==="
log "Backup folder : $DIR"
log "Backup archive: $ARCHIVE"
log "Checksum file : $ARCHIVE.sha256"
echo
echo "REMINDER: this backup contains Kubernetes Secrets (base64, not encrypted)."
echo "Store the archive somewhere private, e.g. an encrypted S3 bucket."
