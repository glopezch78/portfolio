#!/usr/bin/env bash
# SQL Server Always On lab (2 nodes) on EC2: Active Directory + WSFC + SQL Server Developer.
# Fully automated: infrastructure (AWS CLI) and in-guest configuration (via SSM, no RDP needed).
#
#   ./sqlag-lab.sh up              create and configure EVERYTHING (~50-70 min)
#   ./sqlag-lab.sh resume N        resume from step N after a failure (steps are listed in STEPS below)
#   ./sqlag-lab.sh info            public IPs and credentials
#   ./sqlag-lab.sh status          cluster and availability group state
#   ./sqlag-lab.sh failover        manual failover (the secondary becomes primary)
#   ./sqlag-lab.sh myip [CIDR]     replace the allowed client IP in the security group
#   ./sqlag-lab.sh down            delete EVERYTHING (stops all charges)
#
# Requirements: AWS CLI v2 configured, EC2/IAM/SSM permissions, curl, openssl, base64.
# Required:  SQL_ISO_URL   pre-signed URL of the SQL Server Developer ISO (see README)
# Optional:  AWS_DEFAULT_REGION (default us-east-1), DC_TYPE, SQL_TYPE (instance types),
#            MY_CIDR (your client IP as x.x.x.x/32; use it when running from CloudShell,
#            otherwise the CloudShell IP gets whitelisted instead of yours)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}"
export AWS_PAGER=""
P="sqlag-lab"
ENV_FILE="./${P}.env"
PS_DIR="./ps"
ROLE="${P}-ssm"
AZ1="${AWS_DEFAULT_REGION}a"
AZ2="${AWS_DEFAULT_REGION}b"
DC_TYPE="${DC_TYPE:-t3.medium}"
SQL_TYPE="${SQL_TYPE:-t3.large}"
DOMAIN="corp.local"
NETBIOS="CORP"
DC_IP="10.0.1.10"; N1_IP="10.0.1.20"; N2_IP="10.0.2.20"
SQL_ISO_URL="${SQL_ISO_URL:-}"
DELIV=600   # send-command delivery timeout (seconds)

die() { echo "ERROR: $*" >&2; exit 1; }
b64() { base64 | tr -d '\n'; }
save() { printf "%s='%s'\n" "$1" "${!1}" >> "$ENV_FILE"; chmod 600 "$ENV_FILE"; }
load() { [[ -f "$ENV_FILE" ]] || die "$ENV_FILE not found. Run first: $0 up"; source "$ENV_FILE"; }

# ---------------------------------------------------------------- SSM helpers
# ssm_run MODE "ids" file.ps1 [timeout_min]   (MODE: system | admin)
ssm_run() {
  local mode=$1 ids=$2 file=$3 tmo=${4:-90}
  local vars payload wrapper wb64 pf cid id st out err rc=0
  vars="\$ErrorActionPreference='Stop'; \$ProgressPreference='SilentlyContinue'; \$LabPwd='${LAB_PWD}'; \$Domain='${DOMAIN}'; \$Netbios='${NETBIOS}'; \$DcIp='${DC_IP}'; \$SqlIsoUrl='${SQL_ISO_URL}'"
  payload=$( { echo "$vars"; cat "$PS_DIR/_lib.ps1"; cat "$file"; } | b64 )
  wrapper=$(<"$PS_DIR/_wrapper.ps1")
  wrapper=${wrapper//__MODE__/$mode}
  wrapper=${wrapper//__TIMEOUT__/$tmo}
  wrapper=${wrapper//__NETBIOS__/$NETBIOS}
  wrapper=${wrapper//__PWD__/$LAB_PWD}
  wrapper=${wrapper//__B64__/$payload}
  wb64=$(printf '%s' "$wrapper" | b64)
  pf=$(mktemp)
  printf '{"commands":["iex ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(\x27%s\x27)))"],"executionTimeout":["%s"]}' \
    "$wb64" "$((tmo * 60 + 600))" > "$pf"
  cid=$(aws ssm send-command --document-name AWS-RunPowerShellScript --instance-ids $ids \
        --parameters "file://$pf" --timeout-seconds "$DELIV" --query Command.CommandId --output text) || { rm -f "$pf"; return 1; }
  rm -f "$pf"
  LAST_OUT=""
  for id in $ids; do
    while :; do
      st=$(aws ssm get-command-invocation --command-id "$cid" --instance-id "$id" --query Status --output text 2>/dev/null || echo Pending)
      case "$st" in
        Success) break ;;
        Pending|InProgress|Delayed) sleep 10 ;;
        *) rc=1; break ;;
      esac
    done
    out=$(aws ssm get-command-invocation --command-id "$cid" --instance-id "$id" --query StandardOutputContent --output text 2>/dev/null || true)
    LAST_OUT="$out"
    if [[ -z "${QUIET:-}" ]]; then
      echo "--- $id [$st]"
      [[ "$out" != "None" ]] && echo "$out"
      if [[ "$st" != "Success" ]]; then
        err=$(aws ssm get-command-invocation --command-id "$cid" --instance-id "$id" --query StandardErrorContent --output text 2>/dev/null || true)
        [[ "$err" != "None" ]] && echo "$err" >&2
      fi
    fi
  done
  return $rc
}

wait_ssm() {  # wait until the instances show up as Online in SSM
  local id n
  for id in "$@"; do
    n=0
    until [[ "$(aws ssm describe-instance-information --filters "Key=InstanceIds,Values=$id" \
              --query 'InstanceInformationList[0].PingStatus' --output text 2>/dev/null)" == "Online" ]]; do
      n=$((n + 1)); (( n < 90 )) || die "$id did not register in SSM within 15 min"
      sleep 10
    done
  done
}

boot_after() {  # returns 0 if the instance booted after $2 (epoch seconds)
  local out
  QUIET=1 DELIV=30 ssm_run system "$1" "$PS_DIR/_boot.ps1" 5 || return 1
  out=$(echo "$LAST_OUT" | tr -d '[:space:]')
  [[ "$out" =~ ^[0-9]+$ ]] && (( out >= $2 ))
}

reboot_wait() {  # reboot and wait for the SSM agent to come back
  local t0 id n
  t0=$(date +%s)
  for id in "$@"; do aws ec2 reboot-instances --instance-ids "$id"; done
  sleep 45
  for id in "$@"; do
    n=0
    until boot_after "$id" "$t0"; do
      n=$((n + 1)); (( n < 80 )) || die "$id did not come back after the reboot"
      sleep 15
    done
  done
}

# ---------------------------------------------------------------- infrastructure
infra() {
  [[ ! -f "$ENV_FILE" ]] || die "$ENV_FILE already exists. Use '$0 down' or '$0 resume N'."
  MY_IP="${MY_CIDR:-$(curl -s https://checkip.amazonaws.com | tr -d '[:space:]')/32}"; save MY_IP
  LAB_PWD="Lab#$(openssl rand -hex 6)aA1!"; save LAB_PWD
  echo "Region: $AWS_DEFAULT_REGION | Allowed client IP: $MY_IP"

  # IAM role so that SSM can manage the instances
  aws iam create-role --role-name "$ROLE" --assume-role-policy-document \
    '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}' >/dev/null
  aws iam attach-role-policy --role-name "$ROLE" --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
  aws iam create-instance-profile --instance-profile-name "$ROLE" >/dev/null
  aws iam add-role-to-instance-profile --instance-profile-name "$ROLE" --role-name "$ROLE"
  IAM_CREATED=1; save IAM_CREATED

  local BASE_AMI
  BASE_AMI=$(aws ssm get-parameter --name /aws/service/ami-windows-latest/Windows_Server-2022-English-Full-Base \
    --query Parameter.Value --output text)

  VPC=$(aws ec2 create-vpc --cidr-block 10.0.0.0/16 --query Vpc.VpcId --output text); save VPC
  aws ec2 modify-vpc-attribute --vpc-id "$VPC" --enable-dns-hostnames
  aws ec2 create-tags --resources "$VPC" --tags "Key=Name,Value=$P" "Key=Project,Value=$P"
  S1=$(aws ec2 create-subnet --vpc-id "$VPC" --cidr-block 10.0.1.0/24 --availability-zone "$AZ1" --query Subnet.SubnetId --output text); save S1
  S2=$(aws ec2 create-subnet --vpc-id "$VPC" --cidr-block 10.0.2.0/24 --availability-zone "$AZ2" --query Subnet.SubnetId --output text); save S2
  aws ec2 modify-subnet-attribute --subnet-id "$S1" --map-public-ip-on-launch
  aws ec2 modify-subnet-attribute --subnet-id "$S2" --map-public-ip-on-launch
  IGW=$(aws ec2 create-internet-gateway --query InternetGateway.InternetGatewayId --output text); save IGW
  aws ec2 attach-internet-gateway --internet-gateway-id "$IGW" --vpc-id "$VPC"
  RT=$(aws ec2 create-route-table --vpc-id "$VPC" --query RouteTable.RouteTableId --output text); save RT
  aws ec2 create-route --route-table-id "$RT" --destination-cidr-block 0.0.0.0/0 --gateway-id "$IGW" >/dev/null
  aws ec2 associate-route-table --route-table-id "$RT" --subnet-id "$S1" >/dev/null
  aws ec2 associate-route-table --route-table-id "$RT" --subnet-id "$S2" >/dev/null

  SG=$(aws ec2 create-security-group --group-name "$P" --description "$P" --vpc-id "$VPC" --query GroupId --output text); save SG
  aws ec2 authorize-security-group-ingress --group-id "$SG" --protocol -1 --source-group "$SG" >/dev/null
  aws ec2 authorize-security-group-ingress --group-id "$SG" --protocol tcp --port 3389 --cidr "$MY_IP" >/dev/null
  aws ec2 authorize-security-group-ingress --group-id "$SG" --protocol tcp --port 1433 --cidr "$MY_IP" >/dev/null

  launch() {  # name type subnet ip   (public IP assigned explicitly)
    local i out errf
    errf=$(mktemp)
    for i in 1 2 3 4 5 6 7 8; do
      if out=$(aws ec2 run-instances --image-id "$BASE_AMI" --instance-type "$2" \
        --iam-instance-profile "Name=$ROLE" \
        --network-interfaces "DeviceIndex=0,SubnetId=$3,PrivateIpAddress=$4,Groups=$SG,AssociatePublicIpAddress=true" \
        --block-device-mappings 'DeviceName=/dev/sda1,Ebs={VolumeSize=60,VolumeType=gp3}' \
        --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$1},{Key=Project,Value=$P}]" \
        --query 'Instances[0].InstanceId' --output text 2>"$errf"); then
        rm -f "$errf"; echo "$out"; return 0
      fi
      # retry only while the instance profile has not propagated yet; any other error is final
      grep -qi 'instance profile' "$errf" || break
      sleep 10
    done
    echo "AWS error while launching $1 ($2):" >&2
    cat "$errf" >&2
    echo "Clean up what was created with: $0 down" >&2
    exit 1
  }
  DC=$(launch DC01     "$DC_TYPE"  "$S1" "$DC_IP"); save DC
  N1=$(launch SQLNODE1 "$SQL_TYPE" "$S1" "$N1_IP"); save N1
  N2=$(launch SQLNODE2 "$SQL_TYPE" "$S2" "$N2_IP"); save N2
  aws ec2 wait instance-running --instance-ids "$DC" "$N1" "$N2"

  # Secondary private IPs on each node: one for the cluster and one for the listener (one per subnet)
  eni() { aws ec2 describe-instances --instance-ids "$1" \
            --query 'Reservations[0].Instances[0].NetworkInterfaces[0].NetworkInterfaceId' --output text; }
  aws ec2 assign-private-ip-addresses --network-interface-id "$(eni "$N1")" --private-ip-addresses 10.0.1.50 10.0.1.51 >/dev/null
  aws ec2 assign-private-ip-addresses --network-interface-id "$(eni "$N2")" --private-ip-addresses 10.0.2.50 10.0.2.51 >/dev/null

  # Elastic IPs: stable public IPs even if you stop and start the instances
  local name var alloc
  for name in DC N1 N2; do
    alloc=$(aws ec2 allocate-address --domain vpc --query AllocationId --output text)
    var="EIP_$name"; printf -v "$var" '%s' "$alloc"; save "$var"
    aws ec2 associate-address --instance-id "${!name}" --allocation-id "$alloc" >/dev/null
  done
  echo "Infrastructure ready."
}

# ---------------------------------------------------------------- configuration steps
s_wait_ssm()   { wait_ssm "$DC" "$N1" "$N2"; }
s_adminpwd()   { ssm_run system "$DC $N1 $N2" "$PS_DIR/00-set-admin-pwd.ps1" 10; }
s_dc_rename()  { ssm_run system "$DC" "$PS_DIR/01-dc-rename.ps1" 10; reboot_wait "$DC"; }
s_dc_forest()  { ssm_run system "$DC" "$PS_DIR/02-dc-forest.ps1" 60; reboot_wait "$DC"; sleep 120; }
s_dc_post()    { ssm_run admin  "$DC" "$PS_DIR/03-dc-post.ps1" 30; }
s_join()       { ssm_run system "$N1 $N2" "$PS_DIR/04-node-join.ps1" 30; reboot_wait "$N1" "$N2"; }
s_sqlinstall() { ssm_run system "$N1 $N2" "$PS_DIR/05-node-sql-install.ps1" 120; reboot_wait "$N1" "$N2"; }
s_cluster()    { ssm_run admin  "$N1" "$PS_DIR/06-cluster.ps1" 30; }
s_cno()        { ssm_run admin  "$DC" "$PS_DIR/07-dc-cno-perms.ps1" 10; }
s_alwayson()   { ssm_run admin  "$N1 $N2" "$PS_DIR/08-node-alwayson.ps1" 30; }
s_ag()         { ssm_run admin  "$N1" "$PS_DIR/09-ag-primary.ps1" 30; }
s_secondary()  { ssm_run admin  "$N2" "$PS_DIR/10-ag-secondary.ps1" 30; }
s_listener()   { ssm_run admin  "$N1" "$PS_DIR/11-listener.ps1" 30; }
s_status()     { ssm_run admin  "$N1 $N2" "$PS_DIR/99-status.ps1" 15; }

STEPS=(s_wait_ssm s_adminpwd s_dc_rename s_dc_forest s_dc_post s_join s_sqlinstall
       s_cluster s_cno s_alwayson s_ag s_secondary s_listener s_status)

run_steps() {
  local from=$1 i
  if (( from <= 7 )) && [[ -z "$SQL_ISO_URL" ]]; then
    die "SQL_ISO_URL is not set. Upload the SQL Server Developer ISO to S3 and export a pre-signed URL (see README)."
  fi
  for ((i = from - 1; i < ${#STEPS[@]}; i++)); do
    echo
    echo "=== Step $((i + 1))/${#STEPS[@]}: ${STEPS[$i]} ($(date +%H:%M:%S)) ==="
    "${STEPS[$i]}" || die "Step $((i + 1)) (${STEPS[$i]}) failed. Fix the cause and run: $0 resume $((i + 1))"
  done
}

# ---------------------------------------------------------------- commands
info() {
  load
  aws ec2 describe-instances --instance-ids "$DC" "$N1" "$N2" \
    --query 'Reservations[].Instances[].[Tags[?Key==`Name`]|[0].Value,PublicIpAddress,PrivateIpAddress]' --output table
  echo "RDP (3389)  user: ${NETBIOS}\\Administrator   password: $LAB_PWD"
  echo "SSMS        server: <public IP of a SQL node>,1433   user: sa   password: $LAB_PWD"
  echo "Listener AGL (10.0.1.51 / 10.0.2.51) is only reachable from inside the VPC."
  echo "Access allowed only from: $MY_IP  (if your IP changes: $0 myip <x.x.x.x/32>)"
}

myip() {
  load
  local new; new="${1:-$(curl -s https://checkip.amazonaws.com | tr -d '[:space:]')/32}"
  local port
  for port in 3389 1433; do
    aws ec2 revoke-security-group-ingress --group-id "$SG" --protocol tcp --port "$port" --cidr "$MY_IP" >/dev/null 2>&1 || true
    aws ec2 authorize-security-group-ingress --group-id "$SG" --protocol tcp --port "$port" --cidr "$new" >/dev/null
  done
  sed -i.bak "s#^MY_IP=.*#MY_IP='$new'#" "$ENV_FILE" && rm -f "$ENV_FILE.bak"
  echo "Allowed IP updated to $new"
}

down() {
  load
  echo "Deleting resources..."
  # only use IDs that exist: if 'up' failed halfway, some may be empty and would break the command
  local ids=() x
  for x in "${DC:-}" "${N1:-}" "${N2:-}"; do [[ -n "$x" ]] && ids+=("$x"); done
  if (( ${#ids[@]} )); then
    aws ec2 terminate-instances --instance-ids "${ids[@]}" >/dev/null || echo "WARNING: could not terminate ${ids[*]}" >&2
    aws ec2 wait instance-terminated --instance-ids "${ids[@]}" 2>/dev/null || true
  fi
  local a
  for a in "${EIP_DC:-}" "${EIP_N1:-}" "${EIP_N2:-}"; do
    [[ -n "$a" ]] && aws ec2 release-address --allocation-id "$a" 2>/dev/null || true
  done
  local i
  for i in 1 2 3 4 5 6; do
    aws ec2 delete-security-group --group-id "${SG:-}" 2>/dev/null && break || sleep 10
  done
  [[ -n "${S1:-}" ]] && aws ec2 delete-subnet --subnet-id "$S1" 2>/dev/null || true
  [[ -n "${S2:-}" ]] && aws ec2 delete-subnet --subnet-id "$S2" 2>/dev/null || true
  [[ -n "${RT:-}" ]] && aws ec2 delete-route-table --route-table-id "$RT" 2>/dev/null || true
  if [[ -n "${IGW:-}" ]]; then
    aws ec2 detach-internet-gateway --internet-gateway-id "$IGW" --vpc-id "${VPC:-}" 2>/dev/null || true
    aws ec2 delete-internet-gateway --internet-gateway-id "$IGW" 2>/dev/null || true
  fi
  [[ -n "${VPC:-}" ]] && aws ec2 delete-vpc --vpc-id "$VPC" 2>/dev/null || true
  if [[ -n "${IAM_CREATED:-}" ]]; then
    aws iam remove-role-from-instance-profile --instance-profile-name "$ROLE" --role-name "$ROLE" 2>/dev/null || true
    aws iam delete-instance-profile --instance-profile-name "$ROLE" 2>/dev/null || true
    aws iam detach-role-policy --role-name "$ROLE" --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore 2>/dev/null || true
    aws iam delete-role --role-name "$ROLE" 2>/dev/null || true
  fi
  rm -f "$ENV_FILE"
  echo "Done. Check the EC2 console for leftovers (instances, Elastic IPs, VPC '$P')."
}

case "${1:-}" in
  up)       infra; run_steps 1; echo; info ;;
  resume)   load; run_steps "${2:?Provide the step number}"; echo; info ;;
  info)     info ;;
  status)   load; s_status ;;
  failover) load; ssm_run admin "$N1 $N2" "$PS_DIR/12-failover.ps1" 10; sleep 20; s_status ;;
  myip)     myip "${2:-}" ;;
  down)     down ;;
  *)        sed -n '2,/^set -e/p' "$0" | sed '$d'; exit 1 ;;
esac
