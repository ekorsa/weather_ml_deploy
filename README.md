# Weather ML — Kubernetes Deployment on AKS

This repository contains everything needed to deploy the [weather_ml](../weather_ml) pipeline
to Azure Kubernetes Service: Terraform infrastructure, Helm chart, Prometheus monitoring,
and a GitHub Actions CI/CD pipeline.

## Architecture

```
Internet
   │
   ▼
NGINX Ingress Controller (LoadBalancer)
   │  weather-ml.yourdomain.com
   ▼
FastAPI (api.py)  ──── PostgreSQL (Bitnami)
   │                         ▲
   │  /predict (subprocess)  │
   ▼                         │
predict.py ──────────────────┘
   │
   └──► PushGateway:9091 ──► Prometheus ──► Grafana
          ▲
CronJobs ─┘
  fetch_weather.py  (every hour at :00)   → Redis
  train.py          (daily at 02:00 UTC)  → models/ (Azure Files PVC)
  predict.py        (every hour at :30)   → PostgreSQL + PushGateway
```

**Shared PVC:** `train.py` saves `models/weather_model.pkl` to an Azure Files volume
(ReadWriteMany). The same volume is mounted by the `predict` CronJob and the API pod.

## Prerequisites

| Tool | Version |
|------|---------|
| Azure CLI | >= 2.50 |
| Terraform | >= 1.5 |
| kubectl | >= 1.28 |
| Helm | >= 3.13 |
| Docker | >= 24 |

```bash
az login
az account set --subscription "<your-subscription-id>"
```

## Step 1 — Provision infrastructure with Terraform

```bash
cd terraform

terraform init
terraform plan
terraform apply
```

After `apply`, capture the outputs you will need later:

```bash
terraform output acr_login_server    # e.g. weathermlacr.azurecr.io
terraform output acr_name            # e.g. weathermlacr
terraform output aks_cluster_name
terraform output resource_group_name

# Write kubeconfig
terraform output -raw kube_config > ~/.kube/config
kubectl get nodes                    # verify cluster access
```

> **Note:** ACR name and Storage Account name must be globally unique.
> Change `acr_name` and `storage_account_name` in `terraform/variables.tf` if the defaults are taken.

## Step 2 — Install NGINX Ingress Controller

```bash
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update

helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx --create-namespace \
  --set controller.service.type=LoadBalancer

# Wait for the external IP, then create a DNS A-record pointing to it
kubectl get svc -n ingress-nginx ingress-nginx-controller
```

## Step 3 — Install Prometheus Stack

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

helm upgrade --install kube-prometheus-stack \
  prometheus-community/kube-prometheus-stack \
  --namespace monitoring --create-namespace \
  --values monitoring/kube-prometheus-stack-values.yaml
```

Edit `monitoring/kube-prometheus-stack-values.yaml` to set your Grafana domain and password
before running the command.

## Step 4 — Configure GitHub Secrets

Go to **Settings → Secrets and variables → Actions** in the `weather_ml_deploy` repository
and add the following secrets:

| Secret | How to get it |
|--------|--------------|
| `AZURE_CREDENTIALS` | `az ad sp create-for-rbac --role contributor --scopes /subscriptions/<id> --sdk-auth` |
| `ACR_NAME` | `terraform output acr_name` |
| `ACR_LOGIN_SERVER` | `terraform output acr_login_server` |
| `AKS_CLUSTER_NAME` | `terraform output aks_cluster_name` |
| `AKS_RESOURCE_GROUP` | `terraform output resource_group_name` |
| `SOURCE_REPO` | GitHub path to the source repo, e.g. `myorg/weather_ml` |
| `GH_PAT` | Personal Access Token with `repo` scope (only if `weather_ml` is private) |
| `POSTGRES_PASSWORD` | Strong password of your choice |
| `REDIS_PASSWORD` | Strong password of your choice |

## Step 5 — First manual deploy (optional)

If you want to deploy before pushing to `main`:

```bash
# Add Bitnami repo and download subchart tarballs
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo update
helm dependency update helm/weather-ml

# Create namespace
kubectl create namespace weather-ml

# Deploy
helm upgrade --install weather-ml ./helm/weather-ml \
  --namespace weather-ml \
  --values helm/weather-ml/values.yaml \
  --values helm/weather-ml/values-prod.yaml \
  --set image.registry=<ACR_LOGIN_SERVER> \
  --set api.image.tag=latest \
  --set ml.image.tag=latest \
  --set secrets.postgresPassword=<POSTGRES_PASSWORD> \
  --set secrets.redisPassword=<REDIS_PASSWORD> \
  --set postgresql.auth.password=<POSTGRES_PASSWORD> \
  --set redis.auth.password=<REDIS_PASSWORD>
```

> You must build and push images to ACR at least once before this step.
> See the build commands in `.github/workflows/deploy.yml` (build-push job) for reference.

## Step 6 — CI/CD

Every push to `main` automatically:
1. Checks out both `weather_ml_deploy` (this repo) and `weather_ml` (source repo).
2. Builds `api` and `ml` Docker images and pushes them to ACR tagged with the git SHA.
3. Runs `helm upgrade --install` with the new image tags.

You can also trigger a deploy manually from **Actions → CI/CD — Build, Push, Deploy → Run workflow**.

## Step 7 — Verify the deployment

```bash
# All pods should be Running
kubectl get pods -n weather-ml

# Check Ingress address
kubectl get ingress -n weather-ml

# Hit the API
curl http://weather-ml.yourdomain.com/
curl http://weather-ml.yourdomain.com/predictions

# Trigger CronJobs manually (runs once immediately)
kubectl create job --from=cronjob/weather-ml-fetch   fetch-manual   -n weather-ml
kubectl create job --from=cronjob/weather-ml-train   train-manual   -n weather-ml
kubectl create job --from=cronjob/weather-ml-predict predict-manual -n weather-ml

# Check training logs
kubectl logs -n weather-ml -l app.kubernetes.io/component=ml-train --tail=50
```

## CronJob schedules

| CronJob | Script | Schedule | Purpose |
|---------|--------|----------|---------|
| `weather-ml-fetch` | `fetch_weather.py` | `0 * * * *` | Fetch hourly data from Open-Meteo → Redis |
| `weather-ml-train` | `train.py` | `0 2 * * *` | Retrain model from Redis → Azure Files |
| `weather-ml-predict` | `predict.py` | `30 * * * *` | Predict next temperature → PostgreSQL + PushGateway |

Schedules are configurable in `helm/weather-ml/values.yaml` under `ml.fetch.schedule`, etc.

## Monitoring

- **Grafana:** `http://grafana.yourdomain.com` (default user: `admin` / password set in `kube-prometheus-stack-values.yaml`)
- **Metrics scraped:** API (`/metrics`), PushGateway (ML job predictions), PostgreSQL exporter, Redis exporter
- **Key metric:** `ml_prediction_value` — the last predicted temperature, pushed by `predict.py` after every run

## Known limitations

- `api.py` triggers `predict.py` via `subprocess.run`. This works in K8s (both scripts are in
  the same image), but means the API pod also needs the models PVC mounted — already handled
  in `templates/api/deployment.yaml`.
- `predict.py` hardcodes `pushgateway:9091` as the PushGateway address. The Service in
  `templates/monitoring/pushgateway.yaml` is therefore named `pushgateway` (not prefixed with
  the Helm release name) to match this.
- TLS is disabled by default. For production, set `ingress.tls.enabled=true` in
  `values-prod.yaml` and provision a certificate (cert-manager recommended).
