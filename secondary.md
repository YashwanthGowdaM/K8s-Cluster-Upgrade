# EKS Cluster: Backup + Upgrade Guide (1.34 → 1.35 → 1.36)

A beginner-friendly, copy-paste guide for the cluster created with:

```bash
eksctl create cluster --name my-eks-cluster --nodegroup-name my-worker-node \
  --node-type t2.medium --nodes 2 --managed --region us-east-1
```

**What you will achieve**

| Task | What it means on EKS |
|------|----------------------|
| Part 2 – "Back up etcd & API server" | Save every Kubernetes object (the data etcd stores, read through the API server) + the AWS-side cluster config |
| Part 3 – Upgrade | Move the cluster **1.34 → 1.35** and then, optionally, **1.35 → 1.36** |

> **What is new in this version:** Part 3 now documents the full upgrade cycle exactly as it was run for **1.34 → 1.35** and **1.35 → 1.36**, including the extra verification and dependency checks (Upgrade Insights, add-on inventory and Default versions, capacity checks, DNS test, node and pod watches, `/readyz`, `describe-update`). Every step has **Explanation → Commands → Expected output → Verification**. Part 4 is a **1.34 / 1.35 / 1.36 comparison table**. Real account IDs, subnet IDs and insight IDs in the outputs were replaced with placeholders. The Velero section (2.5) was not exercised in these runs.

---

## 0. Read this first (5 minutes)

### 0.1 Tiny glossary

| Term | Plain-English meaning |
|------|-----------------------|
| **Control plane** | The "brain" of Kubernetes. It contains the API server and etcd. On EKS, **AWS runs it for you**. |
| **API server** | The front door. Every command you type with `kubectl` talks to it. |
| **etcd** | The database where Kubernetes stores everything (deployments, secrets, configs). |
| **Node / worker node** | The EC2 machines that run your apps. You have 2 (`t2.medium`). |
| **Node group** | A set of identical worker nodes (yours is `my-worker-node`). |
| **Add-on** | System components such as `kube-proxy`, `vpc-cni`, `coredns` that must be upgraded with the cluster. |
| **Pod** | The smallest unit that runs your container(s). |

### 0.2 Important truth about "etcd backup" on EKS

On a self-built cluster you run `etcdctl snapshot save`. **On EKS you cannot do that**: etcd and the API server run inside AWS's managed control plane, and you have no SSH or direct access to them. AWS already replicates and backs up etcd for you.

What you *can* (and should) back up yourself is:

1. **All Kubernetes objects**, read through the API server. This is exactly the data stored in etcd that matters to you. (Method A and Method B below.)
2. **Persistent volume data** (EBS disks), if you use any. (Method B, Velero.)
3. **AWS-side cluster configuration** (version, node group, add-ons, IAM). (Step 2.2.)

So "backup of etcd & API server" = steps in Part 2.

### 0.3 Upgrade rules you must know

* EKS upgrades **one minor version at a time**. You **cannot jump 1.34 → 1.36**. Do **1.34 → 1.35**, then **1.35 → 1.36**.
* Order is always: **(1) control plane → (2) add-ons → (3) worker nodes**.
* **A control plane upgrade cannot be rolled back.** That is why we back up first.
* The control plane upgrade has no downtime for the API in normal cases; worker nodes are replaced one at a time (rolling).
* In the lab run, AWS listed 1.34, 1.35, 1.36 **and 1.37** as `STANDARD_SUPPORT`. Confirm with the command in Step 1.4.

### 0.4 Cost warning

An EKS control plane costs about **$0.10 per hour** plus EC2 nodes (during a node group upgrade you briefly pay for 4 nodes instead of 2). Delete the cluster when finished practising (see Part 6).

---

## 1. Prerequisites and health check

### 1.1 Confirm the tools are installed

#### 1.1.a Install `eksctl` (only if it is missing): download

**Explanation**
Downloads the latest `eksctl` release and unpacks it into `/tmp`.

**Command**

```bash
curl --silent --location "https://github.com/weaveworks/eksctl/releases/latest/download/eksctl_$(uname -s)_amd64.tar.gz" | tar xz -C /tmp
```

**Expected output**
No output (`--silent`).

**Verification**
✅ `ls -l /tmp/eksctl` shows the file.

#### 1.1.b Install `eksctl` (only if it is missing): move it into the PATH

**Explanation**
Puts the binary in `/usr/local/bin` so the `eksctl` command works from anywhere.

**Command**

```bash
sudo mv /tmp/eksctl /usr/local/bin
```

**Expected output**
No output.

**Verification**
✅ `which eksctl` prints `/usr/local/bin/eksctl`.

#### 1.1.c Check `eksctl`

**Explanation**
Prints the installed `eksctl` version.

**Command**

```bash
eksctl version
```

**Expected output (version will differ; this is the lab version)**

```
0.231.0
```

**Verification**
✅ A version number is printed. `command not found` means redo 1.1.a and 1.1.b.

#### 1.1.d Check `kubectl`

**Explanation**
Prints only the client version (it does not contact a cluster).

**Command**

```bash
kubectl version --client
```

**Expected output**

```
Client Version: v1.37.1
Kustomize Version: v5.8.1
```

**Verification**
✅ A client version is printed. `kubectl` should be within ±1 minor version of the cluster; a 1.37 client against a 1.34 or 1.35 cluster works but prints a *version skew* warning on `kubectl version`. It is only a warning.

#### 1.1.e Check the AWS CLI

**Explanation**
Prints the AWS CLI version. It must be new enough to know `describe-cluster-versions` and `list-insights`.

**Command**

```bash
aws --version
```

**Expected output**

```
aws-cli/2.38.5 Python/3.14.8 Linux/7.0.0-1014-aws exe/x86_64.ubuntu.26
```

**Verification**
✅ A version is printed. If a command says `command not found`, redo that install step from your setup notes.

### 1.2 Confirm AWS credentials work

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

If you get `Unable to locate credentials`, run `aws configure` and enter your Access Key, Secret Key, region `us-east-1`, output `json`.

> Use the same IAM user/role that created the cluster. It needs permissions for EKS, EC2, IAM, CloudFormation and S3.

### 1.3 Connect `kubectl` to the cluster

Set variables once (copy these into every new terminal):

```bash
export CLUSTER=my-eks-cluster
export REGION=us-east-1
export NODEGROUP=my-worker-node
export ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
```

Load the variables in a new terminal (the lab kept them in `~/.bashrc`):

#### 1.3.a Load the saved variables

**Explanation**
Reads `~/.bashrc` so `CLUSTER`, `REGION`, `NODEGROUP` and `ACCOUNT` exist in this terminal.

**Command**

```bash
source ~/.bashrc
```

**Expected output**
No output.

**Verification**
✅ The next sub-step prints all four values.

#### 1.3.b Check the variables

**Explanation**
Prints the four variables, one per line.

**Command**

```bash
echo -e "$CLUSTER\n$REGION\n$NODEGROUP\n$ACCOUNT"
```

**Expected output**

```
my-eks-cluster
us-east-1
my-worker-node
123456789012
```

**Verification**
✅ Four non-empty lines. An empty line means that variable is not set; redo the `export` lines above.

#### 1.3.c Create the kubeconfig entry

```bash
aws eks update-kubeconfig --name $CLUSTER --region $REGION
```

**Expected output:**

```
Added new context arn:aws:eks:us-east-1:123456789012:cluster/my-eks-cluster to /home/<you>/.kube/config
```

Test the connection:

```bash
kubectl get nodes
```

**Expected output:**

```
NAME                             STATUS   ROLES    AGE   VERSION
ip-192-168-xx-xx.ec2.internal    Ready    <none>   2h    v1.34.x-eks-xxxxxxx
ip-192-168-yy-yy.ec2.internal    Ready    <none>   2h    v1.34.x-eks-xxxxxxx
```

Both nodes must be `Ready`. If not, stop and fix that first.

### 1.4 Check the current version and which versions are available

```bash
aws eks describe-cluster --name $CLUSTER --region $REGION --query "cluster.version" --output text
```

**Expected output:** `1.34`

```bash
aws eks describe-cluster-versions --region $REGION \
  --query "clusterVersions[].{Version:clusterVersion,Status:status}" --output table
```

**Expected output (from the lab):**

```
|  STANDARD_SUPPORT |  1.37     |
|  STANDARD_SUPPORT |  1.36     |
|  STANDARD_SUPPORT |  1.35     |
|  STANDARD_SUPPORT |  1.34     |
|  EXTENDED_SUPPORT |  1.33     |
|  EXTENDED_SUPPORT |  1.32     |
|  EXTENDED_SUPPORT |  1.31     |
```

`1.35` and `1.36` must be listed (here `STANDARD_SUPPORT`).

> If `describe-cluster-versions` is not recognised, your AWS CLI is old. Update it (re-run the AWS-CLI install steps; add `--update` to `sudo ./aws/install`).

### 1.5 (Recommended) Deploy a sample app so you can prove nothing breaks

```bash
kubectl create namespace demo
kubectl create deployment web --image=nginx --replicas=2 -n demo
kubectl expose deployment web --port=80 -n demo
kubectl get all -n demo
```

**Expected output (similar):**

```
NAME                       READY   STATUS    RESTARTS   AGE
pod/web-xxxxxxxxxx-aaaaa   1/1     Running   0          20s
pod/web-xxxxxxxxxx-bbbbb   1/1     Running   0          20s

NAME          TYPE        CLUSTER-IP     EXTERNAL-IP   PORT(S)   AGE
service/web   ClusterIP   10.100.x.x     <none>        80/TCP    15s

NAME                  READY   UP-TO-DATE   AVAILABLE   AGE
deployment.apps/web   2/2     2            2           20s
```

### 1.6 Check all system pods are healthy

```bash
kubectl get pods -A
```

**Expected:** every pod is `Running` (or `Completed`). In the lab cluster the `kube-system` namespace held these pods, each with `READY` complete:

```
aws-node-xxxxx          2/2   Running      (2 pods, one per node)
coredns-xxxxxxxxxx-xxxxx    1/1   Running      (2 pods)
kube-proxy-xxxxx        1/1   Running      (2 pods, one per node)
metrics-server-xxxxxxxxxx-xxxxx   1/1   Running   (2 pods)
```

Anything `Pending`, `CrashLoopBackOff` or `Error` should be fixed **before** any upgrade. To list only the unhealthy ones: `kubectl get pods -A | grep -v -E "Running|Completed"` (only the header line should print).

> Two convenience shell aliases were used in the lab terminal: `kns` (list namespaces) and `kgp` (list pods in all namespaces). They are not required; the plain `kubectl get ns` and `kubectl get pods -A` do the same.

---

## 2. TASK 1: Backup (etcd data + API server objects + cluster config)

Do **Step 2.1 and 2.2 always**. **Method B (Velero)** is optional but recommended if you have persistent volumes or want one-command restore.

### Step 2.1: Method A: Export every Kubernetes object to YAML files

This reads everything through the API server (the same data etcd holds) and stores it as files. No extra tools needed.

Create the script:

```bash
mkdir -p ~/eks-backups && cd ~/eks-backups
cat > backup-k8s.sh <<'EOF'
#!/bin/bash
# Exports all Kubernetes objects of the current cluster to YAML files.
set -u
STAMP=$(date +%Y%m%d-%H%M%S)
DIR="$HOME/eks-backups/k8s-backup-$STAMP"
mkdir -p "$DIR/cluster-scoped" "$DIR/namespaced"

echo ">> Backing up cluster-scoped resources..."
for r in $(kubectl api-resources --namespaced=false --verbs=list -o name | grep -v -E '^(events|events.events.k8s.io|componentstatuses)$'); do
  if [ -n "$(kubectl get "$r" -o name 2>/dev/null)" ]; then
    kubectl get "$r" -o yaml > "$DIR/cluster-scoped/$r.yaml" 2>/dev/null
  fi
done

echo ">> Backing up namespaced resources..."
NAMESPACED=$(kubectl api-resources --namespaced=true --verbs=list -o name | grep -v -E '^(events|events.events.k8s.io|endpoints|endpointslices.discovery.k8s.io)$')
for ns in $(kubectl get ns -o jsonpath='{.items[*].metadata.name}'); do
  mkdir -p "$DIR/namespaced/$ns"
  for r in $NAMESPACED; do
    if [ -n "$(kubectl get "$r" -n "$ns" -o name 2>/dev/null)" ]; then
      kubectl get "$r" -n "$ns" -o yaml > "$DIR/namespaced/$ns/$r.yaml" 2>/dev/null
    fi
  done
  echo "   namespace $ns done"
done

tar -czf "$DIR.tar.gz" -C "$HOME/eks-backups" "k8s-backup-$STAMP"
echo ">> DONE. Backup folder : $DIR"
echo ">> DONE. Backup archive: $DIR.tar.gz"
EOF
chmod +x backup-k8s.sh
```

Run it (takes 1–5 minutes):

```bash
./backup-k8s.sh
```

**Expected output (similar):**

```
>> Backing up cluster-scoped resources...
>> Backing up namespaced resources...
   namespace default done
   namespace demo done
   namespace kube-node-lease done
   namespace kube-public done
   namespace kube-system done
>> DONE. Backup folder : /home/<you>/eks-backups/k8s-backup-20261024-101500
>> DONE. Backup archive: /home/<you>/eks-backups/k8s-backup-20261024-101500.tar.gz
```

Verify the backup contains your demo app:

```bash
ls ~/eks-backups/k8s-backup-*/namespaced/demo/
```

**Expected output (similar):**

```
configmaps.yaml  deployments.apps.yaml  pods.metrics.k8s.io.yaml  pods.yaml  replicasets.apps.yaml  serviceaccounts.yaml  services.yaml
```

(`pods.metrics.k8s.io.yaml` appears because the `metrics-server` add-on is installed.) Every run of the script creates a **new** timestamped folder and archive, so you keep one backup per run (the lab ended up with three: before the 1.35 upgrade, right before it, and before the 1.36 upgrade).

> ⚠️ **Security:** the backup contains **Secrets** (base64, not encrypted). Never commit it to Git or share it. Restrict access: `chmod -R go-rwx ~/eks-backups`.

### Step 2.2: Back up the AWS-side cluster configuration

Each command saves one piece of AWS-side configuration into a timestamped folder.

#### 2.2.a Create a folder for the AWS-side configuration

**Explanation**
Stores the folder name in a variable first, so the `cd` always goes to the folder that was just created.

**Command**

```bash
AWSDIR=~/eks-backups/aws-config-$(date +%Y%m%d-%H%M%S)
mkdir -p $AWSDIR && cd $AWSDIR
```

**Expected output**
No output (the command succeeds silently).

**Verification**
✅ `pwd` prints `/home/ubuntu/eks-backups/aws-config-<timestamp>`.

#### 2.2.b Save `cluster.json`

**Explanation**
Saves the full AWS description of the cluster (version, endpoint, VPC, logging, status).

**Command**

```bash
aws eks describe-cluster --name $CLUSTER --region $REGION > cluster.json
```

**Expected output**
No output (the command succeeds silently).

**Verification**
✅ `cluster.json` exists and is not empty (`ls -l` in the next sub-step).

#### 2.2.c Save `nodegroups-list.json`

**Explanation**
Saves the list of node group names in the cluster.

**Command**

```bash
aws eks list-nodegroups --cluster-name $CLUSTER --region $REGION > nodegroups-list.json
```

**Expected output**
No output (the command succeeds silently).

**Verification**
✅ `nodegroups-list.json` exists and is not empty (`ls -l` in the next sub-step).

#### 2.2.d Save `nodegroup.json`

**Explanation**
Saves the node group settings (version, release version, scaling, AMI type, instance types).

**Command**

```bash
aws eks describe-nodegroup --cluster-name $CLUSTER --nodegroup-name $NODEGROUP --region $REGION > nodegroup.json
```

**Expected output**
No output (the command succeeds silently).

**Verification**
✅ `nodegroup.json` exists and is not empty (`ls -l` in the next sub-step).

#### 2.2.e Save `addons.json`

**Explanation**
Saves the names of the installed managed add-ons.

**Command**

```bash
aws eks list-addons --cluster-name $CLUSTER --region $REGION > addons.json
```

**Expected output**
No output (the command succeeds silently).

**Verification**
✅ `addons.json` exists and is not empty (`ls -l` in the next sub-step).

#### 2.2.f Save `eksctl-cluster.yaml`

**Explanation**
Saves eksctl's view of the cluster as YAML.

**Command**

```bash
eksctl get cluster --name $CLUSTER --region $REGION -o yaml > eksctl-cluster.yaml
```

**Expected output**
No output (the command succeeds silently).

**Verification**
✅ `eksctl-cluster.yaml` exists (if it is empty that is fine; `cluster.json` and `nodegroup.json` hold the important data).

#### 2.2.g Save `eksctl-nodegroup.yaml`

**Explanation**
Saves eksctl's view of the node group as YAML.

**Command**

```bash
eksctl get nodegroup --cluster $CLUSTER --region $REGION -o yaml > eksctl-nodegroup.yaml
```

**Expected output**
No output (the command succeeds silently).

**Verification**
✅ `eksctl-nodegroup.yaml` exists (if it is empty that is fine; `cluster.json` and `nodegroup.json` hold the important data).

#### 2.2.h Save `kubectl-version.txt`

**Explanation**
Records the client and server versions before the change.

**Command**

```bash
kubectl version > kubectl-version.txt
```

**Expected output**

```
Warning: version difference between client (1.37) and server (1.35) exceeds the supported minor version skew of +/-1
```

**Verification**
✅ `kubectl-version.txt` exists. The warning is printed to the terminal only when your `kubectl` is more than one minor version away; it is harmless here. If your client is within ±1 there is no output.

#### 2.2.i Save `nodes.txt`

**Explanation**
Records node names, versions, IPs and OS image before the change.

**Command**

```bash
kubectl get nodes -o wide > nodes.txt
```

**Expected output**
No output (the command succeeds silently).

**Verification**
✅ `nodes.txt` exists and is not empty (`ls -l` in the next sub-step).

#### 2.2.j List the saved files

**Explanation**
Confirms all eight files were written and are not empty.

**Command**

```bash
ls -l
```

**Expected output**

```
total 40
-rw-rw-r-- 1 ubuntu ubuntu  111 Oct 24 04:13 addons.json
-rw-rw-r-- 1 ubuntu ubuntu 5650 Oct 24 04:13 cluster.json
-rw-rw-r-- 1 ubuntu ubuntu 4383 Oct 24 04:13 eksctl-cluster.yaml
-rw-rw-r-- 1 ubuntu ubuntu  509 Oct 24 04:13 eksctl-nodegroup.yaml
-rw-rw-r-- 1 ubuntu ubuntu   87 Oct 24 04:13 kubectl-version.txt
-rw-rw-r-- 1 ubuntu ubuntu 2311 Oct 24 04:13 nodegroup.json
-rw-rw-r-- 1 ubuntu ubuntu   55 Oct 24 04:13 nodegroups-list.json
-rw-rw-r-- 1 ubuntu ubuntu  606 Oct 24 04:13 nodes.txt
```

**Verification**
✅ Eight files are listed (`addons.json`, `cluster.json`, `eksctl-cluster.yaml`, `eksctl-nodegroup.yaml`, `kubectl-version.txt`, `nodegroup.json`, `nodegroups-list.json`, `nodes.txt`).

(If an `eksctl get ...` file is empty, that's fine; `cluster.json` and `nodegroup.json` hold the important data.)

### Step 2.3: Copy backups to S3 (so they survive if your machine dies)

#### 2.3.a Set the backup bucket name

**Explanation**
Builds a unique S3 bucket name from your account ID and region and keeps it in a variable for the next commands.

**Command**

```bash
export BACKUP_BUCKET=eks-backups-$ACCOUNT-$REGION
```

**Expected output**
No output (the command succeeds silently).

**Verification**
✅ `echo $BACKUP_BUCKET` prints `eks-backups-123456789012-us-east-1`.

#### 2.3.b Create the S3 bucket

**Explanation**
Creates the bucket that will hold the off-machine copy of your backups.

**Command**

```bash
aws s3 mb s3://$BACKUP_BUCKET --region $REGION
```

**Expected output**

```
make_bucket: eks-backups-123456789012-us-east-1
```

**Verification**
✅ The `make_bucket:` line is printed. On a repeat run for the same bucket you already own in the same region, the same line was printed again; that is harmless.

#### 2.3.c Copy the backups to S3

**Explanation**
Uploads everything under `~/eks-backups` (archives, extracted YAML, AWS config files, the script). `sync` is incremental, so later runs upload only new files.

**Command**

```bash
aws s3 sync ~/eks-backups s3://$BACKUP_BUCKET/$CLUSTER/
```

**Expected output**

```
upload: ./cluster.json to s3://eks-backups-123456789012-us-east-1/my-eks-cluster/aws-config-20261024/cluster.json
upload: ../k8s-backup-20261024-040705.tar.gz to s3://eks-backups-123456789012-us-east-1/my-eks-cluster/k8s-backup-20261024-040705.tar.gz
...
```

**Verification**
✅ One `upload:` line per file and no `error` lines.

#### 2.3.d List what is in S3

**Explanation**
Proves the files really arrived in the bucket.

**Command**

```bash
aws s3 ls s3://$BACKUP_BUCKET/$CLUSTER/ --recursive | head
```

**Expected output**

```
2026-10-24 04:16:13        111 my-eks-cluster/aws-config-20261024/addons.json
2026-10-24 04:16:13       5650 my-eks-cluster/aws-config-20261024/cluster.json
...
2026-10-24 04:16:13       1241 my-eks-cluster/backup-k8s.sh
2026-10-24 04:16:13      78435 my-eks-cluster/k8s-backup-20261024-040705.tar.gz
```

**Verification**
✅ The `.tar.gz` archive and the `aws-config-...` files are listed.

> If you also see `BrokenPipeError: [Errno 32] Broken pipe`, it is only `head` closing the pipe early; the listing is fine.

### Step 2.4: How to restore from Method A (when needed)

Only run this if something was deleted or broken:

```bash
# Example: restore just the demo namespace
kubectl create namespace demo --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f ~/eks-backups/k8s-backup-<STAMP>/namespaced/demo/deployments.apps.yaml
kubectl apply -f ~/eks-backups/k8s-backup-<STAMP>/namespaced/demo/services.yaml
```

> Exported YAML includes read-only fields (`status`, `uid`, `resourceVersion`). `kubectl apply` usually tolerates them for Deployments/Services, but for a full-cluster restore **Velero (Method B) is far easier and safer**.

---

### Step 2.5 (Optional, recommended): Method B: Velero (backup + restore + EBS volume snapshots)

Velero is a standard Kubernetes backup tool. It saves objects to S3 and snapshots EBS volumes. Skip this section if you only want the simple method above.

#### 2.5.1 Install the Velero CLI

Check the latest release number at https://github.com/vmware-tanzu/velero/releases and set it here:

```bash
export VELERO_VERSION=v1.16.2     # <-- replace with the latest release
cd /tmp
curl -L https://github.com/vmware-tanzu/velero/releases/download/${VELERO_VERSION}/velero-${VELERO_VERSION}-linux-amd64.tar.gz -o velero.tar.gz
tar -xzf velero.tar.gz
mv velero-${VELERO_VERSION}-linux-amd64/velero ~/.local/bin/velero
velero version --client-only
```

**Expected output:**

```
Client:
	Version: v1.16.2
	Git commit: xxxxxxxx
```

#### 2.5.2 Create the S3 bucket for Velero

```bash
export VELERO_BUCKET=velero-$CLUSTER-$ACCOUNT
aws s3api create-bucket --bucket $VELERO_BUCKET --region $REGION
```

**Expected output:**

```json
{
    "Location": "/velero-my-eks-cluster-123456789012"
}
```

#### 2.5.3 Create the IAM permissions

```bash
cat > velero-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ec2:DescribeVolumes", "ec2:DescribeSnapshots", "ec2:CreateTags",
        "ec2:CreateVolume", "ec2:CreateSnapshot", "ec2:DeleteSnapshot"
      ],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "s3:GetObject", "s3:DeleteObject", "s3:PutObject",
        "s3:AbortMultipartUpload", "s3:ListMultipartUploadParts"
      ],
      "Resource": "arn:aws:s3:::${VELERO_BUCKET}/*"
    },
    {
      "Effect": "Allow",
      "Action": ["s3:ListBucket"],
      "Resource": "arn:aws:s3:::${VELERO_BUCKET}"
    }
  ]
}
EOF

aws iam create-policy --policy-name VeleroPolicy-$CLUSTER --policy-document file://velero-policy.json
```

**Expected output:** JSON containing `"Arn": "arn:aws:iam::123456789012:policy/VeleroPolicy-my-eks-cluster"`.

Enable the OIDC provider (lets pods use IAM roles) and create the role:

```bash
eksctl utils associate-iam-oidc-provider --cluster $CLUSTER --region $REGION --approve

eksctl create iamserviceaccount \
  --cluster $CLUSTER --region $REGION \
  --namespace velero --name velero \
  --role-name eks-velero-$CLUSTER \
  --role-only \
  --attach-policy-arn arn:aws:iam::$ACCOUNT:policy/VeleroPolicy-$CLUSTER \
  --approve
```

**Expected output (end of log):**

```
... created IAM role for serviceaccount "velero/velero"
```

#### 2.5.4 Install Velero in the cluster

Check plugin compatibility at https://github.com/vmware-tanzu/velero-plugin-for-aws#compatibility and set the matching tag:

```bash
export AWS_PLUGIN_VERSION=v1.12.2   # <-- must match your Velero version, check the link above

velero install \
  --provider aws \
  --plugins velero/velero-plugin-for-aws:$AWS_PLUGIN_VERSION \
  --bucket $VELERO_BUCKET \
  --backup-location-config region=$REGION \
  --snapshot-location-config region=$REGION \
  --no-secret \
  --sa-annotations eks.amazonaws.com/role-arn=arn:aws:iam::$ACCOUNT:role/eks-velero-$CLUSTER \
  --use-node-agent \
  --default-volumes-to-fs-backup=false \
  --wait
```

**Expected output (end):**

```
Deployment/velero: attempting to create resource
Deployment/velero: created
Velero is installed! ⛵ Use 'kubectl logs deployment/velero -n velero' to view the status.
```

Verify:

```bash
kubectl get pods -n velero
velero backup-location get
```

**Expected output:**

```
NAME                      READY   STATUS    RESTARTS   AGE
node-agent-xxxxx          1/1     Running   0          1m
node-agent-yyyyy          1/1     Running   0          1m
velero-xxxxxxxxxx-zzzzz   1/1     Running   0          1m

NAME      PROVIDER   BUCKET/PREFIX                       PHASE       LAST VALIDATED
default   aws        velero-my-eks-cluster-123456789012  Available   10s ago
```

`PHASE` must be **Available**. If it is `Unavailable`, see Troubleshooting.

#### 2.5.5 Take the backup

```bash
velero backup create pre-upgrade-1-34 --snapshot-volumes --wait
velero backup describe pre-upgrade-1-34
```

**Expected output:**

```
Backup request "pre-upgrade-1-34" submitted successfully.
Waiting for backup to complete...
Backup completed with status: Completed.
```

and in `describe`: `Phase: Completed`, `Errors: 0`.

List backups any time:

```bash
velero backup get
```

```
NAME               STATUS      ERRORS   WARNINGS   CREATED         EXPIRES
pre-upgrade-1-34   Completed   0        0          2026-10-24 ...  29d
```

#### 2.5.6 Test a restore (proves the backup works)

```bash
kubectl delete namespace demo
velero restore create --from-backup pre-upgrade-1-34 --include-namespaces demo --wait
kubectl get all -n demo
```

**Expected output:** the `web` deployment, pods and service are back, as in Step 1.5.

✅ **Checkpoint:** you now have (a) YAML backup, (b) AWS config backup, (c) copy in S3, and optionally (d) a Velero backup. **Task 1 is complete.**

---

## 3. TASK 2: Upgrade the cluster 1.34 → 1.35 → 1.36

You run the **same 10-step cycle twice**: once with `TARGET=1.35`, then (after the cluster is healthy) once with `TARGET=1.36`. **Every command has its own sub-step** (3.1.a, 3.1.b, ...) with:

* **Explanation**: what that one command does and why.
* **Command**: copy-paste, one command at a time.
* **Expected output**: only the important lines, taken from the real 1.35 and 1.36 runs (account IDs, subnet IDs and insight IDs are replaced with placeholders).
* **Verification**: how you know that command did what it should before you continue.

| Step | What | Done in 1.35 run | Done in 1.36 run |
|------|------|:---:|:---:|
| 3.1 | Set target + fresh backup | ✅ | ✅ |
| 3.2 | Confirm cluster state and available versions | ✅ | ✅ |
| 3.3 | EKS Upgrade Insights | ✅ | ✅ |
| 3.4 | Add-on inventory and compatibility check | ✅ | ✅ |
| 3.5 | Capacity and health pre-checks | ✅ | (not repeated) |
| 3.6 | Upgrade the control plane | ✅ | ✅ |
| 3.7 | Upgrade the add-ons | ✅ | ✅ |
| 3.8 | Upgrade the worker nodes | ✅ | ✅ |
| 3.9 | Verify the upgrade | ✅ | ✅ |
| 3.10 | Extra post-upgrade health checks | (basic only) | ✅ |

> Prerequisite: the variables from Step 1.3 (`CLUSTER`, `REGION`, `NODEGROUP`, `ACCOUNT`) must be set in your terminal (sub-step 1.3.b checks this).

---

### Step 3.1: Set the target version and take a fresh backup

The control plane upgrade **cannot be rolled back**, so you take a backup *immediately before* each hop: Kubernetes objects, AWS-side configuration, and a copy in S3.

#### 3.1.a Set the target version

**Explanation**
`TARGET` is set once and reused by every later command, so you cannot accidentally upgrade to the wrong version. Use `1.36` for the second hop.

**Command**

```bash
export TARGET=1.35
```

**Expected output**
No output (the command succeeds silently).

**Verification**
✅ Run `echo $TARGET`; it prints `1.35` (or `1.36` on the second hop).

#### 3.1.b Back up all Kubernetes objects

**Explanation**
Runs the script from Step 2.1. It reads every object through the API server and writes YAML files plus a `.tar.gz`. Take this **immediately before** each hop because a control plane upgrade cannot be rolled back.

**Command**

```bash
~/eks-backups/backup-k8s.sh
```

**Expected output**

```
>> Backing up cluster-scoped resources...
>> Backing up namespaced resources...
   namespace default done
   namespace demo done
   namespace kube-node-lease done
   namespace kube-public done
   namespace kube-system done
>> DONE. Backup folder : /home/ubuntu/eks-backups/k8s-backup-20261024-044438
>> DONE. Backup archive: /home/ubuntu/eks-backups/k8s-backup-20261024-044438.tar.gz
```

**Verification**
✅ All five namespaces report `done` and the `DONE. Backup archive:` line shows a new timestamped `.tar.gz`.

#### 3.1.c Check the demo app is in the backup

**Explanation**
Lists the demo namespace's files in every backup folder so you can see the new one contains your app.

**Command**

```bash
ls ~/eks-backups/k8s-backup-*/namespaced/demo/
```

**Expected output**

```
/home/ubuntu/eks-backups/k8s-backup-20261024-053930/namespaced/demo/:
configmaps.yaml  deployments.apps.yaml  pods.metrics.k8s.io.yaml  pods.yaml  replicasets.apps.yaml  serviceaccounts.yaml  services.yaml
```

**Verification**
✅ The newest folder contains `deployments.apps.yaml` and `services.yaml`. (`pods.metrics.k8s.io.yaml` is there because the `metrics-server` add-on is installed.)

#### 3.1.d Create a folder for the AWS-side configuration

**Explanation**
Stores the folder name in a variable first, so the `cd` always goes to the folder that was just created. (Calling `$(date ...)` twice can land on different seconds.)

**Command**

```bash
AWSDIR=~/eks-backups/aws-config-$(date +%Y%m%d-%H%M%S)
mkdir -p $AWSDIR && cd $AWSDIR
```

**Expected output**
No output (the command succeeds silently).

**Verification**
✅ `pwd` prints `/home/ubuntu/eks-backups/aws-config-<timestamp>`.

#### 3.1.e Save `cluster.json`

**Explanation**
Saves the full AWS description of the cluster (version, endpoint, VPC, logging, status).

**Command**

```bash
aws eks describe-cluster --name $CLUSTER --region $REGION > cluster.json
```

**Expected output**
No output (the command succeeds silently).

**Verification**
✅ `cluster.json` exists and is not empty (`ls -l` in the next sub-step).

#### 3.1.f Save `nodegroups-list.json`

**Explanation**
Saves the list of node group names in the cluster.

**Command**

```bash
aws eks list-nodegroups --cluster-name $CLUSTER --region $REGION > nodegroups-list.json
```

**Expected output**
No output (the command succeeds silently).

**Verification**
✅ `nodegroups-list.json` exists and is not empty (`ls -l` in the next sub-step).

#### 3.1.g Save `nodegroup.json`

**Explanation**
Saves the node group settings (version, release version, scaling, AMI type, instance types).

**Command**

```bash
aws eks describe-nodegroup --cluster-name $CLUSTER --nodegroup-name $NODEGROUP --region $REGION > nodegroup.json
```

**Expected output**
No output (the command succeeds silently).

**Verification**
✅ `nodegroup.json` exists and is not empty (`ls -l` in the next sub-step).

#### 3.1.h Save `addons.json`

**Explanation**
Saves the names of the installed managed add-ons.

**Command**

```bash
aws eks list-addons --cluster-name $CLUSTER --region $REGION > addons.json
```

**Expected output**
No output (the command succeeds silently).

**Verification**
✅ `addons.json` exists and is not empty (`ls -l` in the next sub-step).

#### 3.1.i Save `eksctl-cluster.yaml`

**Explanation**
Saves eksctl's view of the cluster as YAML.

**Command**

```bash
eksctl get cluster --name $CLUSTER --region $REGION -o yaml > eksctl-cluster.yaml
```

**Expected output**
No output (the command succeeds silently).

**Verification**
✅ `eksctl-cluster.yaml` exists (if it is empty that is fine; `cluster.json` and `nodegroup.json` hold the important data).

#### 3.1.j Save `eksctl-nodegroup.yaml`

**Explanation**
Saves eksctl's view of the node group as YAML.

**Command**

```bash
eksctl get nodegroup --cluster $CLUSTER --region $REGION -o yaml > eksctl-nodegroup.yaml
```

**Expected output**
No output (the command succeeds silently).

**Verification**
✅ `eksctl-nodegroup.yaml` exists (if it is empty that is fine; `cluster.json` and `nodegroup.json` hold the important data).

#### 3.1.k Save `kubectl-version.txt`

**Explanation**
Records the client and server versions before the change.

**Command**

```bash
kubectl version > kubectl-version.txt
```

**Expected output**

```
Warning: version difference between client (1.37) and server (1.35) exceeds the supported minor version skew of +/-1
```

**Verification**
✅ `kubectl-version.txt` exists. The warning is printed to the terminal only when your `kubectl` is more than one minor version away; it is harmless here. If your client is within ±1 there is no output.

#### 3.1.l Save `nodes.txt`

**Explanation**
Records node names, versions, IPs and OS image before the change.

**Command**

```bash
kubectl get nodes -o wide > nodes.txt
```

**Expected output**
No output (the command succeeds silently).

**Verification**
✅ `nodes.txt` exists and is not empty (`ls -l` in the next sub-step).

#### 3.1.m List the saved files

**Explanation**
Confirms all eight files were written and are not empty.

**Command**

```bash
ls -l
```

**Expected output**

```
total 40
-rw-rw-r-- 1 ubuntu ubuntu  111 Oct 24 04:13 addons.json
-rw-rw-r-- 1 ubuntu ubuntu 5650 Oct 24 04:13 cluster.json
-rw-rw-r-- 1 ubuntu ubuntu 4383 Oct 24 04:13 eksctl-cluster.yaml
-rw-rw-r-- 1 ubuntu ubuntu  509 Oct 24 04:13 eksctl-nodegroup.yaml
-rw-rw-r-- 1 ubuntu ubuntu   87 Oct 24 04:13 kubectl-version.txt
-rw-rw-r-- 1 ubuntu ubuntu 2311 Oct 24 04:13 nodegroup.json
-rw-rw-r-- 1 ubuntu ubuntu   55 Oct 24 04:13 nodegroups-list.json
-rw-rw-r-- 1 ubuntu ubuntu  606 Oct 24 04:13 nodes.txt
```

**Verification**
✅ Eight files are listed (`addons.json`, `cluster.json`, `eksctl-cluster.yaml`, `eksctl-nodegroup.yaml`, `kubectl-version.txt`, `nodegroup.json`, `nodegroups-list.json`, `nodes.txt`).

#### 3.1.n Set the backup bucket name

**Explanation**
Builds a unique S3 bucket name from your account ID and region and keeps it in a variable for the next commands.

**Command**

```bash
export BACKUP_BUCKET=eks-backups-$ACCOUNT-$REGION
```

**Expected output**
No output (the command succeeds silently).

**Verification**
✅ `echo $BACKUP_BUCKET` prints `eks-backups-123456789012-us-east-1`.

#### 3.1.o Create the S3 bucket

**Explanation**
Creates the bucket that will hold the off-machine copy of your backups.

**Command**

```bash
aws s3 mb s3://$BACKUP_BUCKET --region $REGION
```

**Expected output**

```
make_bucket: eks-backups-123456789012-us-east-1
```

**Verification**
✅ The `make_bucket:` line is printed. On a repeat run for the same bucket you already own in the same region, the same line was printed again; that is harmless.

#### 3.1.p Copy the backups to S3

**Explanation**
Uploads everything under `~/eks-backups` (archives, extracted YAML, AWS config files, the script). `sync` is incremental, so later runs upload only new files.

**Command**

```bash
aws s3 sync ~/eks-backups s3://$BACKUP_BUCKET/$CLUSTER/
```

**Expected output**

```
upload: ./cluster.json to s3://eks-backups-123456789012-us-east-1/my-eks-cluster/aws-config-20261024/cluster.json
upload: ../k8s-backup-20261024-040705.tar.gz to s3://eks-backups-123456789012-us-east-1/my-eks-cluster/k8s-backup-20261024-040705.tar.gz
...
```

**Verification**
✅ One `upload:` line per file and no `error` lines.

#### 3.1.q List what is in S3

**Explanation**
Proves the files really arrived in the bucket.

**Command**

```bash
aws s3 ls s3://$BACKUP_BUCKET/$CLUSTER/ --recursive | head
```

**Expected output**

```
2026-10-24 04:16:13        111 my-eks-cluster/aws-config-20261024/addons.json
2026-10-24 04:16:13       5650 my-eks-cluster/aws-config-20261024/cluster.json
...
2026-10-24 04:16:13       1241 my-eks-cluster/backup-k8s.sh
2026-10-24 04:16:13      78435 my-eks-cluster/k8s-backup-20261024-040705.tar.gz
```

**Verification**
✅ The `.tar.gz` archive and the `aws-config-...` files are listed.

> If you also see `BrokenPipeError: [Errno 32] Broken pipe`, it is only `head` closing the pipe early; the listing is fine.

---

### Step 3.2: Confirm the cluster state and the available versions

Before changing anything, prove that the cluster is `ACTIVE`, is on the version you think it is, that `kubectl` points at the right cluster, and that AWS offers the target version.

#### 3.2.a Check cluster status and current version

**Explanation**
Reads the cluster's `status` and `version` from AWS (not from `kubectl`).

**Command**

```bash
aws eks describe-cluster --name $CLUSTER --region $REGION \
  --query "cluster.{Version:version,Status:status}" --output table
```

**Expected output**

```
1.35 run (cluster on 1.34):          1.36 run (cluster on 1.35):
|  Status  |  Version  |                  |  Status  |  Version  |
|  ACTIVE  |  1.34     |                  |  ACTIVE  |  1.35     |
```

**Verification**
✅ `Status` is `ACTIVE` and `Version` is the version you are upgrading **from**. (In the 1.35 run this was checked with `--query "cluster.version" --output text`, which printed `1.34`.)

#### 3.2.b List the Kubernetes versions AWS supports

**Explanation**
Confirms the target version is offered and shows its support type.

**Command**

```bash
aws eks describe-cluster-versions --region $REGION \
  --query "clusterVersions[].{Version:clusterVersion,Status:status}" --output table
```

**Expected output**

```
|  STANDARD_SUPPORT |  1.37  |
|  STANDARD_SUPPORT |  1.36  |
|  STANDARD_SUPPORT |  1.35  |
|  STANDARD_SUPPORT |  1.34  |
|  EXTENDED_SUPPORT |  1.33  |   (and 1.32, 1.31)
```

**Verification**
✅ `TARGET` (1.35 or 1.36) is in the list with `STANDARD_SUPPORT`.

#### 3.2.c Point `kubectl` at the cluster

**Explanation**
Writes (or refreshes) the kubeconfig entry so `kubectl` talks to this cluster.

**Command**

```bash
aws eks update-kubeconfig --name $CLUSTER --region $REGION
```

**Expected output**

```
Updated context arn:aws:eks:us-east-1:123456789012:cluster/my-eks-cluster in /home/ubuntu/.kube/config
```

**Verification**
✅ The context line names `my-eks-cluster`. (The very first time it says `Added new context`.)

#### 3.2.d Check the nodes

**Explanation**
Shows that every node is `Ready` and which version it runs before the upgrade.

**Command**

```bash
kubectl get nodes
```

**Expected output**

```
NAME                             STATUS   ROLES    AGE   VERSION
ip-192-168-5-11.ec2.internal     Ready    <none>   30m   v1.35.9-eks-117f323      <- 1.36 run
ip-192-168-51-209.ec2.internal   Ready    <none>   30m   v1.35.9-eks-117f323
```

**Verification**
✅ Both nodes are `Ready` at the old version. If one is not `Ready`, stop and fix it first.

---

### Step 3.3: EKS Upgrade Insights (what could break)

Upgrade Insights are AWS's own pre-flight checks: deprecated APIs in use, kubelet and kube-proxy version skew, add-on compatibility, cluster health. Anything other than `PASSING` must be understood before you continue.

#### 3.3.a List the insights for the target version

**Explanation**
Asks AWS for the checks that apply to `TARGET`, showing only name and status.

**Command**

```bash
aws eks list-insights --cluster-name $CLUSTER --region $REGION \
  --filter kubernetesVersions=$TARGET \
  --query "insights[].{Name:name,Status:insightStatus.status}" --output table
```

**Expected output**

```
1.35 run:
|  kube-proxy version skew           |  PASSING |
|  Cluster health issues             |  PASSING |
|  Kubelet version skew              |  PASSING |
|  EKS add-on version compatibility  |  UNKNOWN |
|  Amazon Linux 2 compatibility      |  PASSING |

1.36 run:
{ "insights": [] }
```

**Verification**
✅ Every row is `PASSING`. A row that is not (here `UNKNOWN`) is investigated in 3.3.c to 3.3.e. An empty list (1.36 run) means nothing is stored for that filter; use 3.3.b instead.

#### 3.3.b List all insights with their target version

**Explanation**
Used when the filtered list is empty. Shows every insight and which Kubernetes version it is about.

**Command**

```bash
aws eks list-insights --cluster-name $CLUSTER --region $REGION \
  --query "insights[].{Name:name,Target:kubernetesVersion,Status:insightStatus.status}" --output table
```

**Expected output**

```
|  kube-proxy version skew                      |  PASSING |  1.35  |
|  Deprecated APIs removed in Kubernetes v1.38  |  PASSING |  1.38  |
|  Deprecated APIs removed in Kubernetes v1.37  |  PASSING |  1.37  |
|  Cluster health issues                        |  PASSING |  1.35  |
|  Kubelet version skew                         |  PASSING |  1.35  |
|  EKS add-on version compatibility             |  UNKNOWN |  1.35  |
|  Amazon Linux 2 compatibility                 |  PASSING |  1.35  |
```

**Verification**
✅ Same picture as 3.3.a: everything `PASSING` except `EKS add-on version compatibility`.

#### 3.3.c Read the details of the `UNKNOWN` insight

**Explanation**
Opens the full record of one insight. Copy the `id` for it from `aws eks list-insights` (without `--query`) and put it in place of `<INSIGHT_ID>`.

**Command**

```bash
aws eks describe-insight --cluster-name $CLUSTER --region $REGION --id <INSIGHT_ID>
```

**Expected output**

```
"status": "UNKNOWN",
"reason": "Unable to determine version compatibility of EKS add-ons."
...
"reason": "Unable to determine addon compatibility: addon 'coredns' is in 'DEGRADED' state."   <- coredns resource
"reason": "All installed EKS add-on versions are compatible with next Kubernetes version."     <- kube-proxy, vpc-cni
```

**Verification**
✅ You now know *why* it is `UNKNOWN`: AWS saw CoreDNS as `DEGRADED`. `kube-proxy` and `vpc-cni` were reported compatible. Check CoreDNS yourself in the next two sub-steps.

#### 3.3.d Check CoreDNS health in AWS

**Explanation**
Reads the CoreDNS add-on record to see whether it really has health issues.

**Command**

```bash
aws eks describe-addon --cluster-name $CLUSTER --addon-name coredns --region $REGION
```

**Expected output**

```
"status": "ACTIVE",
"addonVersion": "v1.12.4-eksbuild.58",
"health": { "issues": [] },
```

**Verification**
✅ `status` is `ACTIVE` and `issues` is empty.

#### 3.3.e Check the CoreDNS pods

**Explanation**
Confirms the CoreDNS pods are running and where they are scheduled.

**Command**

```bash
kubectl -n kube-system get pods -l k8s-app=kube-dns -o wide
```

**Expected output**

```
NAME                       READY   STATUS    RESTARTS   AGE   NODE
coredns-7879986bf8-7sqmx   1/1     Running   0          31m   ip-192-168-21-69.ec2.internal
coredns-7879986bf8-j2kn4   1/1     Running   0          31m   ip-192-168-21-69.ec2.internal
```

**Verification**
✅ Both pods are `1/1 Running`. Together with 3.3.d, CoreDNS is healthy, so the `UNKNOWN` was most likely a stale reading (the insight's `lastRefreshTime` `03:59:19` is right when cluster creation finished). The upgrade went ahead and succeeded. If CoreDNS had really been unhealthy, fix that first.

#### 3.3.f Look ahead: deprecated APIs in the next version

**Explanation**
Checks whether your cluster uses APIs that will be removed in the version *after* your target, so the next hop holds no surprises.

**Command**

```bash
aws eks list-insights --cluster-name $CLUSTER --region $REGION \
  --filter kubernetesVersions=1.37 --output table
```

**Expected output**

```
"name": "Deprecated APIs removed in Kubernetes v1.37"
"reason": "No deprecated API usage detected within the last 30 days."
"status": "PASSING"
```

**Verification**
✅ `PASSING` with no deprecated API usage.

---

### Step 3.4: Add-on inventory and compatibility check

Add-ons (`kube-proxy`, `vpc-cni`, `coredns`, `metrics-server`) are versioned separately from Kubernetes. Before upgrading you need to know what is installed now, which versions are compatible with `TARGET`, and which one AWS marks as **Default**. You use the Default version in Step 3.7.

#### 3.4.a Show the installed add-ons (eksctl view)

**Explanation**
Lists the managed add-ons, their versions, health, and which newer builds are available.

**Command**

```bash
eksctl get addon --cluster $CLUSTER --region $REGION
```

**Expected output**

```
NAME            VERSION                 STATUS  ISSUES  ...
coredns         v1.12.4-eksbuild.58     ACTIVE  0
kube-proxy      v1.34.6-eksbuild.52     ACTIVE  0
metrics-server  v0.9.0-eksbuild.14      ACTIVE  0
vpc-cni         v1.22.4-eksbuild.3      ACTIVE  0
```

**Verification**
✅ Four add-ons, all `ACTIVE`, `ISSUES 0`. If the table is empty your add-ons are self-managed (see 3.7.e to 3.7.g). The `UPDATE AVAILABLE` column lists newer builds you can pick.

#### 3.4.b Show the installed add-ons (AWS view)

**Explanation**
Gets just the add-on names directly from the EKS API.

**Command**

```bash
aws eks list-addons --cluster-name $CLUSTER --region $REGION
```

**Expected output**

```
{
    "addons": [ "coredns", "kube-proxy", "metrics-server", "vpc-cni" ]
}
```

**Verification**
✅ The same four names as in 3.4.a.

#### 3.4.c Print each add-on's installed version

**Explanation**
Loops over the four add-ons and prints the version of each. (One `for` loop, one result per add-on.)

**Command**

```bash
for ADDON in kube-proxy vpc-cni coredns metrics-server; do
  echo -n "$ADDON: "
  aws eks describe-addon --cluster-name $CLUSTER --addon-name $ADDON --region $REGION \
    --query "addon.addonVersion" --output text
done
```

**Expected output**

```
(1.36 run)
kube-proxy: v1.35.3-eksbuild.52
vpc-cni: v1.22.4-eksbuild.3
coredns: v1.13.2-eksbuild.51
metrics-server: v0.9.0-eksbuild.14
```

**Verification**
✅ Four versions printed. Write them down; you compare them with the Default versions in 3.4.g.

#### 3.4.d Show the add-on pods in detail

**Explanation**
Shows the pods that make up the add-ons, with their nodes and ages, before anything changes.

**Command**

```bash
kubectl get pods -n kube-system -o wide
```

**Expected output**

```
aws-node-rmql9                    2/2   Running   0   38m   ip-192-168-21-69.ec2.internal
aws-node-s7wxr                    2/2   Running   0   38m   ip-192-168-44-47.ec2.internal
coredns-7879986bf8-7sqmx          1/1   Running   0   41m
kube-proxy-jm6tg                  1/1   Running   0   38m
metrics-server-68c65f79d8-8lcjw   1/1   Running   0   36m
```

**Verification**
✅ Every pod is `Running` with full `READY`.

#### 3.4.e Show the images of `aws-node` and `kube-proxy`

**Explanation**
Reads the container image tag actually used by the two DaemonSets (the real running version).

**Command**

```bash
kubectl get ds aws-node kube-proxy -n kube-system \
  -o jsonpath='{range .items[*]}{.metadata.name}{"  "}{.spec.template.spec.containers[0].image}{"\n"}{end}'
```

**Expected output**

```
aws-node  602401143452.dkr.ecr.us-east-1.amazonaws.com/amazon-k8s-cni:v1.22.4-eksbuild.3
kube-proxy  602401143452.dkr.ecr.us-east-1.amazonaws.com/eks/kube-proxy:v1.34.6-eksbuild.52
```

**Verification**
✅ The image tags match the versions from 3.4.a.

#### 3.4.f Show the image of CoreDNS

**Explanation**
Same check for the CoreDNS Deployment.

**Command**

```bash
kubectl get deploy coredns -n kube-system \
  -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
```

**Expected output**

```
602401143452.dkr.ecr.us-east-1.amazonaws.com/eks/coredns:v1.12.4-eksbuild.58
```

**Verification**
✅ The tag matches the CoreDNS version from 3.4.a.

#### 3.4.g Find the Default version of each add-on for the target

**Explanation**
Lists the versions compatible with `TARGET` and marks the AWS Default with `True`. `| head -15` keeps the top of each long list.

**Command**

```bash
for ADDON in kube-proxy vpc-cni coredns metrics-server; do
  echo "=== $ADDON ==="
  aws eks describe-addon-versions --addon-name $ADDON --kubernetes-version $TARGET --region $REGION \
    --query "addons[0].addonVersions[].{Version:addonVersion,Default:compatibilities[0].defaultVersion}" \
    --output table | head -15
done
```

**Expected output**

```
Default versions found:
                 for 1.35                for 1.36
kube-proxy       v1.35.3-eksbuild.52     v1.36.0-eksbuild.48
vpc-cni          v1.22.4-eksbuild.3      v1.22.4-eksbuild.3
coredns          v1.13.2-eksbuild.51     v1.14.7-eksbuild.11
metrics-server   v0.9.0-eksbuild.14      v0.9.0-eksbuild.14
```

**Verification**
✅ You have one `True` (Default) version per add-on. If you do not see a `True` row in the first 15 lines (in the 1.35 run it was the *second* row for `kube-proxy`), remove `| head -15`. An add-on whose installed version already equals the Default (`vpc-cni`, `metrics-server`) needs no change.

#### 3.4.h Save the full CoreDNS version list to a file (optional)

**Explanation**
The 1.35 run stored the complete JSON so it can be searched later (it was written to a file called `output`; a clearer name is used here).

**Command**

```bash
aws eks describe-addon-versions --addon-name coredns --kubernetes-version $TARGET --region $REGION \
  > coredns-versions-$TARGET.json
```

**Expected output**
No output (the command succeeds silently).

**Verification**
✅ `ls -l coredns-versions-$TARGET.json` shows a non-empty file.

#### 3.4.i Check the current CoreDNS build is still supported on the new control plane (1.36 hop)

**Explanation**
Proves the CoreDNS build you run now is valid on the *new* control plane, so nothing breaks in the gap between the control plane upgrade (3.6) and the add-on upgrade (3.7). `grep -n` prints the line number if found.

**Command**

```bash
aws eks describe-addon-versions --addon-name coredns --kubernetes-version 1.36 --region $REGION \
  --query "addons[0].addonVersions[].addonVersion" --output text | tr '\t' '\n' | grep -n "v1.13.2-eksbuild.51"
```

**Expected output**

```
14:v1.13.2-eksbuild.51
```

**Verification**
✅ A line is printed. No output would mean that build is **not** supported on the target.

#### 3.4.j Check the current kube-proxy build is still supported on the new control plane (1.36 hop)

**Explanation**
The same check for `kube-proxy`.

**Command**

```bash
aws eks describe-addon-versions --addon-name kube-proxy --kubernetes-version 1.36 --region $REGION \
  --query "addons[0].addonVersions[].addonVersion" --output text | tr '\t' '\n' | grep -n "v1.35.3-eksbuild.52"
```

**Expected output**

```
16:v1.35.3-eksbuild.52
```

**Verification**
✅ A line is printed.

---

### Step 3.5: Capacity and health pre-checks

During a node group upgrade EKS launches **new nodes before removing the old ones**. In both real runs all **4 nodes existed at the same time** (2 old + 2 new), so you need free IP addresses in the subnets and vCPU quota for 4 `t2.medium` (2 vCPU each = 8 vCPU). It was run for 1.35 and not repeated for 1.36.

#### 3.5.a List the cluster's subnet IDs

**Explanation**
Finds the subnets the cluster uses so you can look at their free IP addresses next.

**Command**

```bash
aws eks describe-cluster --name $CLUSTER --region $REGION \
  --query "cluster.resourcesVpcConfig.subnetIds" --output text
```

**Expected output**

```
subnet-aaaaaaaa    subnet-bbbbbbbb    subnet-cccccccc    subnet-dddddddd
```

**Verification**
✅ Four subnet IDs are printed. Copy them for the next sub-step.

#### 3.5.b Check free IP addresses in those subnets

**Explanation**
Every node and pod takes an IP. This shows how many are left in each subnet. Replace `<SUBNET_1>` ... `<SUBNET_4>` with the IDs from 3.5.a.

**Command**

```bash
aws ec2 describe-subnets \
  --subnet-ids <SUBNET_1> <SUBNET_2> <SUBNET_3> <SUBNET_4> \
  --query "Subnets[].{Subnet:SubnetId,AZ:AvailabilityZone,AvailableIPs:AvailableIpAddressCount}" \
  --output table
```

**Expected output**

```
|  us-east-1f|  8174  |  subnet-aaaaaaaa  |
|  us-east-1d|  8175  |  subnet-bbbbbbbb  |
|  us-east-1d|  8186  |  subnet-cccccccc  |
|  us-east-1f|  8186  |  subnet-dddddddd  |
```

**Verification**
✅ Each subnet has thousands of free IPs (you need only a handful).

#### 3.5.c Check the node group size limits

**Explanation**
Shows the node group's minimum, desired and maximum sizes.

**Command**

```bash
aws eks describe-nodegroup --cluster-name $CLUSTER --nodegroup-name $NODEGROUP --region $REGION \
  --query "nodegroup.scalingConfig" --output table
```

**Expected output**

```
|  desiredSize |  maxSize  |  minSize  |
|  2           |  2        |  2        |
```

**Verification**
✅ `2 / 2 / 2`. The rolling upgrade still adds surge nodes beyond `maxSize` (4 nodes were seen at the peak), so `maxSize 2` does not block it.

#### 3.5.d Check the EC2 vCPU quota

**Explanation**
Reads your account limit for Running On-Demand Standard instances (counted in vCPUs). The upgrade peak needs 8 vCPU.

**Command**

```bash
aws service-quotas get-service-quota --service-code ec2 --quota-code L-1216C47A \
  --region $REGION --query "Quota.Value" --output text
```

**Expected output**

```
16.0
```

**Verification**
✅ The value (`16.0`) is at least 8.

#### 3.5.e Check that no pod is unhealthy

**Explanation**
Lists every pod that is *not* `Running` or `Completed`. Anything shown here must be fixed before upgrading.

**Command**

```bash
kubectl get pods -A | grep -v -E "Running|Completed"
```

**Expected output**

```
NAMESPACE     NAME                              READY   STATUS    RESTARTS   AGE
```

**Verification**
✅ Only the header line is printed (no unhealthy pods).

---

### Step 3.6: Upgrade the control plane (API server + etcd, run by AWS)

This upgrades the AWS-managed control plane by one minor version. Nodes and add-ons are **not** touched yet, which is supported for a while. Do not press `Ctrl+C`; if your terminal disconnects the upgrade continues in AWS.

#### 3.6.a Start the control plane upgrade

**Explanation**
Upgrades the control plane to `TARGET`. Without `--approve` eksctl only shows a plan (a safe dry run).

**Command**

```bash
eksctl upgrade cluster --name $CLUSTER --region $REGION --version $TARGET --approve
```

**Expected output**

```
1.35 run (about 7.5 min):
04:53:46 [ℹ]  will upgrade cluster "my-eks-cluster" control plane from current version "1.34" to "1.35"
05:01:14 [✔]  cluster "my-eks-cluster" control plane has been upgraded to version "1.35"
05:01:14 [ℹ]  you will need to follow the upgrade procedure for all of nodegroups and add-ons
05:01:14 [ℹ]  all nodegroups have up-to-date cloudformation templates

1.36 run (about 7.5 min):
05:50:47 [ℹ]  will upgrade ... from current version "1.35" to "1.36"
05:58:18 [✔]  cluster "my-eks-cluster" control plane has been upgraded to version "1.36"
```

**Verification**
✅ The `[✔] ... has been upgraded to version` line appears.

#### 3.6.b Check the status and version (also usable while it runs)

**Explanation**
From a second terminal this shows `UPDATING` while the upgrade is running and `ACTIVE` when it is done.

**Command**

```bash
aws eks describe-cluster --name $CLUSTER --region $REGION \
  --query "cluster.{Version:version,Status:status}" --output text
```

**Expected output**

```
ACTIVE  1.35        (1.36 run: ACTIVE  1.36)
```

**Verification**
✅ `ACTIVE` and the new version.

#### 3.6.c Check the API server version

**Explanation**
Asks the API server itself which version it runs (the `Server Version` line).

**Command**

```bash
kubectl version
```

**Expected output**

```
Client Version: v1.37.1
Kustomize Version: v5.8.1
Server Version: v1.35.8-eks-b9510e3        (1.36 run: v1.36.4-eks-b9510e3)
Warning: version difference between client (1.37) and server (1.35) exceeds the supported minor version skew of +/-1
```

**Verification**
✅ `Server Version` is the new version. The skew warning was printed in the 1.35 run and disappeared in the 1.36 run (client 1.37 is within ±1 of 1.36); it is harmless.

#### 3.6.d Check that the nodes are unchanged

**Explanation**
Confirms nodes are still `Ready` and still on the **old** version, which is expected until Step 3.8.

**Command**

```bash
kubectl get nodes
```

**Expected output**

```
NAME                            STATUS   ROLES    AGE   VERSION
ip-192-168-21-69.ec2.internal   Ready    <none>   64m   v1.34.12-eks-117f323
ip-192-168-44-47.ec2.internal   Ready    <none>   64m   v1.34.12-eks-117f323
```

**Verification**
✅ Both nodes `Ready` at the old version.

#### 3.6.e Check that no pod became unhealthy

**Explanation**
The same filter as 3.5.e, to make sure the control plane upgrade did not disturb your workloads.

**Command**

```bash
kubectl get pods -A | grep -v -E "Running|Completed"
```

**Expected output**

```
NAMESPACE     NAME                              READY   STATUS    RESTARTS   AGE
```

**Verification**
✅ Only the header line is printed.

---

### Step 3.7: Upgrade the add-ons

Update each managed add-on to the **Default** version found in 3.4.g. `--force` resolves field conflicts if someone edited the add-on by hand. Which sub-steps were run in each hop:

| Hop | Sub-steps run | Why |
|-----|---------------|-----|
| 1.34 → 1.35 | 3.7.a, 3.7.c, 3.7.d, then 3.7.h to 3.7.l | `vpc-cni` was re-applied with the same version (a no-op) |
| 1.35 → 1.36 | 3.7.a, 3.7.b, 3.7.d, then 3.7.h to 3.7.l | `vpc-cni` and `metrics-server` already matched the Default, so they were skipped |

Sub-steps 3.7.e to 3.7.g are the alternative for **self-managed** add-ons (an empty table in 3.4.a); they were not needed in the lab.

#### 3.7.a Update `kube-proxy`

**Explanation**
Moves `kube-proxy` to the Default version for the target. Use `v1.35.3-eksbuild.52` for 1.35 and `v1.36.0-eksbuild.48` for 1.36.

**Command**

```bash
eksctl update addon --name kube-proxy --cluster $CLUSTER --region $REGION --version v1.36.0-eksbuild.48 --force
```

**Expected output**

```
[!]  no IAM OIDC provider associated with cluster, try 'eksctl utils associate-iam-oidc-provider ...'
[ℹ]  Kubernetes version "1.36" in use by cluster "my-eks-cluster"
[ℹ]  new version provided v1.36.0-eksbuild.48
[ℹ]  updating addon
[ℹ]  addon "kube-proxy" active
```

**Verification**
✅ The last line says `addon "kube-proxy" active`. The `no IAM OIDC provider` warning is harmless here (these add-ons run without IRSA roles).

#### 3.7.b Check that the `kube-proxy` pods restarted cleanly (1.36 hop)

**Explanation**
Looks at the `kube-system` pods before touching CoreDNS.

**Command**

```bash
kubectl get pods -n kube-system
```

**Expected output**

```
kube-proxy-6s22n                  1/1   Running   0   66s
kube-proxy-kk4wl                  1/1   Running   0   64s
coredns-547b59986f-bljhn          1/1   Running   0   37m
```

**Verification**
✅ New `kube-proxy` pods with a small AGE, all `1/1 Running`.

#### 3.7.c Update `vpc-cni` (1.35 hop only)

**Explanation**
Re-applies the Default version. It was already `v1.22.4-eksbuild.3`, so nothing really changes; skip it when the installed version already equals the Default.

**Command**

```bash
eksctl update addon --name vpc-cni --cluster $CLUSTER --region $REGION --version v1.22.4-eksbuild.3 --force
```

**Expected output**

```
[ℹ]  updating addon
[ℹ]  addon "vpc-cni" active
```

**Verification**
✅ `addon "vpc-cni" active`.

#### 3.7.d Update `coredns`

**Explanation**
Moves CoreDNS to the Default version. Use `v1.13.2-eksbuild.51` for 1.35 and `v1.14.7-eksbuild.11` for 1.36. The pods are replaced by a rolling update, so DNS keeps working.

**Command**

```bash
eksctl update addon --name coredns --cluster $CLUSTER --region $REGION --version v1.14.7-eksbuild.11 --force
```

**Expected output**

```
[ℹ]  new version provided v1.14.7-eksbuild.11
[ℹ]  updating addon
```

**Verification**
✅ The command ends at `updating addon` with no `active` line. That is normal; confirm in 3.7.h to 3.7.l.

#### 3.7.e Self-managed alternative: update `kube-proxy`

**Explanation**
Only if `eksctl get addon` was empty (not the case in the lab).

**Command**

```bash
eksctl utils update-kube-proxy --cluster $CLUSTER --region $REGION --approve
```

**Expected output**

```
[✔]  "kube-proxy" is now up-to-date
```

**Verification**
✅ The `is now up-to-date` line.

#### 3.7.f Self-managed alternative: update `aws-node` (vpc-cni)

**Explanation**
The same for the VPC CNI DaemonSet.

**Command**

```bash
eksctl utils update-aws-node --cluster $CLUSTER --region $REGION --approve
```

**Expected output**

```
[✔]  "aws-node" is now up-to-date
```

**Verification**
✅ The `is now up-to-date` line.

#### 3.7.g Self-managed alternative: update CoreDNS

**Explanation**
The same for CoreDNS.

**Command**

```bash
eksctl utils update-coredns --cluster $CLUSTER --region $REGION --approve
```

**Expected output**

```
[✔]  "coredns" is now up-to-date
```

**Verification**
✅ The `is now up-to-date` line.

#### 3.7.h Verify the add-on table

**Explanation**
Shows all add-on versions and health after the updates.

**Command**

```bash
eksctl get addon --cluster $CLUSTER --region $REGION
```

**Expected output**

```
coredns         v1.14.7-eksbuild.11     ACTIVE  0
kube-proxy      v1.36.0-eksbuild.48     ACTIVE  0
metrics-server  v0.9.0-eksbuild.14      ACTIVE  0
vpc-cni         v1.22.4-eksbuild.3      ACTIVE  0
```

**Verification**
✅ All four `ACTIVE`, `ISSUES 0`, and the versions equal the Default versions from 3.4.g. `UPDATE AVAILABLE` may still list newer *builds* of the same version (for example `v1.36.0-eksbuild.55`); those are optional.

#### 3.7.i Verify the add-on pods

**Explanation**
Confirms the add-on pods are running and that CoreDNS pods were replaced.

**Command**

```bash
kubectl get pods -n kube-system
```

**Expected output**

```
aws-node-7rtnw                    2/2   Running   0   44m
coredns-687dddfb64-7rbr5          1/1   Running   0   45s       <- new ReplicaSet hash = replaced
coredns-687dddfb64-tf6gd          1/1   Running   0   45s
kube-proxy-6s22n                  1/1   Running   0   5m28s
metrics-server-68c65f79d8-744gh   1/1   Running   0   38m
```

**Verification**
✅ All `Running`, and the CoreDNS pod names have a new hash with a small AGE.

#### 3.7.j Wait for the CoreDNS rollout to finish

**Explanation**
Blocks until the CoreDNS Deployment has finished its rolling update.

**Command**

```bash
kubectl -n kube-system rollout status deployment/coredns
```

**Expected output**

```
deployment "coredns" successfully rolled out
```

**Verification**
✅ The `successfully rolled out` line.

#### 3.7.k Test DNS from inside the cluster

**Explanation**
Starts a temporary busybox pod and looks up the demo service by its full name. The pod is removed afterwards (`--rm`).

**Command**

```bash
kubectl run dnstest --rm -it --restart=Never --image=busybox:1.36 -- nslookup web.demo.svc.cluster.local
```

**Expected output**

```
Server:         10.100.0.10
Address:        10.100.0.10:53

Name:   web.demo.svc.cluster.local
Address: 10.100.153.157

pod "dnstest" deleted from default namespace
```

**Verification**
✅ The address equals the `CLUSTER-IP` of `service/web` (`kubectl get svc web -n demo`).

#### 3.7.l Check CoreDNS status and version in AWS

**Explanation**
A last confirmation from the EKS API.

**Command**

```bash
aws eks describe-addon --cluster-name $CLUSTER --addon-name coredns --region $REGION \
  --query "addon.{Version:addonVersion,Status:status}" --output text
```

**Expected output**

```
ACTIVE  v1.14.7-eksbuild.11
```

**Verification**
✅ `ACTIVE` and the target CoreDNS version.

---

### Step 3.8: Upgrade the worker nodes (node group)

The managed node group is rolled to the new Kubernetes version and matching Amazon Linux 2023 release. EKS **creates new nodes first**, cordons the old ones (`SchedulingDisabled`), drains them and terminates them. Your demo app survives because it has 2 replicas. Open **three terminals**: run 3.8.a in the first, 3.8.b in the second and 3.8.c in the third.

#### 3.8.a Start the node group upgrade (terminal 1)

**Explanation**
Rolls the node group to `TARGET`.

**Command**

```bash
eksctl upgrade nodegroup --name $NODEGROUP --cluster $CLUSTER --region $REGION --kubernetes-version $TARGET
```

**Expected output**

```
1.35 run (about 13.5 min):
05:18:55 [ℹ]  will upgrade nodes to release version: 1.35.9-20261019
05:18:55 [ℹ]  upgrading nodegroup version
05:31:25 [ℹ]  nodegroup successfully upgraded

1.36 run (about 11.5 min):
06:07:25 [ℹ]  will upgrade nodes to release version: 1.36.5-20261019
06:18:50 [ℹ]  nodegroup successfully upgraded
```

**Verification**
✅ The last line says `nodegroup successfully upgraded`.

#### 3.8.b Watch the nodes change (terminal 2)

**Explanation**
Streams node changes live. Press `Ctrl+C` when only new nodes remain.

**Command**

```bash
kubectl get nodes -w
```

**Expected output**

```
ip-192-168-5-11.ec2.internal     Ready                        v1.35.9-eks-117f323   <- old
ip-192-168-16-172.ec2.internal   NotReady                     v1.36.5-eks-117f323   <- new, joining
ip-192-168-16-172.ec2.internal   Ready                        v1.36.5-eks-117f323
ip-192-168-35-221.ec2.internal   Ready                        v1.36.5-eks-117f323
ip-192-168-51-209.ec2.internal   Ready,SchedulingDisabled     v1.35.9-eks-117f323   <- old, cordoned
ip-192-168-51-209.ec2.internal   NotReady,SchedulingDisabled  v1.35.9-eks-117f323   <- old, being terminated
```

**Verification**
✅ New nodes become `Ready` first, then each old node goes `SchedulingDisabled`, then `NotReady`, then disappears.

#### 3.8.c Watch the demo pods move (terminal 3)

**Explanation**
Streams the demo pods so you can see they are replaced one at a time.

**Command**

```bash
kubectl get pods -n demo -w
```

**Expected output**

```
web-64c966cf88-2nqhv   1/1   Terminating
web-64c966cf88-fjnwk   0/1   Pending -> ContainerCreating -> 1/1 Running
web-64c966cf88-hhvcl   1/1   Terminating          <- only after the first replacement is Running
web-64c966cf88-csq45   0/1   Pending -> ContainerCreating -> 1/1 Running
```

**Verification**
✅ In the 1.36 watch a replacement pod was `Running` before the second old pod was terminated, so the app stayed available.

#### 3.8.d Check the nodes after the upgrade

**Explanation**
Shows the final node list.

**Command**

```bash
kubectl get nodes
```

**Expected output**

```
NAME                             STATUS   ROLES    AGE   VERSION
ip-192-168-16-172.ec2.internal   Ready    <none>   12m   v1.36.5-eks-117f323
ip-192-168-35-221.ec2.internal   Ready    <none>   12m   v1.36.5-eks-117f323
```

**Verification**
✅ Exactly 2 nodes, both `Ready`, both on the new version.

#### 3.8.e Check the node group in AWS

**Explanation**
Confirms the node group's version and release version from the EKS API.

**Command**

```bash
aws eks describe-nodegroup --cluster-name $CLUSTER --nodegroup-name $NODEGROUP --region $REGION \
  --query "nodegroup.{Version:version,Release:releaseVersion,Status:status}" --output table
```

**Expected output**

```
|      Release     | Status  |  Version  |
|  1.36.5-20261019 |  ACTIVE |  1.36     |
```

**Verification**
✅ `ACTIVE`, with the new version and release.

---

### Step 3.9: Verify the upgrade

A final checklist that proves the whole cluster is on the new version and your app is healthy. Run the six commands one by one.

#### 3.9.a API server version

**Explanation**
Confirms the control plane version.

**Command**

```bash
kubectl version
```

**Expected output**

```
Server Version: v1.35.8-eks-b9510e3        (after the 1.36 hop: v1.36.4-eks-b9510e3)
```

**Verification**
✅ `Server Version` is the new version.

#### 3.9.b Node versions

**Explanation**
Confirms every node runs the new version and is `Ready`.

**Command**

```bash
kubectl get nodes
```

**Expected output**

```
2 nodes, STATUS Ready, VERSION v1.35.9-eks-117f323        (after the 1.36 hop: v1.36.5-eks-117f323)
```

**Verification**
✅ Both nodes `Ready` at the new version.

#### 3.9.c All pods

**Explanation**
Confirms every pod in every namespace is healthy.

**Command**

```bash
kubectl get pods -A
```

**Expected output**

```
demo          web-64c966cf88-2nqhv    1/1   Running
kube-system   aws-node-7rtnw          2/2   Running
kube-system   coredns-547b59986f-bljhn   1/1   Running
kube-system   kube-proxy-28lv8        1/1   Running
kube-system   metrics-server-68c65f79d8-744gh   1/1   Running
```

**Verification**
✅ Every pod is `Running`.

#### 3.9.d Demo application

**Explanation**
Confirms your sample app survived the upgrade.

**Command**

```bash
kubectl get all -n demo
```

**Expected output**

```
pod/web-...   1/1   Running   (2 pods)
service/web   ClusterIP   10.100.153.157   80/TCP
deployment.apps/web   2/2   2   2
replicaset.apps/web-64c966cf88   2   2   2
```

**Verification**
✅ `deployment.apps/web   2/2`.

#### 3.9.e Cluster version in AWS

**Explanation**
Asks AWS (not the API server) for the cluster version.

**Command**

```bash
aws eks describe-cluster --name $CLUSTER --region $REGION --query "cluster.version" --output text
```

**Expected output**

```
1.35        (after the 1.36 hop: 1.36)
```

**Verification**
✅ Prints the new version.

#### 3.9.f Add-ons

**Explanation**
Confirms add-on versions and health once more.

**Command**

```bash
eksctl get addon --cluster $CLUSTER --region $REGION
```

**Expected output**

```
All four add-ons ACTIVE, ISSUES 0 (see 3.7.h for the versions).
```

**Verification**
✅ `ACTIVE` and `0` issues for all four. 🎉 The hop is complete. Wait until you are happy with the cluster (an hour is plenty for a lab) before repeating Steps 3.1 to 3.9 with the next `TARGET`.

---

### Step 3.10: Extra post-upgrade health checks (run after the 1.36 hop)

Deeper checks that go beyond "pods are Running": node conditions, recent events, resource usage, the API server's own readiness (including etcd), and AWS's record of the upgrade. They are optional but cheap, and they are the closest you can get to "checking etcd and the API server" on EKS.

#### 3.10.a Node health conditions

**Explanation**
Shows the first condition (memory pressure) of each node. Run `kubectl describe nodes | grep -A8 Conditions` to see them all.

**Command**

```bash
kubectl describe nodes | grep -A3 Conditions
```

**Expected output**

```
MemoryPressure   False   ...   KubeletHasSufficientMemory   kubelet has sufficient memory available
```

**Verification**
✅ `False` (no pressure) for every node.

#### 3.10.b Recent events

**Explanation**
Shows what the cluster did recently, newest last. The output is long, so only the end is shown here.

**Command**

```bash
kubectl get events -A --sort-by=.lastTimestamp | tail -30
```

**Expected output**

```
default   9m9s   Normal    NodeNotReady   node/ip-192-168-5-11.ec2.internal
default   8m31s  Normal    RemovingNode   node/ip-192-168-5-11.ec2.internal
```

**Verification**
✅ Events match what you did (nodes removed, pods rescheduled). Warnings you can ignore right after a node roll: `FailedDaemonPod` / `NodeShutdown` for `aws-node` and `kube-proxy` on the **old** nodes, `Readiness probe failed` for a CoreDNS pod in its first seconds, `InvalidDiskCapacity` on a fresh node.

#### 3.10.c Only the warning events

**Explanation**
Filters the events down to warnings, so real problems stand out.

**Command**

```bash
kubectl get events -A --field-selector type=Warning
```

**Expected output**

```
(old-node warnings from the drain, as listed in 3.10.b; nothing that keeps repeating on a current node)
```

**Verification**
✅ No warning keeps repeating on a *current* node.

#### 3.10.d All workload controllers

**Explanation**
Shows Deployments, StatefulSets and DaemonSets and whether they are fully ready.

**Command**

```bash
kubectl get deploy,statefulset,daemonset -A
```

**Expected output**

```
demo          deployment.apps/web              2/2
kube-system   deployment.apps/coredns          2/2
kube-system   deployment.apps/metrics-server   2/2
kube-system   daemonset.apps/aws-node          2   2   2   2   2
kube-system   daemonset.apps/kube-proxy        2   2   2   2   2
```

**Verification**
✅ `READY` equals `DESIRED` everywhere.

#### 3.10.e Resource usage

**Explanation**
Shows CPU and memory per pod. It works because the `metrics-server` add-on is installed.

**Command**

```bash
kubectl top pods -A
```

**Expected output**

```
demo          web-64c966cf88-csq45        0m    3Mi
kube-system   coredns-687dddfb64-7t2hx    1m    10Mi
kube-system   metrics-server-68c65f79d8-cjtrf   2m   18Mi
```

**Verification**
✅ Numbers are returned (an error here would mean `metrics-server` is not healthy).

#### 3.10.f `aws-node` DaemonSet

**Explanation**
Checks the VPC CNI DaemonSet is fully rolled out on every node.

**Command**

```bash
kubectl get daemonset aws-node -n kube-system
```

**Expected output**

```
aws-node   2   2   2   2   2   <none>   151m
```

**Verification**
✅ `DESIRED`, `CURRENT`, `READY`, `UP-TO-DATE`, `AVAILABLE` are all `2`.

#### 3.10.g `kube-proxy` DaemonSet

**Explanation**
The same check for `kube-proxy`.

**Command**

```bash
kubectl get daemonset kube-proxy -n kube-system
```

**Expected output**

```
kube-proxy   2   2   2   2   2   <none>   151m
```

**Verification**
✅ All columns `2`.

#### 3.10.h API server and etcd readiness

**Explanation**
Asks the API server to report each of its own health checks, including etcd (which AWS manages for you).

**Command**

```bash
kubectl get --raw='/readyz?verbose'
```

**Expected output**

```
[+]ping ok
[+]log ok
[+]etcd ok
[+]etcd-readiness ok
[+]informer-sync ok
...
```

**Verification**
✅ Every line starts with `[+]` and says `ok`, in particular `etcd ok` and `etcd-readiness ok`.

#### 3.10.i AWS's record of the upgrade

**Explanation**
Fetches the latest update record of the cluster. The inner command finds the newest update ID.

**Command**

```bash
aws eks describe-update --name $CLUSTER --region $REGION \
  --update-id $(aws eks list-updates --name $CLUSTER --region $REGION --query "updateIds[-1]" --output text)
```

**Expected output**

```
"status": "Successful",
"type": "VersionUpdate",
"params": [ { "type": "Version", "value": "1.36" }, { "type": "PlatformVersion", "value": "eks.15" } ],
"errors": []
```

**Verification**
✅ `Successful`, the new version, and an empty `errors` list.

#### 3.10.j Control plane logging status

**Explanation**
Shows whether control plane logs (api, audit, authenticator, controllerManager, scheduler) are sent to CloudWatch.

**Command**

```bash
aws eks describe-cluster --name $CLUSTER --region $REGION --query "cluster.logging.clusterLogging"
```

**Expected output**

```
[ { "types": [ "api", "audit", "authenticator", "controllerManager", "scheduler" ], "enabled": false } ]
```

**Verification**
✅ `false` is the default and not a problem. Enable logging only if you need it (it costs money).

#### 3.10.k Add-on table

**Explanation**
Final add-on check after the whole cycle.

**Command**

```bash
eksctl get addon --cluster $CLUSTER --region $REGION
```

**Expected output**

```
coredns         v1.14.7-eksbuild.11     ACTIVE  0
kube-proxy      v1.36.0-eksbuild.48     ACTIVE  0
metrics-server  v0.9.0-eksbuild.14      ACTIVE  0
vpc-cni         v1.22.4-eksbuild.3      ACTIVE  0
```

**Verification**
✅ All `ACTIVE`, `ISSUES 0`.

#### 3.10.l Insights for the next version

**Explanation**
Looks one version ahead for deprecated APIs.

**Command**

```bash
aws eks list-insights --cluster-name $CLUSTER --region $REGION \
  --filter kubernetesVersions=1.37 \
  --query "insights[].{Name:name,Status:insightStatus.status}" --output table
```

**Expected output**

```
|  Deprecated APIs removed in Kubernetes v1.37  |  PASSING |
```

**Verification**
✅ `PASSING`.

#### 3.10.m Extra DNS probe (optional)

**Explanation**
A second DNS test using a short name.

**Command**

```bash
kubectl run dns-test --image=busybox:1.36 --rm -it --restart=Never -- nslookup kubernetes.default
```

**Expected output**

```
** server can't find kubernetes.default: NXDOMAIN
pod "dns-test" deleted from default namespace
```

**Verification**
⚠️ In the lab this returned `NXDOMAIN` although CoreDNS was healthy and 3.7.k had worked. Use the full name `kubernetes.default.svc.cluster.local` for this kind of test (see Troubleshooting).

---


## 4. Comparison: 1.34 vs 1.35 vs 1.36

Everything below comes from the real command output of the lab cluster (`my-eks-cluster`, `us-east-1`, managed node group `my-worker-node`, 2 × `t2.medium`). "Not captured" means the value was not printed in the saved terminal logs.

### 4.1 Versions and components

| Item | 1.34 | 1.35 | 1.36 |
|------|------|------|------|
| Control plane (EKS) version | `1.34` (created by `eksctl create cluster`) | `1.35` | `1.36` |
| API server (`kubectl version`, Server) | `v1.34.x` (patch not captured) | `v1.35.8-eks-b9510e3` | `v1.36.4-eks-b9510e3` |
| EKS platform version | not captured | not captured | `eks.15` |
| Node (kubelet) version | `v1.34.12-eks-117f323` | `v1.35.9-eks-117f323` | `v1.36.5-eks-117f323` |
| Node group release version | AmazonLinux2023 / 1.34 (exact release not captured) | `1.35.9-20261019` | `1.36.5-20261019` |
| Node count / type | 2 × `t2.medium` | 2 × `t2.medium` | 2 × `t2.medium` |
| Node names | `ip-192-168-21-69`, `ip-192-168-44-47` | `ip-192-168-5-11`, `ip-192-168-51-209` | `ip-192-168-16-172`, `ip-192-168-35-221` |
| `kube-proxy` add-on | `v1.34.6-eksbuild.52` | `v1.35.3-eksbuild.52` | `v1.36.0-eksbuild.48` |
| `vpc-cni` add-on | `v1.22.4-eksbuild.3` | `v1.22.4-eksbuild.3` (unchanged) | `v1.22.4-eksbuild.3` (unchanged) |
| `coredns` add-on | `v1.12.4-eksbuild.58` | `v1.13.2-eksbuild.51` | `v1.14.7-eksbuild.11` |
| `metrics-server` add-on | `v0.9.0-eksbuild.14` | `v0.9.0-eksbuild.14` (unchanged) | `v0.9.0-eksbuild.14` (unchanged) |
| CoreDNS ReplicaSet (pod name prefix) | `coredns-7879986bf8` | `coredns-547b59986f` | `coredns-687dddfb64` |
| EKS support status | `STANDARD_SUPPORT` | `STANDARD_SUPPORT` | `STANDARD_SUPPORT` |
| Demo app `deployment.apps/web` | `2/2` | `2/2` | `2/2` |

### 4.2 Process and checks

| Item | 1.34 | 1.35 | 1.36 |
|------|------|------|------|
| How it got there | Created with `eksctl create cluster` (about 16.5 min) | `eksctl upgrade cluster --version 1.35 --approve` | `eksctl upgrade cluster --version 1.36 --approve` |
| Control plane upgrade time | n/a | about 7.5 min (04:53 → 05:01) | about 7.5 min (05:50 → 05:58) |
| Node group upgrade time | n/a | about 13.5 min (05:17 → 05:31) | about 11.5 min (06:07 → 06:18) |
| Add-on update order | n/a | `kube-proxy` → `vpc-cni` (same version) → `coredns` | `kube-proxy` → `coredns` (`vpc-cni`, `metrics-server` unchanged) |
| Upgrade Insights | n/a | 4 × `PASSING`; `EKS add-on version compatibility` = `UNKNOWN` (CoreDNS had been `DEGRADED`; later `ACTIVE`) | Filter for `1.36` returned an empty list; unfiltered list all `PASSING` except the same stale `UNKNOWN`; `1.37` deprecated-API check `PASSING` |
| Subnet free IPs / vCPU quota | not checked | about 8,170–8,190 free IPs per subnet; quota `16.0` vCPU | not repeated |
| Peak node count during node roll | n/a | 4 (2 old + 2 new) | 4 (2 old + 2 new) |
| Pre-upgrade backup | `k8s-backup-20261024-040705` and `-044438`, `aws-config-20261024`, copied to S3 | `k8s-backup-20261024-053930`, `aws-config-20261024-054531`, copied to S3 | none taken after the final hop |
| `kubectl` client vs server | client `v1.37.1`; skew warning printed (1.37 vs 1.34) | skew warning printed (1.37 vs 1.35) | no warning (1.37 vs 1.36 is within ±1) |
| Tool versions (all runs) | `eksctl 0.231.0`, `aws-cli 2.38.5`, `kubectl v1.37.1` | same | same |
| Extra post-upgrade checks | n/a | basic (version, nodes, pods, demo app) | full set from Step 3.10 (`/readyz` with etcd ok, `describe-update` = `Successful`, events, `top pods`) |
| Final cluster status | `ACTIVE` | `ACTIVE` | `ACTIVE`, update record `Successful`, 0 errors |

### 4.3 What stayed the same, what did not

* **Never changed across the three versions:** `vpc-cni` (`v1.22.4-eksbuild.3` was the Default for both 1.35 and 1.36), `metrics-server`, node count and instance type, the demo workload.
* **Changed every hop:** control plane, node (kubelet) version and node names (nodes are replaced, not patched in place), `kube-proxy`, `coredns`.
* **Rule of thumb from these runs:** after each control plane upgrade, always re-check the Default add-on versions (Step 3.4). They moved for `kube-proxy` and `coredns` on both hops but not for `vpc-cni` or `metrics-server`.

---

## 5. Troubleshooting

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| `error: You must be logged in to the server (Unauthorized)` | Wrong AWS user/profile or expired credentials | Run `aws sts get-caller-identity`; use the same identity that created the cluster; re-run `aws eks update-kubeconfig ...` |
| `The connection to the server ... was refused` / no context | kubeconfig missing | Re-run Step 1.3 |
| `eksctl upgrade cluster` only prints a plan | Forgot `--approve` | Add `--approve` |
| `Unsupported Kubernetes minor version update from 1.34 to 1.36` | Skipping a version | Upgrade to 1.35 first |
| Insights show `ERROR` | Deprecated/removed API or incompatible component | `aws eks describe-insight ...`, fix manifests/charts, re-check |
| Nodes upgrade stuck / "PodEvictionFailure" | A PodDisruptionBudget blocks draining | `kubectl get pdb -A`; relax the PDB or scale the app to more replicas, then retry |
| Pods `Pending` during node upgrade | Not enough capacity on small `t2.medium` nodes | `kubectl describe pod <name>`; scale down non-essential apps temporarily |
| Add-on update shows `ISSUES` / conflict | Manual edits on the add-on | Re-run update with `--force` |
| `velero backup-location get` shows `Unavailable` | IAM role/bucket permissions wrong | `kubectl logs deployment/velero -n velero`; confirm role ARN annotation and bucket name; redo Step 2.5.3 |
| `kubectl` warns about version skew | Client too far from server | Install a `kubectl` within ±1 minor of the server version (re-run the kubectl download step). In the lab the warning appeared with client 1.37 against 1.34 and 1.35 and was harmless for the upgrade; it disappeared at 1.36 |
| Insight `EKS add-on version compatibility` = `UNKNOWN` | The insight could not read an add-on's health (in the lab it said CoreDNS was `DEGRADED`, likely a stale reading from cluster creation) | `aws eks describe-insight ... --id <ID>`, then `aws eks describe-addon --addon-name coredns ...` and `kubectl -n kube-system get pods -l k8s-app=kube-dns`. If the add-on is `ACTIVE` with no issues, continue; otherwise fix it first |
| `aws eks list-insights --filter kubernetesVersions=<target>` returns `"insights": []` | No insights are stored for that target version yet | Run `list-insights` without `--filter` (use the `Target` column) and check the next version's deprecated-API insight |
| `eksctl update addon` prints `no IAM OIDC provider associated with cluster` | OIDC is not set up | Harmless for `kube-proxy`, `vpc-cni`, `coredns` in this lab. Run `eksctl utils associate-iam-oidc-provider --cluster $CLUSTER --region $REGION --approve` if you need IAM roles for service accounts (Velero does) |
| `eksctl update addon --name coredns` ends at `updating addon` with no `active` line | The command returns before the rollout finishes | `kubectl -n kube-system rollout status deployment/coredns` and `eksctl get addon ...` |
| `nslookup kubernetes.default` returns `NXDOMAIN` from a `busybox:1.36` test pod although CoreDNS is healthy | Short-name lookup through busybox's `nslookup` did not resolve in the lab | Test with the full name: `nslookup kubernetes.default.svc.cluster.local` or `nslookup web.demo.svc.cluster.local` (the latter worked) |
| `BrokenPipeError` after `aws s3 ls ... \| head` | `head` closed the pipe | Ignore; the listing is complete |
| Many `Warning` events (`FailedDaemonPod`, `NodeShutdown`, `Readiness probe failed`, `InvalidDiskCapacity`) after a node roll | Normal noise while old nodes drain and new pods start | Ignore if they stop within a few minutes; investigate only warnings that repeat on a current node |

Useful debug commands:

```bash
kubectl describe node <node-name>
kubectl describe pod <pod-name> -n <namespace>
kubectl logs <pod-name> -n <namespace>
kubectl get events -A --sort-by=.lastTimestamp | tail -20
eksctl utils describe-stacks --cluster $CLUSTER --region $REGION
aws eks describe-update --name $CLUSTER --region $REGION \
  --update-id $(aws eks list-updates --name $CLUSTER --region $REGION --query "updateIds[-1]" --output text)
kubectl get --raw='/readyz?verbose'
```

### Rollback reality check

* The EKS control plane **cannot be downgraded**.
* If an app breaks after the upgrade, **restore the app** from backup (Step 2.4 or Velero restore), or fix the manifests for the new version.
* In a real disaster you would create a new cluster and restore from the Velero backup into it.

---

## 6. Cleanup (stop paying for the lab)

```bash
kubectl delete namespace demo
# If you installed Velero:
velero uninstall --force

eksctl delete cluster --name $CLUSTER --region $REGION
```

**Expected output (end):**

```
[✔]  all cluster resources were deleted
```

Optionally delete the S3 buckets once you no longer need the backups:

```bash
aws s3 rb s3://$BACKUP_BUCKET --force
aws s3 rb s3://$VELERO_BUCKET --force
```

---

## 7. Quick-reference checklist

- [ ] `kubectl get nodes` shows all nodes `Ready`
- [ ] `kubectl get pods -A` shows no failing pods
- [ ] Upgrade insights show no errors for the target version (understand any `UNKNOWN`)
- [ ] Add-on Default versions looked up for the target (Step 3.4)
- [ ] Free subnet IPs and vCPU quota for 4 nodes checked (Step 3.5)
- [ ] Backup done: YAML export + AWS config (+ S3 copy, + Velero)
- [ ] Control plane upgraded (`eksctl upgrade cluster ... --approve`)
- [ ] Add-ons upgraded (kube-proxy, vpc-cni, coredns)
- [ ] Node group upgraded (`eksctl upgrade nodegroup ...`)
- [ ] Verified: versions, pods, demo app, DNS lookup, `/readyz` (etcd ok), `describe-update` = `Successful`
- [ ] Repeat for the next minor version if desired

---

### Appendix: "Real" etcd snapshot (only for self-managed clusters)

If you ever run a **self-built** cluster (kubeadm, not EKS) you can snapshot etcd directly on a control-plane node:

```bash
sudo ETCDCTL_API=3 etcdctl snapshot save /backup/etcd-snapshot.db \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key
```

This is **not possible on EKS**; use Part 2 instead.
