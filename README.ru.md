# Weather ML — деплой в Kubernetes на AKS

Этот репозиторий содержит всё необходимое для развёртывания пайплайна [weather_ml](../weather_ml)
в Azure Kubernetes Service: Terraform-инфраструктура, Helm chart, мониторинг Prometheus
и CI/CD на GitHub Actions.

## Архитектура

```
Интернет
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
  fetch_weather.py  (каждый час в :00)  → Redis
  train.py          (ежедневно 02:00)   → models/ (Azure Files PVC)
  predict.py        (каждый час в :30)  → PostgreSQL + PushGateway
```

**Общий PVC:** `train.py` сохраняет `models/weather_model.pkl` в Azure Files (ReadWriteMany).
Тот же том монтируется в CronJob `predict` и в поды API.

## Локальное тестирование на Minikube

### 1. Запустить Minikube и включить Ingress

```bash
minikube start --memory=4096 --cpus=2
minikube addons enable ingress
```

### 2. Собрать образы внутри Docker-демона Minikube

```bash
eval $(minikube docker-env)
docker build -f ../weather_ml/Dockerfile.api -t api:latest ../weather_ml
docker build -f ../weather_ml/Dockerfile.ml  -t ml:latest  ../weather_ml
```

### 3. Добавить Bitnami repo и скачать зависимости chart'а

```bash
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo update
helm dependency update helm/weather-ml
```

### 4. Задеплоить

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

### 5. Добавить DNS и проверить

```bash
echo "$(minikube ip) weather-ml.local" | sudo tee -a /etc/hosts

# Ждать пока поды поднимутся
kubectl get pods -n weather-ml -w

# Проверить Ingress
kubectl get ingress -n weather-ml

# Проверить API
curl http://weather-ml.local/
curl http://weather-ml.local/predictions
```

### 6. Запустить ML джобы вручную (первый запуск)

CronJob'ы работают по расписанию, но для первого предсказания нужны данные.
Запустить один раз по порядку:

```bash
kubectl create job --from=cronjob/weather-ml-fetch   fetch-1   -n weather-ml
kubectl wait --for=condition=complete job/fetch-1 -n weather-ml --timeout=60s

kubectl create job --from=cronjob/weather-ml-train   train-1   -n weather-ml
kubectl wait --for=condition=complete job/train-1 -n weather-ml --timeout=120s

kubectl create job --from=cronjob/weather-ml-predict predict-1 -n weather-ml
kubectl wait --for=condition=complete job/predict-1 -n weather-ml --timeout=60s

# Проверить что предсказания появились в БД
curl http://weather-ml.local/predictions
```

### 7. Удалить стенд

```bash
helm uninstall weather-ml -n weather-ml
minikube stop
```

---

## Предварительные требования

| Инструмент | Версия |
|------------|--------|
| Azure CLI | >= 2.50 |
| Terraform | >= 1.5 |
| kubectl | >= 1.28 |
| Helm | >= 3.13 |
| Docker | >= 24 |

```bash
az login
az account set --subscription "<your-subscription-id>"
```

## Шаг 1 — Создание инфраструктуры через Terraform

```bash
cd terraform

terraform init
terraform plan
terraform apply
```

После `apply` сохраните нужные значения:

```bash
terraform output acr_login_server    # например weathermlacr.azurecr.io
terraform output acr_name            # например weathermlacr
terraform output aks_cluster_name
terraform output resource_group_name

# Записать kubeconfig
terraform output -raw kube_config > ~/.kube/config
kubectl get nodes                    # проверить доступ к кластеру
```

> **Важно:** имена ACR и Storage Account должны быть глобально уникальными в Azure.
> Если дефолтные значения заняты — измените `acr_name` и `storage_account_name`
> в `terraform/variables.tf`.

## Шаг 2 — Установка NGINX Ingress Controller

```bash
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update

helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx --create-namespace \
  --set controller.service.type=LoadBalancer

# Дождитесь External IP, затем создайте DNS A-запись
kubectl get svc -n ingress-nginx ingress-nginx-controller
```

## Шаг 3 — Установка Prometheus Stack

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

helm upgrade --install kube-prometheus-stack \
  prometheus-community/kube-prometheus-stack \
  --namespace monitoring --create-namespace \
  --values monitoring/kube-prometheus-stack-values.yaml
```

Перед запуском отредактируйте `monitoring/kube-prometheus-stack-values.yaml` —
укажите домен Grafana и пароль администратора.

## Шаг 4 — Настройка GitHub Secrets

Перейдите в **Settings → Secrets and variables → Actions** репозитория `weather_ml_deploy`
и добавьте следующие секреты:

| Секрет | Как получить |
|--------|-------------|
| `AZURE_CREDENTIALS` | `az ad sp create-for-rbac --role contributor --scopes /subscriptions/<id> --sdk-auth` |
| `ACR_NAME` | `terraform output acr_name` |
| `ACR_LOGIN_SERVER` | `terraform output acr_login_server` |
| `AKS_CLUSTER_NAME` | `terraform output aks_cluster_name` |
| `AKS_RESOURCE_GROUP` | `terraform output resource_group_name` |
| `SOURCE_REPO` | Путь к исходному репо, например `myorg/weather_ml` |
| `GH_PAT` | Personal Access Token с правом `repo` (только если `weather_ml` приватный) |
| `POSTGRES_PASSWORD` | Надёжный пароль на ваш выбор |
| `REDIS_PASSWORD` | Надёжный пароль на ваш выбор |

## Шаг 5 — Первый ручной деплой (опционально)

Если хотите задеплоить до первого пуша в `main`:

```bash
# Добавить Bitnami и скачать subcharts
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo update
helm dependency update helm/weather-ml

# Создать namespace
kubectl create namespace weather-ml

# Деплой
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

> До этого шага необходимо хотя бы один раз собрать образы и запушить в ACR.
> Команды сборки — в файле `.github/workflows/deploy.yml` (job `build-push`).

## Шаг 6 — CI/CD

Каждый пуш в `main` автоматически:
1. Checkout'ит `weather_ml_deploy` (этот репо) и `weather_ml` (исходный код).
2. Собирает образы `api` и `ml` и пушит их в ACR с тегом git SHA.
3. Запускает `helm upgrade --install` с новыми тегами образов.

Также можно запустить деплой вручную: **Actions → CI/CD — Build, Push, Deploy → Run workflow**.

## Шаг 7 — Проверка деплоя

```bash
# Все поды должны быть в статусе Running
kubectl get pods -n weather-ml

# Проверить Ingress
kubectl get ingress -n weather-ml

# Запросить API
curl http://weather-ml.yourdomain.com/
curl http://weather-ml.yourdomain.com/predictions

# Запустить CronJob вручную (немедленно)
kubectl create job --from=cronjob/weather-ml-fetch   fetch-manual   -n weather-ml
kubectl create job --from=cronjob/weather-ml-train   train-manual   -n weather-ml
kubectl create job --from=cronjob/weather-ml-predict predict-manual -n weather-ml

# Посмотреть логи тренировки
kubectl logs -n weather-ml -l app.kubernetes.io/component=ml-train --tail=50
```

## Расписание CronJob

| CronJob | Скрипт | Расписание | Назначение |
|---------|--------|-----------|-----------|
| `weather-ml-fetch` | `fetch_weather.py` | `0 * * * *` | Загрузка данных Open-Meteo → Redis |
| `weather-ml-train` | `train.py` | `0 2 * * *` | Переобучение модели из Redis → Azure Files |
| `weather-ml-predict` | `predict.py` | `30 * * * *` | Предсказание → PostgreSQL + PushGateway |

Расписания настраиваются в `helm/weather-ml/values.yaml` через ключи
`ml.fetch.schedule`, `ml.train.schedule`, `ml.predict.schedule`.

## Мониторинг

- **Grafana:** `http://grafana.yourdomain.com` (логин: `admin`, пароль из `kube-prometheus-stack-values.yaml`)
- **Что собирается:** API (`/metrics`), PushGateway (предсказания ML), postgres-exporter, redis-exporter
- **Ключевая метрика:** `ml_prediction_value` — последнее предсказанное значение температуры,
  отправляется в PushGateway после каждого запуска `predict.py`

## Известные ограничения

- `api.py` вызывает `predict.py` через `subprocess.run`. В K8s это работает, так как оба скрипта
  находятся в одном образе, но требует монтирования PVC с моделью в поды API —
  это уже сделано в `templates/api/deployment.yaml`.
- `predict.py` содержит жёстко прописанный адрес `pushgateway:9091`. Сервис в
  `templates/monitoring/pushgateway.yaml` поэтому называется именно `pushgateway`
  (без префикса Helm release), чтобы совпадало с кодом.
- TLS по умолчанию отключён. Для продакшена установите `ingress.tls.enabled=true`
  в `values-prod.yaml` и выпустите сертификат (рекомендуется cert-manager).
