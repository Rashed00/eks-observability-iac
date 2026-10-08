#!/usr/bin/env bash
# destroy.sh - tear down the whole observability hub and leave nothing billable.
#
# Put this file in eks-observability-iac/scripts/ and run it from anywhere:
#   ./scripts/destroy.sh               # full run, asks once before deleting anything
#   ./scripts/destroy.sh -y            # same, no question
#   ./scripts/destroy.sh --from sweep  # resume at a step after a failure
#
# Steps, in order:
#   preflight      check tools and login, see if the cluster still exists
#   freeze-argocd  stop ArgoCD so it does not put back what we delete
#   gateway        delete the Gateway + LoadBalancer services, wait for the AWS load balancer to go
#   volumes        delete the apps' disks (PVCs), wait for the EBS volumes to go
#   nodes          delete the Karpenter node pools, wait for their EC2 instances to go
#   dns            remove *.monitoring.<domain> from Route53
#   tf-cluster     terraform: everything except the network (in-cluster things, then EKS)
#   sweep          delete what the cluster made that Terraform does not know about
#   tf-network     terraform: NAT instance + VPC
#   report         list anything still left in the account
#
# Steps that need the cluster skip themselves when it is already gone, so
# running again after a half-finished destroy is safe.
#
# KEPT on purpose: the Terraform state bucket and the Route53 hosted zone.
#
# Settings you can override with environment variables (same as spin-up.sh):
#   CLUSTER_NAME (observability-cluster)  DOMAIN (relsayed.online)
#   AWS_REGION (eu-central-1)  AWS_PROFILE (default)

set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TF_DIR="${REPO_ROOT}/environments/production"
CLUSTER_NAME="${CLUSTER_NAME:-observability-cluster}"
DOMAIN="${DOMAIN:-relsayed.online}"
AWS_REGION="${AWS_REGION:-eu-central-1}"
export AWS_PROFILE="${AWS_PROFILE:-default}"
export AWS_REGION AWS_DEFAULT_REGION="${AWS_REGION}"
NAT_NAME="${CLUSTER_NAME}-fck-nat"

STEPS=(preflight freeze-argocd gateway volumes nodes dns tf-cluster sweep tf-network report)
FROM="preflight"
ASSUME_YES="${YES:-0}"
CURRENT_STEP="preflight"
KUBE_READY=0

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m!!  %s\033[0m\n' "$*"; }
die()  { printf '\n\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

on_error() {
  printf '\n\033[1;31mStopped in step "%s".\033[0m\n' "${CURRENT_STEP}" >&2
  printf 'Fix the problem, then continue with:\n  %s --from %s\n' "$0" "${CURRENT_STEP}" >&2
}
trap on_error ERR

usage() {
  awk 'NR>1 && /^#/ { sub(/^# ?/, ""); print; next } NR>1 { exit }' "$0"
}

tf() { (cd "${TF_DIR}" && terraform "$@"); }
tf_init() { tf init -backend-config=backend.tfbackend -input=false >/dev/null; }

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------
cluster_exists() {
  aws eks describe-cluster --name "${CLUSTER_NAME}" >/dev/null 2>&1
}

# Use at the top of a step that needs kubectl:  need_cluster || return 0
need_cluster() {
  if ! cluster_exists; then
    echo "The cluster is already gone, skipping this step."
    return 1
  fi
  if [[ "${KUBE_READY}" != "1" ]]; then
    aws eks update-kubeconfig --region "${AWS_REGION}" --name "${CLUSTER_NAME}" >/dev/null
    if ! kubectl get namespaces >/dev/null 2>&1; then
      warn "The cluster exists but kubectl cannot reach it, skipping this step. The sweep step cleans up after it."
      return 1
    fi
    KUBE_READY=1
  fi
}

state_bucket() {
  grep -E '^\s*bucket\s*=' "${TF_DIR}/backend.tfbackend" | head -1 | cut -d'"' -f2
}

vpc_id() {
  local id
  id="$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=${CLUSTER_NAME}-vpc" \
    --query 'Vpcs[0].VpcId' --output text 2>/dev/null || true)"
  if [[ "${id}" == "None" ]]; then id=""; fi
  echo "${id}"
}

# Load balancers / target groups made by the AWS Load Balancer Controller for this cluster.
cluster_lbs() {
  local arn
  for arn in $(aws elbv2 describe-load-balancers --query 'LoadBalancers[].LoadBalancerArn' --output text); do
    if [[ "$(aws elbv2 describe-tags --resource-arns "${arn}" \
        --query "length(TagDescriptions[0].Tags[?Key=='elbv2.k8s.aws/cluster' && Value=='${CLUSTER_NAME}'])" \
        --output text)" == "1" ]]; then
      echo "${arn}"
    fi
  done
  return 0
}

cluster_tgs() {
  local arn
  for arn in $(aws elbv2 describe-target-groups --query 'TargetGroups[].TargetGroupArn' --output text); do
    if [[ "$(aws elbv2 describe-tags --resource-arns "${arn}" \
        --query "length(TagDescriptions[0].Tags[?Key=='elbv2.k8s.aws/cluster' && Value=='${CLUSTER_NAME}'])" \
        --output text)" == "1" ]]; then
      echo "${arn}"
    fi
  done
  return 0
}

cluster_pvcs()       { kubectl get pvc -A -o name 2>/dev/null || true; }
cluster_pvs()        { kubectl get pv -o name 2>/dev/null || true; }
karpenter_claims()   { kubectl get nodeclaims.karpenter.sh -o name 2>/dev/null || true; }

# wait_gone <what> <tries> <seconds> <command...>
# Repeats the command until it prints nothing. Returns 1 if it never does.
wait_gone() {
  local what="$1" tries="$2" pause="$3" left i
  shift 3
  for ((i = 1; i <= tries; i++)); do
    left="$("$@" || true)"
    if [[ -z "${left}" ]]; then
      echo "  no ${what} left."
      return 0
    fi
    echo "  waiting for $(wc -w <<<"${left}") ${what} to go (${i}/${tries})..."
    sleep "${pause}"
  done
  warn "Still there after waiting (${what}):"
  echo "${left}"
  return 1
}

# ---------------------------------------------------------------------------
# preflight
# ---------------------------------------------------------------------------
step_preflight() {
  log "Preflight checks"

  local cmd
  for cmd in terraform aws kubectl jq; do
    command -v "${cmd}" >/dev/null || die "'${cmd}' is not installed."
  done

  aws sts get-caller-identity --query Account --output text >/dev/null \
    || die "AWS login does not work for profile '${AWS_PROFILE}'."
  echo "AWS account: $(aws sts get-caller-identity --query Account --output text)"

  [[ -f "${TF_DIR}/backend.tfbackend" ]] || die "Missing ${TF_DIR}/backend.tfbackend"
  echo "State bucket (kept): $(state_bucket)"

  if cluster_exists; then
    echo "Cluster ${CLUSTER_NAME}: $(aws eks describe-cluster --name "${CLUSTER_NAME}" --query cluster.status --output text)"
  else
    echo "Cluster ${CLUSTER_NAME}: already gone (the in-cluster steps will be skipped)"
  fi

  if [[ "${ASSUME_YES}" != "1" ]]; then
    echo
    echo "This DELETES the cluster and everything in it: metrics, logs, traces, dashboards, disks."
    read -rp "Type 'destroy' to continue: " answer
    [[ "${answer}" == "destroy" ]] || { echo "Cancelled."; exit 0; }
  fi
}

# ---------------------------------------------------------------------------
# freeze-argocd: otherwise ArgoCD re-creates the Gateway and disks we delete
# ---------------------------------------------------------------------------
step_freeze_argocd() {
  need_cluster || return 0
  log "Stopping ArgoCD so it does not put things back"

  if ! kubectl get namespace argocd >/dev/null 2>&1; then
    echo "ArgoCD is not installed, nothing to stop."
    return 0
  fi

  kubectl -n argocd scale statefulset argocd-application-controller --replicas=0 2>/dev/null \
    || warn "No argocd-application-controller statefulset found."
  kubectl -n argocd scale deployment argocd-applicationset-controller --replicas=0 2>/dev/null || true
  kubectl -n argocd wait --for=delete pod -l app.kubernetes.io/name=argocd-application-controller \
    --timeout=120s 2>/dev/null || true
  echo "ArgoCD is paused."
}

# ---------------------------------------------------------------------------
# gateway: the AWS load balancer blocks the certificate, security groups and VPC
# ---------------------------------------------------------------------------
step_gateway() {
  need_cluster || return 0
  log "Deleting the Gateway, ingresses and LoadBalancer services"

  if kubectl get crd gateways.gateway.networking.k8s.io >/dev/null 2>&1; then
    kubectl delete gateways.gateway.networking.k8s.io --all -A --wait=false
  fi
  kubectl delete ingress --all -A --wait=false

  kubectl get svc -A -o json \
    | jq -r '.items[] | select(.spec.type=="LoadBalancer") | "\(.metadata.namespace) \(.metadata.name)"' \
    | while read -r ns name; do
        kubectl delete svc -n "${ns}" "${name}" --wait=false
      done

  log "Waiting for the AWS load balancer to be deleted"
  wait_gone "load balancer(s)" 40 15 cluster_lbs \
    || die "The load balancer did not go away. Check the controller: kubectl logs -A -l app.kubernetes.io/name=aws-load-balancer-controller --tail=30"
}

# ---------------------------------------------------------------------------
# volumes: delete PVCs while the cluster is alive, so the EBS disks go too
# ---------------------------------------------------------------------------
step_volumes() {
  need_cluster || return 0
  log "Deleting the apps' disks"

  local namespaces ns kind
  namespaces="$(kubectl get pvc -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"\n"}{end}' | sort -u)"
  if [[ -z "${namespaces}" ]]; then
    echo "No disks (PVCs) in the cluster."
    return 0
  fi

  # The Prometheus operator re-creates its StatefulSets, so remove what it manages first.
  for kind in prometheuses.monitoring.coreos.com alertmanagers.monitoring.coreos.com thanosrulers.monitoring.coreos.com; do
    if kubectl get crd "${kind}" >/dev/null 2>&1; then
      kubectl delete "${kind}" --all -A --wait=false
    fi
  done

  # A disk cannot be released while a pod still uses it.
  for ns in ${namespaces}; do
    echo "  namespace ${ns}: stopping apps and deleting PVCs"
    kubectl -n "${ns}" delete statefulset,deployment --all --wait=false
    kubectl -n "${ns}" delete pvc --all --wait=false
  done

  wait_gone "PVC(s)" 40 10 cluster_pvcs \
    || die "Some PVCs are stuck. Check: kubectl get pvc -A ; kubectl get pods -A | grep -v Running"
  wait_gone "EBS disk(s)" 30 10 cluster_pvs \
    || warn "Some disks were not deleted by the cluster. The sweep step deletes leftover disks."
}

# ---------------------------------------------------------------------------
# nodes: Karpenter's EC2 instances are not in Terraform
# ---------------------------------------------------------------------------
step_nodes() {
  need_cluster || return 0

  if ! kubectl get crd nodepools.karpenter.sh >/dev/null 2>&1; then
    echo "Karpenter is not installed, nothing to remove."
    return 0
  fi

  log "Deleting Karpenter node pools (Karpenter drains and removes its nodes)"
  kubectl delete nodepools.karpenter.sh --all --wait=false
  wait_gone "Karpenter node(s)" 40 15 karpenter_claims \
    || die "Karpenter nodes did not go away. Check: kubectl get nodeclaims ; kubectl logs -A -l app.kubernetes.io/name=karpenter --tail=30"

  if kubectl get crd ec2nodeclasses.karpenter.k8s.aws >/dev/null 2>&1; then
    kubectl delete ec2nodeclasses.karpenter.k8s.aws --all --timeout=120s \
      || warn "EC2NodeClass is still deleting, continuing."
  fi
}

# ---------------------------------------------------------------------------
# dns: the record points at a load balancer that no longer exists
# ---------------------------------------------------------------------------
step_dns() {
  log "Removing the monitoring records from Route53"

  local zone_id records batch
  zone_id="$(aws route53 list-hosted-zones-by-name --dns-name "${DOMAIN}" \
    --query 'HostedZones[0].Id' --output text)"
  zone_id="${zone_id##*/}"

  # A / AAAA / CNAME records under monitoring.<domain>, including the wildcard.
  # Names starting with "_" are certificate checks owned by Terraform, left alone.
  records="$(aws route53 list-resource-record-sets --hosted-zone-id "${zone_id}" --output json \
    | jq --arg d "monitoring.${DOMAIN}." '[.ResourceRecordSets[]
        | select(.Name | endswith($d))
        | select(.Name | startswith("_") | not)
        | select(.Type == "A" or .Type == "AAAA" or .Type == "CNAME")]')"

  if [[ "$(jq length <<<"${records}")" == "0" ]]; then
    echo "No monitoring records left."
    return 0
  fi

  jq -r '.[] | "  deleting \(.Name) \(.Type)"' <<<"${records}" | sed 's/\\052/*/'
  batch="$(jq '{Changes: [.[] | {Action: "DELETE", ResourceRecordSet: .}]}' <<<"${records}")"
  aws route53 change-resource-record-sets --hosted-zone-id "${zone_id}" --change-batch "${batch}" >/dev/null
  echo "Done."
}

# ---------------------------------------------------------------------------
# tf-cluster: everything Terraform owns except the network
# ---------------------------------------------------------------------------
step_tf_cluster() {
  log "terraform init"
  tf_init

  local extra=()
  if ! cluster_exists; then
    # The Kubernetes/Helm/kubectl providers cannot start without the cluster.
    # Anything Terraform still lists inside it died with the cluster, so forget it,
    # and skip the refresh so those providers are never loaded.
    local addrs=()
    mapfile -t addrs < <(tf state list | grep -E '(^|\.)(kubectl_|kubernetes_|helm_)' || true)
    if [[ "${#addrs[@]}" -gt 0 ]]; then
      warn "The cluster is gone but Terraform still lists things inside it. Removing them from the state:"
      printf '  %s\n' "${addrs[@]}"
      tf state rm "${addrs[@]}"
    fi
    extra=(-refresh=false)
  fi

  # Everything in the state except the VPC and NAT, one target per module/resource.
  local targets=()
  mapfile -t targets < <(tf state list \
    | grep -v '^data\.' \
    | grep -vE '^module\.(vpc|fck_nat)[.\[]' \
    | sed -E 's/^(module\.[^.]+)\..*/\1/; s/\[.*$//' \
    | sort -u)

  if [[ "${#targets[@]}" -eq 0 ]]; then
    echo "Nothing left in Terraform except the network."
    return 0
  fi

  log "Stage 1/2: cluster and everything on it (about 10-15 min)"
  printf '  %s\n' "${targets[@]}"
  tf destroy -auto-approve -input=false "${extra[@]}" "${targets[@]/#/-target=}"
}

# ---------------------------------------------------------------------------
# sweep: things the cluster made in AWS that block the VPC or cost money
# ---------------------------------------------------------------------------
step_sweep() {
  log "Cleaning up what the cluster made outside Terraform"

  local arn
  for arn in $(cluster_lbs); do
    echo "  deleting load balancer ${arn}"
    aws elbv2 delete-load-balancer --load-balancer-arn "${arn}"
  done
  wait_gone "load balancer(s)" 20 15 cluster_lbs || warn "A load balancer is still deleting."

  for arn in $(cluster_tgs); do
    echo "  deleting target group ${arn}"
    aws elbv2 delete-target-group --target-group-arn "${arn}" || warn "Could not delete ${arn}"
  done

  local vpc
  vpc="$(vpc_id)"
  if [[ -n "${vpc}" ]]; then
    # EC2 instances in the VPC other than the NAT (left-over Karpenter nodes).
    local ids
    ids="$(aws ec2 describe-instances \
      --filters "Name=vpc-id,Values=${vpc}" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
      --query "Reservations[].Instances[?!(Tags[?Key=='aws:autoscaling:groupName' && Value=='${NAT_NAME}'])].InstanceId" \
      --output text)"
    if [[ -n "${ids}" ]]; then
      echo "  terminating left-over instances: ${ids}"
      # shellcheck disable=SC2086
      aws ec2 terminate-instances --instance-ids ${ids} >/dev/null
      # shellcheck disable=SC2086
      aws ec2 wait instance-terminated --instance-ids ${ids}
    fi

    # Unattached network cards (not the NAT's).
    local eni
    for eni in $(aws ec2 describe-network-interfaces \
        --filters "Name=vpc-id,Values=${vpc}" "Name=status,Values=available" \
        --query "NetworkInterfaces[?!contains(Description || '', 'fck-nat')].NetworkInterfaceId" \
        --output text); do
      echo "  deleting network interface ${eni}"
      aws ec2 delete-network-interface --network-interface-id "${eni}" || warn "Could not delete ${eni}"
    done

    # Security groups the cluster made (k8s-traffic-..., and EKS ones if Terraform missed them).
    local sgs sg rules i deleted
    sgs="$(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=${vpc}" \
      --query "SecurityGroups[?GroupName!='default' && GroupName!='${NAT_NAME}'].GroupId" --output text)"
    # They can point at each other, so empty them all first, then delete.
    for sg in ${sgs}; do
      rules="$(aws ec2 describe-security-group-rules --filters "Name=group-id,Values=${sg}" \
        --query 'SecurityGroupRules[?!IsEgress].SecurityGroupRuleId' --output text)"
      if [[ -n "${rules}" ]]; then
        # shellcheck disable=SC2086
        aws ec2 revoke-security-group-ingress --group-id "${sg}" --security-group-rule-ids ${rules} >/dev/null
      fi
      rules="$(aws ec2 describe-security-group-rules --filters "Name=group-id,Values=${sg}" \
        --query 'SecurityGroupRules[?IsEgress].SecurityGroupRuleId' --output text)"
      if [[ -n "${rules}" ]]; then
        # shellcheck disable=SC2086
        aws ec2 revoke-security-group-egress --group-id "${sg}" --security-group-rule-ids ${rules} >/dev/null
      fi
    done
    for sg in ${sgs}; do
      deleted=0
      for i in $(seq 1 12); do
        if aws ec2 delete-security-group --group-id "${sg}" >/dev/null 2>&1; then
          echo "  deleted security group ${sg}"
          deleted=1
          break
        fi
        sleep 10
      done
      if [[ "${deleted}" != "1" ]]; then
        warn "Could not delete security group ${sg} (something still uses it)."
      fi
    done
  else
    echo "  VPC is already gone, skipping the VPC checks."
  fi

  # Unattached disks made by the EBS storage driver.
  local vols vol
  vols="$(aws ec2 describe-volumes \
    --filters "Name=status,Values=available" "Name=tag:ebs.csi.aws.com/cluster,Values=true" \
    --query 'Volumes[].VolumeId' --output text)"
  for vol in ${vols}; do
    echo "  deleting disk ${vol}"
    aws ec2 delete-volume --volume-id "${vol}" || warn "Could not delete ${vol}"
  done

  echo "Sweep finished."
}

# ---------------------------------------------------------------------------
# tf-network: NAT instance + VPC
# ---------------------------------------------------------------------------
step_tf_network() {
  log "terraform init"
  tf_init

  log "Stage 2/2: NAT instance and VPC (about 2-5 min)"
  tf destroy -auto-approve -input=false -target=module.fck_nat -target=module.vpc

  local left
  left="$(tf state list | grep -v 'data\.' || true)"
  if [[ -n "${left}" ]]; then
    warn "Terraform still lists these:"
    echo "${left}"
  else
    echo "Terraform state is empty."
  fi
}

# ---------------------------------------------------------------------------
# report: what is still in the account
# ---------------------------------------------------------------------------
LEFT=0
report_item() {
  local title="$1" out
  shift
  out="$("$@" 2>/dev/null | grep -vE '^[[:space:]]*(None)?[[:space:]]*$' || true)"
  if [[ -n "${out}" ]]; then
    printf '\n  %s:\n' "${title}"
    sed 's/^/    /' <<<"${out}"
    LEFT=1
  fi
}

step_report() {
  log "What is still in your account (${AWS_REGION})"

  local bucket zone_id
  bucket="$(state_bucket)"
  zone_id="$(aws route53 list-hosted-zones-by-name --dns-name "${DOMAIN}" \
    --query 'HostedZones[0].Id' --output text)"

  report_item "EKS clusters"     aws eks list-clusters --query clusters --output text
  report_item "EC2 instances"    aws ec2 describe-instances --filters Name=instance-state-name,Values=pending,running,stopping,stopped --query 'Reservations[].Instances[].[InstanceId,State.Name]' --output text
  report_item "Load balancers"   aws elbv2 describe-load-balancers --query 'LoadBalancers[].LoadBalancerName' --output text
  report_item "Target groups"    aws elbv2 describe-target-groups --query 'TargetGroups[].TargetGroupName' --output text
  report_item "EBS disks"        aws ec2 describe-volumes --query 'Volumes[].[VolumeId,State,Size]' --output text
  report_item "EFS"              aws efs describe-file-systems --query 'FileSystems[].FileSystemId' --output text
  report_item "Network cards"    aws ec2 describe-network-interfaces --query 'NetworkInterfaces[].[NetworkInterfaceId,Description]' --output text
  report_item "Elastic IPs"      aws ec2 describe-addresses --query 'Addresses[].[PublicIp,AssociationId]' --output text
  report_item "VPCs"             aws ec2 describe-vpcs --query 'Vpcs[?IsDefault==`false`].VpcId' --output text
  report_item "Security groups"  aws ec2 describe-security-groups --query 'SecurityGroups[?GroupName!=`default`].[GroupId,GroupName]' --output text
  report_item "Auto Scaling"     aws autoscaling describe-auto-scaling-groups --query 'AutoScalingGroups[].AutoScalingGroupName' --output text
  report_item "Certificates"     aws acm list-certificates --query 'CertificateSummaryList[].DomainName' --output text
  report_item "S3 buckets"       aws s3api list-buckets --query "Buckets[?Name!='${bucket}'].Name" --output text
  report_item "Secrets"          aws secretsmanager list-secrets --include-planned-deletion --query 'SecretList[].Name' --output text
  report_item "SQS queues"       aws sqs list-queues --query 'QueueUrls' --output text
  report_item "IAM roles"        aws iam list-roles --query "Roles[?contains(RoleName,'observability') || contains(RoleName,'arpenter')].RoleName" --output text
  report_item "IAM policies"     aws iam list-policies --scope Local --query "Policies[?contains(PolicyName,'observability') || contains(PolicyName,'arpenter')].PolicyName" --output text
  report_item "KMS aliases"      aws kms list-aliases --query "Aliases[?contains(AliasName,'observability')].AliasName" --output text
  report_item "Log groups"       aws logs describe-log-groups --log-group-name-prefix "/aws/eks/${CLUSTER_NAME}" --query 'logGroups[].logGroupName' --output text
  report_item "DNS records"      aws route53 list-resource-record-sets --hosted-zone-id "${zone_id}" --query 'ResourceRecordSets[?Type!=`NS` && Type!=`SOA`].[Name,Type]' --output text

  echo
  if [[ "${LEFT}" == "0" ]]; then
    log "Your account is clean."
  else
    warn "Something is still there (listed above). If you did not make it yourself, it may still cost money."
  fi
  echo "Kept on purpose: state bucket ${bucket} and the Route53 zone for ${DOMAIN} (about 0.50 USD/month)."
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --from)    FROM="${2:?--from needs a step name}"; shift 2 ;;
    -y|--yes)  ASSUME_YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1 (try --help)" ;;
  esac
done

valid=0
for s in "${STEPS[@]}"; do [[ "$s" == "${FROM}" ]] && valid=1; done
[[ "${valid}" == "1" ]] || die "Unknown step '${FROM}'. Steps: ${STEPS[*]}"

started=0
for s in "${STEPS[@]}"; do
  [[ "$s" == "${FROM}" ]] && started=1
  if [[ "${started}" == "1" ]]; then
    CURRENT_STEP="$s"
    "step_${s//-/_}"
  fi
done

log "Done."
