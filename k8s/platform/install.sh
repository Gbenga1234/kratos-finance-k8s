#!/usr/bin/env bash
# Installs cluster platform services: Redis and SigNoz (+ k8s-infra collectors).
# Run against the target cluster: kubectl config current-context
set -euo pipefail

cd "$(dirname "$0")"

SIGNOZ_CHART_VERSION="0.145.0"
K8S_INFRA_CHART_VERSION="0.17.1"

echo "==> Redis"
kubectl apply -k redis
kubectl -n redis rollout status statefulset/redis --timeout=5m

echo "==> SigNoz"
helm repo add signoz https://charts.signoz.io >/dev/null 2>&1 || true
helm repo update signoz

helm upgrade --install signoz signoz/signoz \
  --namespace signoz --create-namespace \
  --version "$SIGNOZ_CHART_VERSION" \
  -f signoz/values.yaml \
  --wait --timeout 15m

helm upgrade --install k8s-infra signoz/k8s-infra \
  --namespace signoz \
  --version "$K8S_INFRA_CHART_VERSION" \
  -f signoz/k8s-infra-values.yaml \
  --wait --timeout 10m

echo "Done. SigNoz UI: https://signoz.example.com (or: kubectl -n signoz port-forward svc/signoz 8080:8080)"
