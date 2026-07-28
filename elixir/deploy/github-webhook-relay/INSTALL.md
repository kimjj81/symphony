# Install notes for oracle-cluster

These commands are intentionally examples. Replace registry image, domain, and secret values outside git.

## 1. Check cluster context

```bash
kubectl config get-contexts
kubectl --context oracle-cluster get nodes
```

In this session, `kubectl --context oracle-cluster get nodes` timed out, so I did not apply anything to Oracle.

## 2. Install NATS JetStream

```bash
helm repo add nats https://nats-io.github.io/k8s/helm/charts/
helm repo update
kubectl --context oracle-cluster apply -f deploy/github-webhook-relay/k8s/namespace.yaml
helm --kube-context oracle-cluster upgrade --install nats nats/nats \
  --namespace webhook-relay \
  --values deploy/github-webhook-relay/k8s/nats-values.yaml
```

The provided values keep NATS as a ClusterIP service. For a local Symphony process, prefer a private Cloudflare/Tailscale TCP path or `kubectl port-forward` during tests instead of exposing raw NATS publicly.

Pilot port-forward test:

```bash
kubectl --context oracle-cluster -n webhook-relay port-forward svc/nats 4222:4222
```

Then on the Mac:

```bash
export NATS_URL=nats://127.0.0.1:4222
```

## 3. Create secrets outside git

```bash
kubectl --context oracle-cluster -n webhook-relay create secret generic github-webhook-relay-secrets \
  --from-literal=github-webhook-secret='<github webhook secret>'
```

Do not apply `secrets.example.yaml` as-is.

## 4. Build and push relay image

From `deploy/github-webhook-relay/relay`:

```bash
docker build -t ghcr.io/studiojin-dev/github-webhook-relay:<tag> .
docker push ghcr.io/studiojin-dev/github-webhook-relay:<tag>
```

The GitHub token used for GHCR must include package write scopes. With `gh` CLI:

```bash
gh auth refresh -h github.com -s write:packages -s read:packages
gh auth token | docker login ghcr.io -u <github-user> --password-stdin
```

Then build/push an arm64 image for the Oracle node:

```bash
TAG=ghcr.io/<owner>/github-webhook-relay:<tag>
docker build --platform linux/arm64 -t "$TAG" deploy/github-webhook-relay/relay
docker push "$TAG"
```

Patch `k8s/relay-deployment.yaml` to use the pushed tag before applying.

If GHCR push is not available yet, a single-node k3s pilot can import a locally built arm64 image directly into Oracle's containerd instead:

```bash
TAG=ghcr.io/kimjj81/github-webhook-relay:<tag>
docker build -t "$TAG" deploy/github-webhook-relay/relay
docker save "$TAG" | ssh oracle 'sudo k3s ctr -n k8s.io images import -'
kubectl --context oracle-cluster -n webhook-relay set image deployment/github-webhook-relay relay="$TAG"
```

This is useful for a private pilot, but a pushed registry image is better for durable redeploys.

## 5. Deploy relay

```bash
kubectl --context oracle-cluster apply -f deploy/github-webhook-relay/k8s/relay-service.yaml
kubectl --context oracle-cluster apply -f deploy/github-webhook-relay/k8s/relay-deployment.yaml
```

## 6. Expose `/github` via Cloudflare Tunnel

If Cloudflare Tunnel maps a hostname to k3s ingress, use `relay-ingress.example.yaml` as the public route for `ghook.windroamer.com`.

On the current Oracle cluster, `cloudflared` runs as a Kubernetes pod in the `cloudflare` namespace. Because of that, the Cloudflare Tunnel origin URL is resolved from inside the pod network, not from the Oracle host network.

Route the Cloudflare Tunnel public hostname to Traefik's in-cluster Service DNS name:

```text
ghook.windroamer.com -> http://traefik.kube-system.svc.cluster.local:80
```

Do not use `http://127.0.0.1:30128` for this tunnel while `cloudflared` is running in Kubernetes; from inside the cloudflared pod, `127.0.0.1` means the pod itself, not the Oracle host.

If cloudflared is later moved out of Kubernetes and runs directly on the Oracle host, then the host-level NodePort target is:

```text
http://127.0.0.1:30128
```

After the ingress is applied, GitHub should call:

```text
https://ghook.windroamer.com/github
```

GitHub webhook settings:

```text
Payload URL: https://ghook.windroamer.com/github
Content type: application/json
Secret: same value as github-webhook-secret
Events: issues, issue_comment, pull_request, pull_request_review, pull_request_review_comment, workflow_run/check_suite as needed
```

## 7. Connect a local Symphony process

When Symphony runs outside the cluster, install the shared tunnel template from
`local/com.studiojin.myven-nats-tunnel.plist.example` and keep it running. Then enable
Symphony's NATS consumer with `SYMPHONY_NATS_WEBHOOK_ENABLED=true` and its dedicated
`SYMPHONY_NATS_DURABLE=symphony-webhook` configuration. Verify webhook delivery through
the Symphony process logs before relying on the relay operationally.
