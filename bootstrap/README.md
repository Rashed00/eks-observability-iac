# Bootstrap

Things you run **once** per AWS account, before any other Terraform.

## What lives here

| Folder | Purpose |
|---|---|
| `tf-state/` | Creates the S3 bucket that holds all Terraform remote state for this repo. |

## Why is this separate?

Terraform's remote state backend lives in S3, but S3 has to exist *before*
Terraform can use it. That's a chicken-and-egg problem. Solution: a tiny
separate Terraform project that uses **local state** to create the bucket the
rest of the repo will use as **remote state**.

After bootstrap, you never touch this again.

## First-time setup

```bash
# 1. Create the state bucket
cd bootstrap/tf-state
terraform init
terraform apply -var "bucket_name=eks-observability-tfstate-<your-account-id>"

# 2. Copy the printed backend config into environments/production/backend.tfbackend
terraform output backend_config_example > ../../environments/production/backend.tfbackend

# 3. Initialize the production environment with the remote backend
cd ../../environments/production
terraform init -backend-config=backend.tfbackend
```

## Why no DynamoDB lock table?

Terraform 1.10+ supports **native S3 state locking** with `use_lockfile = true`
in the backend config. The lock is stored as a `.tflock` object in the same
bucket as the state, so we no longer need a separate DynamoDB table.

See: https://developer.hashicorp.com/terraform/language/backend/s3#state-locking
