# OKDP deployments repository (reference layout)

This directory is the **only desired state** of an OKDP platform. The console (through
the control plane server) and GitOps users write the same files; Flux **or** Argo CD
deploys them. Helm renders the same chart with the same values layers under both
engines.

- [Layout](#layout)
- [Files written by people and by the console](#files-written-by-people-and-by-the-console)
- [Values layers](#values-layers)
- [Generated files (Flux): byte-exact format](#generated-files-flux-byte-exact-format)
- [Install with Flux](#install-with-flux)
- [Install with Argo CD](#install-with-argo-cd)
- [Scripts](#scripts)

## Layout

```
platform/
  platform-values.yaml            # {global: {okdp: {...}}}: first values layer of every release
  catalog.yaml                    # console service catalog (read/written by the server)
  connections/<name>.yaml         # {connections: {<name>: {...}}}, external connections for components
  kustomization.yaml              # generated: platform values + platform connection ConfigMaps (both engines)
  components/<NN>-<name>/         # platform components; NN = layer 00, 10, 20 or 30
    instance.yaml  values.yaml    #   written by hand
    helmrelease.yaml  kustomization.yaml   # generated (Flux)
projects/<project>/
  project.yaml                    # {name, description, ...}; namespace = <project>
  connections/<name>.yaml         # {connections: {<name>: {...}}}  (external connection)
  services/<instance>/
    instance.yaml                 # engine-neutral source of both engines
    values.yaml                   # user parameters only
    helmrelease.yaml              # generated (Flux)
    kustomization.yaml            # generated (Flux)
  kustomization.yaml              # generated (Flux): services + connection ConfigMaps
flux/                             # Flux entry point
  sync.yaml                       #   GitRepository okdp-gitops + Kustomization okdp (bootstrap)
  platform.yaml                   #   Namespace okdp-releases, Kustomization okdp-platform-values
  components.yaml                 #   generated: one Kustomization per platform component, okdp-projects
  kustomization.yaml
argocd/                           # Argo CD entry point
  project.yaml                    #   AppProject okdp (platform)
  root.yaml                       #   Application okdp (manages argocd/ itself)
  platform-values.yaml            #   Application okdp-platform-values
  components.yaml                 #   ApplicationSet okdp-components (RollingSync by layer)
  services.yaml                   #   ApplicationSet okdp-services
  projects.yaml                   #   ApplicationSet okdp-projects (one AppProject per project)
  okdp-project/                   #   chart of the AppProject project-<p>
optional/                         # components and services not deployed, moved into place by hand
  storage/<store>/                #   the 20-storage stores not in use (scripts/configure.sh)
scripts/configure.sh              # chooses the engine (gitops.engine) and the 20-storage store
scripts/render-flux.sh            # instance.yaml -> generated Flux files
scripts/check.sh                  # CI: generated files up to date, shapes and contracts valid
scripts/compare-engines.sh        # compares the live objects of two clusters (Flux vs Argo)
```

Names used below: `<p>` project, `<i>` instance, `<r>` = `<p>-<i>` the Helm release
name, `<c>` a connection name, `<NN>` a layer.

## Files written by people and by the console

### `projects/<p>/services/<i>/instance.yaml`

```yaml
name: hello                                     # = <i>, the directory name
project: example                                # = <p>, the project directory = target namespace
service: app-template                           # chart name
chart: oci://ghcr.io/bjw-s-labs/helm/app-template   # OCI chart reference, ends with /<service>
version: 5.2.1                                  # exact chart version (a YAML string)
connections:                                    # connection files to layer in, in this order
  - example-s3
```

Rules (enforced by `render-flux.sh`; the server must enforce the same):

| key | rule |
|---|---|
| (all) | exactly these six keys, no others; `name`, `project`, `service`, `chart`, `version` are YAML strings (tag `!!str`: quote a version such as `"6.10.0"` only if needed; `6.10` unquoted is a float and is rejected) |
| `name`, `project`, `service` | DNS label `^[a-z0-9]([-a-z0-9]*[a-z0-9])?$` |
| `name` | equals the directory name; for a component, the directory name without `<NN>-` |
| `project` | equals the project directory (services); free namespace for components |
| `chart` | `^oci://[a-z0-9]([-a-z0-9.]*[a-z0-9])?(:[0-9]+)?(/[a-z0-9]([-a-z0-9._]*[a-z0-9])?)+$`, last path segment = `service` |
| `version` | `^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z][-0-9A-Za-z.]*)?$` (no ranges, no `+build`) |
| `connections` | a list (use `[]` when empty) of distinct DNS labels; each `projects/<p>/connections/<c>.yaml` exists (for a platform component: `platform/connections/<c>.yaml`) |
| release `<p>-<i>` | at most 53 characters; unique across projects and components |

Because the objects in `okdp-releases` are named `<p>-<i>`, `conn-<p>-<c>` and
`values-<p>-<i>`, two pairs that concatenate to the same name (project `a-b` instance
`c` and project `a` instance `b-c`) collide; `render-flux.sh` rejects the layout.

### `values.yaml`

Only what the user set (the console writes the submitted parameters). Required; write
`{}` when empty. Never put `global.okdp` or `connections` here.

### `projects/<p>/project.yaml`

`{name: <p>, description: ...}`. `name` equals the directory name.

### `projects/<p>/connections/<c>.yaml`

```yaml
connections:
  example-s3:                     # = <c>, the file name without .yaml
    contract: s3                  # database-server | s3 | hive | iceberg-catalog | trino
    apiUrl: https://s3.example.com   # non-secret fields of the contract
    bucket: example
    secretRef:
      name: example-s3-credentials   # Secret in namespace <p> holding the secret fields
```

`check.sh` validates the fields against `okdp-lib/contracts/<contract>.schema.json`
(unknown fields, secret fields present, required non-secret fields missing).

### `platform/connections/<c>.yaml`

Same format as a project connection file; used by platform components only (e.g.
`keycloak-db`, the database of `20-keycloak`). Its `secretRef` names a Secret of the
component's target namespace.

### `platform/components/<NN>-<i>/`

Same files as a service instance. `project` is the target namespace and the release is
still `<project>-<name>`; `connections` name files of `platform/connections/`. Layers: `00` CRDs/operators,
`10` infra, `20` identity/storage/db, `30` control plane. A layer starts when every
component of the previous non-empty layer is ready (Flux `dependsOn` + `wait`, Argo
RollingSync).

## Values layers

In this exact order under both engines (later layers win, maps merge deeply, lists
are replaced, as with `helm -f a -f b`):

1. `platform/platform-values.yaml`
2. each connection file in the order of `connections`: `projects/<p>/connections/<c>.yaml`
   for a service, `platform/connections/<c>.yaml` for a platform component
3. the instance's `values.yaml`

| | Flux | Argo CD |
|---|---|---|
| layer 1 | ConfigMap `okdp-releases/okdp-platform-values`, key `values.yaml` | `$values/<prefix>/platform/platform-values.yaml` |
| layer 2, service | ConfigMap `okdp-releases/conn-<p>-<c>`, key `values.yaml` | `$values/<prefix>/projects/<p>/connections/<c>.yaml` |
| layer 2, component | ConfigMap `okdp-releases/okdp-platform-conn-<c>`, key `values.yaml` | `$values/<prefix>/platform/connections/<c>.yaml` |
| layer 3, service | ConfigMap `okdp-releases/values-<p>-<i>`, key `values.yaml` | `$values/<prefix>/projects/<p>/services/<i>/values.yaml` |
| layer 3, component | ConfigMap `okdp-releases/values-<p>-<i>`, key `values.yaml` | `$values/<prefix>/platform/components/<NN>-<i>/values.yaml` |

The ConfigMaps `okdp-releases/okdp-platform-values` and `okdp-platform-conn-<c>` exist
under both engines (they come from the engine-neutral, generated
`platform/kustomization.yaml`); the control plane server reads the platform values from
`okdp-platform-values`.

## Generated files (Flux): byte-exact format

`scripts/render-flux.sh` writes these files; the control plane server's Go writer must
produce **the same bytes** (`check.sh` fails otherwise). They are derived only from
`instance.yaml` files and directory listings, never from `values.yaml` contents.

Common rules:

- UTF-8, LF line endings, 2-space indentation, no tabs, no trailing spaces, the file
  ends with exactly one `\n`, no blank lines.
- The first line is exactly `# Generated by scripts/render-flux.sh. Do not edit.`
  (`render-flux.sh` also uses it to recognise and delete orphaned generated files).
- A value that comes from `instance.yaml` or from a directory/file name is written
  inside double quotes, without escaping (the validation rules above guarantee no `"`
  or `\`). Every other scalar is written unquoted, exactly as below.
- Lists are sorted by byte order (`LC_ALL=C`) wherever the source is a directory
  listing; `valuesFrom` follows the order of `connections`.

In the templates below, `{{r}}`, `{{p}}`, `{{chart}}`, `{{version}}` and `{{c}}` are
substituted literally; `{{#each ...}}` blocks are repeated, once per item, and emit
nothing for an empty list. Nothing else varies.

### `helmrelease.yaml` (service and component)

For a component, `{{p}}` is its `project` and each connection ConfigMap is named
`okdp-platform-conn-{{c}}` instead of `conn-{{p}}-{{c}}`.

```yaml
# Generated by scripts/render-flux.sh. Do not edit.
---
apiVersion: source.toolkit.fluxcd.io/v1
kind: OCIRepository
metadata:
  name: "{{r}}"
  namespace: okdp-releases
  labels:
    okdp.io/project: "{{p}}"
    okdp.io/instance: "{{r}}"
spec:
  interval: 10m
  url: "{{chart}}"
  ref:
    tag: "{{version}}"
  layerSelector:
    mediaType: application/vnd.cncf.helm.chart.content.v1.tar+gzip
    operation: copy
---
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: "{{r}}"
  namespace: okdp-releases
  labels:
    okdp.io/project: "{{p}}"
    okdp.io/instance: "{{r}}"
spec:
  interval: 10m
  releaseName: "{{r}}"
  targetNamespace: "{{p}}"
  storageNamespace: "{{p}}"
  chartRef:
    kind: OCIRepository
    name: "{{r}}"
  timeout: 15m
  install:
    createNamespace: true
    strategy:
      name: RetryOnFailure
      retryInterval: 2m
  upgrade:
    remediation:
      retries: 3
      strategy: rollback
  driftDetection:
    mode: enabled
  valuesFrom:
    - kind: ConfigMap
      name: okdp-platform-values
      valuesKey: values.yaml
{{#each connections as c}}
    - kind: ConfigMap
      name: "conn-{{p}}-{{c}}"
      valuesKey: values.yaml
{{/each}}
    - kind: ConfigMap
      name: "values-{{r}}"
      valuesKey: values.yaml
```

(The `{{#each}}`/`{{/each}}` marker lines are not part of the output.)

A failed action never uninstalls the release: an uninstall stops half-way on the objects
the `okdp.io/protected` policies of `00-tools` refuse to delete (CRDs, Deployments), after
their ServiceAccounts are gone. A failed install (`timeout: 15m` per Helm action, for the
slow first installs of a loaded machine) is kept and retried in place every 2 minutes,
without limit (the retry is a Helm upgrade of the failed release), as Argo CD retries a
sync; a failed upgrade is rolled back to the last deployed release, 3 times at most. A
release that never deployed has no rollback target: when the retry of its install fails as
well, the HelmRelease stalls (`MissingRollbackTarget`) until the next change of its files
or `flux reconcile helmrelease --force`.

### `kustomization.yaml` (service and component)

```yaml
# Generated by scripts/render-flux.sh. Do not edit.
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: okdp-releases
resources:
  - helmrelease.yaml
configMapGenerator:
  - name: "values-{{r}}"
    files:
      - values.yaml
    options:
      disableNameSuffixHash: true
      labels:
        reconcile.fluxcd.io/watch: Enabled
```

### `projects/<p>/kustomization.yaml`

`services` = the sub-directories of `projects/<p>/services/` that contain an
`instance.yaml`, sorted. `connections` = the files `projects/<p>/connections/*.yaml`
(all of them, referenced or not), names without `.yaml`, sorted. Rewrite this file
whenever a service or a connection file is added or removed.

```yaml
# Generated by scripts/render-flux.sh. Do not edit.
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: okdp-releases
resources:
{{#each services as i}}
  - services/{{i}}
{{/each}}
configMapGenerator:
{{#each connections as c}}
  - name: "conn-{{p}}-{{c}}"
    files:
      - values.yaml=connections/{{c}}.yaml
    options:
      disableNameSuffixHash: true
      labels:
        reconcile.fluxcd.io/watch: Enabled
{{/each}}
```

An empty list is written on the key line instead: `resources: []` and/or
`configMapGenerator: []`. Example of a project without services or connections:

```yaml
# Generated by scripts/render-flux.sh. Do not edit.
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: okdp-releases
resources: []
configMapGenerator: []
```

Note: `services/{{i}}` is not quoted (it is a path, not a value).

### `platform/kustomization.yaml` (platform administrators only)

Not written by the server. `connections` = the files `platform/connections/*.yaml`,
names without `.yaml`, sorted. Applied by both engines (Flux Kustomization / Argo
Application `okdp-platform-values`).

```yaml
# Generated by scripts/render-flux.sh. Do not edit.
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: okdp-releases
configMapGenerator:
  - name: okdp-platform-values
    files:
      - values.yaml=platform-values.yaml
    options:
      disableNameSuffixHash: true
      labels:
        reconcile.fluxcd.io/watch: Enabled
{{#each connections as c}}
  - name: "okdp-platform-conn-{{c}}"
    files:
      - values.yaml=connections/{{c}}.yaml
    options:
      disableNameSuffixHash: true
      labels:
        reconcile.fluxcd.io/watch: Enabled
{{/each}}
```

### `flux/components.yaml` (platform administrators only)

Not written by the server (it never writes platform components). One Kustomization per
component directory, layers in order `00 10 20 30`, directories sorted inside a layer.
`dependsOn` lists every component of the nearest lower non-empty layer, or
`okdp-platform-values` for the lowest layer. `{{base}}` is `./<prefix>/platform/components`
(`./platform/components` when the layout is at the repository root; `render-flux.sh
--path-prefix`, by default the path of this directory in its Git repository).

```yaml
# Generated by scripts/render-flux.sh. Do not edit.
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: okdp-component-{{NN}}-{{i}}
  namespace: flux-system
spec:
  interval: 10m
  retryInterval: 1m
  timeout: 10m
  sourceRef:
    kind: GitRepository
    name: okdp-gitops
  path: {{base}}/{{NN}}-{{i}}
  prune: true
  wait: true
  dependsOn:
    - name: {{dependency}}
```

It ends with the Kustomization of the project services, which starts once the platform
is ready: its `dependsOn` lists every component of the highest non-empty layer
(`okdp-platform-values` when there is no component). `{{root}}` is `./<prefix>`
(`.` at the repository root).

```yaml
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: okdp-projects
  namespace: flux-system
spec:
  interval: 10m
  retryInterval: 1m
  sourceRef:
    kind: GitRepository
    name: okdp-gitops
  path: {{root}}/projects
  prune: true
  dependsOn:
    - name: {{dependency}}
```

No `wait` on it: one broken instance must not block the others; the control plane
server reads each HelmRelease's conditions. Without the `dependsOn`, a service
installed before the ingress admission webhook or the CA bundle exists fails its
install and its retry, then stalls (`MissingRollbackTarget`).

### What the server writes, per action

| action | files written | files deleted |
|---|---|---|
| deploy instance | `instance.yaml`, `values.yaml`, `helmrelease.yaml`, `kustomization.yaml` of the instance; `projects/<p>/kustomization.yaml` | |
| edit parameters | `values.yaml` | |
| upgrade (version) | `instance.yaml`, `helmrelease.yaml` | |
| change connections | `instance.yaml`, `helmrelease.yaml` | |
| delete instance | `projects/<p>/kustomization.yaml` | the instance directory |
| create/delete connection | `projects/<p>/connections/<c>.yaml`, `projects/<p>/kustomization.yaml` | the connection file (delete) |
| create project | `project.yaml`, `projects/<p>/kustomization.yaml` | |

The golden fixtures are the files in this directory: running `render-flux.sh` on
them is a no-op.

## Install with Flux

Prerequisites: Flux (tested with v2.9.5: source-controller, kustomize-controller,
helm-controller), a Git server holding this repository, and helm-controller started
with `--feature-gates=DisableChartDigestTracking=true`. Without it, helm-controller
appends the OCI digest to the chart version (`5.2.1+f32d40ce76b5`), so `.Chart.Version`
(the `helm.sh/chart` label, the descriptor `version`) differs from Argo CD's:

```sh
kubectl -n flux-system patch deployment helm-controller --type json \
  -p '[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--feature-gates=DisableChartDigestTracking=true"}]'
```

(With `flux bootstrap`, add the same patch to `flux-system/kustomization.yaml`.)

1. Set the Git URL/branch in `flux/sync.yaml` (and the paths `./gitops/...` in
   `flux/sync.yaml` and `flux/platform.yaml` if the layout is not under `gitops/`;
   then render with `scripts/render-flux.sh --path-prefix <prefix>`). Commit.
2. `kubectl apply -f gitops/flux/sync.yaml`

Flux then manages `flux/` itself (Kustomization `okdp`), the platform values
(`okdp-platform-values`), the components (`okdp-component-*`, ordered by layer) and
all projects (`okdp-projects`: Flux generates the root kustomization of `projects/`
from the `projects/<p>/kustomization.yaml` files). HelmReleases, OCIRepositories and
values ConfigMaps live in namespace `okdp-releases`; Helm release storage is in the
target namespace. Deleting an instance directory uninstalls the release (`prune`).

## Install with Argo CD

Prerequisites: Argo CD (tested with v3.4.2) with progressive syncs enabled on the
ApplicationSet controller, needed by the layer ordering of platform components:

```sh
kubectl -n argocd patch configmap argocd-cmd-params-cm --type merge \
  -p '{"data":{"applicationsetcontroller.enable.progressive.syncs":"true"}}'
kubectl -n argocd rollout restart deployment argocd-applicationset-controller
```

1. Set the Git URL/branch in `argocd/root.yaml`, `argocd/platform-values.yaml`,
   `argocd/components.yaml`, `argocd/services.yaml` and `argocd/projects.yaml` (and the `gitops/` prefix of
   the paths if the layout is elsewhere). Commit.
2. `kubectl apply -n argocd -f gitops/argocd/`

Argo CD then manages `argocd/` itself (Application `okdp`), the platform values
(Application `okdp-platform-values`, same kustomization as Flux), one Application
`<r>` per component and per service instance. Each Application has two sources: the
OCI chart (`repoURL` = chart reference without `oci://` and chart name, `chart` =
name, `targetRevision` = version) and this repository as `ref: values`;
`helm.valueFiles` lists the layers in contract order; `releaseName: <r>`; destination
namespace `<p>` (`CreateNamespace=true` for the components). A service belongs to the
AppProject `project-<p>` (Application `okdp-project-<p>`, chart `argocd/okdp-project`,
one per `projects/<p>/project.yaml`): sources limited to this repository and the OKDP
chart registries (`chartRepositories`), destination limited to namespace `<p>`, no
cluster-scoped resource. The same chart creates namespace `<p>` (the services cannot)
and keeps it when the project is removed (`Delete=false`). `<p>` is the directory name, not the `project` key of
`instance.yaml`, so a file of a project cannot target another namespace; the platform
components keep the AppProject `okdp`. Both ApplicationSets ignore the `caBundle`
that cert-manager's cainjector, ingress-nginx's certgen hook or trust-manager
inject after the apply (webhook configurations and CRD conversion webhooks,
`RespectIgnoreDifferences=true`); `compare-engines.sh` ignores it too. Applications
sync with `ServerSideApply=true` and diff server-side
(`argocd.argoproj.io/compare-options: ServerSideDiff=true,IncludeMutationWebhook=true`:
the objects defaulted by the API server or a mutating webhook, such as CloudNativePG
Clusters or trust-manager Bundles, stay in sync) (the CloudNativePG and External Secrets CRDs exceed
the client-side apply annotation limit; Flux's helm-controller applies server-side as
well) and retry without limit (backoff up to 5 minutes): a service may wait for the
platform on a first install. Deleting an instance directory deletes the
Application and its resources (finalizer). The generated `helmrelease.yaml` and
`kustomization.yaml` files are ignored by Argo CD.

## Scripts

- `scripts/configure.sh [-i] [--engine flux|argocd] [--storage seaweedfs|rustfs]`:
  sets `gitops.engine` of the control plane server and swaps the `20-storage` component
  (`instance.yaml`, `values.yaml`) with the one parked in `optional/storage/<store>`,
  rewrites the `internalUrl` of the connection files pointing at the store, then runs
  `render-flux.sh`. Without arguments on a terminal (or with `-i`) it asks, the current
  values being the defaults; `--show` prints them. Edits the layout only. Needs yq v4.
- `scripts/render-flux.sh [--root DIR] [--path-prefix PREFIX]`: validates every
  `instance.yaml` and writes the generated files. Writes nothing when anything is
  invalid. Needs bash 4+ and yq v4 (mikefarah).
- `scripts/check.sh [--contracts DIR] [--helm]`: YAML syntax, file shapes, connection
  contracts, generated files up to date, `kustomize build` of every kustomization;
  `--helm` also runs `helm template` of every instance with its values layers (pulls
  the charts). Needs yq v4 and jq; kustomize and helm optional.
- `scripts/compare-engines.sh`: compares the live objects of releases between a Flux
  cluster and an Argo CD cluster, ignoring engine-specific metadata. See its header.
