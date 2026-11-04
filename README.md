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
