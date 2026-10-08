#!/usr/bin/env bash
# spin-up.sh - build the whole observability hub from nothing.
#
# Put this file in eks-observability-iac/scripts/ and run it from anywhere:
#   ./scripts/spin-up.sh              # full run, asks once before creating anything
#   ./scripts/spin-up.sh -y           # same, no question
#   ./scripts/spin-up.sh --from argocd   # resume at a step after a failure
#
# Steps, in order:
#   preflight   check tools, files, state bucket, DNS zone and nameservers
#   network     terraform: VPC + NAT instance
#   nat         wait for the NAT instance, check it, fix the source/dest check
#   cluster     terraform: both storage IAM roles + EKS, then everything else
#   kubeconfig  connect kubectl, wait for nodes and the EBS storage add-on
#   cert        put the new ACM certificate ARN in the gitops repo and push it
#   argocd      install ArgoCD and apply the root app
#   dns         wait for the load balancer, point the domain at it
#   verify      wait for Grafana to answer, print a summary
#
# NOT included on purpose: the demo spoke, passwords, shutdown/startup.
#
# Settings you can override with environment variables:
#   GITOPS_DIR  (default: ../eks-observability-gitops next to this repo)
#   CLUSTER_NAME (observability-cluster)  DOMAIN (relsayed.online)
#   AWS_REGION (eu-central-1)  AWS_PROFILE (default)  ARGOCD_CHART_VERSION (8.2.2)

set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TF_DIR="${REPO_ROOT}/environments/production"
GITOPS_DIR="${GITOPS_DIR:-${REPO_ROOT}/../eks-observability-gitops}"
CLUSTER_NAME="${CLUSTER_NAME:-observability-cluster}"
DOMAIN="${DOMAIN:-relsayed.online}"
AWS_REGION="${AWS_REGION:-eu-central-1}"
ARGOCD_CHART_VERSION="${ARGOCD_CHART_VERSION:-8.2.2}"
export AWS_PROFILE="${AWS_PROFILE:-default}"
export AWS_REGION AWS_DEFAULT_REGION="${AWS_REGION}"

STEPS=(preflight network nat cluster kubeconfig cert argocd dns verify)
FROM="preflight"
ASSUME_YES="${YES:-0}"
CURRENT_STEP="preflight"

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m!!  %s\033[0m\n' "$*"; }
die()  { printf '\n\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

on_error() {
  printf '\n\033[1;31mStopped in step "%s".\033[0m\n' "${CURRENT_STEP}" >&2
  printf 'Fix the problem, then continue with:\n  %s --from %s\n' "$0" "${CURRENT_STEP}" >&2
}
trap on_error ERR

usage() {
  sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'
}

tf() { (cd "${TF_DIR}" && terraform "$@"); }

# ---------------------------------------------------------------------------
# preflight
# ---------------------------------------------------------------------------
step_preflight() {
  log "Preflight checks"

  local cmd
  for cmd in terraform aws kubectl helm jq git curl; do
    command -v "${cmd}" >/dev/null || die "'${cmd}' is not installed."
  done

  aws sts get-caller-identity --query Account --output text >/dev/null \
    || die "AWS login does not work for profile '${AWS_PROFILE}'."
  echo "AWS account: $(aws sts get-caller-identity --query Account --output text)"

  [[ -f "${TF_DIR}/terraform.tfvars"    ]] || die "Missing ${TF_DIR}/terraform.tfvars"
  [[ -f "${TF_DIR}/backend.tfbackend"   ]] || die "Missing ${TF_DIR}/backend.tfbackend"
  [[ -d "${GITOPS_DIR}/.git"            ]] || die "GITOPS_DIR '${GITOPS_DIR}' is not a git repo."
  [[ -f "${GITOPS_DIR}/apps/root.yaml"  ]] || die "No apps/root.yaml in ${GITOPS_DIR}"

  # The ArgoCD install values must NOT be wrapped in an "argo-cd:" key.
  if grep -q '^argo-cd:' "${GITOPS_DIR}/bootstrap/argocd-install-values.yaml"; then
    die "bootstrap/argocd-install-values.yaml still starts with 'argo-cd:'. Remove that line and un-indent (see launch plan, phase 0.4)."
  fi

  # State bucket from the bootstrap step.
  local bucket
  bucket="$(grep -E '^\s*bucket\s*=' "${TF_DIR}/backend.tfbackend" | head -1 | cut -d'"' -f2)"
  [[ -n "${bucket}" ]] || die "Could not read the bucket name from backend.tfbackend"
  aws s3api head-bucket --bucket "${bucket}" >/dev/null 2>&1 \
    || die "State bucket '${bucket}' does not exist. Run bootstrap/tf-state first."
  # The EC2 Spot service-linked role belongs to the whole AWS account, so
  # Terraform must not own it. Create it only if it is missing.
  aws iam get-role --role-name AWSServiceRoleForEC2Spot >/dev/null 2>&1 \
    || aws iam create-service-linked-role --aws-service-name spot.amazonaws.com >/dev/null

  # Route53 zone, and Hostinger pointing at it.
  local zone_line zone_id zone_name
  zone_line="$(aws route53 list-hosted-zones-by-name --dns-name "${DOMAIN}" \
    --query 'HostedZones[0].[Id,Name]' --output text)"
  zone_id="$(awk '{print $1}' <<<"${zone_line}")"; zone_id="${zone_id##*/}"
  zone_name="$(awk '{print $2}' <<<"${zone_line}")"
  [[ "${zone_name}" == "${DOMAIN}." ]] \
    || die "No Route53 hosted zone for ${DOMAIN}. Create it first (launch plan, phase 2)."

  if command -v dig >/dev/null; then
    local aws_ns live_ns
    aws_ns="$(aws route53 get-hosted-zone --id "${zone_id}" \
      --query 'DelegationSet.NameServers' --output text | tr '\t' '\n' | sort)"
    live_ns="$(dig +short NS "${DOMAIN}" | sed 's/\.$//' | sort)"
    if [[ -z "$(comm -12 <(echo "${aws_ns}") <(echo "${live_ns}"))" ]]; then
      printf 'Route53 nameservers for this zone:\n%s\n' "${aws_ns}"
      die "The nameservers at Hostinger do not match this Route53 zone (the certificate would time out). Update them, wait for 'dig NS ${DOMAIN} +short' to show them, then retry."
    fi
  else
    warn "'dig' not found, skipping the nameserver check."
  fi

  if [[ "${ASSUME_YES}" != "1" ]]; then
    echo
    echo "This creates billable AWS resources (about 6-8 USD per day while running)."
    read -rp "Continue? (yes/no): " answer
    [[ "${answer}" == "yes" ]] || { echo "Cancelled."; exit 0; }
  fi
}

# ---------------------------------------------------------------------------
# network: VPC + NAT instance
# ---------------------------------------------------------------------------
step_network() {
  log "terraform init"
  tf init -backend-config=backend.tfbackend -input=false

  log "Stage 1/3: VPC and NAT instance"
  tf apply -auto-approve -input=false -target=module.vpc -target=module.fck_nat
}

# ---------------------------------------------------------------------------
# nat: do not build the cluster on a NAT that does not work
# ---------------------------------------------------------------------------
step_nat() {
  log "Waiting for the NAT instance"
  local asg="${CLUSTER_NAME}-fck-nat" id="" i
  for i in $(seq 1 40); do
    id="$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "${asg}" \
      --query 'AutoScalingGroups[0].Instances[?LifecycleState==`InService`].InstanceId | [0]' \
      --output text 2>/dev/null || true)"
    [[ -n "${id}" && "${id}" != "None" ]] && break
    echo "  no running NAT instance yet (${i}/40)..."
    sleep 15
  done
  [[ -n "${id}" && "${id}" != "None" ]] \
    || die "The NAT instance never started. Look at: aws autoscaling describe-scaling-activities --auto-scaling-group-name ${asg}"

  aws ec2 wait instance-status-ok --instance-ids "${id}"
  echo "NAT instance ${id} is up."

  # Safe and repeatable: a NAT must have the source/destination check OFF on
  # every network card.
  local eni
  for eni in $(aws ec2 describe-instances --instance-ids "${id}" \
      --query 'Reservations[0].Instances[0].NetworkInterfaces[].NetworkInterfaceId' --output text); do
    aws ec2 modify-network-interface-attribute --network-interface-id "${eni}" --no-source-dest-check
    echo "  source/dest check off on ${eni}"
  done

  # No private route may point at a dead NAT.
  local vpc_id blackholes
  vpc_id="$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=${CLUSTER_NAME}-vpc" \
    --query 'Vpcs[0].VpcId' --output text)"
  blackholes="$(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=${vpc_id}" \
    --query 'length(RouteTables[].Routes[?State==`blackhole`][])' --output text)"
  [[ "${blackholes}" == "0" ]] || die "${blackholes} route(s) point at a dead target (blackhole) in ${vpc_id}."
  echo "Routes look healthy."
}

# ---------------------------------------------------------------------------
# cluster: IAM roles + EKS, then everything else
# ---------------------------------------------------------------------------
step_cluster() {
  log "Stage 2/3: cluster, both storage IAM roles, node groups, add-ons (about 15 min)"
  tf apply -auto-approve -input=false \
    -target=module.ebs_csi_irsa -target=module.efs_csi_irsa -target=module.eks

  log "Stage 3/3: everything else (about 5-10 min)"
  tf apply -auto-approve -input=false
}

# ---------------------------------------------------------------------------
# kubeconfig: connect and check the cluster is really healthy
# ---------------------------------------------------------------------------
step_kubeconfig() {
  log "Connecting kubectl"
  aws eks update-kubeconfig --region "${AWS_REGION}" --name "${CLUSTER_NAME}"

  log "Waiting for nodes to be Ready"
  kubectl wait --for=condition=Ready node --all --timeout=600s
  kubectl get nodes

  log "Waiting for the EBS storage add-on to be ACTIVE"
  local st="" i
  for i in $(seq 1 40); do
    st="$(aws eks describe-addon --cluster-name "${CLUSTER_NAME}" --addon-name aws-ebs-csi-driver \
      --query addon.status --output text 2>/dev/null || true)"
    [[ "${st}" == "ACTIVE" ]] && break
    echo "  add-on status: ${st:-unknown} (${i}/40)..."
    sleep 15
  done
  [[ "${st}" == "ACTIVE" ]] \
    || die "The EBS add-on is not ACTIVE. Check: kubectl logs -n kube-system deploy/ebs-csi-controller -c ebs-plugin --tail=30"
}

# ---------------------------------------------------------------------------
# cert: the ARN changes on every rebuild, so it has to go back into git
# ---------------------------------------------------------------------------
step_cert() {
  log "Putting the new ACM certificate ARN into the gitops repo"
  local arn file rel="manifests/gateway-api/envoyproxy.yaml"
  arn="$(tf output -raw acm_certificate_arn)"
  file="${GITOPS_DIR}/${rel}"
  [[ -f "${file}" ]] || die "Not found: ${file}"

  git -C "${GITOPS_DIR}" pull --ff-only
  sed -i -E "s#arn:aws:acm:[a-z0-9-]+:[0-9]+:certificate/[0-9a-f-]+#${arn}#" "${file}"

  if ! git -C "${GITOPS_DIR}" diff --quiet -- "${rel}"; then
    git -C "${GITOPS_DIR}" add "${rel}"
    git -C "${GITOPS_DIR}" commit -m "chore: set ACM certificate ARN for the new cluster"
  fi

  [[ "$(git -C "${GITOPS_DIR}" branch --show-current)" == "main" ]] \
    || die "The gitops repo is not on the 'main' branch."

  # Push anything GitHub does not have yet. This also covers a commit left
  # over from an earlier run whose push failed.
  git -C "${GITOPS_DIR}" fetch origin main
  if [[ -n "$(git -C "${GITOPS_DIR}" log origin/main..HEAD --oneline)" ]]; then
    git -C "${GITOPS_DIR}" push origin main
  fi

  git -C "${GITOPS_DIR}" show "origin/main:${rel}" | grep -q "${arn}" \
    || die "GitHub does not have the new certificate ARN yet."
  grep ssl-cert "${file}"
}

# ---------------------------------------------------------------------------
# argocd
# ---------------------------------------------------------------------------
step_argocd() {
  log "Installing ArgoCD"
  kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
  helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
  helm repo update argo >/dev/null
  helm upgrade --install argocd argo/argo-cd -n argocd \
    -f "${GITOPS_DIR}/bootstrap/argocd-install-values.yaml" \
    --version "${ARGOCD_CHART_VERSION}"
  kubectl rollout status deployment/argocd-server -n argocd --timeout=300s

  log "Applying the root app (ArgoCD takes over from here)"
  kubectl apply -f "${GITOPS_DIR}/apps/root.yaml"
  sleep 10
  kubectl get applications -n argocd
}

# ---------------------------------------------------------------------------
# dns
# ---------------------------------------------------------------------------
step_dns() {
  log "Waiting for the load balancer address (ArgoCD must sync the first waves, 5-15 min)"
  local addr="" i
  for i in $(seq 1 90); do
    addr="$(kubectl get gateway observability-gateway -n observability \
      -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || true)"
    [[ -n "${addr}" ]] && break
    echo "  no address yet (${i}/90)..."
    sleep 20
  done
  [[ -n "${addr}" ]] || die "The Gateway never got an address. See: kubectl get applications -n argocd"
  echo "Load balancer: ${addr}"

  log "Pointing *.monitoring.${DOMAIN} at it"
  "${REPO_ROOT}/scripts/update-dns.sh"
}

# ---------------------------------------------------------------------------
# verify
# ---------------------------------------------------------------------------
step_verify() {
  log "Waiting for Grafana to answer (it arrives in a late sync wave, up to 30 min)"
  local code="" i
  for i in $(seq 1 90); do
    code="$(curl -sS -m 10 -o /dev/null -w '%{http_code}' \
      "https://grafana.monitoring.${DOMAIN}/login" 2>/dev/null || true)"
    [[ "${code}" == "200" ]] && break
    echo "  grafana: ${code:-no answer} (${i}/90)..."
    sleep 20
  done

  echo
  echo "Applications that are not Synced + Healthy yet:"
  kubectl get applications -n argocd --no-headers 2>/dev/null \
    | awk '$2!="Synced" || $3!="Healthy"' || true

  echo
  if [[ "${code}" == "200" ]]; then
    log "Grafana is up"
  else
    warn "Grafana did not return 200 in time (last answer: ${code:-none}). Check the applications above."
  fi

  cat <<EOF

Grafana:    https://grafana.monitoring.${DOMAIN}   (user: admin, password from terraform.tfvars)
ArgoCD:     https://argocd.monitoring.${DOMAIN}    (user: admin)
  password: kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
Prometheus: https://prometheus.monitoring.${DOMAIN} (user: alloy, remote-write password)

Next: Phase 8 checks, then the demo spoke. When you are done for the day:
  ./scripts/cluster-shutdown.sh
EOF
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --from)   FROM="${2:?--from needs a step name}"; shift 2 ;;
    -y|--yes) ASSUME_YES=1; shift ;;
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
    "step_${s}"
  fi
done

log "Done."
