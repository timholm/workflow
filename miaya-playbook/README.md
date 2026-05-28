# Miaya — crisis playbook

Private operational tracker for a family mental-health / criminal-legal crisis. Streamlit app, SQLite persistence, deployable to a Kubernetes cluster behind nginx-ingress + basic auth.

## What it does

- **Call tracker** — the 10-step phone tree (Guidance Center, Coconino Court, MHC, SMI line, legal aid, CPG-aware advocate, NAMI). Status, who answered, notes, next action per call.
- **Legal tracks** — decision tree for Mental Health Court diversion vs. Rule 11 vs. POA vs. guardianship.
- **Treatment options** — residential placements with cost/length/intake.
- **Ask Allen** — budget builder for the funding conversation.
- **Your support** — NAMI Family-to-Family, Open Door, peer groups.
- **Documents** — upload court paperwork, medical letters, attorney correspondence.

State persists in SQLite on a PVC. Single replica, single writer.

## Deploy

See [docs/DEPLOY.md](docs/DEPLOY.md). TL;DR:

```bash
# 1. Push image (CI does this on push to main)
# 2. Create namespace + secrets
kubectl create namespace miaya-playbook
kubectl create secret docker-registry ghcr-pull \
  --docker-server=ghcr.io \
  --docker-username=YOUR_GH_USERNAME \
  --docker-password=YOUR_GHCR_PAT \
  -n miaya-playbook

htpasswd -c auth YOUR_USERNAME
kubectl create secret generic basic-auth --from-file=auth -n miaya-playbook

# 3. Edit k8s/ingress.yaml — set your hostname
# 4. Apply
kubectl apply -k k8s/
```

## Local dev

```bash
uv sync
uv run streamlit run src/app.py
# open http://localhost:8501
```

## Privacy

This contains sensitive personal/family information. The repo MUST be private. The cluster ingress MUST be auth-gated. Do not share screenshots without redaction.
