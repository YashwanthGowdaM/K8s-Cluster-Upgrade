# EKS Full Backup: Control Plane Configuration and All Kubernetes Objects

A beginner-friendly, copy-paste guide to run `eks-full-backup.sh`. It saves the EKS control plane configuration and every Kubernetes object in your cluster, so you have a safety net before an upgrade.

Written for: cluster `my-eks-cluster`, region `us-east-1`.

Every step has the same layout: **Explanation**, **Commands**, **Expected output**, and **Important to know**.

---

## Table of Contents

| Part | Steps | What you do |
|------|-------|-------------|
| 0 | [Read this first](#0-read-this-first) | What is backed up, and the truth about etcd on EKS |
| 1 | [Steps 1 to 5](#part-1-prepare) | Check tools, credentials and cluster health |
| 2 | [Steps 6 to 8](#part-2-run-the-backup) | Install and run the script |
| 3 | [Steps 9 to 13](#part-3-verify-and-protect-the-backup) | Verify, checksum, copy to S3 |
| 4 | [Steps 14 to 15](#part-4-before-an-upgrade-and-automation) | Upgrade insights and daily automation |
| 5 | [Steps 16 to 18](#part-5-restore) | Restore an app, restore order, rebuild a cluster |
| 6 | [Troubleshooting](#6-troubleshooting) | Common errors and fixes |
| 7 | [Checklist](#7-final-checklist) | One-page recap |

---

## 0. Read this first

### The truth about etcd on EKS

On a self-built cluster you run `etcdctl snapshot save`. **On EKS you cannot.** AWS runs the API server, etcd, scheduler and controller manager in its own account. There is no SSH access and no etcd snapshot.

What you **can** save is:

1. The **configuration that defines your control plane** (version, networking, logging, encryption, IAM role).
2. **Every Kubernetes object** that etcd stores, read through the API server and saved as YAML.

That is exactly what this script does.

### What the script saves

| Folder in the backup | Contents |
|----------------------|----------|
| `eks/` | Cluster config (`cluster.json`), version, nodes, API versions, OIDC issuer, upgrade insights |
| `iam/` | Cluster IAM role and its attached policies |
| `access/` | `aws-auth` ConfigMap, access entries, pod identity associations |
| `addons/` | One JSON file per EKS add-on (CoreDNS, kube-proxy, VPC CNI, ...) |
| `nodegroups/` | One JSON file per node group |
| `fargate/` | One JSON file per Fargate profile (if any) |
| `k8s/cluster-scoped/` | CRDs, ClusterRoles, StorageClasses, PersistentVolumes, ... |
| `k8s/namespaced/<namespace>/` | Every resource type in every namespace |
| `k8s/kube-system/` | CoreDNS, kube-proxy, aws-node and other system components |
| `SUMMARY.txt`, `backup.log` | Result summary and a log of any warnings |

### What it does NOT save

- **Disk data inside persistent volumes.** Only the volume definitions are saved. Use Velero or EBS snapshots (see the Velero guide).
- **Events and endpoints.** Skipped on purpose; Kubernetes regenerates them.
- **Anything outside the cluster**, such as databases (RDS) or other EC2 servers.

> **Important to know:** The backup contains Kubernetes **Secrets**. They are only base64-encoded, not encrypted. Treat every backup file as sensitive.

---

## Part 1: Prepare

### Step 1: Check the tools are installed

**Explanation:** The script needs the AWS CLI, kubectl and tar.

**Commands:**

```bash
aws --version
kubectl version --client
tar --version | head -1
```

**Expected output (versions will differ):**

```
aws-cli/2.x.x Python/3.x.x Linux/...
Client Version: v1.3x.x
tar (GNU tar) 1.35
```

**Important to know:** If a command says `command not found`, install that tool first. The script stops immediately if any of them is missing.

---

### Step 2: Check your AWS credentials

**Explanation:** The script calls AWS APIs to read your cluster configuration.

**Commands:**

```bash
aws sts get-caller-identity
```

**Expected output:**

```json
{
    "UserId": "AIDA................",
    "Account": "123456789012",
    "Arn": "arn:aws:iam::123456789012:user/your-user"
}
```

**Important to know:** Use the same IAM user or role that created the cluster. If you see `Unable to locate credentials`, run `aws configure`.

---

### Step 3: Set variables and connect kubectl

**Explanation:** Points `kubectl` at the right cluster.

**Commands:**

```bash
export CLUSTER=my-eks-cluster
export REGION=us-east-1
export ACCOUNT=$(aws sts get-caller-identity --query Account --output text)

aws eks update-kubeconfig --name $CLUSTER --region $REGION
```

**Expected output:**

```
Added new context arn:aws:eks:us-east-1:123456789012:cluster/my-eks-cluster to /home/<you>/.kube/config
```

**Important to know:** The script runs `update-kubeconfig` for you too, but doing it here lets you catch problems early.

---

### Step 4: Check the cluster is healthy

**Explanation:** A backup of a broken cluster is less useful, and unhealthy pods can hide problems before an upgrade.

**Commands:**

```bash
kubectl get nodes
kubectl get pods -A | grep -v -E "Running|Completed"
```

**Expected output:**

```
NAME                            STATUS   ROLES    AGE   VERSION
ip-192-168-xx-xx.ec2.internal   Ready    <none>   2h    v1.34.x-eks-xxxxxxx

NAME   READY   STATUS   RESTARTS   AGE
```

All nodes `Ready`, and the second command prints only the header line.

**Important to know:** Fix any `NotReady` node or failing pod before you continue.

---

### Step 5: Note the current version

**Explanation:** Record the version you are on, so you can compare after the upgrade.

**Commands:**

```bash
aws eks describe-cluster --name $CLUSTER --region $REGION --query "cluster.version" --output text
```

**Expected output:**

```
1.34
```

**Important to know:** EKS upgrades one minor version at a time (1.34 to 1.35, then 1.35 to 1.36). A control plane upgrade **cannot be rolled back**, which is why this backup matters.

---

## Part 2: Run the backup

### Step 6: Put the script in place

**Explanation:** Copy `eks-full-backup.sh` into your backup folder and make it executable.

**Commands:**

```bash
mkdir -p ~/eks-backups
cp eks-full-backup.sh ~/eks-backups/
cd ~/eks-backups
chmod +x eks-full-backup.sh
bash -n eks-full-backup.sh && echo "syntax OK"
```

**Expected output:**

```
syntax OK
```

**Important to know:** Run the `cp` command from the folder where you saved the script. If it says `No such file or directory`, check where the file was downloaded.

---

### Step 7: Run the backup

**Explanation:** The script has 7 stages. It takes a few minutes, depending on how many namespaces and resources you have.

**Commands:**

```bash
cd ~/eks-backups
./eks-full-backup.sh my-eks-cluster us-east-1
```

You can optionally add the upgrade target version as a third argument:

```bash
./eks-full-backup.sh my-eks-cluster us-east-1 1.35
```

If you leave it out, the script uses the next minor version.

**Expected output (shortened):**

```
10:42:01 === EKS full backup started ===
10:42:01 Cluster : my-eks-cluster
10:42:01 Region  : us-east-1
10:42:03 >> [1/7] Saving EKS control plane configuration...
10:42:06 >> [2/7] Saving access and auth settings...
10:42:09 >> [3/7] Saving add-ons, node groups and Fargate profiles...
10:42:12 >> [4/7] Saving upgrade insights (deprecated APIs, blockers)...
10:42:14 >> [5/7] Saving cluster-scoped Kubernetes objects...
10:42:40 >> [6/7] Saving namespaced Kubernetes objects (all namespaces)...
   namespace default done
   namespace kube-system done
10:44:10 >> [7/7] Saving kube-system components in one file...

EKS full backup summary
Cluster       : my-eks-cluster
K8s version   : 1.34
Namespaces    : 6
Nodes         : 3
Add-ons       : 3
Node groups   : 1
YAML files    : 140
Warnings      : 0

10:44:15 === DONE ===
Backup folder : /home/<you>/eks-backups/eks-full-backup-my-eks-cluster-<timestamp>
Backup archive: /home/<you>/eks-backups/eks-full-backup-my-eks-cluster-<timestamp>.tar.gz
```

**Important to know:**
- Do not press Ctrl+C while it runs.
- A failed step is logged as a warning, and the script keeps going.
- The script uses read-only commands. It does not change your cluster.

---

### Step 8: Read the summary

**Explanation:** The summary tells you at a glance whether the backup looks complete.

**Commands:**

```bash
cat ~/eks-backups/eks-full-backup-my-eks-cluster-*/SUMMARY.txt
```

**Expected output:**

```
EKS full backup summary
Cluster       : my-eks-cluster
Region        : us-east-1
K8s version   : 1.34
Namespaces    : 6
Nodes         : 3
...
Warnings      : 0
```

**Important to know:** `Warnings : 0` is what you want. If the number is higher, go to Step 10.

---

## Part 3: Verify and protect the backup

### Step 9: Check the folder contents

**Explanation:** Confirm the important files really exist.

**Commands:**

```bash
cd ~/eks-backups/eks-full-backup-my-eks-cluster-*/
ls
ls eks/ addons/ nodegroups/
ls k8s/namespaced/
```

**Expected output:**

```
access  addons  backup.log  eks  fargate  iam  k8s  nodegroups  SUMMARY.txt

eks/:
api-resources.txt  api-versions.txt  cluster-version.txt  cluster.json  nodes.txt  oidc-issuer.txt  upgrade-insights.json

addons/:
addon-coredns.json  addon-kube-proxy.json  addon-vpc-cni.json

nodegroups/:
nodegroup-my-worker-node.json

default  kube-node-lease  kube-public  kube-system  <your-app-namespace>
```

**Important to know:**
- `fargate/` is empty if you do not use Fargate. That is fine.
- `access/aws-auth.yaml` may be missing if your cluster uses access entries instead. That is fine.

---

### Step 10: Check for warnings

**Explanation:** The log lists anything that could not be saved.

**Commands:**

```bash
grep WARN backup.log || echo "no warnings"
```

**Expected output:**

```
no warnings
```

**Important to know:**
- A warning such as "Upgrade insights not available" usually means an old AWS CLI. Update it and re-run.
- A warning about a missing permission means your IAM user cannot read that item. Add the permission and re-run.

---

### Step 11: Check your app is in the backup

**Explanation:** Prove the objects you care about are really saved.

**Commands:**

```bash
ls k8s/namespaced/<your-app-namespace>/
grep -c "kind:" k8s/namespaced/<your-app-namespace>/deployments.apps.yaml
```

**Expected output:**

```
configmaps.yaml  deployments.apps.yaml  pods.yaml  replicasets.apps.yaml  secrets.yaml  serviceaccounts.yaml  services.yaml
3
```

**Important to know:** Replace `<your-app-namespace>` with your real namespace (list them with `kubectl get ns`). The count is the number of `kind:` lines, so it will vary.

---

### Step 12: Verify the archive checksum

**Explanation:** The script creates a `.sha256` file next to the archive. Checking it proves the archive is not corrupted.

**Commands:**

```bash
cd ~/eks-backups
sha256sum -c eks-full-backup-my-eks-cluster-*.tar.gz.sha256
```

**Expected output:**

```
eks-full-backup-my-eks-cluster-20261028-104201.tar.gz: OK
```

**Important to know:** If it says `FAILED`, delete that archive and run the backup again.

---

### Step 13: Copy the backup to S3 (off your machine)

**Explanation:** If your machine dies, a local backup dies with it. This creates a private, encrypted, versioned bucket and uploads the archive.

**Commands:**

```bash
export BACKUP_BUCKET=eks-backups-$ACCOUNT-$REGION

aws s3 mb s3://$BACKUP_BUCKET --region $REGION

aws s3api put-public-access-block --bucket $BACKUP_BUCKET \
  --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

aws s3api put-bucket-versioning --bucket $BACKUP_BUCKET --versioning-configuration Status=Enabled

aws s3 cp ~/eks-backups/ s3://$BACKUP_BUCKET/$CLUSTER/ --recursive \
  --exclude "*" --include "*.tar.gz" --include "*.sha256" --sse AES256

aws s3 ls s3://$BACKUP_BUCKET/$CLUSTER/
```

**Expected output:**

```
make_bucket: eks-backups-123456789012-us-east-1
upload: eks-backups/eks-full-backup-my-eks-cluster-....tar.gz to s3://eks-backups-123456789012-us-east-1/my-eks-cluster/...
2026-10-28 10:50:01   2345678 eks-full-backup-my-eks-cluster-20261028-104201.tar.gz
2026-10-28 10:50:01       112 eks-full-backup-my-eks-cluster-20261028-104201.tar.gz.sha256
```

**Important to know:**
- If the bucket already exists, `mb` prints an error. That is fine, continue with the next commands.
- Never commit these files to Git, never share them, and never make the bucket public. They contain Secrets.
- For any region **other than** `us-east-1`, use `aws s3api create-bucket ... --create-bucket-configuration LocationConstraint=$REGION` instead of `aws s3 mb`.

---

## Part 4: Before an upgrade, and automation

### Step 14: Check upgrade insights for the target version

**Explanation:** EKS tells you if your cluster uses APIs that will be removed in the next version. The script saved these, but reading them yourself is worth the minute.

**Commands:**

```bash
export TARGET=1.35

aws eks list-insights --cluster-name $CLUSTER --region $REGION \
  --filter kubernetesVersions=$TARGET \
  --query "insights[].{Name:name,Status:insightStatus.status}" --output table
```

**Expected output:**

```
---------------------------------------------
|               ListInsights                |
+----------------------------------+--------+
|              Name                | Status |
+----------------------------------+--------+
|  Deprecated APIs removed in 1.35 | PASSING|
|  ...                             | PASSING|
+----------------------------------+--------+
```

If a row shows `ERROR` or `WARNING`, read the details:

```bash
aws eks describe-insight --cluster-name $CLUSTER --region $REGION --id <INSIGHT_ID>
```

**Important to know:** Fix any `ERROR` **before** you upgrade. Your fresh backup is the safety net for the YAML you may need to change.

---

### Step 15: (Optional) Run the backup automatically every day

**Explanation:** `cron` runs the script on a schedule, so you always have a recent backup.

**Commands:**

```bash
crontab -e
```

Add these lines at the bottom (runs at 02:00 every day), then save:

```
PATH=/usr/local/bin:/usr/bin:/bin:/home/<your-user>/.local/bin
0 2 * * * /home/<your-user>/eks-backups/eks-full-backup.sh my-eks-cluster us-east-1 >> /home/<your-user>/eks-backups/cron.log 2>&1
```

Check it was saved:

```bash
crontab -l
```

**Expected output:** The two lines you added.

**Important to know:**
- Replace `<your-user>` with your Linux username (`whoami` shows it).
- `cron` needs working AWS credentials. If you use SSO or temporary credentials, they may expire and the job will fail. Check `cron.log`.
- Old backups pile up. To see which folders are older than 14 days (this only lists them, it does not delete):

```bash
find ~/eks-backups -maxdepth 1 -name 'eks-full-backup-*' -mtime +14
```

---

## Part 5: Restore

> **Important to know:** Restoring from YAML is for **recovering an app or a few objects**, not for rebuilding a whole cluster. For whole-cluster restores, Velero (see the Velero guide) is far easier and safer.

### Step 16: Prepare the YAML for re-applying

**Explanation:** Exported YAML contains fields Kubernetes sets by itself (`uid`, `resourceVersion`, `status`, ...). Creating an object that still has `resourceVersion` set fails, so you must remove those fields first. `yq` does this.

**Commands:**

Install `yq` (one-time):

```bash
sudo snap install yq
yq --version
```

Clean a file (example: Deployments of one namespace):

```bash
cd ~/eks-backups/eks-full-backup-my-eks-cluster-*/k8s/namespaced/<your-app-namespace>/

yq 'del(.items[].metadata.uid, .items[].metadata.resourceVersion, .items[].metadata.creationTimestamp, .items[].metadata.managedFields, .items[].metadata.ownerReferences, .items[].status)' \
  deployments.apps.yaml > /tmp/deployments-clean.yaml

head -20 /tmp/deployments-clean.yaml
```

**Expected output:**

```
yq (https://github.com/mikefarah/yq/) version v4.x.x
```

and a YAML file starting with `apiVersion: v1` / `items:` that no longer contains `uid:`, `resourceVersion:` or `status:` lines.

**Important to know:**
- If `snap` is not available, download `yq` from https://github.com/mikefarah/yq/releases.
- Service objects also carry a fixed `clusterIP`. If the IP is taken, add `.items[].spec.clusterIP` to the `del(...)` list.

---

### Step 17: Restore an app in the correct order

**Explanation:** Objects depend on each other, so the order matters.

**Commands:**

```bash
export NS=<your-app-namespace>
export SRC=$(ls -d ~/eks-backups/eks-full-backup-my-eks-cluster-*/k8s/namespaced/$NS)

# 1. The namespace
kubectl create namespace $NS --dry-run=client -o yaml | kubectl apply -f -

# 2. Config and access objects first
for f in configmaps serviceaccounts secrets persistentvolumeclaims; do
  [ -f "$SRC/$f.yaml" ] && yq 'del(.items[].metadata.uid, .items[].metadata.resourceVersion, .items[].metadata.creationTimestamp, .items[].metadata.managedFields, .items[].metadata.ownerReferences, .items[].status)' "$SRC/$f.yaml" | kubectl apply -f -
done

# 3. The workloads and services
for f in deployments.apps statefulsets.apps services; do
  [ -f "$SRC/$f.yaml" ] && yq 'del(.items[].metadata.uid, .items[].metadata.resourceVersion, .items[].metadata.creationTimestamp, .items[].metadata.managedFields, .items[].metadata.ownerReferences, .items[].status)' "$SRC/$f.yaml" | kubectl apply -f -
done

kubectl get all -n $NS
```

**Expected output:**

```
namespace/<your-app-namespace> created
configmap/... created
deployment.apps/... created
service/... created

NAME                       READY   STATUS    RESTARTS   AGE
pod/web-xxxxxxxxxx-aaaaa   1/1     Running   0          20s
```

**Important to know:**
- **Do not** apply `pods.yaml`, `replicasets.apps.yaml`, `endpoints` or `events`. Deployments create those themselves.
- **Do not** apply anything from `kube-system`. EKS manages those.
- Restoring a PVC recreates the claim, but **not the disk data**. Restore the data from an EBS snapshot or Velero.
- Applying over an object that still exists may report a conflict. Delete the broken object first.

---

### Step 18: Rebuild a lost cluster from the saved configuration

**Explanation:** `eks/cluster.json` and `nodegroups/*.json` record how the cluster was built. Use them as your reference to create an identical cluster.

**Commands:**

```bash
cd ~/eks-backups/eks-full-backup-my-eks-cluster-*/

# Key settings to copy
grep -E '"version"|"endpointPublicAccess"|"endpointPrivateAccess"' eks/cluster.json
grep -E '"instanceTypes"|"minSize"|"maxSize"|"desiredSize"|"diskSize"|"amiType"' nodegroups/*.json
```

Create the new cluster with the same values, for example:

```bash
eksctl create cluster --name my-eks-cluster --region us-east-1 --version 1.34 \
  --nodegroup-name my-worker-node --node-type t3.large --nodes 3 --managed
```

Then restore your add-on versions and apps (Step 17, or Velero).

**Expected output (end of the eksctl log):**

```
[✔]  EKS cluster "my-eks-cluster" in "us-east-1" region is ready
```

**Important to know:**
- The values in the `eksctl` example are placeholders. Take the real values from your saved `cluster.json` and `nodegroup-*.json`.
- IAM role mappings, access entries and OIDC settings are in `access/` and `iam/`. Re-create them on the new cluster.
- Restoring to a different Kubernetes version than the backup is possible, but test it first.

---

## 6. Troubleshooting

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| `ERROR: 'aws' is not installed` | Tool missing or not in PATH | Install it, or `export PATH=$PATH:$HOME/.local/bin` |
| `ERROR: AWS credentials are not working` | Missing or expired credentials | `aws configure`, or refresh your SSO login |
| `ERROR: kubectl cannot reach the cluster` | Wrong cluster, VPN needed, or private endpoint | Re-run Step 3; check the cluster endpoint access settings in `eks/cluster.json` |
| `error: You must be logged in to the server (Unauthorized)` | Not the identity that created the cluster | Use the creator IAM user/role, or ask for an access entry |
| `Warnings` is above 0 | A resource or permission problem | `grep WARN backup.log` and fix the named item |
| "Upgrade insights not available" | AWS CLI too old | Update the AWS CLI and re-run |
| Backup takes very long | Many namespaces and resource types | Normal; each namespace is read separately |
| Restore says `resourceVersion should not be set on objects to be created` | YAML not cleaned | Use the `yq del(...)` command in Step 16 |
| `sha256sum -c` says `FAILED` | Corrupted archive | Delete it and run the backup again |

---

## 7. Final checklist

- [ ] `kubectl get nodes` shows all nodes `Ready`, and no failing pods
- [ ] The script finished with `Warnings : 0`
- [ ] `ls` shows `eks/`, `addons/`, `nodegroups/` and your app's namespace folder
- [ ] The checksum check prints `OK`
- [ ] The archive is copied to a private, encrypted S3 bucket
- [ ] Upgrade insights for the target version show no `ERROR`
- [ ] Persistent volume data is protected separately (Velero or EBS snapshots)
- [ ] Anything outside the cluster has its own backup
- [ ] Backups are never shared or committed to Git

> **Remember:** This script protects the configuration and the objects. Pair it with Velero for volume data, and keep at least one backup taken **right before** each upgrade.
