# SQL Server Always On Availability Group on AWS EC2 — fully automated lab

Deploy a **2-node SQL Server Always On Availability Group** (Windows Server Failover Cluster, Active Directory, multi-subnet listener, automatic failover) on AWS EC2 with **one command**, then practice failovers, readable secondaries and recovery scenarios. Tear it all down with another command.

> **Why EC2 and not RDS?** Amazon RDS for SQL Server does not offer the Developer edition, and its Multi-AZ feature hides the availability group from you. Running SQL Server Developer (free license) on EC2 lets you administer the **entire stack yourself — WSFC, quorum, endpoints, AG, listener** — which is what DBA roles and certification exams ask about.

---

## Table of contents

1. [What you get](#1-what-you-get)
2. [Architecture](#2-architecture)
3. [Cost and prerequisites](#3-cost-and-prerequisites)
4. [Repository layout](#4-repository-layout)
5. [Step-by-step manual](#5-step-by-step-manual)
   - [Step 1 — Prepare the SQL Server ISO](#step-1--prepare-the-sql-server-iso)
   - [Step 2 — Get the project into AWS CloudShell](#step-2--get-the-project-into-aws-cloudshell)
   - [Step 3 — Pick instance types](#step-3--pick-instance-types)
   - [Step 4 — Deploy](#step-4--deploy)
   - [Step 5 — Verify the availability group](#step-5--verify-the-availability-group)
   - [Step 6 — Connect with SSMS](#step-6--connect-with-ssms)
   - [Step 7 — Practice](#step-7--practice)
   - [Step 8 — Tear down](#step-8--tear-down)
6. [What each deployment step does](#6-what-each-deployment-step-does)
7. [How it works](#7-how-it-works)
8. [Design decisions and lessons learned](#8-design-decisions-and-lessons-learned)
9. [Security notes](#9-security-notes)
10. [Command reference](#10-command-reference)
11. [Status and limitations](#11-status-and-limitations)

More documentation: [`docs/troubleshooting.md`](docs/troubleshooting.md) · [`docs/exercises.md`](docs/exercises.md)

---

## 1. What you get

| Component | Details |
|---|---|
| Network | New VPC `10.0.0.0/16`, two public subnets in two Availability Zones, internet gateway, security group restricted to your IP |
| `DC01` | Windows Server 2022, Active Directory domain `corp.local`, DNS, file-share witness |
| `SQLNODE1`, `SQLNODE2` | Windows Server 2022 + SQL Server Developer (2022 or 2025), joined to the domain |
| Cluster | Windows Server Failover Cluster `SQLCL`, **multi-subnet**, file-share witness |
| Availability group | `AG1`, synchronous commit, **automatic failover**, automatic seeding, sample database `LabDB` |
| Listener | `AGL` on port 1433, one IP per subnet (`10.0.1.51`, `10.0.2.51`) |
| Access | Elastic IPs on all three instances, RDP and SQL (1433) open to **your IP only** |
| Operations | `up`, `resume`, `status`, `failover`, `info`, `myip`, `down` |

## 2. Architecture

```
                         VPC 10.0.0.0/16
 ┌──────────── AZ a ─────────────┐        ┌──────────── AZ b ─────────────┐
 │ Subnet 10.0.1.0/24            │        │ Subnet 10.0.2.0/24            │
 │                               │        │                               │
 │  DC01        10.0.1.10        │        │                               │
 │   AD DS · DNS · \\DC01\witness│        │                               │
 │                               │        │                               │
 │  SQLNODE1    10.0.1.20        │  sync  │  SQLNODE2    10.0.2.20        │
 │   cluster IP 10.0.1.50        │◄──────►│   cluster IP 10.0.2.50        │
 │   listener   10.0.1.51        │ :5022  │   listener   10.0.2.51        │
 └───────────────────────────────┘        └───────────────────────────────┘
              Windows Server Failover Cluster "SQLCL"
              Availability Group "AG1"  ·  Listener "AGL" (multi-subnet)
```

Only the listener IP that belongs to the **primary's subnet** is online at any time; clients that use `MultiSubnetFailover=True` try both IPs in parallel and connect to whichever answers.

## 3. Cost and prerequisites

### Cost

This lab is **not covered by the AWS Free Tier**: Windows Server + SQL Server nodes need at least 2 vCPU / 8 GB RAM. The SQL Server *license* is free (Developer edition); you pay for compute, disks and public IPv4 addresses.

| Item | Approx. cost |
|---|---|
| 3 Windows EC2 instances + 3 × 60 GB gp3 + 3 public IPv4 | **roughly USD 0.3–0.5 per hour in total** (varies by region and instance type — check the AWS pricing calculator) |

Run it for a few hours, then run `./sqlag-lab.sh down`. Stopping the instances keeps only EBS and IP charges, but `down` is cleaner.

### AWS account notes

- **New "free plan" accounts** can only launch a short list of instance types. If you see `The specified instance type is not eligible for Free Tier`, either use eligible types (see [Step 3](#step-3--pick-instance-types)) or upgrade the account plan.
- A brand-new account (or a first use of a region) may answer `PendingVerification` on `RunInstances`. AWS emails you when it is resolved (minutes to a few hours).
- Your IAM user/role needs permissions for **EC2, IAM (create role / instance profile), and SSM (Run Command)**.

### Tools

- AWS CLI v2 configured with credentials (**AWS CloudShell** already has everything).
- `bash`, `curl`, `openssl`, `base64` (Linux, macOS, WSL or CloudShell).
- SSMS (latest) on your PC if you want to connect from outside AWS.

## 4. Repository layout

```
sqlserver-alwayson-aws-lab/
├── sqlag-lab.sh                 # orchestrator: AWS CLI + SSM
├── ps/
│   ├── _wrapper.ps1             # runs each step on an instance (as SYSTEM or domain admin)
│   ├── _lib.ps1                 # helpers (Q = run T-SQL, Wait-Sql)
│   ├── _boot.ps1                # last boot time probe, used after reboots
│   ├── 00-set-admin-pwd.ps1     # ...one script per deployment step (see section 6)
│   ├── 01-dc-rename.ps1
│   ├── 02-dc-forest.ps1
│   ├── 03-dc-post.ps1
│   ├── 04-node-join.ps1
│   ├── 05-node-sql-install.ps1
│   ├── 06-cluster.ps1
│   ├── 07-dc-cno-perms.ps1
│   ├── 08-node-alwayson.ps1
│   ├── 09-ag-primary.ps1
│   ├── 10-ag-secondary.ps1
│   ├── 11-listener.ps1
│   ├── 12-failover.ps1
│   └── 99-status.ps1
└── docs/
    ├── troubleshooting.md
    └── exercises.md
```

## 5. Step-by-step manual

### Step 1 — Prepare the SQL Server ISO

The nodes install SQL Server from an ISO that you provide through a **pre-signed S3 URL**. (The small Microsoft web installer hangs when it is run non-interactively through SSM, so the ISO route is the reliable one.)

1. On your PC, download **SQL Server Developer** as an **ISO** from the official Microsoft SQL Server downloads page.
   - SQL Server 2025: choose **Enterprise Developer** (full Enterprise feature set; Standard Developer is limited to Standard edition features, whose availability groups are *basic* availability groups).
   - SQL Server 2022 Developer also works.
2. Upload the ISO to a **private** S3 bucket you own, for example `s3://my-bucket/SQLServer2025-x64-ENU-EntDev.iso`.
3. Generate a pre-signed URL valid for 24 hours (you will do this in Step 4):

   ```bash
   export SQL_ISO_URL="$(aws s3 presign s3://my-bucket/SQLServer2025-x64-ENU-EntDev.iso --expires-in 86400)"
   ```

   > `presign` does not check that the object exists. Verify the key with `aws s3 ls s3://my-bucket/`.

### Step 2 — Get the project into AWS CloudShell

```bash
git clone https://github.com/glopezch78/sqlserver-alwayson-aws-lab.git
cd sqlserver-alwayson-aws-lab
chmod +x sqlag-lab.sh
export AWS_DEFAULT_REGION=us-east-2      # any region with >= 2 AZs
```

(Alternatively upload a zip with **Actions → Upload file** in CloudShell.)

### Step 3 — Pick instance types

| Account type | Command prefix |
|---|---|
| Standard paid account (default) | *(nothing — uses `t3.medium` for the DC and `t3.large` for the SQL nodes)* |
| New free-plan account | `DC_TYPE=c7i-flex.large SQL_TYPE=m7i-flex.large` |

List the types your account may launch:

```bash
aws ec2 describe-instance-types --filters Name=free-tier-eligible,Values=true \
  --query 'InstanceTypes[].[InstanceType,VCpuInfo.DefaultVCpus,MemoryInfo.SizeInMiB]' --output table
```

Use x86 types only (not `t4g`, which is ARM). SQL nodes need **2 vCPU and about 8 GB**.

### Step 4 — Deploy

If you run the script from **CloudShell**, tell it your **PC's** public IP (open `https://checkip.amazonaws.com` on your PC). Otherwise the script whitelists CloudShell's IP instead of yours:

```bash
export MY_CIDR="203.0.113.25/32"          # your PC's public IP
export SQL_ISO_URL="$(aws s3 presign s3://my-bucket/SQLServer2025-x64-ENU-EntDev.iso --expires-in 86400)"

# use nohup so the deployment survives a closed CloudShell tab
nohup ./sqlag-lab.sh up > lab.log 2>&1 &
tail -f lab.log
```

Add `DC_TYPE=... SQL_TYPE=...` in front of `nohup` if you chose types in Step 3.

What you will see: `Infrastructure ready.` followed by `=== Step N/14: ... ===` lines. Expect **50–70 minutes**; the longest steps are domain creation (4) and the SQL Server installation (7). `Ctrl+C` only stops `tail`, not the deployment.

**If a step fails**, the script stops and tells you which one. Fix the cause (see [`docs/troubleshooting.md`](docs/troubleshooting.md)) and continue **from that step**:

```bash
nohup ./sqlag-lab.sh resume 8 > lab2.log 2>&1 &
```

> CloudShell closes after ~20–30 minutes of inactivity and kills background processes. The commands already sent to the instances keep running, so before resuming check what AWS still has in flight:
> `aws ssm list-commands --filters key=Status,value=InProgress --query 'Commands[].[CommandId,RequestedDateTime]' --output table`

### Step 5 — Verify the availability group

```bash
./sqlag-lab.sh status
```

Expected result:

- Both cluster nodes `Up`.
- One replica `PRIMARY` and one `SECONDARY`, both `CONNECTED` and `HEALTHY`.
- The listener test returns the primary's name and the row count of `LabDB.dbo.Heartbeat`.

(A secondary replica only reports its own row in the replica view — that is expected.)

### Step 6 — Connect with SSMS

```bash
./sqlag-lab.sh info        # public IPs + generated password
```

| Goal | How |
|---|---|
| **Connect to a node** from your PC | SSMS → server `<node public IP>,1433` → SQL Server Authentication → `sa` / generated password → tick **Trust server certificate**. This connects to *one node*, not the listener. |
| **RDP into a node** | `<node public IP>`, user `CORP\Administrator`, generated password. |
| **Connect to the listener** | The listener has only private IPs, so connect from **inside the VPC**: RDP to a node, install SSMS there, and connect to server `AGL` with Windows authentication, *Trust server certificate*, and Additional Connection Parameters `MultiSubnetFailover=True`. |

If your public IP changes: `./sqlag-lab.sh myip 198.51.100.7/32`.

To reach the private listener IPs from *another VPC* (for instance an Amazon WorkSpace), create a VPC peering connection (inter-region peering is supported), add routes in both route tables and allow the other VPC's CIDR on port 1433 in the `sqlag-lab` security group. Security groups cannot be referenced across regions, so use the CIDR. **Delete the peering before running `down`.**

### Step 7 — Practice

```bash
./sqlag-lab.sh failover      # manual failover: roles swap
./sqlag-lab.sh status
```

For automatic failover, stop the primary instance from the EC2 console, wait 30–60 seconds, and run `status` again. More scenarios are in [`docs/exercises.md`](docs/exercises.md): readable secondary, asynchronous commit and forced failover, adding databases, backup preferences, quorum behavior.

### Step 8 — Tear down

```bash
./sqlag-lab.sh down
```

`down` terminates the instances, releases the Elastic IPs and deletes the security group, subnets, route table, internet gateway, VPC and IAM role. Then check the EC2 console (same region) for leftovers: instances, **Elastic IPs**, and VPCs named `sqlag-lab`. Terminated instances remain visible in the console for about an hour; that is normal and free.

---

## 6. What each deployment step does

| # | Step | Target | What it does |
|---|---|---|---|
| – | `infra` | AWS CLI | IAM role for SSM, VPC, two subnets, internet gateway, route table, security group, three EC2 instances with public IPs, secondary private IPs for cluster/listener, Elastic IPs |
| 1 | `s_wait_ssm` | all | Waits until SSM sees the instances |
| 2 | `s_adminpwd` | all | Sets the generated Administrator password |
| 3 | `s_dc_rename` | DC | Renames to `DC01`, reboots |
| 4 | `s_dc_forest` | DC | Installs AD DS + DNS, creates `corp.local`, reboots |
| 5 | `s_dc_post` | DC | DNS forwarder to the VPC resolver, creates the `\\DC01\witness` share |
| 6 | `s_join` | nodes | Points DNS to the DC, installs Failover Clustering, renames and joins the domain, reboots |
| 7 | `s_sqlinstall` | nodes | Downloads the ISO from your pre-signed URL, installs the SQL engine (mixed mode), SqlServer module, firewall rules, reboots |
| 8 | `s_cluster` | SQLNODE1 | Creates the multi-subnet cluster `SQLCL` and the file-share witness (idempotent) |
| 9 | `s_cno` | DC | Lets the cluster computer object create the listener object in AD |
| 10 | `s_alwayson` | nodes | Enables Always On, grants `NT AUTHORITY\SYSTEM` the AG permissions, creates the endpoint (5022) and the peer machine-account login |
| 11 | `s_ag` | SQLNODE1 | Creates `LabDB` and `AG1` (sync commit, automatic failover, automatic seeding); removes an orphan AG role from a failed attempt |
| 12 | `s_secondary` | SQLNODE2 | Joins `AG1`, grants `CREATE ANY DATABASE` for seeding |
| 13 | `s_listener` | SQLNODE1 | Creates the `AGL` listener (one IP per subnet), waits for synchronization |
| 14 | `s_status` | nodes | Prints cluster, replicas and a listener test |

## 7. How it works

- **No RDP, no user data, no SSH.** After launch, every in-guest action is an **AWS Systems Manager Run Command**. The orchestrator Base64-encodes a PowerShell payload (variables + `_lib.ps1` + the step script) inside a small wrapper, sends it with `AWS-RunPowerShellScript`, polls the invocation and prints the output.
- **Two execution modes.** `system` runs as the SSM agent (local SYSTEM). `admin` registers a one-shot **scheduled task as `CORP\Administrator`** and waits for its result file. This gives full domain-admin credentials locally and avoids the Kerberos double-hop problem that would break `New-Cluster`, `dsacls` or remote T-SQL when using PowerShell remoting.
- **Reboot handling.** After a reboot the orchestrator does not trust the SSM "Online" status (it can lag). It repeatedly runs a tiny probe that returns the instance's last boot time and waits until it is newer than the reboot request.
- **State.** `sqlag-lab.env` (git-ignored, mode 600) stores resource IDs, the generated password and your allowed IP, so `status`, `failover`, `resume`, `info` and `down` work from any later shell session.
- **Idempotent steps.** Cluster creation, AG creation, endpoint/login creation and the SYSTEM grants can be re-run safely, which is what makes `resume N` practical.

## 8. Design decisions and lessons learned

| Topic | Decision / finding |
|---|---|
| **Order matters** | `Enable-SqlAlwaysOn` requires the node to already be a member of a WSFC, so the cluster is created *before* Always On is enabled. |
| **`@@SERVERNAME`** | SQL Server is installed **after** renaming/joining the domain, so the instance name always matches the computer name (an AG requirement). Pre-installed SQL AMIs would need a rename fix-up. |
| **Developer edition AMIs** | AWS does not publish Windows AMIs with SQL Server *Developer*; the project installs it from the ISO instead. |
| **Microsoft SSEI bootstrapper** | It hangs when executed non-interactively (session 0 through SSM). The ISO route avoids it. |
| **Error 41131 / 19435 / 41044** | The AG could not come online because the cluster connects to SQL Server as `NT AUTHORITY\SYSTEM`, which needs `ALTER ANY AVAILABILITY GROUP`, `CONNECT SQL` and `VIEW SERVER STATE` ([Microsoft KB 2847723](https://support.microsoft.com/kb/2847723)). Step 10 grants them. |
| **Listener creation** | The cluster computer object (`SQLCL$`) needs *create computer object* rights in AD or `ADD LISTENER` fails. Step 9 grants it. |
| **Cluster name not in DNS yet** | Right after `New-Cluster`, `-Cluster SQLCL` can fail with *No such host is known*. The quorum step uses the local cluster instead. |
| **Multi-subnet cluster on AWS** | One static IP per subnet, assigned as *secondary private IPs* on each node's ENI, so Windows can bring the cluster/listener IP resources online. Only the IP of the primary's subnet is online. |
| **Quorum** | Two nodes + a file-share witness on the DC. Simple for a lab; for production use a witness outside the nodes' failure domain (e.g. a cloud witness). |
| **Security group references** | Rules reference the group itself for intra-VPC traffic and a single `/32` for your client; cross-region references are not possible. |
| **Cleanup robustness** | `down` ignores IDs that were never created. Early versions skipped termination when `up` failed halfway and left orphan instances — always check the console after a failed deployment. |

## 9. Security notes

This is a **lab**, not a hardened design.

- The Administrator/`sa` password is generated per deployment, stored in `sqlag-lab.env` and printed by `info`. It is destroyed with the lab. Never reuse it.
- Mixed-mode authentication with `sa` and public Elastic IPs are enabled so you can connect from SSMS. Access is limited by the security group to your IP, but the SQL port is still internet-facing. Do not leave the lab running.
- The ISO URL is pre-signed and expires; keep the S3 bucket **private**.
- Never commit `sqlag-lab.env`, `*.pem` or logs (they are in `.gitignore`).
- For anything beyond a lab: private subnets + bastion/SSM Session Manager, encrypted EBS, managed service accounts, certificate-based endpoint authentication, TLS with a proper certificate, and a witness outside the cluster.

## 10. Command reference

| Command | Description |
|---|---|
| `./sqlag-lab.sh up` | Create and configure everything (needs `SQL_ISO_URL`) |
| `./sqlag-lab.sh resume N` | Continue from step N (1–14) |
| `./sqlag-lab.sh status` | Cluster nodes, AG replicas, listener test |
| `./sqlag-lab.sh failover` | Manual failover to the secondary, then status |
| `./sqlag-lab.sh info` | Public IPs, credentials, allowed IP |
| `./sqlag-lab.sh myip [CIDR]` | Replace the allowed client IP (CIDR optional) |
| `./sqlag-lab.sh down` | Delete everything |

| Environment variable | Purpose | Default |
|---|---|---|
| `AWS_DEFAULT_REGION` | Region (needs at least two AZs `a` and `b`) | `us-east-1` |
| `SQL_ISO_URL` | Pre-signed URL of the SQL Server Developer ISO | *required* |
| `DC_TYPE` / `SQL_TYPE` | Instance types | `t3.medium` / `t3.large` |
| `MY_CIDR` | Client IP allowed on 3389/1433 (`x.x.x.x/32`) | detected with `checkip.amazonaws.com` |

Useful on the instances: `C:\lab\step.log` (last step output), the SQL Server `ERRORLOG` under `C:\Program Files\Microsoft SQL Server\MSSQL*\MSSQL\Log\`, and `Get-ClusterLog -UseLocalTime -TimeSpan 20`.

## 11. Status and limitations

- Developed and exercised step by step in **us-east-2** with **Windows Server 2022** and **SQL Server 2025 Enterprise Developer**, resolving the issues listed above along the way. This repository contains the consolidated final scripts; if you hit a problem on a fresh run, please open an issue with the relevant `lab.log` lines.
- One availability group, one database, synchronous commit between two replicas in two AZs.
- Windows Server 2022 base AMI is resolved through the public SSM parameter `/aws/service/ami-windows-latest/Windows_Server-2022-English-Full-Base`.
- Default instance types assume a standard paid account.

## License

MIT — see [LICENSE](LICENSE).
