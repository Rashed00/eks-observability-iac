# Demo spoke cluster

A minimal EKS cluster that exists only to prove the hub-and-spoke story.

After `terraform apply`:

1. Configure kubectl:
   ```bash
   aws eks update-kubeconfig --region eu-central-1 --name demo-spoke --profile default
   ```

2. Install Grafana Alloy on the spoke, pointing at the hub's URLs:
   ```bash
   ../../scripts/install-spoke-alloy.sh demo-spoke
   ```

3. Verify in the hub's Grafana — pick the `Prometheus` datasource and run:
   ```promql
   up{cluster="demo-spoke"}
   ```

   You should see Alloy and the spoke's kubelet metrics.

## Why is this a separate Terraform project?

Hub and spoke have different lifecycles. The hub is permanent; spokes come
and go. Keeping them in separate state files means destroying the demo spoke
later doesn't risk touching the hub.

State file location is `spokes/demo-spoke/terraform.tfstate` in the same S3
bucket the hub uses (see `versions.tf`).
