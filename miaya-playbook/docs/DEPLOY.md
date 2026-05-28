# Deploy

End-to-end deployment to a Kubernetes cluster behind nginx-ingress.

## Prereqs

- `kubectl` configured for your cluster
- `nginx-ingress` controller installed
- A storage class supporting `ReadWriteOnce` (default in most clusters)
- A DNS hostname pointing at your ingress controller (e.g. `miaya.tim.holm.chat`)
- Optional: `cert-manager` for TLS

## 1. Create the GitHub repo (private)

```bash
gh repo create miaya-playbook --private --source=. --remote=origin --push
```

(or do it via the web UI and add the remote)

Push triggers `.github/workflows/build-and-push.yml`, which builds and pushes `ghcr.io/<owner>/miaya-playbook:latest` to GHCR.

Confirm in `https://github.com/<owner>/miaya-playbook/pkgs/container/miaya-playbook` that an image exists. Make the package visibility "private" if not already.

## 2. Prepare cluster

```bash
kubectl apply -f k8s/namespace.yaml
```

### GHCR pull secret

Generate a classic Personal Access Token at https://github.com/settings/tokens with `read:packages` scope:

```bash
kubectl create secret docker-registry ghcr-pull \
  --docker-server=ghcr.io \
  --docker-username=YOUR_GH_USERNAME \
  --docker-password=YOUR_PAT \
  --docker-email=you@example.com \
  -n miaya-playbook
```

### Basic auth secret

```bash
# Pick a username
htpasswd -c auth tim
# (enter password twice)

kubectl create secret generic basic-auth --from-file=auth -n miaya-playbook
rm auth
```

## 3. Edit manifests

In `k8s/deployment.yaml`, replace `OWNER` with your GitHub username/org:

```yaml
image: ghcr.io/tim-username/miaya-playbook:latest
```

In `k8s/ingress.yaml`, replace `miaya.example.com` with your real hostname. If using TLS via cert-manager, uncomment the `tls:` block and the `cert-manager.io/cluster-issuer` annotation.

## 4. Apply

```bash
kubectl apply -k k8s/
```

Watch the rollout:

```bash
kubectl -n miaya-playbook get pods -w
kubectl -n miaya-playbook logs deploy/miaya-playbook -f
```

## 5. Verify

```bash
# Port-forward without ingress
kubectl -n miaya-playbook port-forward svc/miaya-playbook 8080:80
# open http://localhost:8080

# Via ingress
curl -u tim:PASSWORD https://miaya.tim.holm.chat/
```

## Backups

The SQLite database and uploaded documents live on the PVC `miaya-data` at `/data`. Back up via:

```bash
# Snapshot the SQLite DB
kubectl -n miaya-playbook exec deploy/miaya-playbook -- \
  sh -c 'sqlite3 /data/playbook.db ".backup /tmp/backup.db" && cat /tmp/backup.db' \
  > backup-$(date +%Y%m%d).db

# Snapshot the uploads
kubectl -n miaya-playbook cp \
  $(kubectl -n miaya-playbook get pod -l app=miaya-playbook -o jsonpath='{.items[0].metadata.name}'):/data/uploads \
  ./uploads-backup-$(date +%Y%m%d)
```

Or use a CSI snapshot of the PVC if your storage supports it.

## Upgrade

After pushing a new image tag (CI does this automatically on push to `main`):

```bash
kubectl -n miaya-playbook rollout restart deploy/miaya-playbook
```

## Tear down

```bash
kubectl delete -k k8s/
# PVC will be retained per default reclaim policy; delete explicitly if desired:
kubectl -n miaya-playbook delete pvc miaya-data
```
