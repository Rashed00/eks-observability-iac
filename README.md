# eks-observability-iac

**Terraform Infrastructure-as-Code for the EKS observability platform.**

This repo provisions everything in AWS — the EKS cluster, networking, storage,
IAM, secrets, certificates — that the platform runs on. Once `terraform apply`
finishes here, you're ready to install ArgoCD and let the [gitops
repo](../eks-observability-gitops/) take over.

> One of three repos. See the [top-level README](../README.md) for how this
> repo fits with `eks-observability-helm-charts` and `eks-observability-gitops`.

---

## The big picture

```
┌─────────────────────────────────────────────────────────────────────────┐
│                            AWS  (region: eu-central-1)                  │
│                                                                         │
│  ┌──────────────────────────────────────────────────────────────────┐   │
│  │  VPC (10.0.0.0/16) — 3 AZ public/private/intra subnets           │   │
│  │                                                                  │   │
│  │  ┌─────────────────┐                                             │   │
│  │  │  fck-nat        │  (t4g.nano spot, replaces NAT Gateway)      │   │
│  │  └─────────────────┘                                             │   │
│  │                                                                  │   │
│  │  ┌──────────────────────────────────────────────────────────┐    │   │
│  │  │  EKS 1.34  "observability-cluster"  (single-AZ workloads)│    │   │
│  │  │                                                          │    │   │
│  │  │  ┌────────────────┐  ┌────────────────────────────────┐  │    │   │
│  │  │  │ system NG      │  │ observability NG (SPOT)        │  │    │   │
│  │  │  │ (CoreDNS,      │  │ (LGTM stack pods)              │  │    │   │
│  │  │  │  Karpenter)    │  └────────────────────────────────┘  │    │   │
│  │  │  └────────────────┘                                      │    │   │
│  │  │                                                          │    │   │
│  │  │  ┌────────────────────────────────────────────────────┐  │    │   │
│  │  │  │ Karpenter (spot, single-AZ, NodePool default)      │  │    │   │
│  │  │  └────────────────────────────────────────────────────┘  │    │   │
│  │  └──────────────────────────────────────────────────────────┘    │   │
│  └──────────────────────────────────────────────────────────────────┘   │
│                                                                         │
│  ┌────────────────┐  ┌────────────────┐  ┌────────────────┐             │
│  │ S3 (Loki x2,   │  │ EFS            │  │ Secrets Mgr    │             │
│  │   Tempo,       │  │ (Grafana RWX)  │  │ (grafana, basic-auth, slack) │
│  │   Thanos,      │  │                │  │                │             │
│  │   logs)        │  │                │  │                │             │
│  └────────────────┘  └────────────────┘  └────────────────┘             │
│                                                                         │
│  ┌────────────────┐  ┌────────────────┐                                 │
│  │ ACM (wildcard) │  │ Route53 zone   │                                 │
│  │ *.monitoring   │  │ <root_domain>  │                                 │
│  │  .<domain>     │  │                │                                 │
│  └────────────────┘  └────────────────┘                                 │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## Repo layout

```
eks-observability-iac/
├── bootstrap/
│   └── tf-state/                # One-shot TF that creates the S3 state bucket
├── environments/
│   └── production/              # The central observability cluster
├── spokes/
│   └── demo-spoke/              # A second EKS cluster used as a demo spoke
├── spoke-alloy-values/          # Helm values that spoke clusters use for Alloy
│   └── demo-spoke/alloy-values.yaml
├── scripts/                     # Operator scripts (start/stop, DNS, spoke install)
├── ansible/                     # Optional: Traefik-on-EC2 alternative ingress
├── docs/                        # Long-form docs
└── .github/workflows/           # CI: pr-validate, apply, drift-detect
```

The **separation of concerns** to internalize:

| Concern | Where it lives |
|---|---|
| AWS infrastructure (VPC, EKS, IAM, S3, ACM, Secrets Manager) | This repo |
| Helm chart definitions and values | [`eks-observability-helm-charts`](../eks-observability-helm-charts/) |
| ArgoCD apps deciding which chart goes where | [`eks-observability-gitops`](../eks-observability-gitops/) |

A change in any one repo is independent of the other two.

---

## Prerequisites

| Tool | Version |
|---|---|
| Terraform | >= 1.10.0 |
| AWS CLI | >= 2.15 |
| kubectl | >= 1.30 |
| helm | >= 3.14 (for spoke Alloy install) |
| jq | any (for the spoke install script) |

Plus an AWS account where you can:
- Create VPCs, EKS clusters, IAM roles, S3 buckets.
- Use a Route53 hosted zone you already own (for ACM + DNS).

---

## First-time setup

### 1. Create the Terraform state bucket (one shot, per AWS account)

```bash
cd bootstrap/tf-state
terraform init
terraform apply -var "bucket_name=eks-observability-tfstate-<your-account-id>"
```

This writes a small `terraform.tfstate` file **locally** — it's gitignored.

### 2. Configure the production environment

```bash
cd ../../environments/production

cp terraform.tfvars.example terraform.tfvars
cp backend.tfbackend.example backend.tfbackend
# Edit BOTH files. terraform.tfvars holds your secrets; backend.tfbackend points to the state bucket.

terraform init -backend-config=backend.tfbackend
terraform plan
terraform apply
```

This step provisions everything. It takes ~20 minutes the first time.

### 3. Configure kubectl

```bash
$(terraform output -raw configure_kubectl)

kubectl get nodes
```

### 4. Hand off to the gitops repo

You're done here. The next step is to install ArgoCD and apply the root
Application — see [`eks-observability-gitops/README.md`](../eks-observability-gitops/README.md).

### 5. After ArgoCD provisions the Envoy Gateway NLB

```bash
./scripts/update-dns.sh
```

This reads the NLB hostname from the in-cluster Gateway resource and writes
the Route53 wildcard CNAME `*.monitoring.<domain>` → NLB.

### 6. (Optional) Provision the demo spoke

```bash
cd spokes/demo-spoke
terraform init -backend-config=../../environments/production/backend.tfbackend  # same bucket, different key
terraform apply

# Then install Alloy on it
cd ../..
./scripts/install-spoke-alloy.sh demo-spoke
```

Verify in Grafana: `up{cluster="demo-spoke"}` should return rows.

---

## Day-2 operations

### Make a change

1. Edit a `.tf` file in `environments/production/`.
2. `terraform plan` — read the output carefully.
3. Open a PR → CI runs `fmt`, `validate`, `tflint`, `tfsec`, and posts the plan as a comment.
4. After review/approval, merge to `main` → the `apply.yml` workflow runs (requires manual approval in the GitHub Environment).

### Scale down for the night

```bash
./scripts/cluster-shutdown.sh
```

Saves ~120 USD/month if you only need the cluster during business hours.

### Bring it back up

```bash
./scripts/cluster-startup.sh
```

### Rotate a secret

Edit `terraform.tfvars`, re-apply. The External Secrets Operator (deployed
by the gitops repo) picks up the new value within `refreshInterval` (1 hour
by default).

---

## CI/CD

| Workflow | When | What |
|---|---|---|
| `pr-validate.yml` | PR opened / updated | fmt + validate + tflint + tfsec + plan (comments output on PR) |
| `apply.yml` | Push to `main` or manual dispatch | `terraform apply` under a protected GitHub Environment with required reviewers |
| `drift-detect.yml` | Daily at 06:00 UTC | `terraform plan -detailed-exitcode` — opens a GitHub Issue if state drifts from desired |

All workflows use **OIDC** to assume an AWS role (no long-lived AWS keys in GitHub). See `docs/CI_SETUP.md` for how to wire up the OIDC trust policy.

---

## Cost optimizations applied

| Optimization | Saving |
|---|---|
| fck-nat instead of AWS NAT Gateway | ~95 USD/mo |
| Single-AZ workloads (no cross-AZ data transfer) | ~700 USD/mo (at scale) |
| Karpenter on SPOT instances | ~70 % on compute |
| S3 lifecycle Standard → IA → Glacier | ~50 % on storage > 30 days |

The biggest remaining cost is the EKS control plane itself (73 USD/mo, no
way around that on AWS) and the NLB. If you want to drop the NLB cost too,
see [`ansible/README.md`](./ansible/README.md) for the Traefik-on-EC2 path.

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `terraform init` fails with backend errors | Bootstrap not done. Run `bootstrap/tf-state/` first. |
| `aws_iam_service_linked_role.spot` says AlreadyExists | The Spot SLR already exists in your account. Remove that resource from `eks.tf` or `terraform state rm` it. |
| Karpenter pods CrashLoopBackOff | OIDC provider hasn't propagated yet. Wait 60s and re-roll the pods. |
| NLB stuck pending | The AWS Load Balancer Controller pods aren't healthy — `kubectl logs -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller`. |
| `terraform apply` fails on EFS mount target | EFS mount targets need a few seconds; just re-run apply. |

---

## What's intentionally NOT in this repo

- Application deployments (live in the [gitops repo](../eks-observability-gitops/)).
- Helm chart definitions (live in the [helm-charts repo](../eks-observability-helm-charts/)).
- Long-lived AWS access keys (CI uses OIDC; humans use SSO).
