[![Flux](https://img.shields.io/badge/flux-v2.9-purple.svg)](https://fluxcd.io/)
[![Argo CD](https://img.shields.io/badge/argo%20cd-v3.4-orange.svg)](https://argo-cd.readthedocs.io/)&ensp;&ensp;
[![Kubernetes](https://img.shields.io/badge/kubernetes-1.30+-blue.svg)](https://kubernetes.io/)
[![Kind](https://img.shields.io/badge/kind-latest-orange.svg)](https://kind.sigs.k8s.io/)&ensp;&ensp;
[![License Apache2](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](http://www.apache.org/licenses/LICENSE-2.0)

OKDP Sandbox is a hands-on environment for deploying, testing, and exploring the [OKDP](https://okdp.io) ecosystem on a local Kubernetes cluster.

It deploys the platform foundations (identity, object storage, SQL, secrets, ingress), the OKDP Control Plane and a demo project on a local cluster, from a Git repository, with **Flux or Argo CD**: pick one, the repository is the same. Data services (Spark jobs, notebooks, SQL querying, dashboards) are then instantiated per project through the Control Plane, or by writing the same files in Git.

## What is included in the sandbox?

The platform ([`gitops/platform/components`](gitops/platform/components), one directory per component, deployed in layers):

| Layer | Components |
|---|---|
| `00` CRDs and operators | tools (Reloader, replicator, deletion protection), cert-manager, CloudNativePG, External Secrets, Spark Operator |
| `10` infrastructure | ingress-nginx, cluster issuers and trust-manager, CoreDNS patch, DNS server, local secrets provider, Spark RBAC |
| `20` identity, storage, databases | Keycloak and its PostgreSQL, SeaweedFS (S3), **Gitea** (the deployments repository), the CA trust bundle |
| `30` control plane | OKDP Control Plane server and UI |

The demo project ([`gitops/projects/demo`](gitops/projects/demo)): a PostgreSQL, the S3 store and the data services Hive Metastore, Polaris, Trino, Superset, Airflow, JupyterHub and Spark History Server, wired together by connection files.

Optional ([`gitops/optional`](gitops/optional)): Vault (a secret backend), and the [okdp-examples](https://github.com/OKDP/okdp-examples) medallion lakehouse seed for the demo project.

## How it works

```
basic user ─► console UI ─► control-plane server ─(git commit)─┐
GitOps user ────────────────────────────(git commit / PR)────► deployments Git repo (Gitea)
                                                               │
                              Flux: HelmRelease + OCIRepository │ Argo CD: ApplicationSet → Application
                                                               ▼
                                   Helm renders the SAME chart with the SAME values layers
```

- Every component and service is an OKDP Helm chart (or an upstream chart) with its values in Git: [`gitops/`](gitops) is the deployments repository. Its [README](gitops/README.md) specifies every file.
- Git is the only desired state. The console commits to the in-cluster Gitea; so can you. Flux or Argo CD deploys what is in Git.
- The charts come from `oci://quay.io/okdp/platform-charts` ([platform-packages](https://github.com/OKDP/platform-packages)) and `oci://quay.io/okdp/sandbox-charts` ([sandbox-dependencies](https://github.com/OKDP/sandbox-dependencies)).

| Concern | Owner |
|---|---|
| Charts of the OKDP services and control plane | [`OKDP/platform-packages`](https://github.com/OKDP/platform-packages) |
| Library chart `okdp-lib` and the contract schemas | [`OKDP/okdp-lib`](https://github.com/OKDP/okdp-lib) |
| Charts of the third-party and bootstrap dependencies | [`OKDP/sandbox-dependencies`](https://github.com/OKDP/sandbox-dependencies) |
| Notebooks, DAGs, and runnable examples | [`OKDP/okdp-examples`](https://github.com/OKDP/okdp-examples) |
| Control Plane web UI | [`OKDP/okdp-control-plane-ui`](https://github.com/OKDP/okdp-control-plane-ui) |
| Control Plane backend server (API) | [`OKDP/okdp-control-plane-server`](https://github.com/OKDP/okdp-control-plane-server) |
| Sandbox deployments repository (this repository) | `OKDP/okdp-sandbox` |

## Prerequisites

- 16 GB RAM and 4 CPUs at least for the platform; the whole demo project needs about 32 GB.
- [Docker](https://docs.docker.com/get-docker/) or a compatible container runtime, [Kind](https://kind.sigs.k8s.io/docs/user/quick-start/#installation), [kubectl](https://kubernetes.io/docs/tasks/tools/install-kubectl/), [Helm](https://helm.sh/docs/intro/install/) and `git`.
- For Flux: the [Flux CLI](https://fluxcd.io/flux/installation/) (tested with v2.9.5). For Argo CD: nothing more (tested with v3.4.2).

## Quick start

### 1. Clone this repository

```sh
git clone https://github.com/OKDP/okdp-sandbox.git
cd okdp-sandbox
```

### 2. Create the kind cluster

```sh
cat > /tmp/okdp-sandbox-config.yaml <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: okdp-sandbox
nodes:
- role: control-plane
  extraPortMappings:
  - containerPort: 30080
    hostPort: 80
  - containerPort: 30443
    hostPort: 443
  - containerPort: 30053
    hostPort: 30053
    protocol: UDP
EOF
kind create cluster --config /tmp/okdp-sandbox-config.yaml
```

<details>
<summary><strong><small>PowerShell</small></strong></summary>
<br>

```powershell
@"
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: okdp-sandbox
nodes:
- role: control-plane
  extraPortMappings:
  - containerPort: 30080
    hostPort: 80
  - containerPort: 30443
    hostPort: 443
  - containerPort: 30053
    hostPort: 53
    protocol: UDP
"@ | Out-File -FilePath "$env:TEMP\okdp-sandbox-config.yaml" -Encoding UTF8
kind create cluster --config "$env:TEMP\okdp-sandbox-config.yaml"
```

</details>

The console shows pod CPU and memory through metrics-server:

```sh
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
kubectl patch deployment metrics-server -n kube-system --type=json \
  -p='[{"op": "add", "path": "/spec/template/spec/containers/0/args/-", "value": "--kubelet-insecure-tls"},
       {"op": "replace", "path": "/spec/template/spec/containers/0/livenessProbe/timeoutSeconds", "value": 3},
       {"op": "replace", "path": "/spec/template/spec/containers/0/readinessProbe/timeoutSeconds", "value": 3}]'
```

> The default probe timeout of 1s is too tight for a single-node kind cluster: under
> load the probes fail and the pod is restarted with a new IP.

### 3. Put the deployments repository in the cluster

Gitea holds the deployments repository: the engine reads it, the console writes to it. It
is the platform component [`20-gitea`](gitops/platform/components/20-gitea); install it
once with the same release name and values, the engine takes it over afterwards:

```sh
helm upgrade --install gitea-gitea oci://docker.gitea.com/charts/gitea --version 12.7.0 \
  -n gitea --create-namespace --wait \
  -f gitops/platform/platform-values.yaml -f gitops/platform/components/20-gitea/values.yaml
```

Push this repository to it (the first push creates `okdp/okdp-sandbox`, public; the
account is `okdp` / `okdp-sandbox-Passw0rd`, see the component's values):

```sh
kubectl -n gitea port-forward svc/gitea-http 3000:3000 &
git push http://okdp:okdp-sandbox-Passw0rd@localhost:3000/okdp/okdp-sandbox.git HEAD:main
kill %1
```

Then choose **one** engine.

### 4a. Install with Flux

```sh
flux install --components=source-controller,kustomize-controller,helm-controller
# The chart version must not carry the OCI digest (see gitops/README.md).
kubectl -n flux-system patch deployment helm-controller --type json \
  -p '[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--feature-gates=DisableChartDigestTracking=true"}]'
kubectl apply -f gitops/flux/sync.yaml
```

Follow the platform layers, then the project services:

```sh
flux get kustomizations --watch
flux get helmreleases -n okdp-releases
```

### 4b. Install with Argo CD

Set the console's engine first: in
[`30-okdp-control-plane-server/values.yaml`](gitops/platform/components/30-okdp-control-plane-server/values.yaml),
`gitops.engine: argocd`; commit and push it to Gitea as above. Then:

```sh
kubectl create namespace argocd
kubectl apply -n argocd --server-side --force-conflicts \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/v3.4.2/manifests/install.yaml
# Layer ordering of the platform components (RollingSync).
kubectl -n argocd patch configmap argocd-cmd-params-cm --type merge \
  -p '{"data":{"applicationsetcontroller.enable.progressive.syncs":"true"}}'
kubectl -n argocd rollout restart deployment argocd-applicationset-controller
kubectl apply -n argocd -f gitops/argocd/
```

Follow the Applications (one per component and per service):

```sh
kubectl -n argocd get applications --watch
```

Either way, nothing else is applied by hand: the engine deploys the four platform layers
in order, then the demo project (Flux starts the projects once the platform is ready;
Argo CD retries them until it is). Everything is ready after 15 to 30 minutes, depending
on the machine and the network.

### Proxy (optional)

If the cluster reaches the Internet through a proxy, set it on the engine's controllers
(Flux: `kubectl -n flux-system set env deploy -l app.kubernetes.io/part-of=flux HTTPS_PROXY=… NO_PROXY=…`;
Argo CD: the same on `argocd-repo-server`), and for the services in
[`gitops/platform/platform-values.yaml`](gitops/platform/platform-values.yaml)
(`global.okdp.proxy`), committed and pushed.

### Another domain (optional)

The ingress suffix and the OIDC URLs (the five endpoints and the DCR registration URL)
are in [`gitops/platform/platform-values.yaml`](gitops/platform/platform-values.yaml).
Change `okdp.sandbox` there (and in the Gitea, storage and Keycloak component values that
name hosts), commit and push: every release is re-rendered.

### OAuth clients of the services (optional)

The sandbox registers the services' OAuth clients by dynamic client registration
(`global.okdp.oidc.clientProvisioning: dcr`): each service's oidc-dcr Job registers its
client in Keycloak (anonymous registration, `anonymousDCR` in
[`20-keycloak`](gitops/platform/components/20-keycloak/values.yaml)) and writes it to
Secret `<release>-<namespace>-dcr`. The console's own client (`okdp-ui`) stays declared
in the Keycloak realm. The alternative is `clientProvisioning: existing` (drop the `dcr`
block): the services then use the clients declared in `20-keycloak` and their Secrets
`creds-<release>-oauth2` (`projects/demo/services/secrets`). Anonymous registration does
not check where a registration comes from (`checkSenderHost: false`): fine on a sandbox,
see the keycloak chart before exposing such a Keycloak.

### 5. DNS setup

Enable access to OKDP services through DNS resolution for `okdp.sandbox` (or your domain):

- **Option 1 (recommended)**: local DNS server configuration (automatic for all services)
- **Option 2**: manual `/etc/hosts` configuration

See [dns-configuration.md](docs/dns-configuration.md) for your operating system.

### 6. SSL certificate

The sandbox uses a local certificate authority. Import it into your system or browser
trust store to avoid warnings:

```sh
kubectl get secret default-issuer -n cert-manager -o jsonpath='{.data.ca\.crt}' | base64 -d > okdp-sandbox-ca.crt
```

See [install-certificate.md](docs/install-certificate.md). Otherwise, open
https://keycloak.okdp.sandbox first and accept its certificate: every OKDP service talks
to Keycloak.

## Using the sandbox

1. **Console**: https://okdp-ui.okdp.sandbox, login `adm` / `adm` (Keycloak).
2. **The demo project** is deployed with the platform: `projects/demo` in Git, namespace
   `demo`. Its services appear in the console like the ones you deploy from it.
3. **Deploy a service** from the console, or commit the same files: see
   [gitops/README.md](gitops/README.md) (`instance.yaml`, `values.yaml`, then
   `gitops/scripts/render-flux.sh` for the Flux files). The console's commits show up in
   Gitea (https://gitea.okdp.sandbox).
4. **Examples**: move `gitops/optional/projects/demo/services/okdp-examples` to
   `gitops/projects/demo/services/`, run `gitops/scripts/render-flux.sh`, commit and push:
   the seed Job loads the NYC-taxi lakehouse. Then follow the
   [okdp-examples guide](https://github.com/OKDP/okdp-examples).

## Optional components

Move a directory of [`gitops/optional/platform/components`](gitops/optional/platform/components)
to `gitops/platform/components/`, run `gitops/scripts/render-flux.sh`, commit and push.
Remove it the same way (deletion-protected objects, labelled `okdp.io/protected`, must be
unlabelled first).

- **vault**, a secret backend a console `SecretStore` can point at, in dev mode
  (in-memory, sealed on restart).

The object store (`20-storage`, SeaweedFS) can be replaced by any S3-compatible store:
point `gitops/projects/demo/connections/demo-storage.yaml` at it, provide the credentials
Secrets its `secretRef` and the services' `s3SecretRef` name, and create the buckets.

## Cleanup

```sh
kind delete cluster --name okdp-sandbox
rm /tmp/okdp-sandbox-config.yaml
```

## License

This project is licensed under the [Apache License 2.0](http://www.apache.org/licenses/LICENSE-2.0).

---

**Built 🚀 for the OKDP Community**
<a href="https://okdp.io">
  <img src="https://okdp.io/logos/okdp-notext.svg" height="20px" style="margin: 0 2px;" />
</a>
