# Production environment

This directory provisions the central observability EKS cluster.

## What's in here

| File | What it provisions |
|---|---|
| `versions.tf` | Required Terraform + provider versions, S3 backend declaration. |
| `providers.tf` | AWS + Kubernetes + Helm + kubectl provider config. |
| `variables.tf` | All inputs (region, cluster name, domain, secrets). |
| `locals.tf` | Derived values (AZs, account ID, computed domains). |
| `networking.tf` | VPC across 3 AZs + fck-nat (cost-optimized NAT instance). |
| `eks.tf` | EKS 1.34, system + observability node groups, Karpenter, KMS. |
| `addons.tf` | AWS Load Balancer Controller, gp3 + efs-sc storage classes. |
| `storage.tf` | S3 buckets (Loki, Tempo, Thanos, logs), IRSA roles, EFS for Grafana. |
| `secrets.tf` | AWS Secrets Manager entries + IRSA for External Secrets Operator. |
| `acm.tf` | ACM wildcard certificate for `*.monitoring.<root_domain>`. |
| `outputs.tf` | Everything the gitops repo / scripts need to know. |

## Apply

```bash
# 1. Copy and fill in the example files
cp terraform.tfvars.example terraform.tfvars
cp backend.tfbackend.example backend.tfbackend
# edit both - fill in your AWS account ID, domain, secrets, etc.

# 2. Init with the remote backend
terraform init -backend-config=backend.tfbackend

# 3. Plan + apply
terraform plan -out=tfplan
terraform apply tfplan
```

## Outputs you'll need afterwards

After `apply`:

```bash
# Configure kubectl
$(terraform output -raw configure_kubectl)

# See all outputs
terraform output
```

The ArgoCD applications in the gitops repo read these IRSA role ARNs and
S3 bucket names via the values files committed to the helm-charts repo.
Re-render those files if you change anything here that affects them
(IRSA names follow `<cluster_name>-<component>` so they're stable as long
as `cluster_name` is unchanged).

## Cost notes

| Component | Approx. cost (us-east-1, no spot interruptions) |
|---|---|
| EKS control plane | 73 USD/mo |
| fck-nat (t4g.nano spot) | 3 USD/mo |
| Managed node group (1× t3.medium ON_DEMAND) | 30 USD/mo |
| Observability node group (2× t3.large SPOT) | ~40 USD/mo |
| Karpenter overflow (varies) | 0–50 USD/mo |
| NLB (Envoy Gateway exposure) | ~20 USD/mo |
| S3 + EFS storage | ~10 USD/mo |
| **Total** | **~180–230 USD/mo** |

To slash the bill for off-hours, run `../../scripts/cluster-shutdown.sh`.
