# Velero Backup and Restore on Amazon EKS

A beginner-friendly, copy-paste guide to back up and restore everything **inside** an EKS cluster (Kubernetes objects and EBS volume data) using Velero and Amazon S3.

Written for: cluster `my-eks-cluster`, region `us-east-1`. Change the variables in Step 1 if yours differ.

Every step has the same layout: **Explanation**, **Commands**, **Expected output**, and **Important to know**.

---

## Table of Contents

| Part | Steps | What you do |
|------|-------|-------------|
| 0 | [Read this first](#0-read-this-first) | What Velero is, what it covers and does not cover |
| 1 | [Steps 1 to 8](#part-1-set-up-velero) | Install and configure Velero |
| 2 | [Steps 9 to 13](#part-2-take-backups) | Take, verify and schedule backups |
| 3 | [Steps 14 to 16](#part-3-restore) | Test a restore, restore a deleted app, restore to a new cluster |
| 4 | [Steps 17 to 19](#part-4-maintenance-and-cleanup) | List, delete, upgrade, uninstall |
| 5 | [Troubleshooting](#5-troubleshooting) | Common errors and fixes |
| 6 | [Checklist](#6-final-checklist) | One-page recap |

---

## 0. Read this first

### What is Velero?

Velero is a backup tool for Kubernetes. It does two jobs:

1. Saves your Kubernetes objects (Deployments, Services, ConfigMaps, Secrets, and so on) to an S3 bucket.
2. Takes EBS snapshots of your persistent volumes (the actual disk data).

### Why you need it on EKS

On EKS, AWS runs the control plane (API server and etcd) for you. You cannot take an etcd snapshot. AWS replaces failed control plane instances automatically, but it will **not** undo your own mistakes, such as deleting a namespace. Velero is how you get that back.

### What Velero covers and does not cover

| Covered | Not covered (back these up separately) |
|---------|----------------------------------------|
| Deployments, Services, ConfigMaps, Secrets, RBAC, CRDs | EKS cluster settings, node groups, add-ons, IAM roles, VPC (use the `eks-full-backup.sh` guide) |
| Persistent volume data on EBS disks | Databases outside the cluster (RDS), other EC2 servers (for example a Splunk server) |
| Namespace-level or full-cluster restores | S3 data, load balancers, DNS records |
| | EFS volumes (need file-system backup or AWS Backup) |

### Prerequisites checklist

- [ ] `aws`, `kubectl` and `eksctl` are installed
- [ ] `aws sts get-caller-identity` works
- [ ] `kubectl get nodes` shows all nodes `Ready`
- [ ] You can create S3 buckets and IAM policies/roles in your AWS account

> **Important to know:** Velero costs a small amount for S3 storage and EBS snapshots. Old backups are deleted automatically when their TTL (time to live) expires.

---

## Part 1: Set up Velero

### Step 1: Set your variables

**Explanation:** These variables are reused in every later command. Run them again in every new terminal.

**Commands:**

```bash
export CLUSTER=my-eks-cluster
export REGION=us-east-1
export ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
export VELERO_BUCKET=velero-$CLUSTER-$ACCOUNT

echo "$CLUSTER $REGION $ACCOUNT $VELERO_BUCKET"
```

**Expected output:**

```
my-eks-cluster us-east-1 123456789012 velero-my-eks-cluster-123456789012
```

**Important to know:**
- S3 bucket names are unique across all of AWS and must be lowercase.
- If `ACCOUNT` is empty, your AWS credentials are not working. Run `aws configure` and try again.

---

### Step 2: Connect kubectl and check the cluster is healthy

**Explanation:** Never back up (or upgrade) a cluster that is already unhealthy.

**Commands:**

```bash
aws eks update-kubeconfig --name $CLUSTER --region $REGION
kubectl get nodes
kubectl get pods -A | grep -v -E "Running|Completed"
```

**Expected output:**

```
Added new context arn:aws:eks:us-east-1:123456789012:cluster/my-eks-cluster to /home/<you>/.kube/config

NAME                            STATUS   ROLES    AGE   VERSION
ip-192-168-xx-xx.ec2.internal   Ready    <none>   2h    v1.34.x-eks-xxxxxxx
...
NAME   READY   STATUS   RESTARTS   AGE
```

The last command should print only the header line (no unhealthy pods).

**Important to know:** If any node is `NotReady` or any pod is `Pending` or `CrashLoopBackOff`, fix that first.

---

### Step 3: Install the Velero CLI

**Explanation:** The Velero CLI is the command you type on your machine. It talks to Velero running in the cluster.

**Commands:**

1. Open the Velero releases page and pick the latest release: https://github.com/velero-io/velero/releases
2. Open the AWS plugin compatibility table and note which plugin version matches your Velero version: https://github.com/vmware-tanzu/velero-plugin-for-aws#compatibility
3. Set the version and install (replace the example version with the real latest one):

```bash
uname -m     # x86_64 means use "amd64" below; aarch64 means use "arm64"
export VELERO_VERSION=v1.18.0     # <-- replace with the latest release you chose
export ARCH=amd64                 # or arm64

cd /tmp
curl -L https://github.com/velero-io/velero/releases/download/${VELERO_VERSION}/velero-${VELERO_VERSION}-linux-${ARCH}.tar.gz -o velero.tar.gz
tar -xzf velero.tar.gz
mkdir -p ~/.local/bin
mv velero-${VELERO_VERSION}-linux-${ARCH}/velero ~/.local/bin/velero
velero version --client-only
```

**Expected output:**

```
Client:
	Version: v1.18.0
	Git commit: xxxxxxxx
```

**Important to know:**
- If `velero: command not found`, add `~/.local/bin` to your PATH: `export PATH=$PATH:$HOME/.local/bin`
- Velero 1.18 is listed as tested on Kubernetes 1.33, 1.34 and 1.35. Always check the compatibility table for your Kubernetes version.

---

### Step 4: Create and protect the S3 bucket

**Explanation:** Velero stores your backups in this bucket. Because backups contain your Secrets, the bucket must be private and protected from accidental deletion.

**Commands:**

```bash
aws s3api create-bucket --bucket $VELERO_BUCKET --region $REGION

aws s3api put-bucket-versioning --bucket $VELERO_BUCKET \
  --versioning-configuration Status=Enabled

aws s3api put-public-access-block --bucket $VELERO_BUCKET \
  --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
```

**Expected output:** The first command prints:

```json
{
    "Location": "/velero-my-eks-cluster-123456789012"
}
```

The other two print nothing.

**Important to know:**
- For any region **other than** `us-east-1`, add `--create-bucket-configuration LocationConstraint=$REGION` to the first command.
- If the bucket name is taken, change `VELERO_BUCKET` in Step 1 and try again.

---

### Step 5: Create the IAM policy for Velero

**Explanation:** Velero needs permission to read and write the bucket, and to create EBS snapshots.

**Commands:**

```bash
cat > velero-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ec2:DescribeVolumes",
        "ec2:DescribeSnapshots",
        "ec2:CreateTags",
        "ec2:CreateVolume",
        "ec2:CreateSnapshot",
        "ec2:DeleteSnapshot"
      ],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:DeleteObject",
        "s3:PutObject",
        "s3:AbortMultipartUpload",
        "s3:ListMultipartUploadParts"
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

**Expected output:** JSON containing:

```
"Arn": "arn:aws:iam::123456789012:policy/VeleroPolicy-my-eks-cluster"
```

**Important to know:** If you see `EntityAlreadyExists`, the policy was created earlier. That is fine, continue to Step 6.

---

### Step 6: Connect the cluster to IAM (OIDC) and create the Velero role

**Explanation:** This lets the Velero pod use the IAM policy **without storing AWS keys in the cluster** (called IRSA: IAM Roles for Service Accounts).

**Commands:**

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

**Important to know:**
- If the OIDC provider already exists you will see a message saying so. That is fine.
- The role name must be exactly `eks-velero-$CLUSTER`, because Step 7 refers to it.

---

### Step 7: Install Velero in the cluster

**Explanation:** This deploys Velero (and a node agent) into a new `velero` namespace and points it at your bucket.

**Commands:**

```bash
export AWS_PLUGIN_VERSION=v1.13.0   # <-- replace with the version that matches your Velero (Step 3, item 2)

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
Deployment/velero: created
Velero is installed! ⛵ Use 'kubectl logs deployment/velero -n velero' to view the status.
```

**Important to know:**
- The example `v1.13.0` is only a placeholder. Use the plugin version that the compatibility table lists for your Velero version.
- `--no-secret` is correct here because the pod gets its permissions from the IAM role.
- `--default-volumes-to-fs-backup=false` means volumes are backed up with EBS snapshots (fast and simple). EFS volumes would not be covered.

---

### Step 8: Verify Velero is working

**Explanation:** Confirm the pods run and that Velero can reach the bucket.

**Commands:**

```bash
kubectl get pods -n velero
velero backup-location get
```

**Expected output:**

```
NAME                      READY   STATUS    RESTARTS   AGE
node-agent-xxxxx          1/1     Running   0          1m
velero-xxxxxxxxxx-zzzzz   1/1     Running   0          1m

NAME      PROVIDER   BUCKET/PREFIX                         PHASE       LAST VALIDATED
default   aws        velero-my-eks-cluster-123456789012    Available   10s ago
```

You should have one `node-agent` pod per node.

**Important to know:** `PHASE` must be **Available**. If it says `Unavailable`, see the [Troubleshooting](#5-troubleshooting) table. The cause is almost always a wrong role ARN, bucket name or IAM permission.

---

## Part 2: Take backups

### Step 9: Check what storage your apps use

**Explanation:** Velero can only snapshot volumes it understands (EBS). Check now so you are not surprised later.

**Commands:**

```bash
kubectl get pv
kubectl get storageclass
```

**Expected output (if you use persistent volumes):**

```
NAME         CAPACITY   ACCESS MODES   RECLAIM POLICY   STATUS   CLAIM                    STORAGECLASS
pvc-xxxxxxx  10Gi       RWO            Delete           Bound    my-app/data-my-app-0     gp2
```

If you have no persistent volumes, the first command prints `No resources found`. That is fine.

**Important to know:** If a volume uses `efs.csi.aws.com` (EFS) instead of EBS, Velero will not snapshot it with this setup. Back up EFS with AWS Backup.

---

### Step 10: Take a full backup

**Explanation:** This backs up all namespaces, cluster-scoped objects and EBS volumes, and keeps the backup for 90 days (2160 hours).

**Commands:**

```bash
export BACKUP=full-$(date +%Y%m%d-%H%M)
velero backup create $BACKUP --snapshot-volumes --ttl 2160h --wait
```

**Expected output:**

```
Backup request "full-20261028-1015" submitted successfully.
Waiting for backup to complete. You may safely press ctrl-c to stop waiting - your backup will continue in the background.
.....
Backup completed with status: Completed.
```

**Important to know:**
- Without `--ttl`, Velero deletes the backup after 30 days.
- Before an upgrade, always take a fresh backup right before you start.

---

### Step 11: Verify the backup is good

**Explanation:** "Completed" is not enough. Check for errors, warnings and volume snapshots.

**Commands:**

```bash
velero backup describe $BACKUP --details
velero backup get
aws s3 ls s3://$VELERO_BUCKET/backups/$BACKUP/
```

**Expected output (key lines):**

```
Phase:  Completed
Errors:    0
Warnings:  0
...
Velero-Native Snapshots:
  pvc-xxxxxxx:
    Snapshot ID: snap-0abc...
    Type: gp2
```

```
NAME                STATUS      ERRORS   WARNINGS   CREATED   EXPIRES
full-20261028-1015  Completed   0        0          ...       89d
```

The S3 listing shows files such as `velero-backup.json` and `full-...-resource-list.json.gz`.

**Important to know:**
- If you have persistent volumes but the section says `<none included>`, your volumes were **not** backed up. Check Step 9.
- If `Errors` is above 0, run `velero backup logs $BACKUP` to see why.

---

### Step 12: Create a daily automatic backup

**Explanation:** A one-time backup gets old quickly. A schedule keeps fresh backups without you remembering.

**Commands:**

```bash
velero schedule create daily-full --schedule="0 2 * * *" --ttl 720h
velero schedule get
```

**Expected output:**

```
Schedule "daily-full" created successfully.

NAME         STATUS    CREATED   SCHEDULE    BACKUP TTL   LAST BACKUP   SELECTOR
daily-full   Enabled   ...       0 2 * * *   720h0m0s     n/a           <none>
```

**Important to know:**
- The schedule uses UTC time. `0 2 * * *` means 02:00 UTC every day.
- Backups created by a schedule are named `daily-full-<timestamp>`. Keep 30 days (`720h`) to control cost.

---

### Step 13: (Optional) Back up just one namespace

**Explanation:** Useful before you change a single app.

**Commands:**

```bash
velero backup create app-backup-$(date +%Y%m%d-%H%M) --include-namespaces <your-app-namespace> --snapshot-volumes --ttl 720h --wait
```

**Expected output:** `Backup completed with status: Completed.`

**Important to know:** Replace `<your-app-namespace>` with the real namespace. List namespaces with `kubectl get ns`.

---

## Part 3: Restore

### Step 14: Test a restore safely (do this once, before you need it)

**Explanation:** A backup you have never restored is only a guess. This test restores an app into a **copy namespace**, so your real app is not touched.

**Commands:**

```bash
velero restore create test-restore-$(date +%H%M) \
  --from-backup $BACKUP \
  --include-namespaces <your-app-namespace> \
  --namespace-mappings <your-app-namespace>:<your-app-namespace>-restore-test \
  --wait

kubectl get all -n <your-app-namespace>-restore-test
```

**Expected output:**

```
Restore completed with status: Completed.

NAME                       READY   STATUS    RESTARTS   AGE
pod/web-xxxxxxxxxx-aaaaa   1/1     Running   0          30s
...
```

Clean up the test copy:

```bash
kubectl delete namespace <your-app-namespace>-restore-test
```

**Important to know:**
- The restored copy may show errors if the app uses a fixed external resource (for example a LoadBalancer or a hostname). That is normal for a test.
- This test proves the backup is readable and restorable.

---

### Step 15: Restore an app that was deleted

**Explanation:** Use this when a namespace or its contents were deleted by mistake.

**Commands:**

```bash
# Only if the namespace still exists but is broken, and you want a clean restore:
# kubectl delete namespace <your-app-namespace>

velero backup get
velero restore create --from-backup <BACKUP-NAME> --include-namespaces <your-app-namespace> --wait
kubectl get all -n <your-app-namespace>
```

**Expected output:**

```
Restore completed with status: Completed.
```

followed by your Deployments, Pods and Services running again.

**Important to know:**
- By default, Velero does **not** overwrite objects that already exist. It skips them with a warning. To restore over a broken object, delete the broken object first.
- Check the result with `velero restore describe <restore-name> --details`.

---

### Step 16: Restore into a new cluster (disaster recovery)

**Explanation:** If the whole cluster is lost, create a new EKS cluster, install Velero pointing at the **same bucket**, and restore.

**Commands:**

```bash
# 1. On the NEW cluster, repeat Steps 1, 2, 3, 5, 6 and 7 using the SAME bucket name.
#    Do NOT run Step 4 (the bucket already exists).

# 2. Wait about a minute, then list the backups Velero found in the bucket:
velero backup get

# 3. Restore everything except system namespaces that EKS manages:
velero restore create --from-backup <BACKUP-NAME> \
  --exclude-namespaces kube-system,kube-node-lease,kube-public,velero \
  --wait
```

**Expected output:**

```
NAME                 STATUS      ERRORS   WARNINGS   CREATED   EXPIRES
full-20261028-1015   Completed   0        0          ...       89d

Restore completed with status: Completed.
```

**Important to know:**
- Never restore `kube-system` into a different cluster. EKS manages those add-ons (CoreDNS, kube-proxy, VPC CNI) and restoring over them can break the cluster.
- The new cluster needs the EBS CSI driver and the same storage classes if your apps use persistent volumes.
- Velero does not recreate the EKS cluster itself. Recreate it from your saved configuration (see the `eks-full-backup.sh` guide).

---

## Part 4: Maintenance and cleanup

### Step 17: List, inspect and delete backups

**Explanation:** Keep an eye on what you have and remove what you no longer need.

**Commands:**

```bash
velero backup get
velero backup describe <BACKUP-NAME>
velero backup logs <BACKUP-NAME>
velero backup delete <BACKUP-NAME> --confirm
```

**Expected output:** The last command prints `Request to delete backup "<BACKUP-NAME>" submitted successfully.`

**Important to know:** Deleting a backup also deletes its EBS snapshots. You cannot undo this.

---

### Step 18: Check Velero health regularly

**Explanation:** A schedule that silently fails gives you a false sense of safety.

**Commands:**

```bash
velero backup get | head
velero backup-location get
kubectl get pods -n velero
```

**Expected output:** The newest backups show `Completed` with `0` errors, the location shows `Available`, and the pods show `Running`.

**Important to know:** Check weekly, and always before an upgrade.

---

### Step 19: Uninstall Velero (only when you no longer need it)

**Explanation:** Removes Velero from the cluster. It does **not** delete your backups in S3.

**Commands:**

```bash
velero uninstall --force
```

**Expected output:** `Velero uninstalled ⛵`

Optional, to delete all backup data permanently:

```bash
aws s3 rb s3://$VELERO_BUCKET --force
```

**Important to know:** Deleting the bucket permanently destroys every backup. Only do this when you are sure.

---

## 5. Troubleshooting

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| `velero: command not found` | CLI not in PATH | `export PATH=$PATH:$HOME/.local/bin` |
| `BackupStorageLocation` shows `Unavailable` | Wrong role ARN, bucket name or IAM permission | `kubectl logs deployment/velero -n velero`; check the bucket name and that the role is `eks-velero-$CLUSTER` |
| Velero pod logs say `AccessDenied` | IAM policy missing or role not attached | Re-check Steps 5 and 6; confirm the annotation with `kubectl get sa velero -n velero -o yaml` |
| Backup `PartiallyFailed` | Some objects or volumes could not be saved | `velero backup logs <name>` and fix the named items |
| `<none included>` under snapshots, but you have PVs | Volume type not supported or storage class mismatch | Check Step 9; confirm the EBS CSI driver is installed |
| Restore skips objects with "already exists" | Objects still exist in the cluster | Delete the broken objects, then restore again |
| Restored pods stuck `Pending` | Missing storage class or not enough node capacity | `kubectl describe pod <name> -n <ns>` |
| Install fails with plugin errors | Plugin version does not match Velero version | Use the compatible plugin version from the table (Step 3, item 2) |

Useful debug commands:

```bash
kubectl logs deployment/velero -n velero
velero restore describe <restore-name> --details
velero restore logs <restore-name>
kubectl get events -n velero --sort-by=.lastTimestamp | tail -20
```

---

## 6. Final checklist

- [ ] Velero pods are `Running` and the backup location is `Available`
- [ ] A full backup exists with `Phase: Completed` and `Errors: 0`
- [ ] Volume snapshots are listed (if you use persistent volumes)
- [ ] A daily schedule exists (`velero schedule get`)
- [ ] You tested a restore into a copy namespace (Step 14)
- [ ] The S3 bucket has versioning on and public access blocked
- [ ] EKS-level settings are backed up separately (see the `eks-full-backup.sh` guide)
- [ ] Anything outside the cluster (RDS, other EC2 servers) has its own backup

> **Remember:** Velero protects what runs **inside** the cluster. Combine it with the EKS configuration backup for full coverage.
