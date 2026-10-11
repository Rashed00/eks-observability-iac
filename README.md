# eks-observability-iac

**Terraform Infrastructure-as-Code for the EKS observability platform.**

This repo provisions everything in AWS — the EKS cluster, networking, storage,
IAM, secrets, certificates — that the platform runs on. It also holds the two
scripts that run the whole platform: `scripts/spin-up.sh` builds it from
nothing (Terraform, ArgoCD, DNS), and `scripts/destroy.sh` removes it again.

> One of three repos. The other two are
> [`eks-observability-helm-charts`](https://github.com/Rashed00/eks-observability-helm-charts)
> (chart definitions and values) and
> [`eks-observability-gitops`](https://github.com/Rashed00/eks-observability-gitops)
> (ArgoCD Applications). Clone all three side by side: `spin-up.sh` expects
> the gitops repo at `../eks-observability-gitops`.

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
│  │  .<domain>     │  │ (made by hand) │                                 │
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
│   └── production/              # The central observability cluster (the hub)
├── spokes/
│   └── demo-spoke/              # A second EKS cluster used as a demo spoke
├── spoke-alloy-values/          # Helm values that spoke clusters use for Alloy
│   └── demo-spoke/alloy-values.yaml
├── scripts/
│   ├── spin-up.sh               # Build the hub from nothing (staged Terraform + ArgoCD + DNS)
│   ├── destroy.sh               # Tear the hub down in the right order, then report leftovers
│   ├── update-dns.sh            # Point *.monitoring.<domain> at the Gateway's load balancer
│   ├── install-spoke-alloy.sh   # Install Alloy on a spoke cluster
│   ├── cluster-shutdown.sh      # Scale to near zero for off-hours
│   └── cluster-startup.sh       # Bring it back
├── ansible/                     # Optional: Traefik-on-EC2 alternative ingress
└── .github/workflows/           # CI: pr-validate, apply, drift-detect
```

The **separation of concerns** to internalize:

| Concern | Where it lives |
|---|---|
| AWS infrastructure (VPC, EKS, IAM, S3, ACM, Secrets Manager) | This repo |
| Helm chart definitions and values | [`eks-observability-helm-charts`](https://github.com/Rashed00/eks-observability-helm-charts) |
| ArgoCD apps deciding which chart goes where | [`eks-observability-gitops`](https://github.com/Rashed00/eks-observability-gitops) |

---

## Prerequisites

| Tool | Version |
|---|---|
| Terraform | >= 1.10.0 |
| AWS CLI | >= 2.15 |
| kubectl | >= 1.30 |
| helm | >= 3.14 |
| jq, git, curl | any |
| dig | any (optional, for the nameserver check) |

Plus an AWS account where you can create VPCs, EKS clusters, IAM roles and
S3 buckets.

---

## One-time setup (per AWS account)

These survive every spin-up and teardown. Do them once.

### 1. Terraform state bucket

```bash
cd bootstrap/tf-state
terraform init
terraform apply -var "bucket_name=eks-observability-tfstate-<your-account-id>"
```

This writes a small `terraform.tfstate` file **locally** — it's gitignored.

### 2. Route53 hosted zone

Terraform only looks the zone up, it does not create it. Create it by hand
and point your registrar's nameservers at it:

```bash
aws route53 create-hosted-zone --name <root_domain> --caller-reference "zone-$(date +%s)"
aws route53 get-hosted-zone --id <ZONE_ID> --query DelegationSet.NameServers
```

Paste the 4 nameservers at your registrar, then wait until
`dig NS <root_domain> +short` shows them. Otherwise the ACM certificate
validation times out.

### 3. Local config files (never committed)

```bash
cd environments/production
cp terraform.tfvars.example terraform.tfvars      # domain + passwords
cp backend.tfbackend.example backend.tfbackend    # state bucket name
```

The EC2 Spot service-linked role belongs to the whole account, so Terraform
does not manage it. `spin-up.sh` creates it if it is missing.

---

## Spin up the hub

```bash
./scripts/spin-up.sh          # asks once before creating anything; -y skips the question
```

About 40–60 minutes. If a step fails, the script prints which one. Fix the
problem and resume from there:

```bash
./scripts/spin-up.sh --from <step>
```

| Step | What it does |
|---|---|
| `preflight` | Checks tools, AWS login, the local config files, the state bucket, the Route53 zone and nameservers. Creates the Spot role if missing. |
| `network` | Terraform: VPC and the NAT instance only. |
| `nat` | Waits for the NAT instance, turns off its source/dest check, fails on blackhole routes. |
| `cluster` | Terraform: the storage IAM roles and EKS, then everything else. |
| `kubeconfig` | Connects kubectl, waits for nodes and the EBS storage add-on. |
| `cert` | Writes the new ACM certificate ARN into the gitops repo and pushes it (the ARN changes on every rebuild). |
| `argocd` | Installs ArgoCD and applies the root app. ArgoCD deploys the rest from the gitops repo. |
| `dns` | Waits for the Gateway's load balancer, then runs `update-dns.sh`. |
| `verify` | Waits for Grafana to answer, lists any app that is not Synced + Healthy, prints the URLs. |

### Why not just `terraform apply`?

The Kubernetes, Helm and kubectl providers read the cluster's address from
the EKS module. Before the cluster exists (or after it is gone), that
address is empty, and a plain `terraform apply` or `terraform destroy`
fails with:

```
Error: invalid provider configuration: ... no configuration has been provided
```

So Terraform runs in stages with `-target`. Terraform only loads the
providers that the targeted resources need, so the cluster-dependent
providers are not started until the cluster exists.

---

## Tear down the hub

```bash
./scripts/destroy.sh          # type 'destroy' to confirm; -y skips the question
./scripts/destroy.sh --from <step>   # resume after a failure
```

| Step | What it does |
|---|---|
| `preflight` | Checks tools and login, says whether the cluster still exists. |
| `freeze-argocd` | Stops ArgoCD so it does not recreate what we delete. |
| `gateway` | Deletes the Gateway and LoadBalancer services, waits until the AWS load balancer is gone. |
| `volumes` | Deletes the apps' PVCs, waits until their EBS disks are gone. |
| `nodes` | Deletes the Karpenter node pools, waits until their instances are gone. |
| `dns` | Removes the `*.monitoring.<domain>` records. |
| `tf-cluster` | Terraform: everything except the network. |
| `sweep` | Deletes what the cluster created outside Terraform: load balancers, target groups, stray instances, network interfaces, `k8s-traffic-*` security groups, leftover disks. |
| `tf-network` | Terraform: NAT instance and VPC. |
| `report` | Lists anything still in the account. |

**Why the order matters:** the load balancer, its security group, Karpenter
nodes and PVC disks are created by controllers inside the cluster, so
Terraform does not know about them. If they are still alive, Terraform
cannot delete the certificate, the security groups or the VPC, and the
destroy fails. Running the script again after a half-finished destroy is
safe: steps that need the cluster skip themselves when it is gone.

**Kept on purpose:** the state bucket and the Route53 zone.

---

## Demo spoke (optional)

**Always pass the spoke's own state key.** The spoke's `backend "s3"` block
has no key, and the shared `backend.tfbackend` file points at the hub's key.
Without the extra `-backend-config`, the spoke would overwrite the hub's
state.

```bash
cd spokes/demo-spoke
terraform init \
  -backend-config=../../environments/production/backend.tfbackend \
  -backend-config="key=spokes/demo-spoke/terraform.tfstate"
terraform apply

# Then install Alloy on it
cd ../..
./scripts/install-spoke-alloy.sh demo-spoke
```

Verify in the hub's Grafana: `up{cluster="demo-spoke"}` should return rows.

Destroy the spoke before the hub (same `init`, then `terraform destroy`).

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

Scales the workloads and the observability node group to zero. EBS volumes,
S3 data and the control plane stay. Not yet tested against the current setup.

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
| `apply.yml` | Push to `main` (under `environments/production/` or `bootstrap/tf-state/`) or manual dispatch | `terraform apply` under a protected GitHub Environment with required reviewers |
| `drift-detect.yml` | Daily at 06:00 UTC | `terraform plan -detailed-exitcode` — opens a GitHub Issue if state drifts from desired |

All workflows use **OIDC** to assume an AWS role (no long-lived AWS keys in
GitHub).

`apply.yml` runs a single `terraform apply`, so it only works while the
cluster exists. To build the platform from nothing, use `spin-up.sh`.

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
| `invalid provider configuration ... no configuration has been provided` | A plain `terraform apply`/`destroy` while the cluster does not exist. Use `spin-up.sh` / `destroy.sh`, which run Terraform in stages. |
| `aws_iam_service_linked_role.spot` says AlreadyExists | An old version of the code that still managed the Spot role. Pull the latest; the role is now created by `spin-up.sh` only if missing. |
| Every HTTPS route returns 500 | Envoy Gateway rejected the basic-auth secret. It only accepts `{SHA}` hashes, not bcrypt. See `secrets.tf`. |
| ACM certificate stays `PENDING_VALIDATION` | Your registrar is not pointing at the Route53 zone's nameservers. `spin-up.sh` preflight checks this. |
| Karpenter pods CrashLoopBackOff | OIDC provider hasn't propagated yet. Wait 60s and re-roll the pods. |
| NLB stuck pending | The AWS Load Balancer Controller pods aren't healthy — `kubectl logs -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller`. |
| `terraform apply` fails on EFS mount target | EFS mount targets need a few seconds; just re-run apply. |
| `terraform destroy` hangs on security groups, the certificate or the VPC | Something the cluster created is still alive (load balancer, `k8s-traffic-*` security group, Karpenter node). Run `destroy.sh`; its `sweep` step removes them. |

---

## What's intentionally NOT in this repo

- Application deployments (live in the [gitops repo](https://github.com/Rashed00/eks-observability-gitops)).
- Helm chart definitions (live in the [helm-charts repo](https://github.com/Rashed00/eks-observability-helm-charts)).
- Long-lived AWS access keys (CI uses OIDC; humans use SSO).