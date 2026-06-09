# Architecture

This document explains **why** each piece of AWS infrastructure exists. For
*how* to deploy it, see [`README.md`](./README.md).

## Hub-and-spoke

The platform is built around a single **hub** cluster (the central
observability cluster) and any number of **spoke** clusters that push their
telemetry to the hub:

```
                 ┌──────────────────────────────┐
                 │   Hub: observability-cluster │
                 │   (this repo provisions it)  │
                 │                              │
                 │   Prometheus + Thanos        │   metrics
                 │   Loki                       │ ◄─── logs ───── Spoke A
                 │   Tempo                      │   traces        Spoke B
                 │   Grafana                    │                 ...
                 └──────────────────────────────┘
                            ▲
                            │ HTTPS basic-auth
                            │ over NLB → Envoy Gateway
```

The hub also monitors itself (via Grafana Alloy DaemonSet) — the same code
path the spokes use. This is intentional: if self-monitoring breaks, you'll
find out immediately, and you don't have to maintain a second telemetry
pipeline for the hub.

## Why these technology choices

### EKS 1.34 with the upstream `terraform-aws-modules/eks/aws` module

The community EKS module handles dozens of edge cases (OIDC, cluster security
groups, addon ordering, IRSA, log streams) that you'd otherwise have to
re-derive. It's the de-facto standard. We pin to `~> 21.10`.

### Two managed node groups

- **system** (1× `t3.medium` ON_DEMAND, tainted `CriticalAddonsOnly`):
  exists so CoreDNS and Karpenter always have a stable home. Without it,
  the cluster has a chicken-and-egg problem if a spot node dies and
  Karpenter has no node to land on while it tries to provision a replacement.
- **observability** (1–4× `t3.large` SPOT): runs the LGTM stack. Spot for
  the savings; the system NG provides the fallback if all spots get evicted.

### Karpenter for overflow

Once base load is on the managed NG, Karpenter takes over for any pod that
doesn't fit. Pinned to a single AZ to avoid cross-AZ data transfer.

### Single-AZ for workloads

Cross-AZ data transfer at observability scale is the biggest hidden cost in
AWS. Prometheus + Loki + Tempo + Alloy all push and pull large volumes of
data between pods; if those pods are in different AZs, every byte costs
0.01 USD/GB outbound + 0.01 USD/GB inbound. Pinning workloads to one AZ
removes that bill entirely. The control plane is still multi-AZ (AWS
managed) so an AZ outage doesn't take the cluster down — only the workloads
on that AZ would need rescheduling.

### fck-nat instead of NAT Gateway

AWS NAT Gateway is ~32 USD/month per AZ + 0.045 USD/GB processed.
`fck-nat` is a single t4g.nano spot instance (~3 USD/month) running
NAT through `iptables`. The `RaJiska/fck-nat/aws` module handles the ASG +
route table updates. If it dies, the ASG replaces it in ~30 seconds.

### S3 + IRSA for long-term storage

Loki/Tempo/Thanos all support S3 as their durable backend. We give each
component its own IAM role bound to its Kubernetes service account via OIDC
(IRSA), scoped to just its bucket. No long-lived keys touch the cluster.

### EFS for Grafana

Grafana needs `ReadWriteMany` for the dashboards directory if you ever scale
beyond one replica. EFS is the boring AWS-native answer.

### AWS Secrets Manager + External Secrets Operator

Secrets in the gitops repo would be a disaster waiting to happen. Instead:

1. Terraform writes secrets to AWS Secrets Manager under `observability/*`.
2. The External Secrets Operator (deployed by ArgoCD) reads them via IRSA.
3. ESO creates plain `Secret` objects in the cluster for workloads to consume.

A new secret needs only an `ExternalSecret` CR in the gitops repo — no
key material ever lands in git.

### ACM + NLB for TLS termination

The Envoy Gateway in the cluster is exposed by a `Service: LoadBalancer` of
type `nlb`. The NLB terminates TLS using the ACM wildcard cert provisioned
here. Inside the cluster, traffic is HTTP — simpler, no cert management at
the pod level.

## What's deliberately not here

- **No Prometheus, Loki, Tempo, Grafana** — those are deployed by ArgoCD
  from the helm-charts repo. Keeping them out of Terraform means we can
  iterate on dashboards/alerts at the speed of `git push` rather than
  `terraform apply`.
- **No Karpenter NodePools beyond the default** — workload-specific
  NodePools belong in the gitops repo, alongside the workloads that need them.
- **No application observability** — this is platform infra. Apps that
  want to be observed install Alloy or use the OTLP endpoint exposed by
  Envoy Gateway.
