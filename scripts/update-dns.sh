#!/usr/bin/env bash
# After ArgoCD deploys the Envoy Gateway and AWS provisions the NLB, this
# script writes the Route53 wildcard CNAME pointing at the NLB hostname.
#
# We do not create the Route53 record from Terraform because the NLB does not
# exist at `terraform apply` time - it's provisioned by the in-cluster AWS Load
# Balancer Controller after ArgoCD syncs the Envoy Gateway Service.

set -euo pipefail

cd "$(dirname "$0")/../environments/production"

ZONE_ID="$(terraform output -raw route53_zone_id)"
OBS_DOMAIN="$(terraform output -raw observability_domain)"

echo "==> Resolving Envoy Gateway NLB hostname..."
NLB_HOSTNAME="$(kubectl get gateway observability-gateway -n observability \
  -o jsonpath='{.status.addresses[0].value}')"

if [[ -z "${NLB_HOSTNAME}" ]]; then
  echo "ERROR: Gateway has no address yet. Wait for ArgoCD to sync envoy-gateway."
  exit 1
fi

echo "    Wildcard: *.${OBS_DOMAIN}"
echo "    Target:   ${NLB_HOSTNAME}"

CHANGE_BATCH="$(cat <<EOF
{
  "Changes": [
    {
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "*.${OBS_DOMAIN}",
        "Type": "CNAME",
        "TTL": 300,
        "ResourceRecords": [{"Value": "${NLB_HOSTNAME}"}]
      }
    }
  ]
}
EOF
)"

aws route53 change-resource-record-sets \
  --hosted-zone-id "${ZONE_ID}" \
  --change-batch "${CHANGE_BATCH}" \
  --profile "${AWS_PROFILE:-default}" >/dev/null

echo "==> Done. DNS may take a few minutes to propagate."
