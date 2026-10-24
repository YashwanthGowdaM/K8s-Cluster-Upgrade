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

**How this guide is organised**

| Part | Content |
|------|---------|
| 1 | Tool, credential and cluster health checks (single commands, each with expected output) |
| 2 | Backups: YAML export, AWS-side config, S3 copy, optional Velero |
| 3 | Upgrade **1.34 → 1.35** only (pre-checks, control plane, add-ons, nodes, verification) |
| 4 | Upgrade **1.35 → 1.36**: change `TARGET` from `1.35` to `1.36`, repeat Part 3, plus the extra checks used only in this hop |
| 5 to 7 | Troubleshooting, cleanup, checklist |
| 8 | Comparison table: 1.34 vs 1.35 vs 1.36 |

Each step has: **Explanation → Command → Expected output → Verify**. One command per block. Expected output shows only the important lines. Account IDs and subnet IDs are replaced with placeholders.

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
* When this guide was tested, AWS listed 1.34 to 1.37 in standard support. Confirm with the command in Step 1.4.2.

### 0.4 Cost warning

An EKS control plane costs about **$0.10 per hour** plus EC2 nodes. Delete the cluster when finished practising (see Part 6).

---

## 1. Prerequisites and health check

> Every step below uses the same layout: **Explanation → Command → Expected output → Verify**. Each block holds **one command**. Expected output shows only the important lines (the real output was longer). Account IDs are replaced with `123456789012`.

### Step 1.0: Create the cluster (already done)

**Explanation:** This is the cluster used in this guide. `eksctl` creates two CloudFormation stacks (control plane + managed node group) and installs the default add-ons. In our run it took about 16 minutes (03:43 to 03:59).

**Command:**

```bash
eksctl create cluster --name my-eks-cluster --nodegroup-name my-worker-node \
  --node-type t2.medium --nodes 2 --managed --region us-east-1
```

**Expected output (important lines):**

```
[ℹ]  using Kubernetes version 1.34
[ℹ]  default addons vpc-cni, kube-proxy, coredns, metrics-server were not specified, will install them as EKS addons
[✔]  all EKS cluster resources for "my-eks-cluster" have been created
[ℹ]  nodegroup "my-worker-node" has 2 node(s)
[✔]  EKS cluster "my-eks-cluster" in "us-east-1" region is ready
```

**Verify:** The last line says the cluster is ready. Note that `metrics-server` is installed as a 4th add-on, so you will manage **four** add-ons (not three) during upgrades.

> You may also see `Auto Mode will be enabled by default in an upcoming release of eksctl` and a `vpc-cni ... OIDC is disabled` warning. Both are informational for this lab.

### Step 1.1: Confirm the tools are installed

#### Step 1.1.1: eksctl

**Explanation:** `eksctl` creates, upgrades and deletes the cluster and node group.

**Command:**

```bash
eksctl version
```

**Expected output:**

```
0.231.0
```

**Verify:** A version number is printed. If you get `command not found`, install it with the two commands below (one at a time).

```bash
curl --silent --location "https://github.com/weaveworks/eksctl/releases/latest/download/eksctl_$(uname -s)_amd64.tar.gz" | tar xz -C /tmp
```

```bash
sudo mv /tmp/eksctl /usr/local/bin
```

#### Step 1.1.2: kubectl

**Explanation:** `kubectl` is the command-line client for the Kubernetes API server. `--client` prints only the local version and does not contact the cluster.

**Command:**

```bash
kubectl version --client
```

**Expected output:**

```
Client Version: v1.37.1
Kustomize Version: v5.8.1
```

**Verify:** A client version is printed. In our run the client was **v1.37**, which is more than one minor version away from the 1.34 and 1.35 servers, so `kubectl` printed `Warning: version difference between client (1.37) and server (1.34) exceeds the supported minor version skew of +/-1`. It is harmless for this lab, and it disappears once the cluster reaches 1.36.

#### Step 1.1.3: AWS CLI

**Explanation:** The AWS CLI is used for EKS, EC2, S3 and Service Quotas calls.

**Command:**

```bash
aws --version
```

**Expected output:**

```
aws-cli/2.38.5 Python/3.14.8 Linux/7.0.0-1014-aws exe/x86_64.ubuntu.26
```

**Verify:** The version starts with `aws-cli/2`. The upgrade-insight commands in Part 3 need a recent AWS CLI v2.

### Step 1.2: Confirm AWS credentials work

**Explanation:** Confirms which AWS identity your terminal is using. Use the same IAM user/role that created the cluster. It needs permissions for EKS, EC2, IAM, CloudFormation and S3.

**Command:**

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

**Verify:** `Account` is the account that owns the cluster. If you get `Unable to locate credentials`, run `aws configure` and enter your Access Key, Secret Key, region `us-east-1`, output `json`.

### Step 1.3: Set variables and connect `kubectl` to the cluster

#### Step 1.3.1: Set the cluster name

**Explanation:** Variables keep every later command short and copy-paste safe.

**Command:**

```bash
export CLUSTER=my-eks-cluster
```

**Expected output:** none.

#### Step 1.3.2: Set the region

**Command:**

```bash
export REGION=us-east-1
```

**Expected output:** none.

#### Step 1.3.3: Set the node group name

**Command:**

```bash
export NODEGROUP=my-worker-node
```

**Expected output:** none.

#### Step 1.3.4: Set the AWS account ID

**Explanation:** Reads the account number from your credentials (used later for the S3 bucket name).

**Command:**

```bash
export ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
```

**Expected output:** none.

#### Step 1.3.5: Make the variables permanent (recommended)

**Explanation:** Variables are lost when the terminal closes. Add the four `export` lines from Steps 1.3.1 to 1.3.4 at the bottom of `~/.bashrc` so every new terminal has them.

**Command:**

```bash
nano ~/.bashrc
```

**Expected output:** the editor opens. Paste the four `export` lines at the end, save (`Ctrl+O`, `Enter`) and exit (`Ctrl+X`).

#### Step 1.3.6: Load the variables into the current terminal

**Command:**

```bash
source ~/.bashrc
```

**Expected output:** none.

#### Step 1.3.7: Verify the variables

**Command:**

```bash
echo -e "$CLUSTER\n$REGION\n$NODEGROUP\n$ACCOUNT"
```

**Expected output:**

```
my-eks-cluster
us-east-1
my-worker-node
123456789012
```

**Verify:** All four lines have a value. An empty line means that variable is not set; redo the matching step.

#### Step 1.3.8: Create the kubeconfig entry

**Explanation:** Tells `kubectl` how to reach (and authenticate to) the cluster's API server.

**Command:**

```bash
aws eks update-kubeconfig --name $CLUSTER --region $REGION
```

**Expected output:**

```
Added new context arn:aws:eks:us-east-1:123456789012:cluster/my-eks-cluster to /home/<you>/.kube/config
```

**Verify:** The message says `Added new context` (or `Updated context` if it already existed).

#### Step 1.3.9: Test the connection

**Command:**

```bash
kubectl get nodes
```

**Expected output:**

```
NAME                            STATUS   ROLES    AGE     VERSION
ip-192-168-21-69.ec2.internal   Ready    <none>   3m17s   v1.34.12-eks-117f323
ip-192-168-44-47.ec2.internal   Ready    <none>   3m16s   v1.34.12-eks-117f323
```

**Verify:** Both nodes are `Ready` and on `v1.34.x`. If not, stop and fix that first.

### Step 1.4: Check the current version and the available versions

#### Step 1.4.1: Current cluster version

**Explanation:** Reads the control plane version from the EKS API.

**Command:**

```bash
aws eks describe-cluster --name $CLUSTER --region $REGION --query "cluster.version" --output text
```

**Expected output:**

```
1.34
```

**Verify:** It prints `1.34`.

#### Step 1.4.2: Versions EKS offers

**Explanation:** Lists every Kubernetes version EKS supports and its support type. Upgrades are one minor version at a time, so you need `1.35` and `1.36` in this list.

**Command:**

```bash
aws eks describe-cluster-versions --region $REGION \
  --query "clusterVersions[].{Version:clusterVersion,Status:status}" --output table
```

**Expected output:**

```
|  STANDARD_SUPPORT |  1.37     |
|  STANDARD_SUPPORT |  1.36     |
|  STANDARD_SUPPORT |  1.35     |
|  STANDARD_SUPPORT |  1.34     |
|  EXTENDED_SUPPORT |  1.33     |
```

**Verify:** `1.35` and `1.36` show `STANDARD_SUPPORT`. If `describe-cluster-versions` is not recognised, your AWS CLI is old; update it (re-run the AWS-CLI install and add `--update` to `sudo ./aws/install`).

### Step 1.5: Deploy a sample app (proves nothing breaks during the upgrade)

#### Step 1.5.1: Create a namespace

**Command:**

```bash
kubectl create namespace demo
```

**Expected output:**

```
namespace/demo created
```

#### Step 1.5.2: Create a 2-replica nginx deployment

**Command:**

```bash
kubectl create deployment web --image=nginx --replicas=2 -n demo
```

**Expected output:**

```
deployment.apps/web created
```

#### Step 1.5.3: Expose it as a service

**Command:**

```bash
kubectl expose deployment web --port=80 -n demo
```

**Expected output:**

```
service/web exposed
```

#### Step 1.5.4: Check everything is running

**Command:**

```bash
kubectl get all -n demo
```

**Expected output:**

```
NAME                       READY   STATUS    RESTARTS   AGE
pod/web-64c966cf88-nlgz5   1/1     Running   0          20s
pod/web-64c966cf88-wjfxx   1/1     Running   0          20s

NAME          TYPE        CLUSTER-IP       EXTERNAL-IP   PORT(S)   AGE
service/web   ClusterIP   10.100.153.157   <none>        80/TCP    11s

NAME                  READY   UP-TO-DATE   AVAILABLE   AGE
deployment.apps/web   2/2     2            2           20s
```

**Verify:** `deployment.apps/web` shows `2/2`. Note the service `CLUSTER-IP` (`10.100.153.157` here); it should stay the same after every upgrade.

### Step 1.6: Check all system pods are healthy

#### Step 1.6.1: List namespaces

**Explanation:** (`kns` in our terminal is a shortcut alias for this command.)

**Command:**

```bash
kubectl get ns
```

**Expected output:**

```
NAME              STATUS   AGE
default           Active   12m
demo              Active   2m5s
kube-node-lease   Active   12m
kube-public       Active   12m
kube-system       Active   12m
```

**Verify:** All namespaces are `Active`.

#### Step 1.6.2: List pods in all namespaces

**Explanation:** (`kgp` in our terminal is a shortcut alias.) Anything `Pending`, `CrashLoopBackOff` or `Error` must be fixed **before** any upgrade.

**Command:**

```bash
kubectl get pods -A
```

**Expected output (important lines):**

```
NAMESPACE     NAME                              READY   STATUS    RESTARTS   AGE
kube-system   aws-node-rmql9                    2/2     Running   0          6m43s
kube-system   coredns-7879986bf8-7sqmx          1/1     Running   0          10m
kube-system   kube-proxy-jm6tg                  1/1     Running   0          6m42s
kube-system   metrics-server-68c65f79d8-8lcjw   1/1     Running   0          4m37s
```

**Verify:** Every pod is `Running` (or `Completed`). You should see `aws-node`, `coredns`, `kube-proxy` and `metrics-server` pods.

---

## 2. TASK 1: Backup (etcd data + API server objects + cluster config)

Do **Step 2.1 to 2.3 always**. **Method B (Velero)** is optional but recommended if you have persistent volumes or want one-command restore.

### Step 2.1: Method A: Export every Kubernetes object to YAML files

This reads everything through the API server (the same data etcd holds) and stores it as files. No extra tools needed.

#### Step 2.1.1: Create the backup folder

**Command:**

```bash
mkdir -p ~/eks-backups && cd ~/eks-backups
```

**Expected output:** none (your prompt now ends with `~/eks-backups$`).

#### Step 2.1.2: Create the backup script

**Explanation:** The script loops over every cluster-scoped and namespaced resource type, saves each as YAML, then makes a `.tar.gz` archive.

**Command:**

```bash
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
```

**Expected output:** none.

#### Step 2.1.3: Make the script executable

**Command:**

```bash
chmod +x backup-k8s.sh
```

**Expected output:** none.

#### Step 2.1.4: Confirm the script exists

**Command:**

```bash
ls
```

**Expected output:**

```
backup-k8s.sh
```

#### Step 2.1.5: Run the script (takes 1–5 minutes)

**Command:**

```bash
./backup-k8s.sh
```

**Expected output:**

```
>> Backing up cluster-scoped resources...
>> Backing up namespaced resources...
   namespace default done
   namespace demo done
   namespace kube-node-lease done
   namespace kube-public done
   namespace kube-system done
>> DONE. Backup folder : /home/<you>/eks-backups/k8s-backup-20261024-040705
>> DONE. Backup archive: /home/<you>/eks-backups/k8s-backup-20261024-040705.tar.gz
```

**Verify:** Both `DONE` lines are printed and all five namespaces say `done`.

#### Step 2.1.6: Verify the backup contains the demo app

**Command:**

```bash
ls ~/eks-backups/k8s-backup-*/namespaced/demo/
```

**Expected output:**

```
configmaps.yaml  deployments.apps.yaml  pods.metrics.k8s.io.yaml  pods.yaml  replicasets.apps.yaml  serviceaccounts.yaml  services.yaml
```

**Verify:** `deployments.apps.yaml` and `services.yaml` are present. (`pods.metrics.k8s.io.yaml` appears because `metrics-server` is installed.) If you have taken several backups, the command lists one folder per backup.

#### Step 2.1.7: Restrict access to the backup

**Explanation:** ⚠️ The backup contains **Secrets** (base64, not encrypted). Never commit it to Git or share it.

**Command:**

```bash
chmod -R go-rwx ~/eks-backups
```

**Expected output:** none.

### Step 2.2: Back up the AWS-side cluster configuration

**Explanation:** The YAML export has no EKS settings (version, node group, add-ons, VPC). These commands save them as JSON/YAML next to the backup.

#### Step 2.2.1: Choose a unique folder name

**Explanation:** Storing the name in a variable guarantees every command below writes to the *same* folder (calling `date` repeatedly could produce different names a second apart).

**Command:**

```bash
export AWS_CFG_DIR=$HOME/eks-backups/aws-config-$(date +%Y%m%d-%H%M%S)
```

**Expected output:** none.

#### Step 2.2.2: Create the folder

**Command:**

```bash
mkdir -p $AWS_CFG_DIR
```

**Expected output:** none.

#### Step 2.2.3: Move into the folder

**Command:**

```bash
cd $AWS_CFG_DIR
```

**Expected output:** none (prompt shows `.../aws-config-20261024-...$`).

#### Step 2.2.4: Save the cluster definition

**Command:**

```bash
aws eks describe-cluster --name $CLUSTER --region $REGION > cluster.json
```

**Expected output:** none. Creates `cluster.json` (version, VPC, endpoint, role).

#### Step 2.2.5: Save the node group list

**Command:**

```bash
aws eks list-nodegroups --cluster-name $CLUSTER --region $REGION > nodegroups-list.json
```

**Expected output:** none. Creates `nodegroups-list.json`.

#### Step 2.2.6: Save the node group definition

**Command:**

```bash
aws eks describe-nodegroup --cluster-name $CLUSTER --nodegroup-name $NODEGROUP --region $REGION > nodegroup.json
```

**Expected output:** none. Creates `nodegroup.json` (instance type, scaling, AMI release).

#### Step 2.2.7: Save the add-on list

**Command:**

```bash
aws eks list-addons --cluster-name $CLUSTER --region $REGION > addons.json
```

**Expected output:** none. Creates `addons.json`.

#### Step 2.2.8: Save the eksctl view of the cluster

**Command:**

```bash
eksctl get cluster --name $CLUSTER --region $REGION -o yaml > eksctl-cluster.yaml
```

**Expected output:** none. Creates `eksctl-cluster.yaml`.

#### Step 2.2.9: Save the eksctl view of the node group

**Command:**

```bash
eksctl get nodegroup --cluster $CLUSTER --region $REGION -o yaml > eksctl-nodegroup.yaml
```

**Expected output:** none. Creates `eksctl-nodegroup.yaml`.

#### Step 2.2.10: Save the kubectl client/server versions

**Command:**

```bash
kubectl version > kubectl-version.txt
```

**Expected output:** the version-skew warning only (the versions go into the file):

```
Warning: version difference between client (1.37) and server (1.34) exceeds the supported minor version skew of +/-1
```

#### Step 2.2.11: Save the node list

**Command:**

```bash
kubectl get nodes -o wide > nodes.txt
```

**Expected output:** none. Creates `nodes.txt`.

#### Step 2.2.12: Verify all 8 files exist

**Command:**

```bash
ls -l
```

**Expected output:**

```
-rw-rw-r-- 1 ubuntu ubuntu  111 Oct 24 04:13 addons.json
-rw-rw-r-- 1 ubuntu ubuntu 5650 Oct 24 04:13 cluster.json
-rw-rw-r-- 1 ubuntu ubuntu 4383 Oct 24 04:13 eksctl-cluster.yaml
-rw-rw-r-- 1 ubuntu ubuntu  509 Oct 24 04:13 eksctl-nodegroup.yaml
-rw-rw-r-- 1 ubuntu ubuntu   87 Oct 24 04:13 kubectl-version.txt
-rw-rw-r-- 1 ubuntu ubuntu 2311 Oct 24 04:13 nodegroup.json
-rw-rw-r-- 1 ubuntu ubuntu   55 Oct 24 04:13 nodegroups-list.json
-rw-rw-r-- 1 ubuntu ubuntu  606 Oct 24 04:13 nodes.txt
```

**Verify:** Eight files, none with size `0`. (If an `eksctl get ...` file is empty, that's fine; `cluster.json` and `nodegroup.json` hold the important data.)

### Step 2.3: Copy backups to S3 (so they survive if your machine dies)

#### Step 2.3.1: Choose the bucket name

**Command:**

```bash
export BACKUP_BUCKET=eks-backups-$ACCOUNT-$REGION
```

**Expected output:** none.

#### Step 2.3.2: Create the bucket

**Command:**

```bash
aws s3 mb s3://$BACKUP_BUCKET --region $REGION
```

**Expected output:**

```
make_bucket: eks-backups-123456789012-us-east-1
```

**Verify:** `make_bucket` is printed. Running it again for a bucket you already own just prints the same line.

#### Step 2.3.3: Upload the backups

**Explanation:** `sync` uploads only new or changed files, so the next backup round is much faster.

**Command:**

```bash
aws s3 sync ~/eks-backups s3://$BACKUP_BUCKET/$CLUSTER/
```

**Expected output (important lines):**

```
upload: ./cluster.json to s3://eks-backups-123456789012-us-east-1/my-eks-cluster/aws-config-20261024/cluster.json
upload: ../k8s-backup-20261024-040705.tar.gz to s3://eks-backups-123456789012-us-east-1/my-eks-cluster/k8s-backup-20261024-040705.tar.gz
upload: ../backup-k8s.sh to s3://eks-backups-123456789012-us-east-1/my-eks-cluster/backup-k8s.sh
...
```

**Verify:** You see `upload:` lines for the `.tar.gz`, the `aws-config-...` files and `backup-k8s.sh`, and no `error` lines.

#### Step 2.3.4: List what is in S3

**Command:**

```bash
aws s3 ls s3://$BACKUP_BUCKET/$CLUSTER/ --recursive | head
```

**Expected output:**

```
2026-10-24 04:16:13       5650 my-eks-cluster/aws-config-20261024/cluster.json
2026-10-24 04:16:13       1241 my-eks-cluster/backup-k8s.sh
2026-10-24 04:16:13      78435 my-eks-cluster/k8s-backup-20261024-040705.tar.gz
...
```

**Verify:** The `.tar.gz` and `aws-config` files are listed. The messages `aws: [ERROR]: [Errno 32] Broken pipe` and `BrokenPipeError` that may follow are **harmless**: `head` closes the pipe after 10 lines.

### Step 2.4: How to restore from Method A (when needed)

Only run this if something was deleted or broken. Example: restore just the `demo` namespace. Replace `<STAMP>` with your backup folder's timestamp.

#### Step 2.4.1: Re-create the namespace

**Command:**

```bash
kubectl create namespace demo --dry-run=client -o yaml | kubectl apply -f -
```

**Expected output:** `namespace/demo created` (or `configured` if it still exists).

#### Step 2.4.2: Restore the deployment

**Command:**

```bash
kubectl apply -f ~/eks-backups/k8s-backup-<STAMP>/namespaced/demo/deployments.apps.yaml
```

**Expected output:** `deployment.apps/web created`.

#### Step 2.4.3: Restore the service

**Command:**

```bash
kubectl apply -f ~/eks-backups/k8s-backup-<STAMP>/namespaced/demo/services.yaml
```

**Expected output:** `service/web created`.

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

## 3. TASK 2: Upgrade the cluster 1.34 → 1.35

> This Part covers **only 1.34 → 1.35**. Do not mix in the 1.36 hop. When Step 3.5 is finished, go to **Part 4**, where you change `TARGET` from `1.35` to `1.36` and repeat the same cycle.
>
> Order is always: **(1) pre-checks → (2) control plane → (3) add-ons → (4) worker nodes → (5) verify.**

### Step 3.0: Set the target version

**Explanation:** Every later command reads the target version from this variable, so the same steps can be reused for the next upgrade by changing one value.

**Command:**

```bash
export TARGET=1.35
```

**Expected output:** none.

**Verify:**

```bash
echo $TARGET
```

```
1.35
```

### Step 3.1: Pre-upgrade checks

#### Step 3.1.1: Cluster is ACTIVE and on the expected version

**Explanation:** An upgrade only starts from an `ACTIVE` cluster whose version is exactly one minor version below the target.

**Command:**

```bash
aws eks describe-cluster --name $CLUSTER --region $REGION \
  --query "cluster.{Version:version,Status:status}" --output table
```

**Expected output:**

```
|  Status  |  Version  |
|  ACTIVE  |  1.34     |
```

**Verify:** `ACTIVE` and `1.34`.

#### Step 3.1.2: Nodes are Ready

**Explanation:** Unhealthy nodes make the rolling node upgrade fail or hang.

**Command:**

```bash
kubectl get nodes
```

**Expected output:**

```
NAME                            STATUS   ROLES    AGE   VERSION
ip-192-168-21-69.ec2.internal   Ready    <none>   64m   v1.34.12-eks-117f323
ip-192-168-44-47.ec2.internal   Ready    <none>   64m   v1.34.12-eks-117f323
```

**Verify:** Both nodes `Ready`, version `v1.34.x`.

#### Step 3.1.3: No unhealthy pods

**Explanation:** Shows every pod whose status is *not* `Running` or `Completed`.

**Command:**

```bash
kubectl get pods -A | grep -v -E "Running|Completed"
```

**Expected output:** only the header line (no pods listed under it):

```
NAMESPACE     NAME                              READY   STATUS    RESTARTS   AGE
```

**Verify:** Nothing below the header. Fix any `Pending` / `CrashLoopBackOff` / `Error` pod first.

#### Step 3.1.4: EKS Upgrade Insights for 1.35

**Explanation:** AWS scans the cluster and reports what could break when moving to the target version (removed APIs, version skew, add-on compatibility).

**Command:**

```bash
aws eks list-insights --cluster-name $CLUSTER --region $REGION \
  --filter kubernetesVersions=$TARGET \
  --query "insights[].{Name:name,Status:insightStatus.status}" --output table
```

**Expected output (ours):**

```
|  kube-proxy version skew           |  PASSING |
|  Cluster health issues             |  PASSING |
|  Kubelet version skew              |  PASSING |
|  EKS add-on version compatibility  |  UNKNOWN |
|  Amazon Linux 2 compatibility      |  PASSING |
```

**Verify:** Every row should be `PASSING`. We got one `UNKNOWN` (add-on compatibility). `UNKNOWN` is not an error, but it must be explained before you continue, so Steps 3.1.5 to 3.1.9 investigate it. If you ever see `ERROR` or `WARNING`, read the details with Step 3.1.5b and fix the reported issue (usually a removed/deprecated API in your manifests) first.

#### Step 3.1.5: Investigate the `UNKNOWN` insight

**a) Get the insight ID**

**Explanation:** The previous table does not print IDs, so this command prints just the ID of the add-on compatibility insight.

**Command:**

```bash
aws eks list-insights --cluster-name $CLUSTER --region $REGION \
  --filter kubernetesVersions=$TARGET \
  --query "insights[?name=='EKS add-on version compatibility'].id" --output text
```

**Expected output:**

```
88f7d638-d4bf-4963-a674-10c185ac1d36
```

**b) Read the insight details**

**Explanation:** Shows *why* the status is `UNKNOWN` and which add-on builds are compatible with 1.35.

**Command:**

```bash
aws eks describe-insight --cluster-name $CLUSTER --region $REGION --id <INSIGHT_ID_FROM_ABOVE>
```

**Expected output (important part):**

```json
"insightStatus": {
    "status": "UNKNOWN",
    "reason": "Unable to determine version compatibility of EKS add-ons."
},
...
"reason": "Unable to determine addon compatibility: addon 'coredns' is in 'DEGRADED' state."   <- coredns row: UNKNOWN
"reason": "All installed EKS add-on versions are compatible with next Kubernetes version."     <- kube-proxy and vpc-cni rows: PASSING
```

**Verify:** The cause is only `coredns`, which was `DEGRADED` when the insight was calculated (`lastRefreshTime` 03:59, about a minute after cluster creation). `kube-proxy` and `vpc-cni` are already `PASSING`. The next command checks whether `coredns` is healthy now.

**c) Check CoreDNS health now**

**Explanation:** Reads the live state of the `coredns` add-on.

**Command:**

```bash
aws eks describe-addon --cluster-name $CLUSTER --addon-name coredns --region $REGION
```

**Expected output (important part):**

```json
"addonName": "coredns",
"status": "ACTIVE",
"addonVersion": "v1.12.4-eksbuild.58",
"health": {
    "issues": []
}
```

**Verify:** `status` is `ACTIVE` and `issues` is empty. The `DEGRADED` state was most likely transient, right after cluster creation, so the `UNKNOWN` can be treated as a stale reading.

**d) Check the CoreDNS pods**

**Explanation:** `k8s-app=kube-dns` is the label CoreDNS pods carry.

**Command:**

```bash
kubectl -n kube-system get pods -l k8s-app=kube-dns -o wide
```

**Expected output:**

```
NAME                       READY   STATUS    RESTARTS   AGE   IP               NODE
coredns-7879986bf8-7sqmx   1/1     Running   0          31m   192.168.3.73     ip-192-168-21-69.ec2.internal
coredns-7879986bf8-j2kn4   1/1     Running   0          31m   192.168.14.244   ip-192-168-21-69.ec2.internal
```

**Verify:** Two pods, `1/1 Running`.

**e) List the managed add-ons**

**Explanation:** Confirms which add-ons EKS manages for this cluster (these are the ones to upgrade).

**Command:**

```bash
aws eks list-addons --cluster-name $CLUSTER --region $REGION
```

**Expected output:**

```json
{
    "addons": [
        "coredns",
        "kube-proxy",
        "metrics-server",
        "vpc-cni"
    ]
}
```

**Verify:** Four add-ons. `metrics-server` is included because `eksctl` installs it by default.

#### Step 3.1.6: Current add-on versions and available updates

**Explanation:** One table with every add-on's current version, status and newer builds.

**Command:**

```bash
eksctl get addon --cluster $CLUSTER --region $REGION
```

**Expected output (important columns):**

```
NAME            VERSION               STATUS  ISSUES  UPDATE AVAILABLE
coredns         v1.12.4-eksbuild.58   ACTIVE  0       v1.13.2-eksbuild.59,v1.13.2-eksbuild.51,...
kube-proxy      v1.34.6-eksbuild.52   ACTIVE  0       v1.34.6-eksbuild.59
metrics-server  v0.9.0-eksbuild.14    ACTIVE  0
vpc-cni         v1.22.4-eksbuild.3    ACTIVE  0       v1.23.2-eksbuild.6,...
```

**Verify:** All four are `ACTIVE` with `ISSUES 0`. Write these versions down; they are the "before" values.

#### Step 3.1.7: What is actually running (pods and images)

**a) Pods with node placement**

**Command:**

```bash
kubectl get pods -n kube-system -o wide
```

**Expected output (important lines):**

```
aws-node-rmql9                    2/2     Running   0          38m   ...   ip-192-168-21-69.ec2.internal
coredns-7879986bf8-7sqmx          1/1     Running   0          41m   ...   ip-192-168-21-69.ec2.internal
kube-proxy-jm6tg                  1/1     Running   0          38m   ...   ip-192-168-44-47.ec2.internal
metrics-server-68c65f79d8-8lcjw   1/1     Running   0          36m   ...   ip-192-168-21-69.ec2.internal
```

**Verify:** All `Running`; `aws-node` and `kube-proxy` have one pod per node.

**b) Container images of `aws-node` (VPC CNI) and `kube-proxy`**

**Explanation:** Confirms the image tags match what `eksctl get addon` reports.

**Command:**

```bash
kubectl get ds aws-node kube-proxy -n kube-system \
  -o jsonpath='{range .items[*]}{.metadata.name}{"  "}{.spec.template.spec.containers[0].image}{"\n"}{end}'
```

**Expected output:**

```
aws-node  602401143452.dkr.ecr.us-east-1.amazonaws.com/amazon-k8s-cni:v1.22.4-eksbuild.3
kube-proxy  602401143452.dkr.ecr.us-east-1.amazonaws.com/eks/kube-proxy:v1.34.6-eksbuild.52
```

**c) Container image of CoreDNS**

**Command:**

```bash
kubectl get deploy coredns -n kube-system \
  -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
```

**Expected output:**

```
602401143452.dkr.ecr.us-east-1.amazonaws.com/eks/coredns:v1.12.4-eksbuild.58
```

**Verify:** Tags match Step 3.1.6.

#### Step 3.1.8: Which add-on versions are compatible with 1.35

**a) kube-proxy, vpc-cni and coredns**

**Explanation:** Lists every build compatible with the target version. The row where `Default` is `True` is the version EKS recommends and the one we used.

**Command:**

```bash
for ADDON in kube-proxy vpc-cni coredns; do
  echo "=== $ADDON ==="
  aws eks describe-addon-versions --addon-name $ADDON --kubernetes-version $TARGET --region $REGION \
    --query "addons[0].addonVersions[].{Version:addonVersion,Default:compatibilities[0].defaultVersion}" --output table
done
```

**Expected output (trimmed to the `Default = True` rows; the real tables list dozens of builds):**

```
=== kube-proxy ===
|  True    |  v1.35.3-eksbuild.52   |
=== vpc-cni ===
|  True    |  v1.22.4-eksbuild.3  |
=== coredns ===
|  True    |  v1.13.2-eksbuild.51  |
```

**b) metrics-server**

**Explanation:** Same lookup for the fourth add-on (kept separate because it is not in the README's original loop).

**Command:**

```bash
aws eks describe-addon-versions --addon-name metrics-server --kubernetes-version $TARGET --region $REGION \
  --query "addons[0].addonVersions[].{Version:addonVersion,Default:compatibilities[0].defaultVersion}" --output table
```

**Expected output (trimmed):**

```
|  True    |  v0.9.0-eksbuild.14  |
```

**c) metrics-server version currently installed**

**Command:**

```bash
aws eks describe-addon --cluster-name $CLUSTER --addon-name metrics-server --region $REGION \
  --query "addon.addonVersion" --output text
```

**Expected output:**

```
v0.9.0-eksbuild.14
```

**Verify (decision table for 1.35):**

| Add-on | Current (1.34) | Default for 1.35 | Action |
|--------|----------------|------------------|--------|
| kube-proxy | v1.34.6-eksbuild.52 | v1.35.3-eksbuild.52 | Update |
| vpc-cni | v1.22.4-eksbuild.3 | v1.22.4-eksbuild.3 | Already the default (command still safe to run) |
| coredns | v1.12.4-eksbuild.58 | v1.13.2-eksbuild.51 | Update |
| metrics-server | v0.9.0-eksbuild.14 | v0.9.0-eksbuild.14 | No change needed |

#### Step 3.1.9: Take a fresh backup right before the upgrade

**Explanation:** The control plane upgrade cannot be rolled back, so take a new backup now (optionally also `velero backup create pre-upgrade-$TARGET --wait`).

**Command:**

```bash
~/eks-backups/backup-k8s.sh
```

**Expected output (last lines):**

```
   namespace kube-system done
>> DONE. Backup folder : /home/<you>/eks-backups/k8s-backup-20261024-044438
>> DONE. Backup archive: /home/<you>/eks-backups/k8s-backup-20261024-044438.tar.gz
```

**Verify:** Both `DONE` lines are printed. (Optional: re-run Step 2.3.3 to copy it to S3.)

#### Step 3.1.10: Free IP addresses in the cluster subnets

**Explanation:** The control plane upgrade and the replacement nodes need free IPs in your subnets.

**a) Find the subnets used by the cluster**

**Command:**

```bash
aws eks describe-cluster --name $CLUSTER --region $REGION \
  --query "cluster.resourcesVpcConfig.subnetIds" --output text
```

**Expected output:** four subnet IDs separated by tabs, for example:

```
subnet-0aaaaaaaaaaaaaaaa   subnet-0bbbbbbbbbbbbbbbb   subnet-0cccccccccccccccc   subnet-0dddddddddddddddd
```

**b) Count the free IPs in each subnet**

**Command:**

```bash
aws ec2 describe-subnets \
  --subnet-ids <SUBNET_1> <SUBNET_2> <SUBNET_3> <SUBNET_4> \
  --query "Subnets[].{Subnet:SubnetId,AZ:AvailabilityZone,AvailableIPs:AvailableIpAddressCount}" \
  --output table
```

**Expected output:**

```
|     AZ     | AvailableIPs |
|  us-east-1f|  8174        |
|  us-east-1d|  8175        |
|  us-east-1d|  8186        |
|  us-east-1f|  8186        |
```

**Verify:** Each subnet has thousands of free IPs (a handful is the real minimum).

#### Step 3.1.11: Node group scaling settings

**Explanation:** Shows how many nodes the group keeps.

**Command:**

```bash
aws eks describe-nodegroup --cluster-name $CLUSTER --nodegroup-name $NODEGROUP --region $REGION \
  --query "nodegroup.scalingConfig" --output table
```

**Expected output:**

```
| desiredSize |  maxSize  |  minSize  |
|  2          |  2        |  2        |
```

**Verify:** 2 / 2 / 2. In our run the node upgrade completed with this setting unchanged.

#### Step 3.1.12: EC2 vCPU quota

**Explanation:** The node upgrade launches replacement nodes **before** removing the old ones. In our run **both** new nodes were launched first, so 4 `t2.medium` nodes (4 × 2 = 8 vCPUs) briefly existed. Quota `L-1216C47A` is the On-Demand Standard-instance vCPU limit.

**Command:**

```bash
aws service-quotas get-service-quota --service-code ec2 --quota-code L-1216C47A \
  --region $REGION --query "Quota.Value" --output text
```

**Expected output:**

```
16.0
```

**Verify:** The value is at least 8 (we had 16).

✅ **Pre-checks done when:** cluster `ACTIVE` on 1.34, nodes `Ready`, no unhealthy pods, insights explained, add-on target versions noted, fresh backup taken, IPs and quota sufficient.

### Step 3.2: Upgrade the control plane (API server + etcd, handled by AWS)

#### Step 3.2.1: Start the control plane upgrade

**Explanation:** `eksctl` asks AWS to upgrade the managed control plane. Without `--approve`, `eksctl` only shows a plan and does nothing (a safe "dry run"). ⏱ In our run it took about **7.5 minutes** (04:53 to 05:01); 10 to 20 minutes is normal. Do not press Ctrl+C. If your terminal disconnects, the upgrade continues in AWS.

**Command:**

```bash
eksctl upgrade cluster --name $CLUSTER --region $REGION --version $TARGET --approve
```

**Expected output:**

```
[ℹ]  will upgrade cluster "my-eks-cluster" control plane from current version "1.34" to "1.35"
[✔]  cluster "my-eks-cluster" control plane has been upgraded to version "1.35"
[ℹ]  you will need to follow the upgrade procedure for all of nodegroups and add-ons
[✔]  all resources in cluster stack "eksctl-my-eks-cluster-cluster" are up-to-date
[ℹ]  all nodegroups have up-to-date cloudformation templates
```

**Verify:** The `has been upgraded to version "1.35"` line is printed.

#### Step 3.2.2: Confirm the cluster state in EKS

**Explanation:** `UPDATING` while running, `ACTIVE` when done. This also works from another terminal if the first one disconnected.

**Command:**

```bash
aws eks describe-cluster --name $CLUSTER --region $REGION \
  --query "cluster.{Version:version,Status:status}" --output text
```

**Expected output:**

```
ACTIVE  1.35
```

**Verify:** `ACTIVE  1.35`.

#### Step 3.2.3: Confirm the API server version

**Command:**

```bash
kubectl version
```

**Expected output:**

```
Client Version: v1.37.1
Kustomize Version: v5.8.1
Server Version: v1.35.8-eks-b9510e3
Warning: version difference between client (1.37) and server (1.35) exceeds the supported minor version skew of +/-1
```

**Verify:** `Server Version: v1.35.x`. The skew warning is about the `kubectl` client only (see Part 5).

#### Step 3.2.4: Nodes are still on 1.34 (expected)

**Command:**

```bash
kubectl get nodes
```

**Expected output:**

```
NAME                            STATUS   ROLES    AGE   VERSION
ip-192-168-21-69.ec2.internal   Ready    <none>   64m   v1.34.12-eks-117f323
ip-192-168-44-47.ec2.internal   Ready    <none>   64m   v1.34.12-eks-117f323
```

**Verify:** Nodes `Ready` on `v1.34.x` while the server is `v1.35.x`. This temporary mismatch is supported.

#### Step 3.2.5: Pods are still healthy

**Command:**

```bash
kubectl get pods -A | grep -v -E "Running|Completed"
```

**Expected output:** only the header line.

**Verify:** No pod is unhealthy after the control plane upgrade.

### Step 3.3: Upgrade the add-ons

Add-ons are upgraded **after** the control plane and **before** the nodes. All four of our add-ons are EKS-managed (listed in Step 3.1.5e), so use `eksctl update addon`.

#### Step 3.3.1: Re-check the add-on table on the new control plane

**Command:**

```bash
eksctl get addon --cluster $CLUSTER --region $REGION
```

**Expected output (important part):**

```
[ℹ]  Kubernetes version "1.35" in use by cluster "my-eks-cluster"
NAME            VERSION               STATUS  ISSUES  UPDATE AVAILABLE
coredns         v1.12.4-eksbuild.58   ACTIVE  0       v1.14.7-eksbuild.19,...,v1.13.2-eksbuild.51,...
kube-proxy      v1.34.6-eksbuild.52   ACTIVE  0       v1.35.3-eksbuild.59,v1.35.3-eksbuild.52,...
metrics-server  v0.9.0-eksbuild.14    ACTIVE  0
vpc-cni         v1.22.4-eksbuild.3    ACTIVE  0       v1.23.2-eksbuild.6,...
```

**Verify:** The header says Kubernetes `1.35`, and `UPDATE AVAILABLE` now lists 1.35-compatible builds for `kube-proxy` and `coredns`.

#### Step 3.3.2: Update kube-proxy

**Explanation:** Use the `Default = True` version from Step 3.1.8. `--force` resolves conflicts if the add-on was edited by hand.

**Command:**

```bash
eksctl update addon --name kube-proxy --cluster $CLUSTER --region $REGION \
  --version v1.35.3-eksbuild.52 --force
```

**Expected output:**

```
[ℹ]  Kubernetes version "1.35" in use by cluster "my-eks-cluster"
[ℹ]  new version provided v1.35.3-eksbuild.52
[ℹ]  updating addon
[ℹ]  addon "kube-proxy" active
```

**Verify:** `addon "kube-proxy" active`. (The `no IAM OIDC provider associated with cluster` warning is informational; these add-ons do not need an IAM role.)

#### Step 3.3.3: Update vpc-cni

**Explanation:** The installed version is already the default for 1.35, so nothing changes. Running the command still confirms the add-on is healthy and compatible.

**Command:**

```bash
eksctl update addon --name vpc-cni --cluster $CLUSTER --region $REGION \
  --version v1.22.4-eksbuild.3 --force
```

**Expected output:**

```
[ℹ]  updating addon
[ℹ]  addon "vpc-cni" active
```

**Verify:** `addon "vpc-cni" active`.

#### Step 3.3.4: Update coredns

**Explanation:** CoreDNS gives names like `web.demo.svc.cluster.local` to services. The command returns right after starting the update, so confirm completion in Steps 3.3.5 and 3.3.6.

**Command:**

```bash
eksctl update addon --name coredns --cluster $CLUSTER --region $REGION \
  --version v1.13.2-eksbuild.51 --force
```

**Expected output:**

```
[ℹ]  new version provided v1.13.2-eksbuild.51
[ℹ]  updating addon
```

**Verify:** The command exits without an error (no `addon "coredns" active` line is printed in this case).

#### Step 3.3.5: Check the add-on versions

**Command:**

```bash
eksctl get addon --cluster $CLUSTER --region $REGION
```

**Expected output (important columns):**

```
NAME            VERSION               STATUS  ISSUES
coredns         v1.13.2-eksbuild.51   ACTIVE  0
kube-proxy      v1.35.3-eksbuild.52   ACTIVE  0
metrics-server  v0.9.0-eksbuild.14    ACTIVE  0
vpc-cni         v1.22.4-eksbuild.3    ACTIVE  0
```

**Verify:** `coredns` and `kube-proxy` show the new versions, all `ACTIVE`, `ISSUES 0`. `UPDATE AVAILABLE` may still list newer builds (for example `v1.35.3-eksbuild.59`). We deliberately stayed on the Default builds.

#### Step 3.3.6: Check the add-on pods

**Command:**

```bash
kubectl get pods -n kube-system
```

**Expected output:**

```
NAME                              READY   STATUS    RESTARTS   AGE
aws-node-rmql9                    2/2     Running   0          78m
aws-node-s7wxr                    2/2     Running   0          78m
coredns-547b59986f-lmlff          1/1     Running   0          2m20s
coredns-547b59986f-thspj          1/1     Running   0          2m20s
kube-proxy-j5htq                  1/1     Running   0          5m42s
kube-proxy-pg7j2                  1/1     Running   0          5m45s
metrics-server-68c65f79d8-8lcjw   1/1     Running   0          75m
metrics-server-68c65f79d8-wttv2   1/1     Running   0          75m
```

**Verify:** `coredns` and `kube-proxy` pods are new (young `AGE`, new names) and `Running`. `aws-node` and `metrics-server` kept their old pods because their versions did not change.

> **Only if your add-on table is empty (self-managed add-ons; not our case).** Run these one at a time:
>
> ```bash
> eksctl utils update-kube-proxy --cluster $CLUSTER --region $REGION --approve
> ```
>
> ```bash
> eksctl utils update-aws-node --cluster $CLUSTER --region $REGION --approve
> ```
>
> ```bash
> eksctl utils update-coredns --cluster $CLUSTER --region $REGION --approve
> ```
>
> Expected output (each): `[✔] "kube-proxy" is now up-to-date` (and similar for `aws-node`, `coredns`).

### Step 3.4: Upgrade the worker nodes (node group)

#### Step 3.4.1: Open a second terminal and watch the nodes

**Explanation:** Run this in a **second terminal** before starting the upgrade so you can see the rolling replacement live. Stop it with `Ctrl+C` when finished.

**Command:**

```bash
kubectl get nodes -w
```

**Expected output (at first):**

```
NAME                            STATUS   ROLES    AGE   VERSION
ip-192-168-21-69.ec2.internal   Ready    <none>   79m   v1.34.12-eks-117f323
ip-192-168-44-47.ec2.internal   Ready    <none>   79m   v1.34.12-eks-117f323
```

#### Step 3.4.2: Start the node group upgrade (first terminal)

**Explanation:** AWS launches new nodes with the 1.35 AMI, drains the old nodes (moving pods away) and removes them. ⏱ About **13.5 minutes** in our run (05:17 to 05:31); 10 to 25 minutes is normal. Your demo app keeps running because it has 2 replicas.

**Command:**

```bash
eksctl upgrade nodegroup --name $NODEGROUP --cluster $CLUSTER --region $REGION \
  --kubernetes-version $TARGET
```

**Expected output (important lines):**

```
[ℹ]  setting ForceUpdateEnabled value to false
[ℹ]  updating nodegroup stack
[ℹ]  will upgrade nodes to release version: 1.35.9-20261019
[ℹ]  upgrading nodegroup version
[ℹ]  nodegroup successfully upgraded
```

**Verify:** The last line is `nodegroup successfully upgraded`. Many `waiting for CloudFormation stack` lines before it are normal.

#### Step 3.4.3: What the watch terminal should show

**Explanation:** This is the pattern we observed in the second terminal.

**Expected output (condensed):**

```
ip-192-168-5-11.ec2.internal     NotReady   <none>   0s    v1.35.9-eks-117f323     <- new node joins
ip-192-168-51-209.ec2.internal   NotReady   <none>   0s    v1.35.9-eks-117f323     <- new node joins
ip-192-168-5-11.ec2.internal     Ready      <none>   10s   v1.35.9-eks-117f323     <- new node ready
ip-192-168-21-69.ec2.internal    Ready,SchedulingDisabled   <none>   83m   v1.34.12-eks-117f323   <- old node cordoned
ip-192-168-44-47.ec2.internal    NotReady,SchedulingDisabled   <none>   87m   v1.34.12-eks-117f323   <- old node shutting down
```

**Verify:** New `v1.35.9` nodes become `Ready`, old `v1.34.12` nodes go `SchedulingDisabled`, then `NotReady`, then disappear.

#### Step 3.4.4: Confirm the nodes

**Command:**

```bash
kubectl get nodes
```

**Expected output:**

```
NAME                             STATUS   ROLES    AGE   VERSION
ip-192-168-5-11.ec2.internal     Ready    <none>   12m   v1.35.9-eks-117f323
ip-192-168-51-209.ec2.internal   Ready    <none>   12m   v1.35.9-eks-117f323
```

**Verify:** Exactly 2 nodes, `Ready`, `v1.35.x`, with **new node names** (the old nodes were replaced, not modified).

### Step 3.5: Verify the upgrade

#### Step 3.5.1: Server version

**Command:**

```bash
kubectl version
```

**Expected output:**

```
Server Version: v1.35.8-eks-b9510e3
```

**Verify:** Server `v1.35.x`.

#### Step 3.5.2: All pods

**Command:**

```bash
kubectl get pods -A
```

**Expected output:**

```
NAMESPACE     NAME                              READY   STATUS    RESTARTS   AGE
demo          web-64c966cf88-2nqhv              1/1     Running   0          13m
demo          web-64c966cf88-hhvcl              1/1     Running   0          9m
kube-system   aws-node-7rtnw                    2/2     Running   0          14m
kube-system   coredns-547b59986f-bljhn          1/1     Running   0          12m
kube-system   coredns-547b59986f-prrlp          1/1     Running   0          13m
kube-system   kube-proxy-28lv8                  1/1     Running   0          14m
kube-system   metrics-server-68c65f79d8-744gh   1/1     Running   0          9m
...
```

**Verify:** Everything is `Running`. Pods were re-created on the new nodes, so their ages are small.

#### Step 3.5.3: Demo app

**Command:**

```bash
kubectl get all -n demo
```

**Expected output (important lines):**

```
service/web   ClusterIP   10.100.153.157   <none>   80/TCP   89m
deployment.apps/web   2/2     2            2           90m
```

**Verify:** `deployment.apps/web` is `2/2` and the service keeps its original `CLUSTER-IP`.

#### Step 3.5.4: Cluster version in EKS

**Command:**

```bash
aws eks describe-cluster --name $CLUSTER --region $REGION --query "cluster.version" --output text
```

**Expected output:**

```
1.35
```

**Verify:** `1.35`.

🎉 **Upgrade to 1.35 complete.** Wait until everything above is healthy (ideally an hour, or a day of normal running) before starting Part 4.

---

## 4. Upgrade from 1.35 → 1.36 (second hop)

> **Do not copy steps into this Part.** The 1.35 → 1.36 upgrade is the **same cycle as Part 3**. You change **one value (`TARGET`)** and re-run Steps 3.1 to 3.5. Only the values in Step 4.2 and the extra checks in Step 4.4 are specific to this hop.

### Step 4.1: Update the target value from 1.35 to 1.36

**Explanation:** Every command in Part 3 that uses `$TARGET` now points to 1.36. Do this in every terminal you use.

**Command:**

```bash
export TARGET=1.36
```

**Expected output:** none.

**Verify:**

```bash
echo $TARGET
```

```
1.36
```

### Step 4.2: Re-run Part 3 with the new target

Run the steps in the same order. Replace anything that mentions 1.34/1.35 with the values below.

| Part 3 step | What to do for 1.36 | What you should see |
|-------------|--------------------|---------------------|
| 3.1.1 Cluster state | Re-run unchanged | `ACTIVE` / `1.35` (the *current* version is now 1.35) |
| 3.1.2 and 3.1.3 Nodes and pods | Re-run unchanged | Nodes `Ready` on `v1.35.9-eks-117f323`, no unhealthy pods |
| 3.1.4 and 3.1.5 Upgrade insights | **Different**, see Step 4.3 | |
| 3.1.6 to 3.1.8 Add-on versions | **Different**, see Step 4.3 | |
| 3.1.9 Fresh backup | Re-run unchanged | `DONE. Backup folder : .../k8s-backup-20261024-053930` |
| 3.1.10 to 3.1.12 IPs, scaling, quota | Re-run unchanged | Same results as Part 3 |
| 3.2 Control plane | Re-run unchanged (`--version $TARGET`) | `from current version "1.35" to "1.36"`, then `ACTIVE  1.36` (about 7.5 min: 05:50 to 05:58) |
| 3.3 Add-ons | Re-run 3.3.2 and 3.3.4 with the 1.36 versions in the table below | kube-proxy and coredns `ACTIVE` on new builds |
| 3.4 Node group | Re-run unchanged | `will upgrade nodes to release version: 1.36.5-20261019`, then `nodegroup successfully upgraded` (about 11.5 min: 06:07 to 06:18) |
| 3.5 Verify | Re-run unchanged | Server `v1.36.4-eks-b9510e3`, nodes `v1.36.5-eks-117f323`, cluster version `1.36` |

**Add-on versions used for 1.36** (the `Default = True` rows from Step 4.3):

| Add-on | Before (1.35) | After (1.36) | Command to re-run |
|--------|---------------|--------------|-------------------|
| kube-proxy | v1.35.3-eksbuild.52 | **v1.36.0-eksbuild.48** | Step 3.3.2 with `--version v1.36.0-eksbuild.48` |
| coredns | v1.13.2-eksbuild.51 | **v1.14.7-eksbuild.11** | Step 3.3.4 with `--version v1.14.7-eksbuild.11` |
| vpc-cni | v1.22.4-eksbuild.3 | v1.22.4-eksbuild.3 (unchanged) | None needed |
| metrics-server | v0.9.0-eksbuild.14 | v0.9.0-eksbuild.14 (unchanged) | None needed |

> In our run we updated `kube-proxy` first, checked pods, then updated `coredns` (Step 4.4.1 and 4.4.2), then upgraded the nodes.

### Step 4.3: What was different in the pre-checks

#### Step 4.3.1: Insights for 1.36

**Explanation:** Same command as Step 3.1.4, but without the `--query` formatting, to see the raw result.

**Command:**

```bash
aws eks list-insights --cluster-name $CLUSTER --region $REGION --filter kubernetesVersions=$TARGET
```

**Expected output (ours):**

```json
{
    "insights": []
}
```

**Verify:** No insights were returned for 1.36, so there was nothing to fix. Because an empty list gives no positive confirmation, we also ran Steps 4.3.2 to 4.3.5 to prove the add-ons are compatible.

#### Step 4.3.2: All insights, any target version

**Explanation:** Without a filter you also see insights for later versions (useful to plan the next hop).

**Command:**

```bash
aws eks list-insights --cluster-name $CLUSTER --region $REGION \
  --query "insights[].{Name:name,Target:kubernetesVersion,Status:insightStatus.status}" --output table
```

**Expected output:**

```
|  kube-proxy version skew                     |  PASSING |  1.35    |
|  Deprecated APIs removed in Kubernetes v1.38 |  PASSING |  1.38    |
|  Deprecated APIs removed in Kubernetes v1.37 |  PASSING |  1.37    |
|  Cluster health issues                       |  PASSING |  1.35    |
|  Kubelet version skew                        |  PASSING |  1.35    |
|  EKS add-on version compatibility            |  UNKNOWN |  1.35    |
|  Amazon Linux 2 compatibility                |  PASSING |  1.35    |
```

**Verify:** The `UNKNOWN` row is the old insight for target **1.35** (the one explained in Step 3.1.5). It is not about 1.36.

#### Step 4.3.3: Current add-on versions

**Explanation:** Prints the installed version of each add-on, one per line.

**Command:**

```bash
for ADDON in kube-proxy vpc-cni coredns metrics-server; do
  echo -n "$ADDON: "
  aws eks describe-addon --cluster-name $CLUSTER --addon-name $ADDON --region $REGION --query "addon.addonVersion" --output text
done
```

**Expected output:**

```
kube-proxy: v1.35.3-eksbuild.52
vpc-cni: v1.22.4-eksbuild.3
coredns: v1.13.2-eksbuild.51
metrics-server: v0.9.0-eksbuild.14
```

**Verify:** Matches the "After (1.35)" values from Part 3.

#### Step 4.3.4: Compatible add-on versions for 1.36

**Explanation:** Same idea as Step 3.1.8, but limited to the first 15 lines of each table with `head -15`, because the `Default = True` row is near the top.

**Command:**

```bash
for ADDON in kube-proxy vpc-cni coredns metrics-server; do
  echo "=== $ADDON ==="
  aws eks describe-addon-versions --addon-name $ADDON --kubernetes-version $TARGET --region $REGION \
    --query "addons[0].addonVersions[].{Version:addonVersion,Default:compatibilities[0].defaultVersion}" --output table | head -15
done
```

**Expected output (important rows):**

```
=== kube-proxy ===       |  True  |  v1.36.0-eksbuild.48  |
=== vpc-cni ===          |  True  |  v1.22.4-eksbuild.3   |
=== coredns ===          |  True  |  v1.14.7-eksbuild.11  |
=== metrics-server ===   |  True  |  v0.9.0-eksbuild.14   |
```

**Verify:** These are the target versions in Step 4.2. `vpc-cni` and `metrics-server` are already on the default, so they need no update.

#### Step 4.3.5: Are the *current* add-on builds still supported by 1.36?

**Explanation:** Between the control plane upgrade and the add-on update, your 1.35 builds run against a 1.36 control plane. These two commands search the 1.36-compatible list for the builds you already have. The number before the colon is the line position in the list.

**a) CoreDNS**

**Command:**

```bash
aws eks describe-addon-versions --addon-name coredns --kubernetes-version 1.36 --region $REGION \
  --query "addons[0].addonVersions[].addonVersion" --output text | tr '\t' '\n' | grep -n "v1.13.2-eksbuild.51"
```

**Expected output:**

```
14:v1.13.2-eksbuild.51
```

**b) kube-proxy**

**Command:**

```bash
aws eks describe-addon-versions --addon-name kube-proxy --kubernetes-version 1.36 --region $REGION \
  --query "addons[0].addonVersions[].addonVersion" --output text | tr '\t' '\n' | grep -n "v1.35.3-eksbuild.52"
```

**Expected output:**

```
16:v1.35.3-eksbuild.52
```

**Verify:** Both builds are on the 1.36-compatible list, so the cluster is safe during the short window before the add-ons are updated. No output means the build is **not** compatible; update that add-on before anything else.

### Step 4.4: Extra verification used only in the 1.36 hop

Run these after Step 3.3 / 3.4 of the repeat cycle (the order below is the one we used).

#### Step 4.4.1: Server version and kubectl skew

**Explanation:** After the control plane upgrade, confirm the new server version. The earlier skew warning is gone because the `kubectl` client (v1.37) is now within one minor version of the server (1.36).

**Command:**

```bash
kubectl version
```

**Expected output:**

```
Client Version: v1.37.1
Kustomize Version: v5.8.1
Server Version: v1.36.4-eks-b9510e3
```

**Verify:** `Server Version: v1.36.x` and no `Warning: version difference` line.

#### Step 4.4.2: DNS test after the CoreDNS update

**Explanation:** Starts a temporary busybox pod, resolves the demo service by its full name, and deletes the pod (`--rm`). It proves CoreDNS answers queries and finds the `web` service.

**Command:**

```bash
kubectl run dnstest --rm -it --restart=Never --image=busybox:1.36 -- nslookup web.demo.svc.cluster.local
```

**Expected output:**

```
Server:         10.100.0.10
Address:        10.100.0.10:53

Name:   web.demo.svc.cluster.local
Address: 10.100.153.157
pod "dnstest" deleted from default namespace
```

**Verify:** The `Address` equals the `CLUSTER-IP` of `service/web` from Step 1.5.4 (`10.100.153.157`).

> **Known false alarm:** later we ran the same test with the short name (`nslookup kubernetes.default`) and got `** server can't find kubernetes.default: NXDOMAIN`, plus a `couldn't attach to pod` warning. The full-name test above had already succeeded, and the BusyBox `nslookup` tool is known to handle short names (search domains) poorly. If you test the Kubernetes API service, use its full name `kubernetes.default.svc.cluster.local`.

#### Step 4.4.3: CoreDNS add-on state

**Command:**

```bash
aws eks describe-addon --cluster-name $CLUSTER --addon-name coredns --region $REGION \
  --query "addon.{Version:addonVersion,Status:status}" --output text
```

**Expected output:**

```
ACTIVE  v1.14.7-eksbuild.11
```

**Verify:** `ACTIVE` on the new version.

#### Step 4.4.4: CoreDNS rollout finished

**Command:**

```bash
kubectl -n kube-system rollout status deployment/coredns
```

**Expected output:**

```
deployment "coredns" successfully rolled out
```

**Verify:** The message says `successfully rolled out`.

#### Step 4.4.5: Node group state

**Explanation:** Confirms the node group itself (not just the nodes) is on 1.36.

**Command:**

```bash
aws eks describe-nodegroup --cluster-name $CLUSTER --nodegroup-name $NODEGROUP --region $REGION \
  --query "nodegroup.{Version:version,Release:releaseVersion,Status:status}" --output table
```

**Expected output:**

```
|      Release     | Status  |  Version  |
|  1.36.5-20261019 |  ACTIVE |  1.36     |
```

**Verify:** `ACTIVE`, version `1.36`, release `1.36.5-...`.

#### Step 4.4.6: Node conditions

**Explanation:** Checks the health flags the kubelet reports for each node (memory, disk and PID pressure, Ready).

**Command:**

```bash
kubectl describe nodes | grep -A3 Conditions
```

**Expected output (first rows per node):**

```
Conditions:
  Type             Status  LastHeartbeatTime                 LastTransitionTime                Reason                       Message
  ----             ------  -----------------                 ------------------                ------                       -------
  MemoryPressure   False   Sat, 24 Oct 2026 06:22:37 +0000   Sat, 24 Oct 2026 06:08:41 +0000   KubeletHasSufficientMemory   kubelet has sufficient memory available
```

**Verify:** `MemoryPressure` is `False`. (Use `grep -A6 Conditions` to also see `DiskPressure`, `PIDPressure` and `Ready`.)

#### Step 4.4.7: Cluster events

**Explanation:** Events show what Kubernetes did during the node replacement. The output is long, so show only the newest lines.

**Command:**

```bash
kubectl get events -A --sort-by=.lastTimestamp | tail -20
```

**Expected output:** mostly `Normal` events (`Scheduled`, `Pulled`, `Started`, `Killing`, `RemovingNode`). During the node replacement we also saw these `Warning` events, which were **expected and temporary**:

```
Warning   FailedDaemonPod   daemonset/kube-proxy   Found failed daemon pod ... will try to kill it
Warning   NodeShutdown      pod/aws-node-...       Pod was rejected as the node is shutting down.
Warning   Unhealthy         pod/coredns-...        Readiness probe failed: ... connection refused
```

**Verify:** Warnings only refer to pods on nodes being replaced or pods that had just started. No warnings should keep appearing once all nodes are `v1.36` and pods are `Running`.

#### Step 4.4.8: Workloads and DaemonSets are fully ready

**Command:**

```bash
kubectl get deploy,statefulset,daemonset -A
```

**Expected output:**

```
NAMESPACE     NAME                             READY   UP-TO-DATE   AVAILABLE
demo          deployment.apps/web              2/2     2            2
kube-system   deployment.apps/coredns          2/2     2            2
kube-system   deployment.apps/metrics-server   2/2     2            2

NAMESPACE     NAME                        DESIRED   CURRENT   READY   UP-TO-DATE   AVAILABLE
kube-system   daemonset.apps/aws-node     2         2         2       2            2
kube-system   daemonset.apps/kube-proxy   2         2         2       2            2
```

**Verify:** `READY` equals the wanted count everywhere (no `1/2`, no `0/2`).

#### Step 4.4.9: aws-node DaemonSet

**Command:**

```bash
kubectl get daemonset aws-node -n kube-system
```

**Expected output:**

```
NAME       DESIRED   CURRENT   READY   UP-TO-DATE   AVAILABLE   NODE SELECTOR   AGE
aws-node   2         2         2       2            2           <none>          151m
```

**Verify:** `DESIRED` = `READY` = number of nodes (2).

#### Step 4.4.10: kube-proxy DaemonSet

**Command:**

```bash
kubectl get daemonset kube-proxy -n kube-system
```

**Expected output:**

```
NAME         DESIRED   CURRENT   READY   UP-TO-DATE   AVAILABLE   NODE SELECTOR   AGE
kube-proxy   2         2         2       2            2           <none>          151m
```

**Verify:** `DESIRED` = `READY` = 2.

#### Step 4.4.11: Metrics API works

**Explanation:** `kubectl top` reads from `metrics-server`, so this proves that add-on still works after the upgrade.

**Command:**

```bash
kubectl top pods -A
```

**Expected output (important lines):**

```
NAMESPACE     NAME                              CPU(cores)   MEMORY(bytes)
demo          web-64c966cf88-csq45              0m           3Mi
kube-system   coredns-687dddfb64-7t2hx          1m           10Mi
kube-system   metrics-server-68c65f79d8-cjtrf   2m           18Mi
```

**Verify:** CPU and memory numbers are shown for every pod (no `error: Metrics API not available`).

#### Step 4.4.12: API server and etcd health

**Explanation:** On EKS you cannot reach etcd directly, but the API server reports its own health, including etcd, through `/readyz`. This is the closest equivalent to an "etcd health check".

**Command:**

```bash
kubectl get --raw='/readyz?verbose'
```

**Expected output (important lines):**

```
[+]ping ok
[+]etcd ok
[+]etcd-readiness ok
[+]informer-sync ok
...
readyz check passed
```

**Verify:** Every line starts with `[+]` and the last line is `readyz check passed`. A `[-]` line names the failing component.

#### Step 4.4.13: Control plane component status

**Explanation:** Older-style check of the scheduler, controller manager and etcd. It prints a deprecation warning, but still works.

**Command:**

```bash
kubectl get componentstatuses
```

**Expected output:**

```
Warning: v1 ComponentStatus is deprecated in v1.19+
NAME                 STATUS    MESSAGE   ERROR
controller-manager   Healthy   ok
scheduler            Healthy   ok
etcd-0               Healthy   ok
```

**Verify:** All three are `Healthy`.

#### Step 4.4.14: Control plane logging status

**Explanation:** Shows whether EKS control plane logs are sent to CloudWatch. In this lab they are off, so there are no control plane logs to read if something fails.

**Command:**

```bash
aws eks describe-cluster --name $CLUSTER --region $REGION --query "cluster.logging.clusterLogging"
```

**Expected output:**

```json
[
    {
        "types": ["api", "audit", "authenticator", "controllerManager", "scheduler"],
        "enabled": false
    }
]
```

**Verify:** `enabled: false` matches the creation output ("CloudWatch logging will not be enabled"). To enable: `eksctl utils update-cluster-logging --enable-types=all --region $REGION --cluster $CLUSTER --approve`.

#### Step 4.4.15: Find the ID of the latest cluster update

**Command:**

```bash
aws eks list-updates --name $CLUSTER --region $REGION --query "updateIds[-1]" --output text
```

**Expected output:**

```
c84ac538-3184-3d9b-8507-72bdd0c9cec9
```

#### Step 4.4.16: Read that update's result

**Explanation:** Gives an audit record of the upgrade: type, status, versions and any errors.

**Command:**

```bash
aws eks describe-update --name $CLUSTER --region $REGION --update-id c84ac538-3184-3d9b-8507-72bdd0c9cec9
```

**Expected output (important part):**

```json
"status": "Successful",
"type": "VersionUpdate",
"params": [
    { "type": "Version", "value": "1.36" },
    { "type": "PlatformVersion", "value": "eks.15" }
],
"errors": []
```

**Verify:** `status` is `Successful`, `Version` is `1.36`, `errors` is empty. Replace the ID with the one printed in Step 4.4.15.

#### Step 4.4.17: Final add-on table

**Command:**

```bash
eksctl get addon --cluster $CLUSTER --region $REGION
```

**Expected output (important columns):**

```
NAME            VERSION               STATUS  ISSUES  UPDATE AVAILABLE
coredns         v1.14.7-eksbuild.11   ACTIVE  0       v1.14.7-eksbuild.19
kube-proxy      v1.36.0-eksbuild.48   ACTIVE  0       v1.36.0-eksbuild.55
metrics-server  v0.9.0-eksbuild.14    ACTIVE  0
vpc-cni         v1.22.4-eksbuild.3    ACTIVE  0       v1.23.2-eksbuild.6,...
```

**Verify:** All `ACTIVE` with `ISSUES 0`. Newer patch builds are optional.

#### Step 4.4.18: Check readiness for the next version (1.37)

**Explanation:** If you plan another hop, this shows whether anything in the cluster uses APIs removed in 1.37.

**Command:**

```bash
aws eks list-insights --cluster-name $CLUSTER --region $REGION --filter kubernetesVersions=1.37 \
  --query "insights[].{Name:name,Status:insightStatus.status}" --output table
```

**Expected output:**

```
|  Deprecated APIs removed in Kubernetes v1.37  |  PASSING |
```

**Verify:** `PASSING` (the detail said: "No deprecated API usage detected within the last 30 days.").

🎉 **Upgrade to 1.36 complete.** Final expected result: nodes `v1.36.x`, and `aws eks describe-cluster ... --query cluster.version` prints `1.36`.

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
| `kubectl` warns about version skew | Client too far from server | Install a `kubectl` within ±1 minor of the server version (re-run the kubectl download step) |
| Insight `EKS add-on version compatibility` shows `UNKNOWN` | An add-on (for us `coredns`) was `DEGRADED` or updating when AWS calculated the insight | `aws eks describe-insight ...` to see which add-on; `aws eks describe-addon ...` must show `ACTIVE` with empty `issues` (Step 3.1.5) |
| `nslookup kubernetes.default` returns `NXDOMAIN` in a BusyBox pod | BusyBox `nslookup` handles short names (search domains) poorly | Test with the full name, e.g. `web.demo.svc.cluster.local` (Step 4.4.2) |
| `aws s3 ls ... \| head` ends with `Broken pipe` | `head` closed the pipe after 10 lines | Harmless; ignore it |
| `kubectl get events` shows `FailedDaemonPod`, `NodeShutdown`, `Unhealthy` during a node upgrade | Pods on nodes being replaced, or pods that just started | Expected and temporary; recheck when all nodes are on the new version (Step 4.4.7) |

Useful debug commands:

```bash
kubectl describe node <node-name>
kubectl describe pod <pod-name> -n <namespace>
kubectl logs <pod-name> -n <namespace>
kubectl get events -A --sort-by=.lastTimestamp | tail -20
eksctl utils describe-stacks --cluster $CLUSTER --region $REGION
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
- [ ] Upgrade insights show no errors for the target version
- [ ] Backup done: YAML export + AWS config (+ S3 copy, + Velero)
- [ ] Control plane upgraded (`eksctl upgrade cluster ... --approve`)
- [ ] Add-ons upgraded (kube-proxy, vpc-cni, coredns)
- [ ] Node group upgraded (`eksctl upgrade nodegroup ...`)
- [ ] Verified: versions, pods, demo app
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


---

## 8. Comparison table: 1.34 vs 1.35 vs 1.36

Values come from the logs of this cluster (`my-eks-cluster`, us-east-1, 2 × `t2.medium`). "n/a" means that item was not captured in that phase.

| Item | 1.34 | 1.35 | 1.36 |
|------|------|------|------|
| Cluster version (`aws eks describe-cluster`) | 1.34 | 1.35 | 1.36 |
| Cluster status | ACTIVE | ACTIVE | ACTIVE |
| Support type (`describe-cluster-versions`) | STANDARD_SUPPORT | STANDARD_SUPPORT | STANDARD_SUPPORT |
| API server (`kubectl version`, Server Version) | v1.34.x (exact build not captured) | v1.35.8-eks-b9510e3 | v1.36.4-eks-b9510e3 |
| `kubectl` client version | v1.37.1 | v1.37.1 | v1.37.1 |
| Client/server skew warning | Yes (1.37 vs 1.34) | Yes (1.37 vs 1.35) | No (1.37 vs 1.36 is within ±1) |
| Worker node version | v1.34.12-eks-117f323 | v1.35.9-eks-117f323 | v1.36.5-eks-117f323 |
| Node group release version | n/a (AL2023 for 1.34 at creation) | 1.35.9-20261019 | 1.36.5-20261019 |
| Node names (nodes are replaced each upgrade) | ip-192-168-21-69, ip-192-168-44-47 | ip-192-168-5-11, ip-192-168-51-209 | ip-192-168-16-172, ip-192-168-35-221 |
| kube-proxy add-on | v1.34.6-eksbuild.52 | v1.35.3-eksbuild.52 | v1.36.0-eksbuild.48 |
| CoreDNS add-on | v1.12.4-eksbuild.58 | v1.13.2-eksbuild.51 | v1.14.7-eksbuild.11 |
| VPC CNI add-on (`aws-node`) | v1.22.4-eksbuild.3 | v1.22.4-eksbuild.3 (unchanged) | v1.22.4-eksbuild.3 (unchanged) |
| metrics-server add-on | v0.9.0-eksbuild.14 | v0.9.0-eksbuild.14 (unchanged) | v0.9.0-eksbuild.14 (unchanged) |
| CoreDNS ReplicaSet (pod name prefix) | coredns-7879986bf8 | coredns-547b59986f | coredns-687dddfb64 |
| Upgrade insights | n/a | 4 `PASSING`, 1 `UNKNOWN` (add-on compatibility, CoreDNS was `DEGRADED` at creation time) | Empty list for 1.36; 1.37 deprecated-API insight `PASSING` |
| Control plane upgrade duration | n/a | about 7.5 min (04:53:46 to 05:01:14) | about 7.5 min (05:50:47 to 05:58:18) |
| Node group upgrade duration | n/a | about 13.5 min (05:17:54 to 05:31:25) | about 11.5 min (06:07:25 to 06:18:50) |
| Backup taken before the upgrade | `k8s-backup-20261024-040705` + `aws-config-20261024` (baseline) | `k8s-backup-20261024-044438` | `k8s-backup-20261024-053930` + `aws-config-20261024-054531` |
| Demo app `web` (namespace `demo`) | 2/2 Running | 2/2 Running (pods re-created) | 2/2 Running (pods re-created) |
| Service `web` ClusterIP | 10.100.153.157 | 10.100.153.157 | 10.100.153.157 |
| etcd / API server health (`/readyz`) | n/a | n/a | `[+]etcd ok`, `readyz check passed` |
| Control plane logging to CloudWatch | Disabled | Disabled | Disabled |
