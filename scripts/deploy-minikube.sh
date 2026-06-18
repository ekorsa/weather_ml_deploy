#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# deploy-minikube.sh — full local deploy of weather-ml on minikube
#
# Usage:
#   ./scripts/deploy-minikube.sh              # deploy app only
#   ./scripts/deploy-minikube.sh --with-prometheus   # deploy app + Prometheus stack
#   ./scripts/deploy-minikube.sh --teardown   # remove everything
#
# Run from the repo root:
#   cd weather_ml_deploy && ./scripts/deploy-minikube.sh
# ─────────────────────────────────────────────────────────────────────────────

NAMESPACE="weather-ml"
RELEASE="weather-ml"
CHART="./helm/weather-ml"
SOURCE_DIR="../weather_ml"
HOST="weather-ml.local"
MONITORING_NS="monitoring"
POSTGRES_PASSWORD="testpass"

WITH_PROMETHEUS=false
TEARDOWN=false

for arg in "$@"; do
  case $arg in
    --with-prometheus) WITH_PROMETHEUS=true ;;
    --teardown)        TEARDOWN=true ;;
  esac
done

# ── Helpers ───────────────────────────────────────────────────────────────────

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

info()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()     { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
section() { echo -e "\n${GREEN}══ $* ══${NC}"; }

require() {
  command -v "$1" &>/dev/null || err "'$1' not found. Install it and retry."
}

# ── Teardown ──────────────────────────────────────────────────────────────────

if $TEARDOWN; then
  section "Teardown"
  helm uninstall "$RELEASE" -n "$NAMESPACE" 2>/dev/null && info "Removed helm release $RELEASE" || warn "$RELEASE not installed"
  helm uninstall kube-prometheus-stack -n "$MONITORING_NS" 2>/dev/null && info "Removed kube-prometheus-stack" || true
  kubectl delete namespace "$NAMESPACE" --ignore-not-found
  kubectl delete namespace "$MONITORING_NS" --ignore-not-found
  info "Removing /etc/hosts entry for $HOST"
  sudo sed -i "/$HOST/d" /etc/hosts
  info "Done. Run 'minikube stop' to shut down the cluster."
  exit 0
fi

# ── Prerequisites ─────────────────────────────────────────────────────────────

section "Checking prerequisites"
require minikube
require kubectl
require helm
require docker

[ -d "$SOURCE_DIR" ] || err "Source repo not found at $SOURCE_DIR. Clone weather_ml next to this repo."
[ -f "$CHART/Chart.yaml" ] || err "Helm chart not found at $CHART. Run from the repo root."

info "All prerequisites present."

# ── Start minikube ────────────────────────────────────────────────────────────

section "Starting minikube"
if minikube status | grep -q "Running"; then
  info "minikube is already running."
else
  minikube start --memory=4096 --cpus=2
  info "minikube started."
fi

info "Enabling ingress addon..."
minikube addons enable ingress

# ── Build images ──────────────────────────────────────────────────────────────

section "Building Docker images inside minikube"
info "Switching Docker context to minikube daemon..."
eval "$(minikube docker-env)"

info "Building api:latest..."
docker build -f "$SOURCE_DIR/Dockerfile.api" -t api:latest "$SOURCE_DIR"

info "Building ml:latest..."
docker build -f "$SOURCE_DIR/Dockerfile.ml"  -t ml:latest  "$SOURCE_DIR"

# ── Pull Bitnami images ───────────────────────────────────────────────────────

section "Pulling Bitnami images into minikube"
info "Pulling bitnami/postgresql:latest..."
docker pull bitnami/postgresql:latest

info "Pulling bitnami/redis:latest..."
docker pull bitnami/redis:latest

# ── Helm dependencies ─────────────────────────────────────────────────────────

section "Setting up Helm chart dependencies"
helm repo add bitnami https://charts.bitnami.com/bitnami 2>/dev/null || true
helm repo update
helm dependency update "$CHART"

# ── Deploy app ────────────────────────────────────────────────────────────────

section "Deploying weather-ml"
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

helm upgrade --install "$RELEASE" "$CHART" \
  --namespace "$NAMESPACE" \
  --values "$CHART/values.yaml" \
  --values "$CHART/values-minikube.yaml" \
  --set image.registry="" \
  --set image.pullPolicy=Never \
  --set secrets.postgresPassword="$POSTGRES_PASSWORD" \
  --set postgresql.auth.password="$POSTGRES_PASSWORD"

# ── DNS ───────────────────────────────────────────────────────────────────────

section "Configuring DNS"
MINIKUBE_IP="$(minikube ip)"
if grep -q "$HOST" /etc/hosts; then
  warn "/etc/hosts already has an entry for $HOST — skipping."
else
  echo "$MINIKUBE_IP $HOST" | sudo tee -a /etc/hosts
  info "Added: $MINIKUBE_IP $HOST"
fi

# ── Wait for pods ─────────────────────────────────────────────────────────────

section "Waiting for pods to become ready"
info "This may take 2-3 minutes on first run (image pulls)..."
kubectl rollout status deployment/"$RELEASE-api" -n "$NAMESPACE" --timeout=180s
kubectl wait pod \
  --for=condition=ready \
  --selector=app.kubernetes.io/instance="$RELEASE" \
  --namespace="$NAMESPACE" \
  --timeout=180s
info "All pods are ready."

# ── Verify API ────────────────────────────────────────────────────────────────

section "Verifying API"
sleep 3
HTTP=$(curl -s -o /dev/null -w "%{http_code}" "http://$HOST/" || true)
if [ "$HTTP" = "200" ]; then
  info "API root endpoint OK (HTTP 200)"
else
  warn "API returned HTTP $HTTP — ingress may still be initialising. Try: curl http://$HOST/"
fi

# ── Run ML pipeline ───────────────────────────────────────────────────────────

section "Running ML pipeline (fetch → train → predict)"

info "Step 1/3: fetch_weather.py — pulling data from Open-Meteo into Redis..."
kubectl delete job fetch-init -n "$NAMESPACE" --ignore-not-found
kubectl create job --from=cronjob/"$RELEASE-fetch" fetch-init -n "$NAMESPACE"
kubectl wait --for=condition=complete job/fetch-init -n "$NAMESPACE" --timeout=60s
info "fetch complete."
kubectl logs -n "$NAMESPACE" -l job-name=fetch-init --tail=5

info "Step 2/3: train.py — training model and saving to PVC..."
kubectl delete job train-init -n "$NAMESPACE" --ignore-not-found
kubectl create job --from=cronjob/"$RELEASE-train" train-init -n "$NAMESPACE"
kubectl wait --for=condition=complete job/train-init -n "$NAMESPACE" --timeout=120s
info "train complete."
kubectl logs -n "$NAMESPACE" -l job-name=train-init --tail=5

info "Step 3/3: predict.py — predicting and saving to PostgreSQL..."
kubectl delete job predict-init -n "$NAMESPACE" --ignore-not-found
kubectl create job --from=cronjob/"$RELEASE-predict" predict-init -n "$NAMESPACE"
kubectl wait --for=condition=complete job/predict-init -n "$NAMESPACE" --timeout=60s
info "predict complete."
kubectl logs -n "$NAMESPACE" -l job-name=predict-init --tail=5

# ── End-to-end check ──────────────────────────────────────────────────────────

section "End-to-end verification"
PREDICTIONS=$(curl -s "http://$HOST/predictions")
if echo "$PREDICTIONS" | grep -q "prediction"; then
  info "Predictions endpoint returned data:"
  echo "$PREDICTIONS" | python3 -m json.tool 2>/dev/null || echo "$PREDICTIONS"
else
  warn "Predictions endpoint returned: $PREDICTIONS"
  warn "Run: kubectl logs -n $NAMESPACE -l job-name=predict-init"
fi

# ── Prometheus (optional) ─────────────────────────────────────────────────────

if $WITH_PROMETHEUS; then
  section "Installing Prometheus + Grafana (kube-prometheus-stack)"

  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
  helm repo update

  helm upgrade --install kube-prometheus-stack \
    prometheus-community/kube-prometheus-stack \
    --namespace "$MONITORING_NS" --create-namespace \
    --values monitoring/kube-prometheus-stack-values.yaml \
    --set grafana.adminPassword=admin \
    --set prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.storageClassName=standard \
    --set prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.resources.requests.storage=2Gi

  info "Waiting for Prometheus and Grafana pods (~2 min)..."
  kubectl wait pod \
    --for=condition=ready \
    --selector=app.kubernetes.io/instance=kube-prometheus-stack \
    --namespace="$MONITORING_NS" \
    --timeout=300s

  info "Enabling ServiceMonitors in weather-ml..."
  helm upgrade "$RELEASE" "$CHART" \
    --namespace "$NAMESPACE" \
    --reuse-values \
    --set monitoring.serviceMonitor.enabled=true

  info "kube-prometheus-stack ready."
fi

# ── Summary ───────────────────────────────────────────────────────────────────

section "Deployment complete"

echo ""
echo -e "  API:          ${GREEN}http://$HOST/${NC}"
echo -e "  Predictions:  ${GREEN}http://$HOST/predictions${NC}"
echo -e "  API metrics:  ${GREEN}http://$HOST/metrics${NC}"
echo ""
echo "  kubectl get pods -n $NAMESPACE"
echo ""

if $WITH_PROMETHEUS; then
  echo "  Prometheus (port-forward first):"
  echo "    kubectl port-forward svc/kube-prometheus-stack-prometheus 9090:9090 -n $MONITORING_NS &"
  echo -e "    ${GREEN}http://localhost:9090${NC}  →  query: ml_prediction_value"
  echo ""
  echo "  Grafana (port-forward first):"
  echo "    kubectl port-forward svc/kube-prometheus-stack-grafana 3000:80 -n $MONITORING_NS &"
  echo -e "    ${GREEN}http://localhost:3000${NC}  →  admin / admin"
  echo ""
fi

echo "  Teardown:"
echo "    ./scripts/deploy-minikube.sh --teardown"
echo ""
