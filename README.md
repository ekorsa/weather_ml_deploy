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

## Local testing with Minikube

### 1. Start Minikube and enable Ingress

```bash
minikube start --memory=4096 --cpus=2
minikube addons enable ingress
```

### 2. Build images inside Minikube's Docker daemon

```bash
eval $(minikube docker-env)
docker build -f ../weather_ml/Dockerfile.api -t api:latest ../weather_ml
docker build -f ../weather_ml/Dockerfile.ml  -t ml:latest  ../weather_ml
```

### 3. Add Bitnami repo and download chart dependencies

```bash
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo update
helm dependency update helm/weather-ml
```

### 4. Deploy

```bash
helm upgrade --install weather-ml ./helm/weather-ml \
  --namespace weather-ml --create-namespace \
  --values helm/weather-ml/values.yaml \
  --values helm/weather-ml/values-minikube.yaml \
  --set image.registry="" \
  --set image.pullPolicy=Never \
  --set secrets.postgresPassword=testpass \
  --set secrets.redisPassword=testpass \
  --set postgresql.auth.password=testpass \
  --set redis.auth.password=testpass
```

### 5. Add DNS entry

```bash
echo "$(minikube ip) weather-ml.local" | sudo tee -a /etc/hosts
```

### 6. Check all pods are Running

```bash
kubectl get pods -n weather-ml -w
```

Expected output (all pods `Running` or `Completed`):
```
NAME                                       READY   STATUS    RESTARTS
weather-ml-api-xxxxxxxxx-xxxxx             1/1     Running   0
weather-ml-postgresql-0                    1/1     Running   0
weather-ml-redis-master-0                  1/1     Running   0
weather-ml-pushgateway-xxxxxxxxx-xxxxx     1/1     Running   0
```

If a pod is not ready: `kubectl describe pod <pod-name> -n weather-ml`

### 7. Verify the API

```bash
# Root endpoint — should return {"message": "Weather ML API is running"}
curl http://weather-ml.local/

# Prometheus metrics exposed by the API
curl http://weather-ml.local/metrics | head -20

# Predictions endpoint — returns [] until predict job has run
curl http://weather-ml.local/predictions
```

### 8. Run the ML pipeline manually (first-time setup)

CronJobs run on a schedule. For the first test, trigger them once **in order** —
each step depends on the previous one:

```bash
# Step 1: fetch weather data from Open-Meteo API → Redis
kubectl create job --from=cronjob/weather-ml-fetch fetch-1 -n weather-ml
kubectl wait --for=condition=complete job/fetch-1 -n weather-ml --timeout=60s
kubectl logs -n weather-ml -l job-name=fetch-1

# Step 2: train model on Redis data → save model.pkl to PVC
kubectl create job --from=cronjob/weather-ml-train train-1 -n weather-ml
kubectl wait --for=condition=complete job/train-1 -n weather-ml --timeout=120s
kubectl logs -n weather-ml -l job-name=train-1

# Step 3: load model, predict next temperature → save to PostgreSQL
kubectl create job --from=cronjob/weather-ml-predict predict-1 -n weather-ml
kubectl wait --for=condition=complete job/predict-1 -n weather-ml --timeout=60s
kubectl logs -n weather-ml -l job-name=predict-1
```

### 9. Verify end-to-end result

```bash
# Predictions must now contain at least one record
curl http://weather-ml.local/predictions

# Expected response (array with one prediction object):
# [{"prediction": 18.42, "created_at": "2024-..."}]

# Trigger prediction via API endpoint (uses subprocess internally)
curl -X POST http://weather-ml.local/predict

# Check PushGateway received the ML metric
curl http://$(minikube ip):$(kubectl get svc pushgateway -n weather-ml \
  -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null || echo "9091")/metrics \
  | grep ml_prediction_value
```

### 10. Useful debug commands

```bash
# Stream API logs
kubectl logs -n weather-ml -l app.kubernetes.io/component=api -f

# Check why a job failed
kubectl logs -n weather-ml -l job-name=train-1

# Inspect the shared PVC (model file should appear after train-1)
kubectl run pvc-check --image=busybox --restart=Never \
  --overrides='{"spec":{"volumes":[{"name":"m","persistentVolumeClaim":{"claimName":"weather-ml-models"}}],"containers":[{"name":"c","image":"busybox","command":["ls","-lh","/models"],"volumeMounts":[{"mountPath":"/models","name":"m"}]}]}}' \
  -n weather-ml
kubectl logs pvc-check -n weather-ml
kubectl delete pod pvc-check -n weather-ml

# Port-forward to access PushGateway directly
kubectl port-forward svc/pushgateway 9091:9091 -n weather-ml &
curl http://localhost:9091/metrics | grep ml_prediction
```

### 11. Install and verify Prometheus + Grafana (optional)

#### Install

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

helm upgrade --install kube-prometheus-stack \
  prometheus-community/kube-prometheus-stack \
  --namespace monitoring --create-namespace \
  --values monitoring/kube-prometheus-stack-values.yaml
```

Wait for all pods to become ready (takes ~2 min):

```bash
kubectl get pods -n monitoring -w
```

All pods should reach `Running` status:
```
NAME                                                   READY   STATUS
alertmanager-kube-prometheus-stack-alertmanager-0      2/2     Running
kube-prometheus-stack-grafana-xxxxxxxxx-xxxxx          3/3     Running
kube-prometheus-stack-operator-xxxxxxxxx-xxxxx         1/1     Running
kube-prometheus-stack-prometheus-node-exporter-xxxxx   1/1     Running
prometheus-kube-prometheus-stack-prometheus-0          2/2     Running
```

#### Enable ServiceMonitors for the weather-ml app

Re-deploy with ServiceMonitors enabled so Prometheus discovers the app metrics:

```bash
helm upgrade weather-ml ./helm/weather-ml \
  --namespace weather-ml \
  --reuse-values \
  --set monitoring.serviceMonitor.enabled=true
```

#### Access Prometheus UI

```bash
kubectl port-forward svc/kube-prometheus-stack-prometheus 9090:9090 -n monitoring
```

Open in browser: **http://localhost:9090**

Useful queries to run in the Prometheus UI:

| Query | What it shows |
|-------|--------------|
| `up` | All scraped targets and their status |
| `ml_prediction_value` | Last temperature prediction from `predict.py` |
| `http_requests_total` | Total requests to the FastAPI |
| `process_resident_memory_bytes{job="weather-ml"}` | API memory usage |

Or verify via curl:
```bash
# Check targets are being scraped (look for weather-ml and pushgateway)
curl -s http://localhost:9090/api/v1/targets | python3 -m json.tool | grep -E '"job"|"health"'

# Query ml_prediction_value
curl -s 'http://localhost:9090/api/v1/query?query=ml_prediction_value' | python3 -m json.tool
```

#### Access Grafana UI

```bash
kubectl port-forward svc/kube-prometheus-stack-grafana 3000:80 -n monitoring
```

Open in browser: **http://localhost:3000**

Default credentials: **admin / prom-operator**

> If you changed `grafana.adminPassword` in `monitoring/kube-prometheus-stack-values.yaml`,
> use that password instead.

In Grafana: **Explore → select Prometheus datasource → run `ml_prediction_value`**
to see the latest prediction on a graph.

### 12. Teardown

```bash
helm uninstall weather-ml -n weather-ml
helm uninstall kube-prometheus-stack -n monitoring
kubectl delete namespace weather-ml monitoring
minikube stop
```

---

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
