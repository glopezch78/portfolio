# Troubleshooting

Real problems hit while building this lab, with cause and fix. Run commands from the project directory; load the saved state first when you need resource IDs:

```bash
source sqlag-lab.env      # defines $DC $N1 $N2 $VPC $SG $RT ...
export AWS_DEFAULT_REGION=us-east-2
```

## Deployment fails before any instance exists

| Symptom | Cause | Fix |
|---|---|---|
| `SQL_ISO_URL is not set` | The ISO URL is mandatory | `export SQL_ISO_URL="$(aws s3 presign s3://<bucket>/<iso> --expires-in 86400)"` |
| `The specified instance type is not eligible for Free Tier` (`InvalidParameterCombination`) | The account is on the new AWS *free plan*, which only allows a short list of instance types | List them (`describe-instance-types --filters Name=free-tier-eligible,Values=true`) and run with e.g. `DC_TYPE=c7i-flex.large SQL_TYPE=m7i-flex.large`, or upgrade the plan. Do not pick ARM (`t4g`) types. |
| `PendingVerification` on `RunInstances` | AWS is validating the account/region | Wait for the validation email (minutes to ~4 h) or open an account-verification support case. Run `./sqlag-lab.sh down`, then `up` again. |
| `Invalid IAM Instance Profile name` | The new instance profile has not propagated yet | The script retries automatically for ~80 s. If it still fails, wait a minute and use `down` + `up`. |
| `already exists` for the env file | A previous deployment left `sqlag-lab.env` | Run `./sqlag-lab.sh down` first. |

## A step fails

The orchestrator prints `Step N (...) failed`. Read the output above it, fix the cause, then `./sqlag-lab.sh resume N`.

| Step | Symptom | Cause | Fix |
|---|---|---|---|
| 1 | Never leaves "wait for SSM" | Instances cannot reach SSM endpoints (no public IP / no IGW route) or the IAM role is missing | Check the instances have a public IP and the instance profile `sqlag-lab-ssm` |
| 7 | Step hangs for an hour, `SQL2022-SSEI-Dev` process using no CPU | Microsoft's web installer does not work non-interactively | Use the ISO route (`SQL_ISO_URL`). Cancel the stuck command (below), then resume at 7. |
| 7 | `The downloaded ISO is missing or too small` | Expired/incorrect pre-signed URL or wrong key | `aws s3 ls`, regenerate the URL, `resume 7` |
| 8 | `Set-ClusterQuorum : ... No such host is known` | The cluster name is not in DNS yet | Fixed in `06-cluster.ps1` (uses the local cluster and is re-runnable). `resume 8`. |
| 11 | `Failed to bring availability group 'AG1' online ... error 41131` (SQL log: 19435 / 41044; cluster log: `Res AG1: ProcessingFailure`) | `NT AUTHORITY\SYSTEM` lacks permissions on SQL Server | Fixed in `08-node-alwayson.ps1`. `resume 10` (re-applies the grants and retries). See [KB 2847723](https://support.microsoft.com/kb/2847723). |
| 13 | `ADD LISTENER` fails with an AD / permission error | The cluster object cannot create the listener computer object | Step 9 grants it; re-run `resume 9`. Check the cluster name is online: `Get-ClusterResource`. |

### Cancel a stuck SSM command

```bash
# commands still running
aws ssm list-commands --filters key=Status,value=InProgress \
  --query 'Commands[].[CommandId,RequestedDateTime,Parameters.executionTimeout[0]]' --output table
aws ssm cancel-command --command-id <CommandId>

# kill leftover processes on the nodes
aws ssm send-command --document-name AWS-RunPowerShellScript --instance-ids $N1 $N2 \
  --parameters '{"commands":["Get-Process setup,SQL2022-SSEI-Dev -ErrorAction SilentlyContinue | Stop-Process -Force; \"clean\""]}'
```

### Read the SQL Server and cluster logs on a node

```bash
CID=$(aws ssm send-command --document-name AWS-RunPowerShellScript --instance-ids $N1 \
  --query Command.CommandId --output text --parameters \
  '{"commands":["Import-Module FailoverClusters; Get-ClusterGroup | Format-Table Name,State,OwnerNode -Auto | Out-String","Get-ClusterResource | Format-Table Name,State,ResourceType -Auto | Out-String","$f=(Get-ChildItem \"C:\\Program Files\\Microsoft SQL Server\\MSSQL*\\MSSQL\\Log\\ERRORLOG\" | Select-Object -First 1).FullName; Get-Content $f -Tail 40"]}')
sleep 15
aws ssm get-command-invocation --command-id $CID --instance-id $N1 --query StandardOutputContent --output text
```

In a multi-subnet cluster it is **normal** for one `Cluster IP Address` resource to be `Offline`: only the IP of the owner node's subnet is online.

## The CloudShell session ended while deploying

CloudShell stops after ~20–30 minutes without interaction and kills background jobs. Commands already sent to the instances keep running.

1. Reconnect, `cd` to the project, `tail -20 lab.log` to see the last step reached.
2. `pgrep -af sqlag-lab.sh` — if it is gone, check in-flight commands (`list-commands ... InProgress`).
3. If the step's command is still `InProgress`, wait for it to finish — **do not re-run step 7** while the installer is still running.
4. If it finished (`Success`) but the nodes did not reboot, reboot them yourself and continue at the next step:
   ```bash
   aws ec2 reboot-instances --instance-ids $N1 $N2 && sleep 240
   nohup ./sqlag-lab.sh resume 8 > lab2.log 2>&1 &
   ```

## Connectivity

| Symptom | Cause | Fix |
|---|---|---|
| SSMS/RDP time out from your PC | The security group allows CloudShell's IP, not yours (the script detects the IP of the machine that runs it) | Redeploy with `MY_CIDR=<your-ip>/32`, or: `./sqlag-lab.sh myip <your-ip>/32` |
| SSMS: *network path not found / Named Pipes error 53* when connecting to `AGL` | `AGL` only resolves in the `corp.local` DNS and its IPs are private | Connect from inside the VPC (RDP to a node), or use VPC peering + the listener IP (`10.0.1.51,1433` / `10.0.2.51,1433`) |
| Connecting by listener IP stops working after a failover | Only the listener IP of the primary's subnet is online | Use the other IP, or use the name with `MultiSubnetFailover=True` |
| SSMS TLS / certificate error | SQL Server 2022+/SSMS 21+ default to mandatory encryption | Tick **Trust server certificate** |
| An Amazon WorkSpace in another region cannot reach the listener | No route between VPCs; security groups cannot reference other regions | Inter-region VPC peering, routes both ways, allow the other VPC's CIDR on 1433; delete the peering before `down` |

## Cleanup problems

- **Duplicate/orphan instances after a failed `up`.** Early versions of `down` skipped termination when a resource ID was missing. Find orphans by tag and compare with the IDs in `sqlag-lab.env`:
  ```bash
  aws ec2 describe-instances --filters Name=tag:Project,Values=sqlag-lab \
    Name=instance-state-name,Values=pending,running,stopping,stopped \
    --query 'Reservations[].Instances[].[InstanceId,Tags[?Key==`Name`]|[0].Value,VpcId]' --output table
  ```
  Terminate the extras, then delete their VPC dependencies (security group, subnets, route table, internet gateway, VPC).
- **`down` cannot delete the VPC.** A VPC peering connection or leftover ENI is attached. Delete the peering first (`aws ec2 delete-vpc-peering-connection`), then run `down` again.
- **Unassociated Elastic IPs keep billing:**
  ```bash
  aws ec2 describe-addresses --query 'Addresses[?AssociationId==null].[PublicIp,AllocationId]' --output table
  aws ec2 release-address --allocation-id eipalloc-xxxxxxxx
  ```
- **Terminated instances still listed in the console.** Normal for about an hour. They cost nothing.

## Health queries

```sql
-- replicas
SELECT ar.replica_server_name, ars.role_desc, ars.connected_state_desc, ars.synchronization_health_desc
FROM sys.availability_replicas ar
JOIN sys.dm_hadr_availability_replica_states ars ON ar.replica_id = ars.replica_id;

-- databases
SELECT DB_NAME(database_id) db, synchronization_state_desc, synchronization_health_desc, log_send_queue_size, redo_queue_size
FROM sys.dm_hadr_database_replica_states WHERE is_local = 1;
```
