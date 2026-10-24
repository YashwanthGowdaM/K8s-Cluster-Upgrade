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

If `eksctl` is missing, install the latest release:

```bash
curl --silent --location "https://github.com/weaveworks/eksctl/releases/latest/download/eksctl_$(uname -s)_amd64.tar.gz" | tar xz -C /tmp
sudo mv /tmp/eksctl /usr/local/bin
```

Then check all three tools:

```bash
eksctl version
kubectl version --client
aws --version
```

**Expected output (versions will differ; these are the ones used in the lab):**

```
0.231.0
Client Version: v1.37.1
Kustomize Version: v5.8.1
aws-cli/2.38.5 Python/3.14.8 Linux/7.0.0-1014-aws exe/x86_64.ubuntu.26
```

> `kubectl` should be within ±1 minor version of the cluster. A `kubectl` 1.37 client against a 1.34 or 1.35 cluster works, but prints a *version skew* warning on every `kubectl version` and on many other commands. It is only a warning.

If a command says `command not found`, redo that install step from your setup notes.

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

Confirm the variables are set (the lab kept them in `~/.bashrc`, so a new terminal needs `source ~/.bashrc` first):

```bash
source ~/.bashrc
echo -e "$CLUSTER\n$REGION\n$NODEGROUP\n$ACCOUNT"
```

**Expected output:**

```
my-eks-cluster
us-east-1
my-worker-node
123456789012
```

Create the kubeconfig entry:

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

```bash
mkdir -p ~/eks-backups/aws-config-$(date +%Y%m%d) && cd ~/eks-backups/aws-config-$(date +%Y%m%d)

aws eks describe-cluster --name $CLUSTER --region $REGION > cluster.json
aws eks list-nodegroups --cluster-name $CLUSTER --region $REGION > nodegroups-list.json
aws eks describe-nodegroup --cluster-name $CLUSTER --nodegroup-name $NODEGROUP --region $REGION > nodegroup.json
aws eks list-addons --cluster-name $CLUSTER --region $REGION > addons.json
eksctl get cluster --name $CLUSTER --region $REGION -o yaml > eksctl-cluster.yaml
eksctl get nodegroup --cluster $CLUSTER --region $REGION -o yaml > eksctl-nodegroup.yaml
kubectl version > kubectl-version.txt
kubectl get nodes -o wide > nodes.txt

ls -l
```

**Expected output:**

```
addons.json  cluster.json  eksctl-cluster.yaml  eksctl-nodegroup.yaml
kubectl-version.txt  nodegroup.json  nodegroups-list.json  nodes.txt
```

(If an `eksctl get ...` file is empty, that's fine; `cluster.json` and `nodegroup.json` hold the important data.)

> If `kubectl version` prints `Warning: version difference between client (1.37) and server (1.34) exceeds the supported minor version skew of +/-1`, the backup is still fine.
> When you repeat this step before each upgrade, use a timestamped folder and a variable so the `cd` always matches the folder just created:
> `AWSDIR=~/eks-backups/aws-config-$(date +%Y%m%d-%H%M%S); mkdir -p $AWSDIR && cd $AWSDIR`

### Step 2.3: Copy backups to S3 (so they survive if your machine dies)

```bash
export BACKUP_BUCKET=eks-backups-$ACCOUNT-$REGION
aws s3 mb s3://$BACKUP_BUCKET --region $REGION
aws s3 sync ~/eks-backups s3://$BACKUP_BUCKET/$CLUSTER/
```

**Expected output:**

```
make_bucket: eks-backups-123456789012-us-east-1
upload: eks-backups/k8s-backup-2026....tar.gz to s3://eks-backups-123456789012-us-east-1/my-eks-cluster/k8s-backup-2026....tar.gz
...
```

Verify:

```bash
aws s3 ls s3://$BACKUP_BUCKET/$CLUSTER/ --recursive | head
```

**Expected output (lab):** the first rows list `aws-config-.../*.json|yaml`, `backup-k8s.sh` and `k8s-backup-<stamp>.tar.gz`. If you also see `BrokenPipeError: [Errno 32] Broken pipe`, it is only `head` closing the pipe early; the listing is fine. `aws s3 sync` is incremental, so later runs upload only new files.

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

You run the **same 10-step cycle twice**: once with `TARGET=1.35`, then (after the cluster is healthy) once with `TARGET=1.36`. Every step below has the same four parts:

* **Explanation**: what the step does and why.
* **Commands**: copy-paste.
* **Expected output**: only the important lines, taken from the real 1.35 and 1.36 runs (account IDs, subnet IDs and insight IDs are replaced with placeholders).
* **Verification**: how you know the step succeeded before moving on.

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

> Prerequisite: the variables from Step 1.3 (`CLUSTER`, `REGION`, `NODEGROUP`, `ACCOUNT`) must be set in your terminal. Check with `echo -e "$CLUSTER\n$REGION\n$NODEGROUP\n$ACCOUNT"`.

---

### Step 3.1: Set the target version and take a fresh backup

**Explanation**
The control plane upgrade **cannot be rolled back**, so you take a backup *immediately before* each hop. `TARGET` is set once here and reused by every later command, so you cannot accidentally upgrade to the wrong version.

**Commands**

```bash
export TARGET=1.35          # use 1.36 for the second hop
echo $TARGET

# a) Kubernetes objects (re-uses the script from Step 2.1)
~/eks-backups/backup-k8s.sh
ls ~/eks-backups/k8s-backup-*/namespaced/demo/

# b) AWS-side configuration (same files as Step 2.2, new timestamped folder)
AWSDIR=~/eks-backups/aws-config-$(date +%Y%m%d-%H%M%S)
mkdir -p $AWSDIR && cd $AWSDIR
aws eks describe-cluster --name $CLUSTER --region $REGION > cluster.json
aws eks list-nodegroups --cluster-name $CLUSTER --region $REGION > nodegroups-list.json
aws eks describe-nodegroup --cluster-name $CLUSTER --nodegroup-name $NODEGROUP --region $REGION > nodegroup.json
aws eks list-addons --cluster-name $CLUSTER --region $REGION > addons.json
eksctl get cluster --name $CLUSTER --region $REGION -o yaml > eksctl-cluster.yaml
eksctl get nodegroup --cluster $CLUSTER --region $REGION -o yaml > eksctl-nodegroup.yaml
kubectl version > kubectl-version.txt
kubectl get nodes -o wide > nodes.txt
ls -l

# c) Copy everything to S3
export BACKUP_BUCKET=eks-backups-$ACCOUNT-$REGION
aws s3 mb s3://$BACKUP_BUCKET --region $REGION
aws s3 sync ~/eks-backups s3://$BACKUP_BUCKET/$CLUSTER/
```

> Tip: the `AWSDIR=` variable is a small improvement over calling `$(date ...)` twice. With a `%H%M%S` timestamp, two separate `date` calls can land on different seconds and the `cd` would fail.

**Expected output (important part)**

```
>> DONE. Backup folder : /home/ubuntu/eks-backups/k8s-backup-20261024-044438
>> DONE. Backup archive: /home/ubuntu/eks-backups/k8s-backup-20261024-044438.tar.gz
configmaps.yaml  deployments.apps.yaml  pods.metrics.k8s.io.yaml  pods.yaml  replicasets.apps.yaml  serviceaccounts.yaml  services.yaml
...
make_bucket: eks-backups-123456789012-us-east-1
upload: ./cluster.json to s3://eks-backups-123456789012-us-east-1/my-eks-cluster/aws-config-.../cluster.json
```

**Verification**

```bash
ls -l ~/eks-backups/*.tar.gz
aws s3 ls s3://$BACKUP_BUCKET/$CLUSTER/ --recursive | grep tar.gz
```

✅ A new `k8s-backup-<timestamp>.tar.gz` exists locally **and** in S3, and the `demo` folder contains `deployments.apps.yaml` and `services.yaml`.

Notes from the real runs:

* `kubectl version > kubectl-version.txt` prints a *client/server skew warning* when your `kubectl` is more than one minor version away from the cluster. It is harmless for the backup (see Troubleshooting).
* Running `aws s3 ls ... | head` can print `BrokenPipeError`. This is only `head` closing the pipe early; the listing is fine.
* In the 1.36 run `aws s3 mb` printed `make_bucket` again for the same bucket name; re-running it on a bucket you already own in the same region is harmless.

---

### Step 3.2: Confirm the cluster state and the available versions

**Explanation**
Before changing anything, prove that the cluster is `ACTIVE`, is on the version you think it is, that `kubectl` points at the right cluster, and that AWS offers the target version.

**Commands**

```bash
aws eks describe-cluster --name $CLUSTER --region $REGION \
  --query "cluster.{Version:version,Status:status}" --output table

aws eks describe-cluster-versions --region $REGION \
  --query "clusterVersions[].{Version:clusterVersion,Status:status}" --output table

aws eks update-kubeconfig --name $CLUSTER --region $REGION
kubectl get nodes
```

**Expected output (important part)**

1.35 run (cluster still on 1.34). The log checked this with `--query "cluster.version" --output text` and got `1.34`; the table form shows:

```
|  Status  |  Version  |
|  ACTIVE  |  1.34     |
```

1.36 run (cluster now on 1.35):

```
|  Status  |  Version  |
|  ACTIVE  |  1.35     |
```

Available versions (same in both runs):

```
|  STANDARD_SUPPORT |  1.37  |
|  STANDARD_SUPPORT |  1.36  |
|  STANDARD_SUPPORT |  1.35  |
|  STANDARD_SUPPORT |  1.34  |
|  EXTENDED_SUPPORT |  1.33  |   (and 1.32, 1.31)
```

```
Updated context arn:aws:eks:us-east-1:123456789012:cluster/my-eks-cluster in /home/ubuntu/.kube/config

NAME                             STATUS   ROLES    AGE   VERSION
ip-192-168-5-11.ec2.internal     Ready    <none>   30m   v1.35.9-eks-117f323      <- 1.36 run
```

**Verification**
✅ `Status` is `ACTIVE`, `Version` is the version you are upgrading **from**, `TARGET` appears in the version list with `STANDARD_SUPPORT`, and every node is `Ready` at the old version.

---

### Step 3.3: EKS Upgrade Insights (what could break)

**Explanation**
Upgrade Insights are AWS's own pre-flight checks: deprecated APIs in use, kubelet and kube-proxy version skew, add-on compatibility, cluster health. Anything other than `PASSING` must be understood before you continue.

**Commands**

```bash
# Insights for the target version
aws eks list-insights --cluster-name $CLUSTER --region $REGION \
  --filter kubernetesVersions=$TARGET \
  --query "insights[].{Name:name,Status:insightStatus.status}" --output table

# If the filtered list is empty, list everything with its target version
aws eks list-insights --cluster-name $CLUSTER --region $REGION \
  --query "insights[].{Name:name,Target:kubernetesVersion,Status:insightStatus.status}" --output table

# Read the details of any insight that is not PASSING
aws eks describe-insight --cluster-name $CLUSTER --region $REGION --id <INSIGHT_ID>

# Look ahead: deprecated APIs scheduled for removal in the NEXT version
aws eks list-insights --cluster-name $CLUSTER --region $REGION \
  --filter kubernetesVersions=1.37 --output table
```

**Expected output (important part)**

1.35 run:

```
|  kube-proxy version skew           |  PASSING |
|  Cluster health issues             |  PASSING |
|  Kubelet version skew              |  PASSING |
|  EKS add-on version compatibility  |  UNKNOWN |
|  Amazon Linux 2 compatibility      |  PASSING |
```

`describe-insight` for the `UNKNOWN` row:

```
"status": "UNKNOWN",
"reason": "Unable to determine version compatibility of EKS add-ons."
...
"reason": "Unable to determine addon compatibility: addon 'coredns' is in 'DEGRADED' state."     <- coredns resource
"reason": "All installed EKS add-on versions are compatible with next Kubernetes version."       <- kube-proxy, vpc-cni
```

1.36 run: `--filter kubernetesVersions=1.36` returned an empty list (`"insights": []`), so the unfiltered command was used:

```
|  kube-proxy version skew                      |  PASSING |  1.35  |
|  Deprecated APIs removed in Kubernetes v1.38  |  PASSING |  1.38  |
|  Deprecated APIs removed in Kubernetes v1.37  |  PASSING |  1.37  |
|  Cluster health issues                        |  PASSING |  1.35  |
|  Kubelet version skew                         |  PASSING |  1.35  |
|  EKS add-on version compatibility             |  UNKNOWN |  1.35  |
|  Amazon Linux 2 compatibility                 |  PASSING |  1.35  |
```

The look-ahead check showed `"reason": "No deprecated API usage detected within the last 30 days."` and `"status": "PASSING"`.

**Verification: investigate the `UNKNOWN`**
The insight said CoreDNS was `DEGRADED`, so check CoreDNS directly:

```bash
aws eks describe-addon --cluster-name $CLUSTER --addon-name coredns --region $REGION
kubectl -n kube-system get pods -l k8s-app=kube-dns -o wide
```

```
"status": "ACTIVE",
"addonVersion": "v1.12.4-eksbuild.58",
"health": { "issues": [] },
...
coredns-7879986bf8-7sqmx   1/1   Running   0   31m
coredns-7879986bf8-j2kn4   1/1   Running   0   31m
```

✅ In both runs CoreDNS was `ACTIVE` with no health issues and both pods were `Running`, while `kube-proxy` and `vpc-cni` were reported compatible. The insight's `lastRefreshTime` (`03:59:19`) is right around the time cluster creation finished (`03:59`), so the `UNKNOWN` was most likely a stale reading from when CoreDNS had no nodes yet. The upgrade then went ahead and succeeded. If CoreDNS had really been unhealthy, fix that first.

---

### Step 3.4: Add-on inventory and compatibility check

**Explanation**
Add-ons (`kube-proxy`, `vpc-cni`, `coredns`, `metrics-server`) are versioned separately from Kubernetes. Before upgrading you need to know (1) what is installed now, (2) which versions are compatible with `TARGET`, and (3) which one AWS marks as **Default**. You will use the Default version in Step 3.7.

**Commands**

```bash
# What is installed (managed add-ons)
eksctl get addon --cluster $CLUSTER --region $REGION
aws eks list-addons --cluster-name $CLUSTER --region $REGION

# Installed version of each add-on
for ADDON in kube-proxy vpc-cni coredns metrics-server; do
  echo -n "$ADDON: "
  aws eks describe-addon --cluster-name $CLUSTER --addon-name $ADDON --region $REGION \
    --query "addon.addonVersion" --output text
done

# What is actually running (container images)
kubectl get pods -n kube-system -o wide
kubectl get ds aws-node kube-proxy -n kube-system \
  -o jsonpath='{range .items[*]}{.metadata.name}{"  "}{.spec.template.spec.containers[0].image}{"\n"}{end}'
kubectl get deploy coredns -n kube-system \
  -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'

# Compatible versions for the target (look for Default = True)
for ADDON in kube-proxy vpc-cni coredns metrics-server; do
  echo "=== $ADDON ==="
  aws eks describe-addon-versions --addon-name $ADDON --kubernetes-version $TARGET --region $REGION \
    --query "addons[0].addonVersions[].{Version:addonVersion,Default:compatibilities[0].defaultVersion}" \
    --output table | head -15
done
```

> The lists are long (dozens of builds). `| head -15` keeps the top; if you do not see a `True` row, remove `head`. In the 1.35 run the `True` row was *not* the first row for `kube-proxy`.
> The 1.35 run also saved the full JSON for CoreDNS to a file with `aws eks describe-addon-versions --addon-name coredns --kubernetes-version 1.35 --region $REGION > coredns-versions.json`, which is handy for searching later.

For the 1.36 hop an extra check proved that the version you already run is still *supported on the new control plane* (so nothing breaks in the gap between Step 3.6 and Step 3.7):

```bash
aws eks describe-addon-versions --addon-name coredns --kubernetes-version 1.36 --region $REGION \
  --query "addons[0].addonVersions[].addonVersion" --output text | tr '\t' '\n' | grep -n "v1.13.2-eksbuild.51"
aws eks describe-addon-versions --addon-name kube-proxy --kubernetes-version 1.36 --region $REGION \
  --query "addons[0].addonVersions[].addonVersion" --output text | tr '\t' '\n' | grep -n "v1.35.3-eksbuild.52"
```

**Expected output (important part)**

Installed before the 1.35 hop (cluster on 1.34):

```
coredns         v1.12.4-eksbuild.58   ACTIVE  0
kube-proxy      v1.34.6-eksbuild.52   ACTIVE  0
metrics-server  v0.9.0-eksbuild.14    ACTIVE  0
vpc-cni         v1.22.4-eksbuild.3    ACTIVE  0

aws-node    .../amazon-k8s-cni:v1.22.4-eksbuild.3
kube-proxy  .../eks/kube-proxy:v1.34.6-eksbuild.52
.../eks/coredns:v1.12.4-eksbuild.58
```

**Default** versions AWS returned:

| Add-on | Default for 1.35 | Default for 1.36 |
|--------|------------------|------------------|
| kube-proxy | `v1.35.3-eksbuild.52` | `v1.36.0-eksbuild.48` |
| vpc-cni | `v1.22.4-eksbuild.3` | `v1.22.4-eksbuild.3` |
| coredns | `v1.13.2-eksbuild.51` | `v1.14.7-eksbuild.11` |
| metrics-server | `v0.9.0-eksbuild.14` | `v0.9.0-eksbuild.14` |

1.36 run, "is my current version still supported?" check:

```
14:v1.13.2-eksbuild.51
16:v1.35.3-eksbuild.52
```

**Verification**
✅ You have a Default version written down for every add-on. ✅ Any add-on whose installed version equals the Default (here `vpc-cni` and `metrics-server`) needs no change. ✅ The `grep -n` lines print a match, meaning the old add-on build is supported on the new control plane.

---

### Step 3.5: Capacity and health pre-checks

**Explanation**
During a node group upgrade EKS launches **new nodes before removing the old ones**. In both real runs all **4 nodes existed at the same time** (2 old + 2 new), so you need free IP addresses in the subnets and vCPU quota for 4 `t2.medium` (2 vCPU each = 8 vCPU). This step proves both, and confirms no pod is already unhealthy. It was run for 1.35; the 1.36 hop re-used the same results.

**Commands**

```bash
# a) Free IPs in the cluster subnets
aws eks describe-cluster --name $CLUSTER --region $REGION \
  --query "cluster.resourcesVpcConfig.subnetIds" --output text

aws ec2 describe-subnets \
  --subnet-ids <SUBNET_1> <SUBNET_2> <SUBNET_3> <SUBNET_4> \
  --query "Subnets[].{Subnet:SubnetId,AZ:AvailabilityZone,AvailableIPs:AvailableIpAddressCount}" \
  --output table

# b) Node group size limits
aws eks describe-nodegroup --cluster-name $CLUSTER --nodegroup-name $NODEGROUP --region $REGION \
  --query "nodegroup.scalingConfig" --output table

# c) EC2 vCPU quota (Running On-Demand Standard instances)
aws service-quotas get-service-quota --service-code ec2 --quota-code L-1216C47A \
  --region $REGION --query "Quota.Value" --output text

# d) No unhealthy pods
kubectl get pods -A | grep -v -E "Running|Completed"
```

**Expected output (important part)**

```
|  us-east-1f|  8174  |  subnet-xxxxxxxx  |
|  us-east-1d|  8175  |  subnet-xxxxxxxx  |
...
|  desiredSize |  maxSize  |  minSize  |
|  2           |  2        |  2        |
16.0
NAMESPACE     NAME      READY   STATUS    RESTARTS   AGE        <- header only = no unhealthy pods
```

**Verification**
✅ Each subnet has thousands of free IPs. ✅ Quota `16.0` vCPU ≥ 8 vCPU needed at the peak. ✅ The last command prints **only the header line**.

> Note: the node group has `maxSize 2`, but the rolling upgrade still adds surge nodes beyond that during the update; it is not blocked by `maxSize`.

---

### Step 3.6: Upgrade the control plane (API server + etcd, run by AWS)

**Explanation**
This upgrades the AWS-managed control plane one minor version. Nodes and add-ons are **not** touched yet, which is supported for a while.

**Commands**

```bash
eksctl upgrade cluster --name $CLUSTER --region $REGION --version $TARGET --approve

# While it runs (from a second terminal), or if your terminal disconnects:
aws eks describe-cluster --name $CLUSTER --region $REGION \
  --query "cluster.{Version:version,Status:status}" --output text
```

**Expected output (important part)**

1.35 run (about 7.5 minutes):

```
04:53:46 [ℹ]  will upgrade cluster "my-eks-cluster" control plane from current version "1.34" to "1.35"
05:01:14 [✔]  cluster "my-eks-cluster" control plane has been upgraded to version "1.35"
05:01:14 [ℹ]  you will need to follow the upgrade procedure for all of nodegroups and add-ons
05:01:14 [ℹ]  all nodegroups have up-to-date cloudformation templates
```

1.36 run (about 7.5 minutes):

```
05:50:47 [ℹ]  will upgrade cluster "my-eks-cluster" control plane from current version "1.35" to "1.36"
05:58:18 [✔]  cluster "my-eks-cluster" control plane has been upgraded to version "1.36"
```

**Verification**

```bash
aws eks describe-cluster --name $CLUSTER --region $REGION \
  --query "cluster.{Version:version,Status:status}" --output text
kubectl version
kubectl get nodes
kubectl get pods -A | grep -v -E "Running|Completed"
```

```
ACTIVE  1.35                                       (1.36 run: ACTIVE  1.36)
Server Version: v1.35.8-eks-b9510e3                (1.36 run: v1.36.4-eks-b9510e3)
ip-192-168-21-69...   Ready   v1.34.12-eks-117f323  <- nodes are still on the OLD version, as expected
```

✅ Status `ACTIVE`, server version is the new one, nodes unchanged and `Ready`, no unhealthy pods.
(In the 1.35 run the output also showed `Warning: version difference between client (1.37) and server (1.35) exceeds the supported minor version skew of +/-1`. In the 1.36 run the warning was gone because `kubectl` 1.37 is within ±1 of 1.36.)

---

### Step 3.7: Upgrade the add-ons

**Explanation**
Update each managed add-on to the **Default** version from Step 3.4. `--force` resolves field conflicts if someone edited the add-on by hand. Do `kube-proxy` first, check the pods, then `coredns`. `vpc-cni` is only updated if its Default changed. In this lab it stayed on `v1.22.4-eksbuild.3` for both hops (the 1.35 run re-applied the same version with `--force`, which is a no-op; the 1.36 run skipped it).

**Commands**

*1.34 → 1.35 run*

```bash
eksctl update addon --name kube-proxy --cluster $CLUSTER --region $REGION --version v1.35.3-eksbuild.52 --force
eksctl update addon --name vpc-cni    --cluster $CLUSTER --region $REGION --version v1.22.4-eksbuild.3  --force
eksctl update addon --name coredns    --cluster $CLUSTER --region $REGION --version v1.13.2-eksbuild.51 --force
```

*1.35 → 1.36 run*

```bash
eksctl update addon --name kube-proxy --cluster $CLUSTER --region $REGION --version v1.36.0-eksbuild.48 --force
kubectl get pods -n kube-system          # kube-proxy pods restarted and Running?
eksctl update addon --name coredns    --cluster $CLUSTER --region $REGION --version v1.14.7-eksbuild.11 --force
```

*If `eksctl get addon` shows an empty table (self-managed add-ons)*: this was not the case in the lab, but the original method still applies:

```bash
eksctl utils update-kube-proxy --cluster $CLUSTER --region $REGION --approve
eksctl utils update-aws-node   --cluster $CLUSTER --region $REGION --approve
eksctl utils update-coredns    --cluster $CLUSTER --region $REGION --approve
```

Expected output of each: `[✔] "kube-proxy" is now up-to-date` (and similar for `aws-node`, `coredns`).

**Expected output (important part)**

```
[!]  no IAM OIDC provider associated with cluster, try 'eksctl utils associate-iam-oidc-provider ...'
[ℹ]  Kubernetes version "1.35" in use by cluster "my-eks-cluster"
[ℹ]  new version provided v1.35.3-eksbuild.52
[ℹ]  updating addon
[ℹ]  addon "kube-proxy" active
```

* The `no IAM OIDC provider` warning is harmless here: these add-ons are running without IRSA roles. (If you installed Velero in Step 2.5 you already associated the provider.)
* For `coredns` the log stops at `updating addon` with no `active` line. That is normal; verify below instead.

**Verification**

```bash
eksctl get addon --cluster $CLUSTER --region $REGION
kubectl get pods -n kube-system
kubectl -n kube-system rollout status deployment/coredns

# Prove DNS still works inside the cluster (FQDN of the demo service)
kubectl run dnstest --rm -it --restart=Never --image=busybox:1.36 -- nslookup web.demo.svc.cluster.local

aws eks describe-addon --cluster-name $CLUSTER --addon-name coredns --region $REGION \
  --query "addon.{Version:addonVersion,Status:status}" --output text
```

```
coredns         v1.14.7-eksbuild.11   ACTIVE  0
kube-proxy      v1.36.0-eksbuild.48   ACTIVE  0
metrics-server  v0.9.0-eksbuild.14    ACTIVE  0
vpc-cni         v1.22.4-eksbuild.3    ACTIVE  0

coredns-687dddfb64-7rbr5   1/1   Running   0   45s       <- new ReplicaSet hash = pods were replaced
kube-proxy-6s22n           1/1   Running   0   5m28s

deployment "coredns" successfully rolled out

Name:   web.demo.svc.cluster.local
Address: 10.100.153.157                                  <- equals the CLUSTER-IP of service/web
ACTIVE  v1.14.7-eksbuild.11
```

✅ All four add-ons `ACTIVE` with `ISSUES 0`, all `kube-system` pods `Running`, the CoreDNS rollout finished, and the DNS lookup returns the service IP. The `UPDATE AVAILABLE` column may still list newer *builds* of the same version (for example `v1.36.0-eksbuild.55`); those are optional.

---

### Step 3.8: Upgrade the worker nodes (node group)

**Explanation**
The managed node group is rolled to the new Kubernetes version and the matching Amazon Linux 2023 release. EKS **creates new nodes first**, cordons the old ones (`SchedulingDisabled`), drains them and terminates them. Your demo app survives because it has 2 replicas.

**Commands**

```bash
# Terminal 1: the upgrade
eksctl upgrade nodegroup --name $NODEGROUP --cluster $CLUSTER --region $REGION --kubernetes-version $TARGET

# Terminal 2: watch nodes
kubectl get nodes -w

# Terminal 3: watch the demo pods
kubectl get pods -n demo -w
```

**Expected output (important part)**

1.35 run (about 13.5 minutes):

```
05:18:55 [ℹ]  will upgrade nodes to release version: 1.35.9-20261019
05:18:55 [ℹ]  upgrading nodegroup version
05:31:25 [ℹ]  nodegroup successfully upgraded
```

1.36 run (about 11.5 minutes):

```
06:07:25 [ℹ]  will upgrade nodes to release version: 1.36.5-20261019
06:18:50 [ℹ]  nodegroup successfully upgraded
```

Terminal 2, what the node watch looks like (1.36 run, trimmed):

```
ip-192-168-5-11.ec2.internal     Ready                        v1.35.9-eks-117f323   <- old
ip-192-168-16-172.ec2.internal   NotReady                     v1.36.5-eks-117f323   <- new, joining
ip-192-168-16-172.ec2.internal   Ready                        v1.36.5-eks-117f323
ip-192-168-35-221.ec2.internal   Ready                        v1.36.5-eks-117f323
ip-192-168-51-209.ec2.internal   Ready,SchedulingDisabled     v1.35.9-eks-117f323   <- old, cordoned
ip-192-168-51-209.ec2.internal   NotReady,SchedulingDisabled  v1.35.9-eks-117f323   <- old, being terminated
```

Terminal 3, what the pod watch looks like:

```
web-64c966cf88-2nqhv   1/1   Terminating          <- one old replica goes away
web-64c966cf88-fjnwk   0/1   Pending -> ContainerCreating -> 1/1 Running
web-64c966cf88-hhvcl   1/1   Terminating          <- only after the first replacement is Running
web-64c966cf88-csq45   0/1   Pending -> ContainerCreating -> 1/1 Running
```

Press `Ctrl+C` in the watch terminals when the node list shows only new nodes.

**Verification**

```bash
kubectl get nodes
aws eks describe-nodegroup --cluster-name $CLUSTER --nodegroup-name $NODEGROUP --region $REGION \
  --query "nodegroup.{Version:version,Release:releaseVersion,Status:status}" --output table
```

```
ip-192-168-16-172.ec2.internal   Ready   <none>   12m   v1.36.5-eks-117f323
ip-192-168-35-221.ec2.internal   Ready   <none>   12m   v1.36.5-eks-117f323

|      Release     | Status  |  Version  |
|  1.36.5-20261019 |  ACTIVE |  1.36     |
```

✅ Exactly 2 nodes, both `Ready`, both on the new version; node group `ACTIVE` with the new release version; in the 1.36 pod watch the demo pods were never both down at the same time (a replacement was `Running` before the second old pod was terminated).

---

### Step 3.9: Verify the upgrade

**Explanation**
A final, short checklist that proves the whole cluster is on the new version and your app is healthy.

**Commands**

```bash
kubectl version
kubectl get nodes
kubectl get pods -A
kubectl get all -n demo
aws eks describe-cluster --name $CLUSTER --region $REGION --query "cluster.version" --output text
eksctl get addon --cluster $CLUSTER --region $REGION
```

**Expected output (important part)**

| Check | After 1.35 hop | After 1.36 hop |
|-------|----------------|----------------|
| `kubectl version` server | `v1.35.8-eks-b9510e3` | `v1.36.4-eks-b9510e3` |
| `kubectl get nodes` | 2 × `Ready`, `v1.35.9-eks-117f323` | 2 × `Ready`, `v1.36.5-eks-117f323` |
| `kubectl get pods -A` | all `Running` | all `Running` |
| `deployment.apps/web` | `2/2` | `2/2` |
| `aws eks describe-cluster ... cluster.version` | `1.35` | `1.36` |

**Verification**
✅ All six rows match the table. 🎉 The hop is complete. Wait until you are happy with the cluster (an hour is plenty for a lab) and only then repeat Steps 3.1 to 3.9 with the next `TARGET`.

---

### Step 3.10: Extra post-upgrade health checks (run after the 1.36 hop)

**Explanation**
Deeper checks that go beyond "pods are Running": node conditions, recent events, resource usage, the API server's own readiness (including etcd), and AWS's record of the upgrade. They are optional but cheap, and they are the closest you can get to "checking etcd and the API server" on EKS.

**Commands**

```bash
# Node health conditions
kubectl describe nodes | grep -A3 Conditions

# Recent events (long output; add | tail -30, or only warnings)
kubectl get events -A --sort-by=.lastTimestamp | tail -30
kubectl get events -A --field-selector type=Warning

# Workload controllers and resource usage (top works because metrics-server is installed)
kubectl get deploy,statefulset,daemonset -A
kubectl top pods -A
kubectl get daemonset aws-node -n kube-system
kubectl get daemonset kube-proxy -n kube-system

# API server readiness, including etcd (AWS-managed)
kubectl get --raw='/readyz?verbose'

# AWS's own record of the upgrade
aws eks describe-update --name $CLUSTER --region $REGION \
  --update-id $(aws eks list-updates --name $CLUSTER --region $REGION --query "updateIds[-1]" --output text)

# Control plane logging status
aws eks describe-cluster --name $CLUSTER --region $REGION --query "cluster.logging.clusterLogging"

# Add-ons, node group and next-version insights
eksctl get addon --cluster $CLUSTER --region $REGION
aws eks list-insights --cluster-name $CLUSTER --region $REGION \
  --filter kubernetesVersions=1.37 \
  --query "insights[].{Name:name,Status:insightStatus.status}" --output table
```

**Expected output (important part)**

```
MemoryPressure   False   ...   KubeletHasSufficientMemory   kubelet has sufficient memory available

demo          deployment.apps/web              2/2
kube-system   deployment.apps/coredns          2/2
kube-system   deployment.apps/metrics-server   2/2
kube-system   daemonset.apps/aws-node          2   2   2   2   2
kube-system   daemonset.apps/kube-proxy        2   2   2   2   2

demo          web-64c966cf88-csq45     0m    3Mi
kube-system   coredns-687dddfb64-7t2hx 1m    10Mi

[+]ping ok
[+]etcd ok
[+]etcd-readiness ok
[+]informer-sync ok
...

"status": "Successful",
"type": "VersionUpdate",
"params": [ { "type": "Version", "value": "1.36" }, { "type": "PlatformVersion", "value": "eks.15" } ],
"errors": []

"enabled": false          <- all five control-plane log types are disabled (default)

|  Deprecated APIs removed in Kubernetes v1.37  |  PASSING |
```

**Verification**
✅ No pressure conditions on the nodes. ✅ All deployments and daemonsets fully ready. ✅ `/readyz` shows `etcd ok`. ✅ The update record says `Successful` with an empty `errors` list. ✅ No deprecated-API findings for the next version (`1.37`).

Events you can safely ignore right after a node roll (seen in the real run): `FailedDaemonPod` / `NodeShutdown` for `aws-node` and `kube-proxy` on the **old** nodes while they drain, `Unhealthy ... Readiness probe failed` for a CoreDNS pod in the first seconds after it starts, and `InvalidDiskCapacity ... invalid capacity 0 on image filesystem` on a freshly started node. Warnings that keep repeating on a *current* node are the ones to investigate.

An extra DNS probe was also run:

```bash
kubectl run dns-test --image=busybox:1.36 --rm -it --restart=Never -- nslookup kubernetes.default
```

It printed `** server can't find kubernetes.default: NXDOMAIN` although CoreDNS was healthy and the earlier lookup of `web.demo.svc.cluster.local` had worked. See the Troubleshooting table: use the full name `kubernetes.default.svc.cluster.local` for this kind of test.

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
