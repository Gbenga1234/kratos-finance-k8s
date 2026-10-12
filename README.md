# kratos-finance-k8s

Kubernetes manifests for the **kratos-finance** app and the platform services it
depends on (Redis, SigNoz), deployed with **Argo CD** (GitOps).

## Layout

```
k8s/
├── base/                     # kratos-finance app (Kustomize)
│   ├── namespace.yaml
│   ├── configmap.yaml        # non-secret env (PORT, REDIS_HOST, OTEL_*)
│   ├── externalsecret.yaml   # DATABASE_URL, SECRET_KEY, REDIS_PASSWORD
│   ├── secret.example.yaml   # plain Secret for clusters without ESO (not applied)
│   ├── deployment.yaml
│   ├── service.yaml
│   ├── ingress.yaml
│   └── kustomization.yaml    # image tag is set here
├── platform/
│   ├── redis/                # single-node Redis StatefulSet (Kustomize)
│   ├── signoz/
│   │   ├── values.yaml           # signoz/signoz Helm values
│   │   └── k8s-infra-values.yaml # signoz/k8s-infra Helm values
│   └── install.sh            # manual install (no Argo CD)
└── argocd/
    ├── root-app.yaml         # app-of-apps entry point (apply once)
    └── apps/
        ├── project.yaml      # AppProject "kratos-finance"
        ├── redis.yaml        # wave 0
        ├── signoz.yaml       # wave 0  (Helm chart 0.145.0)
        ├── k8s-infra.yaml    # wave 1  (Helm chart 0.17.1)
        └── kratos-finance.yaml # wave 2
```

## How it connects

| From | To | Address |
|---|---|---|
| Internet | kratos-finance | `https://kratos-finance.example.com` (Ingress) |
| Internet | SigNoz UI | `https://signoz.example.com` (Ingress) |
| kratos-finance | Redis | `redis.redis.svc.cluster.local:6379` |
| kratos-finance, k8s-infra | SigNoz collector | `signoz-otel-collector.signoz.svc.cluster.local:4317` (OTLP gRPC) |

Secrets are never stored in Git. The External Secrets Operator syncs them from
the secret store into Kubernetes Secrets:

| Kubernetes Secret | Keys |
|---|---|
| `kratos-finance/kratos-finance` | `DATABASE_URL`, `SECRET_KEY`, `REDIS_PASSWORD` |
| `redis/redis` | `REDIS_PASSWORD` |

## Prerequisites

The cluster must already have:

- **Argo CD** in the `argocd` namespace (v2.6+ for multi-source Helm apps)
- **External Secrets Operator** (v0.17+ for `external-secrets.io/v1`) and a
  `ClusterSecretStore`
- **ingress-nginx** (ingress class `nginx`)
- **cert-manager** with a `letsencrypt-prod` `ClusterIssuer`

If a component is missing, adjust the matching manifests (for example, drop the
`cert-manager.io/cluster-issuer` annotation and supply the TLS secret yourself).

## Before the first deploy

Replace the placeholders:

| Placeholder | Files |
|---|---|
| `REPLACE_WITH_ORG`, `REPLACE_WITH_TAG` | `k8s/base/kustomization.yaml`, `k8s/base/deployment.yaml` |
| `REPLACE_WITH_SECRET_STORE_NAME` | `k8s/base/externalsecret.yaml`, `k8s/platform/redis/externalsecret.yaml` |
| `REPLACE_WITH_REMOTE_SECRET_NAME` | `k8s/base/externalsecret.yaml` |
| `REPLACE_WITH_REDIS_REMOTE_SECRET_NAME` | both ExternalSecrets above |
| `kratos-finance.example.com` | `k8s/base/ingress.yaml` |
| `signoz.example.com` | `k8s/platform/signoz/values.yaml` |

Create the matching entries in your secret store (`DATABASE_URL`, `SECRET_KEY`,
`REDIS_PASSWORD`). Then commit and push to `main`.

## Deploy with Argo CD

```sh
kubectl apply -f k8s/argocd/root-app.yaml
```

The `root` Application syncs `k8s/argocd/apps/`, which creates the AppProject
and the four child Applications. Every Application auto-syncs from `main` with
prune and self-heal enabled, so **Git is the source of truth**: change things
by committing, not with `kubectl edit`.

If the repo is private, register it with Argo CD first:

```sh
argocd repo add https://github.com/Gbenga1234/kratos-finance-k8s.git \
  --username <github-user> --password <github-token>
```

Check status:

```sh
argocd app list
argocd app get kratos-finance
```

### Sync ordering

The sync-wave annotations order the apps: Redis and SigNoz first, then k8s-infra,
then kratos-finance. Argo CD only waits on a child Application's health if
Application health assessment is enabled in `argocd-cm`:

```yaml
data:
  resource.customizations.health.argoproj.io_Application: |
    hs = {}
    hs.status = "Progressing"
    hs.message = ""
    if obj.status ~= nil and obj.status.health ~= nil then
      hs.status = obj.status.health.status
      if obj.status.health.message ~= nil then
        hs.message = obj.status.health.message
      end
    end
    return hs
```

Without it all apps sync at once. They still converge, but kratos-finance may
restart a few times while Redis and SigNoz come up.

## Deploy without Argo CD

```sh
./k8s/platform/install.sh    # Redis, SigNoz, k8s-infra
kubectl apply -k k8s/base    # kratos-finance
```

Don't mix the two methods on the same cluster: Argo CD will fight manual changes.

## Common tasks

**Release a new app version:** update `newTag` in `k8s/base/kustomization.yaml`,
commit, push.

**Upgrade SigNoz:** bump `targetRevision` in `k8s/argocd/apps/signoz.yaml` (and
`k8s-infra.yaml`), and `SIGNOZ_CHART_VERSION` in `install.sh` if you use it.
Review the chart changes first:
`helm show values signoz/signoz --version <new>`.

**Access SigNoz without the ingress:**

```sh
kubectl -n signoz port-forward svc/signoz 8080:8080
# open http://localhost:8080
```

**Local/dev cluster without External Secrets:** apply the example secrets
instead of relying on the ExternalSecrets:

```sh
kubectl apply -f k8s/platform/redis/secret.example.yaml
kubectl apply -f k8s/base/secret.example.yaml
```

## Notes

- The app sends telemetry to SigNoz only if it includes the OpenTelemetry SDK.
  The `OTEL_*` variables in the ConfigMap only tell it where to send data.
- Redis is a single instance with AOF persistence and no failover.
- The app container runs as UID 1000 (non-root). Adjust `deployment.yaml` if the
  image needs a different user.
- Health probes: startup and liveness hit `GET /healthz` (process alive, no
  dependency checks); readiness hits `GET /readyz` (ready to serve, including
  DB/Redis). Both must return 2xx/3xx on port 8000.
