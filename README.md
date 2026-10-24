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
* At the time of writing, AWS lists 1.35 and 1.36 as available in standard support. Confirm with the command in Step 1.4.

### 0.4 Cost warning

An EKS control plane costs about **$0.10 per hour** plus EC2 nodes. Delete the cluster when finished practising (see Part 6).

---

## 1. Prerequisites and health check

### 1.1 Confirm the tools are installed

```bash
eksctl version
kubectl version --client
aws --version
```

**Expected output (versions will differ):**

```
0.231.0
Client Version: v1.37.1
Kustomize Version: v5.8.1
aws-cli/2.38.5 Python/3.14.8 Linux/7.0.0-1014-aws exe/x86_64.ubuntu.26
```

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

**Expected output (similar):** a table where `1.35` and `1.36` appear with status `STANDARD_SUPPORT`.

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

**Expected:** every pod is `Running` (or `Completed`). Anything `Pending`, `CrashLoopBackOff` or `Error` should be fixed **before** any upgrade.

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
configmaps.yaml  deployments.apps.yaml  pods.yaml  replicasets.apps.yaml  serviceaccounts.yaml  services.yaml
```

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

## 3. TASK 2: Upgrade the cluster 1.34 → 1.35 (then → 1.36)

> Do the full cycle (Steps 3.1 to 3.5) for **1.35**. Then repeat 3.1 to 3.5 with `1.36` (see Part 4).

Set the target:

```bash
export TARGET=1.35
```

### Step 3.1: Pre-upgrade checks

**a) Cluster is ACTIVE and on the expected version**

```bash
aws eks describe-cluster --name $CLUSTER --region $REGION \
  --query "cluster.{Version:version,Status:status}" --output table
```

**Expected output:**

```
--------------------------
|    DescribeCluster     |
+----------+-------------+
|  Status  |  Version    |
+----------+-------------+
|  ACTIVE  |  1.34       |
+----------+-------------+
```

**b) EKS Upgrade Insights: AWS tells you what could break**

```bash
aws eks list-insights --cluster-name $CLUSTER --region $REGION \
  --filter kubernetesVersions=$TARGET \
  --query "insights[].{Name:name,Status:insightStatus.status}" --output table
```

**Expected output:** every row `Status` = `PASSING`. If you see `ERROR` or `WARNING`, read details:

```bash
aws eks describe-insight --cluster-name $CLUSTER --region $REGION --id <INSIGHT_ID_FROM_ABOVE>
```

and fix the reported issue (usually a removed/deprecated API used by your manifests) before continuing. For this fresh demo cluster you should see all `PASSING`.

**c) Pods healthy and a fresh backup exists**

```bash
kubectl get pods -A | grep -v -E "Running|Completed"
```

**Expected output:** only the header line, or nothing (no unhealthy pods).

Re-run `~/eks-backups/backup-k8s.sh` (and optionally `velero backup create pre-upgrade-$TARGET --wait`) so you have a backup taken **right before** this upgrade.

**d) Free IP addresses and capacity**

The control plane upgrade needs a few free IPs in your cluster subnets, and the node upgrade temporarily adds an extra node (so your account needs room for 3 `t2.medium` instances). Default AWS limits are normally fine.

### Step 3.2: Upgrade the control plane (API server + etcd, handled by AWS)

```bash
eksctl upgrade cluster --name $CLUSTER --region $REGION --version $TARGET --approve
```

> Without `--approve`, eksctl only shows a plan and does nothing (a safe "dry run").

**Expected output (similar):**

```
2026-10-24 10:30:01 [ℹ]  will upgrade cluster "my-eks-cluster" control plane from current version "1.34" to "1.35"
2026-10-24 10:41:33 [✔]  cluster "my-eks-cluster" control plane has been upgraded to version "1.35"
2026-10-24 10:41:33 [ℹ]  you will need to follow the upgrade procedure for all of nodegroups and add-ons
2026-10-24 10:41:33 [ℹ]  re-building cluster stack "eksctl-my-eks-cluster-cluster"
2026-10-24 10:41:38 [✔]  all resources in cluster stack "eksctl-my-eks-cluster-cluster" are up-to-date
2026-10-24 10:41:39 [ℹ]  checking security group configuration for all nodegroups
2026-10-24 10:41:39 [ℹ]  all nodegroups have up-to-date cloudformation templates
```

⏱ Takes **10 to 20 minutes**. Do not press Ctrl+C. If your terminal disconnects, the upgrade continues in AWS; check progress with:

```bash
aws eks describe-cluster --name $CLUSTER --region $REGION --query "cluster.{Version:version,Status:status}" --output text
```

(`UPDATING` while running, `ACTIVE` when done.)

**Verify:**

```bash
kubectl version
```

**Expected output:** `Server Version: v1.35.x-eks-xxxxxxx` (the *Client* version may differ; that's OK, but see Troubleshooting if it is more than 1 minor version away).

At this point the **nodes are still 1.34**. That is expected and supported temporarily.

### Step 3.3: Upgrade the add-ons

Check how your add-ons are managed:

```bash
eksctl get addon --cluster $CLUSTER --region $REGION
```

**Case 1: the table lists `vpc-cni`, `kube-proxy`, `coredns` (managed add-ons).** Expected:

```
NAME         VERSION               STATUS   ISSUES   IAMROLE   UPDATE AVAILABLE
coredns      v1.12.x-eksbuild.x    ACTIVE   0
kube-proxy   v1.34.x-eksbuild.x    ACTIVE   0
vpc-cni      v1.2x.x-eksbuild.x    ACTIVE   0
```

For each add-on, list the versions compatible with the new Kubernetes version and note the one where `Default` is `True`:

```bash
for ADDON in kube-proxy vpc-cni coredns; do
  echo "=== $ADDON ==="
  aws eks describe-addon-versions --addon-name $ADDON --kubernetes-version $TARGET --region $REGION \
    --query "addons[0].addonVersions[].{Version:addonVersion,Default:compatibilities[0].defaultVersion}" --output table
done
```

Then update each one, replacing the version with the **Default** value shown:

```bash
eksctl update addon --name kube-proxy --cluster $CLUSTER --region $REGION --version <DEFAULT_KUBE_PROXY_VERSION> --force
eksctl update addon --name vpc-cni    --cluster $CLUSTER --region $REGION --version <DEFAULT_VPC_CNI_VERSION> --force
eksctl update addon --name coredns    --cluster $CLUSTER --region $REGION --version <DEFAULT_COREDNS_VERSION> --force
```

**Expected output for each:**

```
[ℹ]  updating addon
[ℹ]  new version provided v1.35.x-eksbuild.x
[✔]  addon "kube-proxy" active
```

**Case 2: the table is empty (add-ons are self-managed).** Use:

```bash
eksctl utils update-kube-proxy --cluster $CLUSTER --region $REGION --approve
eksctl utils update-aws-node   --cluster $CLUSTER --region $REGION --approve
eksctl utils update-coredns    --cluster $CLUSTER --region $REGION --approve
```

**Expected output (each):** `[✔] "kube-proxy" is now up-to-date` (and similar for `aws-node`, `coredns`).

**Verify add-ons are healthy:**

```bash
kubectl get pods -n kube-system
```

**Expected:** all `Running` (`aws-node-*`, `kube-proxy-*`, `coredns-*`).

### Step 3.4: Upgrade the worker nodes (node group)

```bash
eksctl upgrade nodegroup \
  --name $NODEGROUP \
  --cluster $CLUSTER \
  --region $REGION \
  --kubernetes-version $TARGET
```

**Expected output (similar):**

```
[ℹ]  setting ForceUpdateVersion to false
[ℹ]  updating nodegroup stack
[ℹ]  waiting for CloudFormation changeset ...
[✔]  nodegroup "my-worker-node" has been updated to version "1.35"   (or similar success message)
```

⏱ Takes **10 to 25 minutes**. What happens behind the scenes: AWS launches a new (1.35) node, moves pods over, removes an old node, and repeats. Your app keeps running because the demo deployment has 2 replicas.

Watch it live in a **second terminal**:

```bash
kubectl get nodes -w
```

You will see nodes with mixed versions, a new node appearing `Ready`, and old ones going `SchedulingDisabled` then disappearing. Press `Ctrl+C` to stop watching.

### Step 3.5: Verify the upgrade

```bash
kubectl get nodes
```

**Expected output:**

```
NAME                             STATUS   ROLES    AGE   VERSION
ip-192-168-aa-aa.ec2.internal    Ready    <none>   5m    v1.35.x-eks-xxxxxxx
ip-192-168-bb-bb.ec2.internal    Ready    <none>   3m    v1.35.x-eks-xxxxxxx
```

```bash
kubectl version
kubectl get pods -A
kubectl get all -n demo
aws eks describe-cluster --name $CLUSTER --region $REGION --query "cluster.version" --output text
```

**Expected:**

* Server version `v1.35.x`, nodes `v1.35.x`.
* All pods `Running`.
* Demo app: `deployment.apps/web   2/2`.
* Last command prints `1.35`.

🎉 **Upgrade to 1.35 complete.**

---

## 4. Upgrade from 1.35 → 1.36 (optional second hop)

Wait until everything in Step 3.5 is healthy (ideally an hour or a day of normal running), then repeat the exact same cycle:

```bash
export TARGET=1.36

# 1) Fresh backup
~/eks-backups/backup-k8s.sh
# (optional) velero backup create pre-upgrade-$TARGET --wait

# 2) Pre-checks (Step 3.1)
aws eks list-insights --cluster-name $CLUSTER --region $REGION \
  --filter kubernetesVersions=$TARGET \
  --query "insights[].{Name:name,Status:insightStatus.status}" --output table

# 3) Control plane (Step 3.2)
eksctl upgrade cluster --name $CLUSTER --region $REGION --version $TARGET --approve

# 4) Add-ons (Step 3.3): repeat the version lookup + update commands using the new $TARGET

# 5) Nodes (Step 3.4)
eksctl upgrade nodegroup --name $NODEGROUP --cluster $CLUSTER --region $REGION --kubernetes-version $TARGET

# 6) Verify (Step 3.5)
kubectl get nodes
```

**Expected final result:** nodes `v1.36.x`, `aws eks describe-cluster ... --query cluster.version` prints `1.36`.

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
