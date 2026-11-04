#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# deploy-minikube.sh — full local deploy of weather-ml on minikube
#
# Usage:
#   ./scripts/deploy-minikube.sh              # deploy app only
#   ./scripts/deploy-minikube.sh --with-prometheus   # deploy app + Prometheus stack
#   ./scripts/deploy-minikube.sh --status     # only print the final summary (no deploy)
#   ./scripts/deploy-minikube.sh --teardown   # remove everything
#
# Run from the repo root:
#   cd weather_ml_deploy && ./scripts/deploy-minikube.sh
#
# Runs in a dedicated minikube profile (default: weather-ml), isolated from
# other clusters. Override: PROFILE=my-profile ./scripts/deploy-minikube.sh
# ─────────────────────────────────────────────────────────────────────────────

PROFILE="${PROFILE:-weather-ml}"
NAMESPACE="weather-ml"
RELEASE="weather-ml"
CHART="./helm/weather-ml"
SOURCE_DIR="../weather_ml"
HOST="weather-ml.local"
MONITORING_NS="monitoring"
POSTGRES_PASSWORD="testpass"

WITH_PROMETHEUS=false
TEARDOWN=false
STATUS_ONLY=false

for arg in "$@"; do
  case $arg in
    --with-prometheus) WITH_PROMETHEUS=true ;;
    --teardown)        TEARDOWN=true ;;
    --status)          STATUS_ONLY=true ;;
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

# Pin every call to the profile's cluster, regardless of the current kube context.
minikube() { command minikube -p "$PROFILE" "$@"; }
kubectl()  { command kubectl --context "$PROFILE" "$@"; }
helm()     { command helm --kube-context "$PROFILE" "$@"; }

indent() { sed 's/^/    /'; }

HOSTPATH_ROOT="/tmp/hostpath-provisioner"

released_pvs_of() {
  kubectl get pv -o jsonpath='{range .items[*]}{.metadata.name} {.spec.claimRef.namespace} {.status.phase}{"\n"}{end}' \
    | awk -v ns="$1" '$2 == ns && $3 == "Released" { print $1 }'
}

# minikube's hostpath provisioner skips deleting PVs it created before its own
# restart ("identity annotation does not match"), and new PVCs reuse the same
# <ns>/<pvc> directories — so old data survives teardown unless removed here.
purge_volumes() {
  local ns="$1" pvs
  pvs=$(released_pvs_of "$ns")
  if [ -n "$pvs" ]; then
    # shellcheck disable=SC2086  # word splitting of PV names is intended
    kubectl delete pv $pvs
  fi
  minikube ssh -- sudo rm -rf "$HOSTPATH_ROOT/$ns" && info "Removed volume data for namespace $ns"
}

remove_hosts_entry() {
  grep -q "$HOST" /etc/hosts || return 0
  if sudo -n sed -i "/$HOST/d" /etc/hosts 2>/dev/null; then
    info "Removed /etc/hosts entry for $HOST"
  else
    warn "No passwordless sudo — remove manually: sudo sed -i '/$HOST/d' /etc/hosts"
  fi
}

# Lists routes from FastAPI's OpenAPI schema, so new endpoints show up automatically.
print_api_endpoints() {
  curl -sf "http://$HOST/openapi.json" | python3 -c '
import json, sys
for path, ops in json.load(sys.stdin)["paths"].items():
    for method, op in ops.items():
        print(method.upper().ljust(7) + path.ljust(15) + op.get("summary", ""))
' | indent || warn "Could not read http://$HOST/openapi.json"
}

print_predictions() {
  curl -sf "http://$HOST/predictions" | python3 -m json.tool | indent \
    || warn "Could not read http://$HOST/predictions"
}

# Final usage info: live endpoints, jobs, predictions, and handy commands.
print_summary() {
  echo ""
  echo -e "  API endpoints (${GREEN}http://$HOST${NC}):"
  print_api_endpoints
  echo -e "    Swagger UI: ${GREEN}http://$HOST/docs${NC}"
  echo "  ($HOST resolves only on this machine; from another host use the port-forward below)"
  echo ""
  echo "  ML jobs (schedule in UTC):"
  kubectl get cronjobs,jobs -n "$NAMESPACE" 2>&1 | indent
  echo ""
  echo "  Predictions (curl http://$HOST/predictions):"
  print_predictions
  echo ""

  K="kubectl --context $PROFILE -n $NAMESPACE"

  echo "  Status and logs:"
  echo "    $K get pods,cronjobs,jobs"
  echo "    $K logs deploy/$RELEASE-api"
  echo "    $K logs job/<job-name>"
  echo ""
  echo "  Run a job now (fetch fresh data → retrain → new prediction):"
  for job in fetch train predict; do
    echo "    $K create job --from=cronjob/$RELEASE-$job $job-\$(date +%s)"
  done
  echo "    curl http://$HOST/predictions"
  echo ""
  echo "  New prediction via API (no job needed):"
  echo "    curl -X POST http://$HOST/predict"
  echo ""
  echo "  Access from another machine:"
  echo "    $K port-forward --address 0.0.0.0 svc/$RELEASE-api 8000:8000"
  echo "    curl http://<this-host-ip>:8000/predictions"
  echo ""
  echo "  Cluster (profile $PROFILE):"
  echo "    minikube stop -p $PROFILE    # stop, keeps data"
  echo "    minikube start -p $PROFILE   # start again"
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
}

# ── Teardown ──────────────────────────────────────────────────────────────────

if $TEARDOWN; then
  section "Teardown"
  helm uninstall "$RELEASE" -n "$NAMESPACE" 2>/dev/null && info "Removed helm release $RELEASE" || warn "$RELEASE not installed"
  helm uninstall kube-prometheus-stack -n "$MONITORING_NS" 2>/dev/null && info "Removed kube-prometheus-stack" || true
  kubectl delete namespace "$NAMESPACE" --ignore-not-found
  kubectl delete namespace "$MONITORING_NS" --ignore-not-found
  for ns in "$NAMESPACE" "$MONITORING_NS"; do
    purge_volumes "$ns"
  done
  remove_hosts_entry
  info "Done. Run 'minikube stop -p $PROFILE' to shut down the cluster."
  exit 0
fi

# ── Status only ───────────────────────────────────────────────────────────────

if $STATUS_ONLY; then
  minikube status &>/dev/null || err "minikube profile $PROFILE is not running. Start it: minikube start -p $PROFILE"
  helm status kube-prometheus-stack -n "$MONITORING_NS" &>/dev/null && WITH_PROMETHEUS=true
  section "weather-ml status (profile: $PROFILE)"
  print_summary
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

section "Starting minikube (profile: $PROFILE)"
if minikube status | grep -q "Running"; then
  info "minikube profile $PROFILE is already running."
else
  minikube start --memory=4096 --cpus=2
  info "minikube profile $PROFILE started."
fi

info "Enabling ingress addon..."
minikube addons enable ingress

info "Waiting for ingress-nginx controller to be ready..."
kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=120s

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

# Image tag stays "latest", so helm sees no spec change after a rebuild —
# restart explicitly to pick up the freshly built image.
info "Restarting API to pick up rebuilt image..."
kubectl rollout restart deployment "$RELEASE-api" -n "$NAMESPACE"

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
kubectl rollout status deployment/"$RELEASE-api" -n "$NAMESPACE" --timeout=360s
kubectl wait pod \
  --for=condition=ready \
  --selector=app.kubernetes.io/instance="$RELEASE" \
  --namespace="$NAMESPACE" \
  --timeout=360s
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
print_summary
