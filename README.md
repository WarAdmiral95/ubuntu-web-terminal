# ubuntu-web-terminal

A browser-based Ubuntu 24.04 terminal, powered by [ttyd](https://github.com/tsl0922/ttyd) and packaged as a Helm chart. Each Helm release is one isolated terminal (one pod), which makes it handy for workshops, demos, training labs and SDK trials.

It runs on any Kubernetes cluster. On Amazon EKS it can optionally sit behind an ALB with Amazon Cognito login.

| Mode | Exposure | Auth | Use for |
| ------ | ---------- | ------ | --------- |
| **Docker** | `docker run`, `http://localhost:7681` | None | Quickest try-out on your own machine |
| **Local** (KIND) | Service `LoadBalancer` via cloud-provider-kind, `http://` | None | Local development |
| **A. LoadBalancer / NLB** | Service `LoadBalancer` (an NLB on EKS), `http://` | None | Private or internal testing |
| **B. ALB + Cognito** (EKS) | Ingress → AWS ALB, `https://` | Cognito login (OIDC) | Shared or public access |

```
Mode B
Browser ──HTTPS──▶ ALB (ACM cert, authenticate-oidc) ──▶ Service (ClusterIP) ──▶ Pod: ttyd :7681 → bash
                     │
                     └──▶ Cognito hosted UI (can be in another AWS account)
```

> **Warning:** a browser terminal gives remote shell access with **passwordless sudo** inside the pod. Never expose Mode A or Local mode to the internet. See [Security notes](#security-notes).

## Contents

- [Fastest way: docker run](#fastest-way-docker-run)
- [Repository layout](#repository-layout)
- [Image](#image)
- [Quick start (local, KIND)](#quick-start-local-kind)
- [Mode A: LoadBalancer / NLB](#mode-a-loadbalancer--nlb)
- [Mode B: EKS with ALB + Cognito login](#mode-b-eks-with-alb--cognito-login)
- [Optional features](#optional-features)
- [Values reference](#values-reference)
- [Troubleshooting](#troubleshooting)
- [Known behaviour and limitations](#known-behaviour-and-limitations)
- [Security notes](#security-notes)

## Fastest way: docker run

If you only want the terminal in a browser tab, you don't need Kubernetes or Helm, just Docker:

```bash
docker run -d --name web-terminal -p 127.0.0.1:7681:7681 aneesh1145/ubuntu-web-terminal:latest
```

Open **<http://localhost:7681>** to get a bash shell as user `ubuntu`, with passwordless `sudo`.

- **`-p 127.0.0.1:7681:7681`** publishes the port on localhost only, so other machines on your network can't reach the shell. To use a different host port, change the first number (e.g. `-p 127.0.0.1:8080:7681`, then open `http://localhost:8080`).
- **`-d`** runs it in the background. Omit it (and add `--rm`) to see the ttyd logs in your terminal and remove the container when you press Ctrl+C.

Manage it:

```bash
docker logs -f web-terminal     # shows "WS /ws - ..." when a browser connects
docker stop web-terminal        # stop (files inside the container are kept)
docker start web-terminal       # start it again
docker rm -f web-terminal       # remove it, and everything inside it
```

**Keep your files** across `docker rm` by putting the home directory on a named volume:

```bash
docker run -d --name web-terminal -p 127.0.0.1:7681:7681 \
  -v web-terminal-home:/home/ubuntu \
  aneesh1145/ubuntu-web-terminal:latest
```

On first use, Docker copies the image's home directory (`.bashrc`, `.profile`) into the new volume. Packages installed with `apt` live outside the home directory, so they're still lost when the container is removed. Delete the data with `docker volume rm web-terminal-home`.

**Build the image yourself** instead of pulling it:

```bash
git clone https://github.com/WarAdmiral95/ubuntu-web-terminal.git
cd ubuntu-web-terminal
docker build -t ubuntu-web-terminal:local .
docker run -d --name web-terminal -p 127.0.0.1:7681:7681 ubuntu-web-terminal:local
```

**Get the latest published image:** run `docker pull aneesh1145/ubuntu-web-terminal:latest`, then recreate the container (`docker rm -f web-terminal` and the `docker run` above).

> Don't publish the port on all interfaces (`-p 7681:7681`) on a shared or public network. Anyone who can reach the port gets a shell with sudo. ttyd has no login of its own; for authenticated access, use [Mode B](#mode-b-eks-with-alb--cognito-login).

| Symptom | Fix |
| --------- | ----- |
| `port is already allocated` | Something else is using 7681. Pick another host port: `-p 127.0.0.1:8080:7681` |
| `Conflict. The container name "/web-terminal" is already in use` | Remove the old one with `docker rm -f web-terminal`, or start it with `docker start web-terminal` |
| Browser can't connect | Check `docker ps` shows the container running, and that you opened `http://` (not `https://`) on the host port you published |
| "Press ⏎ to Reconnect" | A proxy, VPN or browser extension is blocking the WebSocket. Try a private window, or check `docker logs web-terminal` for `WS /ws` |

## Repository layout

```
.
├── Dockerfile                        # Ubuntu 24.04 + ttyd, user "ubuntu" with passwordless sudo
└── chart/
    ├── Chart.yaml
    ├── values.yaml
    └── templates/
        ├── deployment.yaml           # the terminal pod
        ├── service.yaml              # LoadBalancer or ClusterIP
        ├── ingress.yaml              # ALB + Cognito auth (ingress.enabled)
        ├── oidc-secret.yaml          # OIDC client secret for the ALB (cognito.mode=oidc)
        ├── oidc-rbac.yaml            # lets the AWS LB Controller read that secret
        ├── image-pull-secret.yaml    # private registry credentials
        ├── serviceaccount.yaml       # optional ServiceAccount (IRSA)
        ├── aws-secret.yaml           # optional static AWS keys for the pod
        └── pvc.yaml                  # optional home-directory volume (persistence.enabled)
```

## Image

A prebuilt image is published as [`aneesh1145/ubuntu-web-terminal`](https://hub.docker.com/r/aneesh1145/ubuntu-web-terminal), and the chart uses it by default.

- Base `ubuntu:24.04`, with `ttyd` 1.7.4 from apt, plus bash, curl, git, sudo, procps, iproute2, ping, vim and tini.
- Uses the `ubuntu` user (UID 1000) that already exists in the base image, with **passwordless sudo**, so users can `apt install` at runtime. If you change the Dockerfile, don't `useradd ubuntu`; the build fails with exit code 9.
- `tini` is PID 1 (`ENTRYPOINT`) and reaps orphaned processes. Without it, daemons started in the background and later stopped linger as `<defunct>` zombies, because ttyd only reaps the shells it starts itself.
- ttyd listens on `7681` and starts `bash -l` for each browser connection (`--writable`).

To build your own image:

```bash
docker build -t <registry>/<repo>:<tag> .
docker push <registry>/<repo>:<tag>
```

Then deploy it with `--set image.repository=<registry>/<repo> --set image.tag=<tag>`. To try a local build on KIND without any registry, see [Option B](#option-b-build-the-image-yourself). Preinstall any tools your users need in the image, because packages installed at runtime are lost when the pod is recreated.

## Quick start (local, KIND)

This needs no cloud account, Ingress or registry. [KIND](https://kind.sigs.k8s.io/) runs Kubernetes in Docker, and [cloud-provider-kind](https://github.com/kubernetes-sigs/cloud-provider-kind) gives `LoadBalancer` Services a reachable IP.

### 1. Install the tools (one time)

You need Docker, `kubectl`, `helm`, and:

```bash
go install sigs.k8s.io/kind@latest                  # or a binary: https://kind.sigs.k8s.io/docs/user/quick-start/#installation
go install sigs.k8s.io/cloud-provider-kind@latest   # or a binary from its GitHub releases page
```

`go install` puts binaries in `$(go env GOPATH)/bin`. Make sure that directory is on your `PATH`.

### 2. Create a cluster and start the load balancer provider

```bash
kind create cluster --name kind          # skip if `kind get clusters` already lists it
```

In a **separate terminal**, start cloud-provider-kind and leave it running:

```bash
cloud-provider-kind
```

- **Linux:** run it as your user, as long as you can use Docker without sudo.
- **macOS / Windows:** run `sudo cloud-provider-kind -enable-lb-port-mapping`, because Docker Desktop's container IPs aren't reachable from the host otherwise.

### 3. Install the chart

Clone the repo first:

```bash
git clone https://github.com/WarAdmiral95/ubuntu-web-terminal.git
cd ubuntu-web-terminal
```

Then pick one option.

#### Option A: use the public image

```bash
helm upgrade --install ubuntu1 ./chart -n web-terminal --create-namespace
```

The defaults (public image, plain `LoadBalancer` Service, no Ingress) work as they are on KIND.

#### Option B: build the image yourself

Use this to try changes to the Dockerfile, or to avoid pulling from Docker Hub. No registry is needed.

1. **Build the image** from the repo root, with a tag other than `latest`:

   ```bash
   docker build -t ubuntu-web-terminal:dev1 .
   docker run --rm ubuntu-web-terminal:dev1 ttyd --version     # quick sanity check
   ```

2. **Load it into the KIND node.** KIND nodes have their own image store and can't see images on your host's Docker:

   ```bash
   kind load docker-image ubuntu-web-terminal:dev1 --name kind
   docker exec kind-control-plane crictl images | grep ubuntu-web-terminal   # confirm it's on the node
   ```

   For a multi-node cluster, `kind load` copies the image to every node. The node container is named `<cluster>-control-plane` (or `<cluster>-worker`, ...).

3. **Install the chart with the local image:**

   ```bash
   helm upgrade --install ubuntu1 ./chart -n web-terminal --create-namespace \
     --set image.repository=ubuntu-web-terminal \
     --set image.tag=dev1 \
     --set image.pullPolicy=IfNotPresent
   ```

   Or keep the overrides in a file, so you don't have to repeat them:

   ```yaml
   # local-values.yaml
   image:
     repository: ubuntu-web-terminal
     tag: dev1
     pullPolicy: IfNotPresent
   ```

   ```bash
   helm upgrade --install ubuntu1 ./chart -n web-terminal --create-namespace -f local-values.yaml
   ```

4. **Confirm the pod uses your image:**

   ```bash
   kubectl get pod -n web-terminal -l app.kubernetes.io/instance=ubuntu1 \
     -o jsonpath='{.items[0].spec.containers[0].image}{"\n"}'      # expect ubuntu-web-terminal:dev1
   ```

Why these settings matter:

| Setting | Why |
| --------- | ----- |
| `image.repository=ubuntu-web-terminal` | No registry prefix, so it matches the image you built and loaded |
| `image.pullPolicy=IfNotPresent` | The chart's default is `Always`, which would try to pull from Docker Hub and fail with `ErrImagePull` |
| A tag other than `latest` | With `latest`, Kubernetes tends to try pulling. A unique tag also makes it obvious which build is running |

**After you change the Dockerfile,** build and load a **new tag**, then upgrade. Reusing the same tag can leave the node running the old image.

```bash
docker build -t ubuntu-web-terminal:dev2 .
kind load docker-image ubuntu-web-terminal:dev2 --name kind
helm upgrade ubuntu1 ./chart -n web-terminal --reuse-values --set image.tag=dev2
```

The Deployment uses the `Recreate` strategy, so the old pod stops before the new one starts, and open browser sessions reconnect to a fresh shell.

### 4. Open the terminal

```bash
kubectl rollout status deploy/ubuntu1 -n web-terminal
kubectl get svc ubuntu1 -n web-terminal -w     # wait until EXTERNAL-IP is set (e.g. 172.18.0.3)
```

- **Linux:** open `http://<EXTERNAL-IP>/`.
- **macOS / Windows** (with `-enable-lb-port-mapping`): find the host port and open `http://localhost:<port>/`:

  ```bash
  docker ps --filter "name=kindccm" --format '{{.Names}}  {{.Ports}}'
  ```

- **Works anywhere,** even without cloud-provider-kind:

  ```bash
  kubectl port-forward -n web-terminal svc/ubuntu1 8080:80
  # open http://localhost:8080/
  ```

Check from the command line:

```bash
IP=$(kubectl get svc ubuntu1 -n web-terminal -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
curl -s -o /dev/null -w '%{http_code}\n' http://$IP/          # expect 200

curl -s -i -N --max-time 3 \
  -H "Connection: Upgrade" -H "Upgrade: websocket" -H "Sec-WebSocket-Version: 13" \
  -H "Sec-WebSocket-Key: dGVzdGtleTEyMzQ1Njc4OQ==" -H "Sec-WebSocket-Protocol: tty" \
  http://$IP/ws | head -1                                       # expect HTTP/1.1 101 Switching Protocols

kubectl logs -n web-terminal deploy/ubuntu1 | grep "WS "       # shows "WS /ws - ..., clients: 1"
```

### 5. Several terminals and cleanup

Each release gets its own pod and LB IP:

```bash
for i in 1 2 3; do
  helm upgrade --install ubuntu$i ./chart -n web-terminal --create-namespace
  # with a locally built image (Option B), add: -f local-values.yaml
done
kubectl get svc -n web-terminal
```

Clean up:

```bash
for i in 1 2 3; do helm uninstall ubuntu$i -n web-terminal; done
kubectl delete namespace web-terminal
# stop cloud-provider-kind with Ctrl+C; optionally: kind delete cluster --name kind
docker rmi ubuntu-web-terminal:dev1 ubuntu-web-terminal:dev2   # if you built images locally (Option B)
```

### Local troubleshooting

| Symptom | Fix |
| --------- | ----- |
| EXTERNAL-IP stays `<pending>` | cloud-provider-kind isn't running. Start it in another terminal |
| `ErrImagePull` / `ImagePullBackOff` with a local image | Image not loaded into KIND, or `pullPolicy` is still `Always`. Run `kind load docker-image ...` and set `image.pullPolicy=IfNotPresent` |
| `kind load` says `image not present locally` | The tag doesn't match what you built. Check `docker images ubuntu-web-terminal` |
| `kind load` loads into the wrong cluster | Pass `--name <cluster>` (see `kind get clusters`). The default name is `kind` |
| Pod runs an old build | You reused the same tag. Load a new tag and `helm upgrade --set image.tag=<new>` |
| EXTERNAL-IP not reachable (macOS/Windows) | Use `-enable-lb-port-mapping` and `localhost:<port>`, or `kubectl port-forward` |
| "Press ⏎ to Reconnect" | Check `kubectl logs` for `WS /ws`. If it's missing, a proxy or browser extension is blocking the WebSocket; try a private window |

## Mode A: LoadBalancer / NLB

On any cloud cluster, the default `LoadBalancer` Service gives the terminal an external address, with **no authentication**. Use it only for private testing, ideally with an internal load balancer or source-IP restrictions.

On **EKS**, a Service without annotations gets a Classic ELB, which isn't a good fit for long-lived WebSockets. Use an NLB through the [AWS Load Balancer Controller](https://kubernetes-sigs.github.io/aws-load-balancer-controller/) instead:

```yaml
# nlb-values.yaml
service:
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-type: "external"
    service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: "ip"
    service.beta.kubernetes.io/aws-load-balancer-scheme: "internet-facing"   # or "internal"
```

```bash
kubectl get deploy -n kube-system aws-load-balancer-controller     # the controller must be installed

helm upgrade --install ubuntu1 ./chart -n web-terminal --create-namespace -f nlb-values.yaml
kubectl get svc ubuntu1 -n web-terminal -w     # wait for EXTERNAL-IP
```

Open `http://<EXTERNAL-IP hostname>`.

- **Without the controller,** use only `service.beta.kubernetes.io/aws-load-balancer-type: "nlb"` (the in-tree provider).
- **Switching an existing release from Classic ELB to NLB:** annotations don't convert an existing load balancer. Delete the Service first, then run `helm upgrade`.

## Mode B: EKS with ALB + Cognito login

### Prerequisites

- An EKS cluster with the AWS Load Balancer Controller installed in `kube-system`.
- An ACM certificate in the **same account and region as the EKS cluster**, covering the terminal's hostname.
- A DNS zone you control (Route 53 or any other provider).
- A Cognito user pool. It can be in the same AWS account or a different one.

### 1. Cognito app client

On the user pool's app client:

| Setting | Value |
| --------- | ------- |
| Client secret | **Required**, because ALB OIDC can't work without one |
| Allowed callback URL | `https://<hostname>/oauth2/idpresponse` (exact match, no trailing slash) |
| OAuth grant type | Authorization code grant |
| OpenID Connect scopes | `openid` (adding `email` is fine) |
| Identity providers | Cognito user pool |
| Domain | Hosted UI domain prefix, or a custom domain (e.g. `auth.example.com`) |

Create the users under **User management → Users**. Self-registration should normally be off.

### 2. Why `cognito.mode: oidc`

ALB's native `authenticate-cognito` action only accepts a user pool in the **same AWS account** as the ALB. A cross-account pool fails with `... is not a valid user pool ARN`. IAM roles can't fix that, because the ELB service validates the ARN itself.

`cognito.mode: oidc` (the default) uses ALB's `authenticate-oidc` against Cognito's standard OIDC endpoints instead, which works in either case. The chart builds the endpoints from `userPoolArn` and `domain`:

| Endpoint | Value |
|----------|-------|
| issuer | `https://cognito-idp.<region>.amazonaws.com/<poolId>` |
| authorize / token / userInfo | `https://<domain>/oauth2/{authorize,token,userInfo}` |

If `domain` contains no dot, it's treated as a prefix and expanded to `<prefix>.auth.<region>.amazoncognito.com`. To compare against Cognito's own config, open `https://cognito-idp.<region>.amazonaws.com/<poolId>/.well-known/openid-configuration`.

Use `cognito.mode: cognito` only when the pool is in the same account as the ALB. That mode needs no client secret Secret.

### 3. Client secret

Create the Secret yourself, so the secret stays out of Helm release history:

```bash
kubectl create namespace web-terminal
kubectl create secret generic ubuntu1-oidc -n web-terminal \
  --from-literal=clientID=<APP_CLIENT_ID> \
  --from-literal=clientSecret='<APP_CLIENT_SECRET>'
```

Alternatively, pass `--set cognito.clientSecret=...` and the chart creates `<release>-oidc`. Rendering fails if neither is set.

The chart also creates a Role and RoleBinding (`oidc-rbac.yaml`). They grant the existing `kube-system/aws-load-balancer-controller` ServiceAccount `get/list/watch` on Secrets **in the release namespace**. Without them, the Ingress fails with `secrets "...-oidc" is forbidden`. The chart doesn't create that ServiceAccount; it only references it. If your controller runs under a different name or namespace, override `cognito.controllerRbac.*`.

### 4. Deploy

```yaml
# cognito-values.yaml
service:
  type: ClusterIP
ingress:
  enabled: true
  hostname: terminal1.example.com
  certificateArn: arn:aws:acm:<region>:<EKS_ACCOUNT_ID>:certificate/<cert-id>
cognito:
  mode: oidc
  userPoolArn: arn:aws:cognito-idp:<region>:<COGNITO_ACCOUNT_ID>:userpool/<poolId>
  clientId: <APP_CLIENT_ID>
  domain: auth.example.com          # or a hosted UI prefix
  existingSecret: ubuntu1-oidc
```

```bash
helm upgrade --install ubuntu1 ./chart -n web-terminal -f cognito-values.yaml
kubectl describe ingress ubuntu1 -n web-terminal   # "Address" = ALB hostname once ready
```

`service.type: ClusterIP` matters: with a `LoadBalancer` Service, that load balancer stays reachable and **bypasses the login**. If you switch an existing release to ClusterIP, check that the old load balancer is gone (`kubectl get svc -n web-terminal`).

### 5. Test before DNS

```bash
ALB=$(kubectl get ingress ubuntu1 -n web-terminal -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
IP=$(dig +short "$ALB" | head -1)
curl -skI --resolve terminal1.example.com:443:$IP https://terminal1.example.com/
```

Expect `HTTP/2 302`, with `location:` pointing at the Cognito `/oauth2/authorize` URL and containing `redirect_uri=https://terminal1.example.com/oauth2/idpresponse`.

### 6. DNS

The ALB only serves `ingress.hostname`, so DNS must point that name at it:

- **Route 53, same account as the ALB:** create an A record with Alias turned on, targeting the Application Load Balancer in its region.
- **Route 53 in another account, or any other DNS provider:** create a CNAME from the hostname to the ALB hostname, TTL 300.

```bash
dig +short terminal1.example.com      # should return the ALB IPs
```

Open **`https://terminal1.example.com`**. The ALB has no port-80 listener, so `http://` hangs.

## Optional features

### Private registry credentials

```bash
# Option 1: an existing dockerconfigjson Secret (recommended)
kubectl create secret docker-registry regcred -n web-terminal \
  --docker-server=<registry> --docker-username=<user> --docker-password=<token>
helm upgrade ... --set imageCredentials.existingSecret=regcred

# Option 2: let the chart create <release>-image-pull
helm upgrade ... --set imageCredentials.registry=<registry> \
  --set imageCredentials.username=<user> --set imageCredentials.password=<token>
```

No pull secret is created unless a username and password, or `existingSecret`, are set. For ECR on EKS, the node role normally handles pulls, so you don't need this.

### AWS access from the pod

Prefer IRSA (an IAM role bound to a ServiceAccount):

```bash
helm upgrade ... --set serviceAccount.create=true \
  --set 'serviceAccount.annotations.eks\.amazonaws\.com/role-arn=arn:aws:iam::<account>:role/<role>' \
  --set aws.region=<region>
```

For static keys, use an existing Secret (keys `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, optional `AWS_SESSION_TOKEN`):

```bash
kubectl create secret generic ubuntu1-aws -n web-terminal \
  --from-literal=AWS_ACCESS_KEY_ID=... --from-literal=AWS_SECRET_ACCESS_KEY=...
helm upgrade ... --set aws.credentials.existingSecret=ubuntu1-aws --set aws.region=<region>
```

- `aws.credentials.accessKeyId` / `secretAccessKey` also work and create `<release>-aws-credentials`, but the values end up in Helm release history.
- `aws.region` sets `AWS_REGION` and `AWS_DEFAULT_REGION`.
- The pod keeps `automountServiceAccountToken: false`. IRSA still works, because EKS injects its own token volume.

> Users have sudo, so they can read any credentials the pod has (`env`, the IRSA token). Grant only the minimum permissions needed, and never use admin or production keys.

### Persistence (home directory)

By default, everything in the pod is lost when the pod is deleted or recreated. Turn on persistence to keep the user's home directory on a PersistentVolumeClaim:

```bash
helm upgrade --install ubuntu1 ./chart -n web-terminal --reuse-values \
  --set persistence.enabled=true \
  --set persistence.size=10Gi
```

When `persistence.enabled=true`, the chart:

- Creates PVC `<release>-data`, or uses `persistence.existingClaim`, and mounts it at `persistence.mountPath` (default `/home/ubuntu`).
- Sets the pod's `fsGroup: 1000` (with `fsGroupChangePolicy: OnRootMismatch`), so the `ubuntu` user can write to a new volume, which typically starts out owned by root.
- Runs a `seed-home` init container that copies `/etc/skel` (`.bashrc`, `.profile`, ...) into the volume **without overwriting** existing files. An empty volume would otherwise hide the image's dotfiles and give a bare prompt.
- Relies on the Deployment's `Recreate` strategy, so the old pod releases the `ReadWriteOnce` volume before the new pod mounts it.

| What | Persists? |
| ------ | ----------- |
| Files under `/home/ubuntu` (tools installed there, data, logs, user files) | Yes |
| Packages installed with `sudo apt install` (`/usr`, `/etc`) | **No**, so bake them into the image |
| Running processes (background daemons) | No. Start them again after the pod is recreated |

Storage requirements:

- **EKS:** the [Amazon EBS CSI driver](https://docs.aws.amazon.com/eks/latest/userguide/ebs-csi.html) add-on and a StorageClass. Check with `kubectl get storageclass`. If none is marked `(default)`, set `persistence.storageClass` (e.g. `gp3`). EBS volumes are tied to one availability zone, so a recreated pod is scheduled in the same AZ.
- **KIND:** works as is, with the built-in `standard` StorageClass (local-path).
- **Other clusters:** any StorageClass that supports `ReadWriteOnce`.

To keep data after `helm uninstall`:

```bash
--set persistence.keepOnUninstall=true    # adds helm.sh/resource-policy: keep to the PVC
```

With the default (`false`), `helm uninstall` deletes the PVC. Depending on the StorageClass reclaim policy (usually `Delete`), the data goes too. To reattach a kept volume to a new release, pass `--set persistence.existingClaim=<old-release>-data`.

Check that it works:

```bash
kubectl exec -n web-terminal deploy/ubuntu1 -- sh -c 'echo hello > ~/persist-test'
kubectl delete pod -n web-terminal -l app.kubernetes.io/instance=ubuntu1
kubectl rollout status deploy/ubuntu1 -n web-terminal
kubectl exec -n web-terminal deploy/ubuntu1 -- cat ~/persist-test      # expect: hello
```

| Symptom | Fix |
| --------- | ----- |
| Pod and PVC stuck `Pending` | No default StorageClass, or (on EKS) the EBS CSI driver isn't installed. Set `persistence.storageClass` or install the driver |
| `Permission denied` writing to `~` | The volume isn't group-writable. Check that `fsGroup: 1000` is in the pod spec (`kubectl get pod -o yaml`) |
| Plain `$` prompt, no colours | Dotfiles are missing. Check the `seed-home` init container logs, or copy them manually: `cp -n /etc/skel/.* ~/` |
| New pod `ContainerCreating` with `Multi-Attach error` | The old pod still holds the RWO volume. Wait for it to terminate. Don't change the strategy to `RollingUpdate` |

### Node placement

```bash
helm upgrade ... --set nodeSelector.workload=web-terminal
helm upgrade ... --set 'nodeSelector.kubernetes\.io/arch=amd64'
```

## Values reference

| Key | Default | Description |
| ----- | --------- | ------------- |
| `image.repository` | `aneesh1145/ubuntu-web-terminal` | Terminal image |
| `image.tag` | `latest` | Image tag. Pin a specific tag for repeatable deployments |
| `image.pullPolicy` | `Always` | Use `IfNotPresent` for images loaded with `kind load` |
| `imageCredentials.existingSecret` | `""` | Existing `kubernetes.io/dockerconfigjson` Secret |
| `imageCredentials.registry` | `docker.io` | Registry for the generated pull secret |
| `imageCredentials.username` / `password` | `""` | Chart creates `<release>-image-pull` when both are set |
| `service.type` | `LoadBalancer` | Use `ClusterIP` with the Ingress |
| `service.port` | `80` | Service port (targets container port 7681) |
| `service.annotations` | `{}` | Load balancer annotations (see [Mode A](#mode-a-loadbalancer--nlb) for an EKS NLB) |
| `serviceAccount.create` / `name` / `annotations` | `false` / `""` / `{}` | ServiceAccount, e.g. for IRSA |
| `aws.region` | `""` | Sets `AWS_REGION` / `AWS_DEFAULT_REGION` |
| `aws.credentials.existingSecret` | `""` | Secret loaded via `envFrom` |
| `aws.credentials.accessKeyId` / `secretAccessKey` / `sessionToken` | `""` | Chart creates `<release>-aws-credentials` |
| `ingress.enabled` | `false` | Create the ALB Ingress with Cognito auth |
| `ingress.hostname` | placeholder | Public hostname (also the Cognito callback host) |
| `ingress.certificateArn` | placeholder | ACM certificate in the EKS account |
| `cognito.mode` | `oidc` | `oidc` (any account) or `cognito` (same account only) |
| `cognito.userPoolArn` / `clientId` / `domain` | placeholders | User pool, app client, hosted UI domain |
| `cognito.existingSecret` | `""` | Secret with `clientID` / `clientSecret` (oidc mode) |
| `cognito.clientSecret` | `""` | Chart creates `<release>-oidc` (oidc mode) |
| `cognito.controllerRbac.create` | `true` | Role and RoleBinding for the LB Controller to read Secrets |
| `cognito.controllerRbac.serviceAccountName` / `serviceAccountNamespace` | `aws-load-balancer-controller` / `kube-system` | Controller identity |
| `persistence.enabled` | `false` | Keep the home directory on a PVC |
| `persistence.mountPath` | `/home/ubuntu` | Where the volume is mounted |
| `persistence.size` | `10Gi` | PVC size |
| `persistence.storageClass` | `""` | StorageClass; empty = cluster default |
| `persistence.accessMode` | `ReadWriteOnce` | PVC access mode |
| `persistence.existingClaim` | `""` | Use an existing PVC instead of creating `<release>-data` |
| `persistence.keepOnUninstall` | `false` | Keep the PVC on `helm uninstall` |
| `nodeSelector` | `{}` | Pod node selector |
| `resources` | 100m/256Mi requests, 2 CPU/2Gi limits | Container resources |

The ALB login session lasts 3600 s (`auth-session-timeout`, set in `ingress.yaml`).

## Troubleshooting

| Symptom | Cause | Fix |
| --------- | ------- | ----- |
| Page loads but always shows **"Press ⏎ to Reconnect"**, and ttyd logs never show `WS /ws` | A corporate proxy or VPN blocks the WebSocket upgrade on plain `http://` | Try another network to confirm. Serve over `https`/`wss` (Mode B), which proxies usually let through, or ask IT to allow the domain |
| ttyd logs show `++ / -- [wsisrv\|n\|adopted]` every 5 s | The readiness probe (a TCP connect every 5 s), not users | Nothing to fix. Real connections log `WS /ws - <ip>` and `started process` |
| On EKS, EXTERNAL-IP looks like `<id>-<n>.<region>.elb.amazonaws.com` | A Classic ELB (no LB annotations) | Use the NLB annotations from [Mode A](#mode-a-loadbalancer--nlb). Delete the Service first |
| Service EXTERNAL-IP stays `<pending>` | No load balancer provider (cloud-provider-kind on KIND, the AWS LB Controller with `type: external` on EKS) | Start or install it, or use `kubectl port-forward` |
| Ingress: `... is not a valid user pool ARN` | Cross-account pool with `cognito.mode: cognito` | Use `cognito.mode: oidc` |
| Ingress: `secrets "...-oidc" is forbidden` | The controller can't read Secrets in the namespace | `cognito.controllerRbac.create: true` (default); check the SA name and namespace |
| Hostname does nothing in the browser | No DNS record, or using `http://` | Create the DNS record; use `https://` |
| Cognito `error=redirect_mismatch` | Callback URL not exactly `https://<hostname>/oauth2/idpresponse`, code grant or `openid` not enabled, or the domain belongs to a different pool | Fix the app client settings ([Mode B step 1](#1-cognito-app-client)) and retry in a private window |
| `401 Authorization Required` on `/oauth2/idpresponse` | Login started at Cognito directly (no ALB nonce cookie), or the client secret doesn't match | Always start at `https://<hostname>/`; compare the secret (below) |
| `<defunct>` processes after stopping background daemons | An older image without tini | Rebuild from the current Dockerfile |

Compare the client secret without printing it:

```bash
kubectl get secret ubuntu1-oidc -n web-terminal -o jsonpath='{.data.clientSecret}' | base64 -d | sha256sum
aws cognito-idp describe-user-pool-client --region <region> --user-pool-id <poolId> \
  --client-id <APP_CLIENT_ID> --query 'UserPoolClient.ClientSecret' --output text | sha256sum
```

## Known behaviour and limitations

- **`exit` doesn't end the session.** The shell exits, and on reconnect ttyd starts a fresh `bash` in the same pod. Files written earlier remain until the pod is recreated.
- **Reopening the tab skips the login** while the ALB session cookie is valid (up to 1 hour), and Cognito's hosted-UI session may log the user straight back in. There's no logout button.
- **Authentication isn't per-terminal.** Any user in the pool can open any terminal that uses the same app client. Cognito has no per-client user assignment; use separate pools, a Pre token generation Lambda that checks group membership, or another authorization layer.
- **One ALB per release.** Each Mode B release creates its own ALB. The LB Controller's `alb.ingress.kubernetes.io/group.name` can share one, but the chart doesn't set it yet.
- **It's a container, not a VM.** `systemctl` doesn't work. Without `persistence.enabled`, nothing survives pod recreation. With it, only the home directory does (see [Persistence](#persistence-home-directory)).
- **Each pod has its own network namespace,** so every terminal can listen on the same ports independently. Avoid `hostNetwork: true`.

## Security notes

- A browser terminal is remote code execution with **root via sudo** inside the pod. Treat the pods as untrusted and disposable, and keep them in a dedicated namespace or node group, away from production workloads.
- Don't leave Mode A or Local mode publicly reachable.
- Give the pod minimal AWS permissions, or none.
- Consider NetworkPolicies to restrict egress, and preinstall dependencies in the image.
- Prefer pre-created Secrets over `--set` for passwords and keys, because `--set` values are stored in Helm release history.
