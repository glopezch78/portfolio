# Practice exercises

Hands-on scenarios for the deployed lab. Connect to a node with SSMS (see the README) or run T-SQL through RDP on a node. Unless noted, run statements on the **current primary**; `./sqlag-lab.sh status` tells you which node that is.

> Remember to run `./sqlag-lab.sh down` when you finish.

## 1. Inspect the topology

```sql
SELECT ag.name, ar.replica_server_name, ar.availability_mode_desc, ar.failover_mode_desc, ar.seeding_mode_desc
FROM sys.availability_groups ag
JOIN sys.availability_replicas ar ON ar.group_id = ag.group_id;

SELECT dns_name, port, ip_configuration_string_from_cluster FROM sys.availability_group_listeners;
```

Questions: which node is primary? What does `ip_configuration_string_from_cluster` show for the IP of the other subnet?

## 2. Manual failover (no data loss)

```bash
./sqlag-lab.sh failover
```

Or in T-SQL, **on the secondary**:

```sql
ALTER AVAILABILITY GROUP [AG1] FAILOVER;
```

Reconnect to `AGL` (from a node, with `MultiSubnetFailover=True`) and run `SELECT @@SERVERNAME;`. Observe which listener IP is now online (`Get-ClusterResource` on a node).

## 3. Automatic failover

1. Note the current primary.
2. Stop that instance from the EC2 console.
3. After 30–60 seconds, connect to `AGL` and check `SELECT @@SERVERNAME;`.
4. Start the instance again and confirm it rejoins as `SECONDARY` and returns to `HEALTHY`.

Why does it work? Synchronous commit + `FAILOVER_MODE = AUTOMATIC` + a cluster that still has quorum (surviving node + file-share witness).

## 4. Write on the primary, read on the secondary

Insert rows from the primary:

```sql
INSERT LabDB.dbo.Heartbeat DEFAULT VALUES;
```

By default the secondary is **not readable**; a `SELECT` against it fails. Make it readable (on the primary):

```sql
ALTER AVAILABILITY GROUP [AG1]
  MODIFY REPLICA ON N'SQLNODE2' WITH (SECONDARY_ROLE (ALLOW_CONNECTIONS = ALL));
```

Connect directly to the other node and read the table. Then try an `INSERT` there and read the error.

## 5. Logins are not replicated

```sql
-- on the primary
CREATE LOGIN demo_login WITH PASSWORD = 'Str0ng!Passw0rd#1';
```

Fail over, then try `demo_login` on the new primary. The login does not exist there — only the **database** is replicated, not instance-level objects. Fix it by creating the login on both nodes (with the same SID to avoid orphaned users).

## 6. Add another database to the group

```sql
CREATE DATABASE Db2;
ALTER DATABASE Db2 SET RECOVERY FULL;
BACKUP DATABASE Db2 TO DISK = 'NUL';
ALTER AVAILABILITY GROUP [AG1] ADD DATABASE [Db2];
```

Automatic seeding copies the database to the secondary. Watch progress:

```sql
SELECT * FROM sys.dm_hadr_automatic_seeding;
```

## 7. Asynchronous commit and forced failover

Asynchronous replicas cannot fail over automatically. On the primary:

```sql
ALTER AVAILABILITY GROUP [AG1] MODIFY REPLICA ON N'SQLNODE2' WITH (FAILOVER_MODE = MANUAL);
ALTER AVAILABILITY GROUP [AG1] MODIFY REPLICA ON N'SQLNODE2' WITH (AVAILABILITY_MODE = ASYNCHRONOUS_COMMIT);
```

Now stop the primary instance, and on the surviving node perform a **forced failover** (it may lose data that was not yet sent):

```sql
ALTER AVAILABILITY GROUP [AG1] FORCE_FAILOVER_ALLOW_DATA_LOSS;
```

When the old primary returns, its databases are `SUSPENDED`; resume data movement and compare what was lost:

```sql
ALTER DATABASE LabDB SET HADR RESUME;
```

Restore the original settings afterwards (`SYNCHRONOUS_COMMIT`, then `FAILOVER_MODE = AUTOMATIC`).

## 8. Backup preference

```sql
ALTER AVAILABILITY GROUP [AG1] SET (AUTOMATED_BACKUP_PREFERENCE = SECONDARY);

SELECT sys.fn_hadr_backup_is_preferred_replica(N'LabDB') AS is_preferred_here;
```

Run the query on both nodes. Which one is preferred? What changes after a failover?

## 9. Quorum behavior

With two nodes and a file-share witness the cluster has three votes.

1. Stop `DC01` (the witness). Does the cluster stay up? (`Get-ClusterNode`, `Get-ClusterQuorum`)
2. Start `DC01`, then stop **one SQL node and `DC01` together**. Does the AG stay online? Why not?
3. Use `Get-ClusterNode | Format-Table Name, State, DynamicWeight, NodeWeight` to see dynamic quorum adjusting votes.

## 10. Look at failures like a DBA

Break something on purpose and find the evidence:

- Stop the SQL Server service on the secondary — where does the primary show the replica as `DISCONNECTED`?
- Block port 5022 in the security group for a minute — what appears in the SQL error log and the cluster log (`Get-ClusterLog -UseLocalTime -TimeSpan 10`)?
- Review the health events: `SELECT * FROM sys.dm_hadr_availability_replica_cluster_states;` and the `AlwaysOn_health` extended events session.
