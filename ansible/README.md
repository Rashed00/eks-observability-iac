# Ansible — optional Traefik-on-EC2 ingress

This directory is a placeholder for an alternative, cost-optimized ingress
path: replacing the AWS NLB with a single ARM EC2 instance running Traefik
in Docker. At the scale of a small observability platform an NLB processes
~1.4 TiB/day of remote-write traffic and costs roughly **820 USD/month**,
while a `t4g.medium` EC2 + Traefik covers the same traffic for about
**24 USD/month**.

The default deployment in this repo uses NLB (simpler, fully managed). The
Traefik path exists as a future learning exercise — here's what it would
look like:

```
ansible/
├── inventory.yml
├── deploy-traefik.yml         # Installs Docker + Traefik on the EC2 host
└── traefik/
    ├── docker-compose.yml
    ├── traefik.yml            # Static config
    ├── dynamic/
    │   ├── routers.yml        # *.monitoring.<domain> -> NodePort 30080
    │   ├── services.yml
    │   ├── middlewares.yml
    │   └── tls.yml
    └── certs/                 # Let's Encrypt wildcard cert (certbot DNS-01)
```

And the matching Terraform additions would be:
- An EC2 t4g.medium with an Elastic IP.
- A security-group rule on the EKS node SG allowing the EC2's SG to reach
  NodePorts 30080/30443.
- A Route53 A record for `*.monitoring.<domain>` → Elastic IP (instead of a
  CNAME → NLB).
- Switch the Envoy Gateway `envoyService.type` from `LoadBalancer` to
  `NodePort` with `nodePort: 30080/30443`.

Reference implementation (closed-source) is at
`/workspace/aau/repositories/eks-observability/ansible/` — copy and adapt
the playbook structure if you want to wire this up.
