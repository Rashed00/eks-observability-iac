#!/usr/bin/env bash
# Scale the observability cluster down to near-zero cost for off-hours.
#
# Order matters:
#   1. Disable ArgoCD auto-sync (so it won't fight the scale-down).
#   2. Scale workloads to zero in the observability + envoy-gateway + argocd namespaces.
#   3. Delete Karpenter NodeClaims while Karpenter is still running.
#   4. Scale the observability managed node group to zero.
#
# EBS volumes and S3 data are preserved. The control plane keeps running
# (~0.10 USD/hour). To bring everything back: ./cluster-startup.sh

set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-observability-cluster}"
AWS_REGION="${AWS_REGION:-eu-central-1}"
AWS_PROFILE="${AWS_PROFILE:-default}"
NAMESPACE_OBS="${NAMESPACE_OBS:-observability}"

# Discover the observability node group name (must match a name prefix in eks.tf).
NODEGROUP_NAME="$(aws eks list-nodegroups \
  --cluster-name "${CLUSTER_NAME}" \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --query 'nodegroups[?starts_with(@,`observability-ng`)] | [0]' \
  --output text)"

if [[ -z "${NODEGROUP_NAME}" || "${NODEGROUP_NAME}" == "None" ]]; then
  echo "ERROR: Could not find the observability node group on cluster ${CLUSTER_NAME}"
  exit 1
fi

echo "Cluster:        ${CLUSTER_NAME}"
echo "Node group:     ${NODEGROUP_NAME}"
echo
read -rp "Are you sure you want to shut down the cluster? (yes/no): " confirm
[[ "${confirm}" == "yes" ]] || { echo "Cancelled."; exit 0; }

echo "==> [1/4] Disabling ArgoCD auto-sync on every Application..."
for app in $(kubectl get applications -n argocd -o jsonpath='{.items[*].metadata.name}'); do
  kubectl patch application "${app}" -n argocd --type=merge \
    -p '{"spec":{"syncPolicy":{"automated":null}}}' || true
done

echo "==> [2/4] Scaling observability + argocd + envoy-gateway workloads to zero..."
for ns in "${NAMESPACE_OBS}" argocd envoy-gateway-system; do
  kubectl get deployments  -n "${ns}" -o name 2>/dev/null | xargs -I{} kubectl scale {} -n "${ns}" --replicas=0 || true
  kubectl get statefulsets -n "${ns}" -o name 2>/dev/null | xargs -I{} kubectl scale {} -n "${ns}" --replicas=0 || true
  # Pause DaemonSets by adding a node selector that matches nothing.
  kubectl get daemonsets -n "${ns}" -o name 2>/dev/null | while read -r ds; do
    kubectl patch "${ds}" -n "${ns}" \
      -p '{"spec":{"template":{"spec":{"nodeSelector":{"shutdown":"true"}}}}}' || true
  done
done

echo "==> [3/4] Deleting Karpenter NodeClaims (Karpenter must still be running)..."
kubectl delete nodeclaims --all --wait=false || true

echo "    Waiting up to 3 minutes for Karpenter to terminate spot nodes..."
end=$((SECONDS + 180))
while [[ $SECONDS -lt $end ]]; do
  remaining=$(kubectl get nodeclaims --no-headers 2>/dev/null | wc -l | tr -d ' ')
  [[ "${remaining}" == "0" ]] && break
  sleep 5
done

echo "==> [4/4] Scaling managed node group to 0..."
aws eks update-nodegroup-config \
  --cluster-name "${CLUSTER_NAME}" \
  --nodegroup-name "${NODEGROUP_NAME}" \
  --scaling-config minSize=0,maxSize=4,desiredSize=0 \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" >/dev/null

echo
echo "Done. Costs while shut down:"
echo "  EKS control plane: ~0.10 USD/hour"
echo "  EBS volumes:       ~0.02 USD/hour"
echo "  EC2 nodes:         0 USD"
echo
echo "To bring the cluster back up: ./cluster-startup.sh"
