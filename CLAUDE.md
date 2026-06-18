# CLAUDE.md — weather_ml_deploy

Deployment repo for the `weather_ml` ML pipeline. The source application lives in `../weather_ml`.

## Repo layout

```
helm/weather-ml/          Helm chart (app + Bitnami postgresql + redis subcharts)
  values.yaml             Default values (production defaults)
  values-minikube.yaml    Minikube overrides
  values-prod.yaml        AKS/production overrides
  templates/
    api/                  API Deployment, Service, Ingress
    ml/                   CronJobs: fetch, train, predict
    monitoring/           PushGateway Deployment+Service+ServiceMonitor, API ServiceMonitor
    configmap.yaml        Env config (hosts, ports, db name)
    secret.yaml           Postgres password
    pvc.yaml              Shared model PVC (Azure Files RWX on AKS, standard RWO on minikube)
monitoring/
  kube-prometheus-stack-values.yaml   Prometheus Operator install config
terraform/                AKS + ACR + Azure Files infrastructure
scripts/
  deploy-minikube.sh      Full local deploy automation (see Usage below)
```

## Key design decisions

- **Redis auth is disabled** (`redis.auth.enabled: false`). `train.py`, `fetch_weather.py`, `predict.py` connect to Redis without a password — the Python code does not read `REDIS_PASSWORD`. Do not re-enable auth without updating the source code first.
- **PushGateway Service is named `pushgateway`** (not Helm-prefixed). `predict.py` hardcodes `push_to_gateway('pushgateway:9091', ...)` — renaming the Service will break metrics push.
- **Shared PVC** at `/app/models` is mounted by the train CronJob (write), predict CronJob (read), and API Deployment (read). On AKS use `azurefile` (RWX); on minikube use `standard` (RWO, single-node so no conflict).
- **ServiceMonitor label** is `release: kube-prometheus-stack` so Prometheus Operator discovers it automatically.
- **Bitnami image tags** are set to `latest` in `values-minikube.yaml` — Bitnami prunes old patch tags from Docker Hub, so pinning a specific tag causes ErrImagePull.

## ML CronJob schedule

| Job | Script | Schedule (UTC) |
|-----|--------|----------------|
| fetch | `fetch_weather.py` | `0 * * * *` — every hour :00 |
| train | `train.py` | `0 2 * * *` — daily 02:00 |
| predict | `predict.py` | `30 * * * *` — every hour :30 |

## Local development (minikube)

```bash
# Full deploy (builds images, installs chart, runs ML pipeline)
./scripts/deploy-minikube.sh

# With Prometheus + Grafana
./scripts/deploy-minikube.sh --with-prometheus

# Teardown
./scripts/deploy-minikube.sh --teardown
```

The script expects the `weather_ml` source repo to be at `../weather_ml`.

## Helm — manual commands

```bash
# Install/upgrade
helm upgrade --install weather-ml ./helm/weather-ml \
  --namespace weather-ml --create-namespace \
  --values helm/weather-ml/values.yaml \
  --values helm/weather-ml/values-minikube.yaml \
  --set image.registry="" \
  --set image.pullPolicy=Never \
  --set secrets.postgresPassword=testpass \
  --set postgresql.auth.password=testpass

# Trigger a job manually
kubectl create job --from=cronjob/weather-ml-fetch fetch-1 -n weather-ml
kubectl create job --from=cronjob/weather-ml-train train-1 -n weather-ml
kubectl create job --from=cronjob/weather-ml-predict predict-1 -n weather-ml
```

## Terraform

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars   # fill in your values
terraform init && terraform apply
```

Outputs `kube_config` and `storage_account_key` — both marked sensitive.

## GitHub Actions secrets required

| Secret | Description |
|--------|-------------|
| `AZURE_CREDENTIALS` | Service principal JSON from `az ad sp create-for-rbac` |
| `ACR_NAME` | ACR registry name (without `.azurecr.io`) |
| `ACR_LOGIN_SERVER` | Full ACR login server, e.g. `weathermlacr.azurecr.io` |
| `AKS_RESOURCE_GROUP` | Resource group name |
| `AKS_CLUSTER_NAME` | AKS cluster name |
| `POSTGRES_PASSWORD` | Postgres password for production |
| `SOURCE_REPO` | `org/weather_ml` — source repo with Dockerfiles |
| `GH_PAT` | PAT for checking out a private source repo |

## Prometheus on minikube

`managed-csi` storageClass does not exist on minikube. Override it:

```bash
helm upgrade kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring --reuse-values \
  --set prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.storageClassName=standard \
  --set prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.resources.requests.storage=2Gi
```

Access:
```bash
kubectl port-forward svc/kube-prometheus-stack-prometheus 9090:9090 -n monitoring &
kubectl port-forward svc/kube-prometheus-stack-grafana 3000:80 -n monitoring &
# Grafana: admin / admin (or whatever --set grafana.adminPassword= was set to)
```
