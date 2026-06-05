#!/usr/bin/env bash
# Bring the observability cluster back up after ./cluster-shutdown.sh
#
# Order matters:
#   1. Scale the managed node group back up so Karpenter has a node to land on.
#   2. Wait for managed nodes Ready.
#   3. Un-pause DaemonSets (remove the fake node selector).
#   4. Scale ArgoCD + Envoy back up.
#   5. Re-enable ArgoCD auto-sync (it restores every other workload).

set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-observability-cluster}"
AWS_REGION="${AWS_REGION:-eu-central-1}"
AWS_PROFILE="${AWS_PROFILE:-default}"
NAMESPACE_OBS="${NAMESPACE_OBS:-observability}"
NODEGROUP_DESIRED="${NODEGROUP_DESIRED:-2}"

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

echo "==> [1/5] Scaling node group ${NODEGROUP_NAME} to desired=${NODEGROUP_DESIRED}..."
aws eks update-nodegroup-config \
  --cluster-name "${CLUSTER_NAME}" \
  --nodegroup-name "${NODEGROUP_NAME}" \
  --scaling-config "minSize=0,maxSize=4,desiredSize=${NODEGROUP_DESIRED}" \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" >/dev/null

echo "==> [2/5] Waiting for managed nodes to be Ready..."
end=$((SECONDS + 300))
while [[ $SECONDS -lt $end ]]; do
  ready=$(kubectl get nodes --no-headers 2>/dev/null | grep -c -v NotReady || true)
  [[ "${ready}" -ge "${NODEGROUP_DESIRED}" ]] && break
  sleep 10
done
echo "    ${ready:-0} nodes Ready"

echo "==> [3/5] Restoring DaemonSets (removing the shutdown nodeSelector)..."
for ns in "${NAMESPACE_OBS}" argocd envoy-gateway-system; do
  kubectl get daemonsets -n "${ns}" -o name 2>/dev/null | while read -r ds; do
    kubectl patch "${ds}" -n "${ns}" --type=json \
      -p='[{"op":"remove","path":"/spec/template/spec/nodeSelector/shutdown"}]' 2>/dev/null || true
  done
done

echo "==> [4/5] Scaling ArgoCD + Envoy Gateway back up..."
kubectl scale deployment  -n argocd --all --replicas=1 || true
kubectl scale statefulset -n argocd --all --replicas=1 || true
kubectl scale deployment  -n envoy-gateway-system --all --replicas=1 || true

echo "    Waiting for ArgoCD server..."
kubectl wait --for=condition=available deployment/argocd-server -n argocd --timeout=300s || true

echo "==> [5/5] Re-enabling ArgoCD auto-sync on every Application..."
for app in $(kubectl get applications -n argocd -o jsonpath='{.items[*].metadata.name}'); do
  kubectl patch application "${app}" -n argocd --type=merge \
    -p '{"spec":{"syncPolicy":{"automated":{"prune":false,"selfHeal":true,"allowEmpty":false}}}}' || true
done

echo
echo "Done. Karpenter will spin up additional spot nodes as workloads come back."
echo "Watch progress with:"
echo "  watch kubectl get applications -n argocd"
echo "  watch kubectl get pods -n ${NAMESPACE_OBS}"
