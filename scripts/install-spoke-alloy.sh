#!/usr/bin/env bash
# Install Grafana Alloy on a spoke cluster and point it at the hub.
#
# Usage:
#   ./scripts/install-spoke-alloy.sh <spoke-name>
#
# Reads the remote-write password from AWS Secrets Manager (observability/remote-write-basic-auth)
# and creates a Kubernetes Secret so the Alloy values file can pull it via envFrom.
#
# Prerequisites:
#   - kubectl configured for the spoke cluster
#   - aws CLI configured with read access to observability/remote-write-basic-auth
#   - helm CLI

set -euo pipefail

SPOKE_NAME="${1:?Usage: $0 <spoke-name>}"
NAMESPACE="${ALLOY_NAMESPACE:-eks-observability}"
AWS_REGION="${AWS_REGION:-eu-central-1}"
AWS_PROFILE="${AWS_PROFILE:-default}"
ALLOY_CHART_VERSION="${ALLOY_CHART_VERSION:-1.5.0}"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VALUES_FILE="${REPO_ROOT}/spoke-alloy-values/${SPOKE_NAME}/alloy-values.yaml"

if [[ ! -f "${VALUES_FILE}" ]]; then
  echo "ERROR: No Alloy values file at ${VALUES_FILE}"
  echo "Create one (copy from spoke-alloy-values/demo-spoke/alloy-values.yaml) and try again."
  exit 1
fi

echo "==> Reading remote-write credentials from AWS Secrets Manager..."
SECRET_JSON=$(aws secretsmanager get-secret-value \
  --secret-id observability/remote-write-basic-auth \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --query SecretString \
  --output text)

REMOTE_WRITE_USER=$(echo "${SECRET_JSON}" | jq -r '.username')
REMOTE_WRITE_PASSWORD=$(echo "${SECRET_JSON}" | jq -r '.password')

echo "==> Ensuring namespace ${NAMESPACE} exists..."
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

echo "==> Creating/updating alloy-remote-write-credentials secret..."
kubectl create secret generic alloy-remote-write-credentials \
  --namespace "${NAMESPACE}" \
  --from-literal=REMOTE_WRITE_USER="${REMOTE_WRITE_USER}" \
  --from-literal=REMOTE_WRITE_PASSWORD="${REMOTE_WRITE_PASSWORD}" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "==> Installing/upgrading Grafana Alloy..."
helm repo add grafana https://grafana.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update >/dev/null

helm upgrade --install alloy grafana/alloy \
  --namespace "${NAMESPACE}" \
  --version "${ALLOY_CHART_VERSION}" \
  --values "${VALUES_FILE}" \
  --wait

echo
echo "==> Done. Verify with:"
echo "    kubectl get pods -n ${NAMESPACE}"
echo "    kubectl logs -n ${NAMESPACE} -l app.kubernetes.io/name=alloy --tail=50"
echo
echo "Then in the hub Grafana, run: up{cluster=\"${SPOKE_NAME}\"}"
