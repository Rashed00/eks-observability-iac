################################################################################
# AWS Secrets Manager + External Secrets Operator (IRSA)
#
# We store secrets here so the gitops repo never has to. The External Secrets
# Operator (deployed via ArgoCD) reads them at runtime and syncs them into
# Kubernetes secrets that the workload pods consume.
#
# Secrets created:
#   - observability/grafana                  (admin user + password)
#   - observability/remote-write-basic-auth  (htpasswd-encoded credentials for
#                                             Envoy SecurityPolicy)
#   - observability/alertmanager-slack       (only if URL is provided)
################################################################################

# ---------------------------------------------------------------------------
# IRSA for External Secrets Operator
# ---------------------------------------------------------------------------

module "external_secrets_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.52"

  role_name = "${var.cluster_name}-external-secrets"

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["external-secrets:external-secrets"]
    }
  }

  role_policy_arns = {
    external_secrets = aws_iam_policy.external_secrets.arn
  }
}

resource "aws_iam_policy" "external_secrets" {
  name        = "${var.cluster_name}-external-secrets"
  description = "Allow External Secrets Operator to read observability/* secrets"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:GetResourcePolicy",
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret",
          "secretsmanager:ListSecretVersionIds",
        ]
        Resource = [
          "arn:aws:secretsmanager:${var.aws_region}:${local.account_id}:secret:observability/*",
        ]
      },
      {
        Effect   = "Allow"
        Action   = ["secretsmanager:ListSecrets"]
        Resource = "*"
      },
    ]
  })
}


# Envoy Gateway's basic auth only accepts {SHA} hashes (SHA1, base64 of the
# raw digest). Terraform has no function for that, so openssl does it.
data "external" "remote_write_htpasswd" {
  program = ["bash", "-c", <<-EOT
    set -euo pipefail
    pw=$(jq -r .password)
    printf '{"sha":"%s"}' "$(printf '%s' "$pw" | openssl dgst -binary -sha1 | base64)"
  EOT
  ]
  query = {
    password = var.remote_write_basic_auth_password
  }
}
# ---------------------------------------------------------------------------
# Secrets
# ---------------------------------------------------------------------------

resource "aws_secretsmanager_secret" "grafana" {
  name                    = "observability/grafana"
  description             = "Grafana admin credentials"
  recovery_window_in_days = 7
}

resource "aws_secretsmanager_secret_version" "grafana" {
  secret_id = aws_secretsmanager_secret.grafana.id
  secret_string = jsonencode({
    admin_user     = var.grafana_admin_user
    admin_password = var.grafana_admin_password
  })
}

# Remote-write basic auth - both the plain creds (for spokes to use) and the
# htpasswd-formatted blob (for Envoy SecurityPolicy to load).
resource "aws_secretsmanager_secret" "remote_write_auth" {
  name                    = "observability/remote-write-basic-auth"
  description             = "Basic auth credentials used by spoke clusters to push telemetry"
  recovery_window_in_days = 7
}

resource "aws_secretsmanager_secret_version" "remote_write_auth" {
  secret_id = aws_secretsmanager_secret.remote_write_auth.id
  secret_string = jsonencode({
    username = var.remote_write_basic_auth_user
    password = var.remote_write_basic_auth_password
    # bcrypt $2y$ hash of <password>, formatted as user:hash for Envoy.
    # Envoy's basic auth filter accepts htpasswd-style entries.
    htpasswd = "${var.remote_write_basic_auth_user}:{SHA}${data.external.remote_write_htpasswd.result.sha}"
    })
}

resource "aws_secretsmanager_secret" "alertmanager_slack" {
  count = var.alertmanager_slack_webhook_url != "" ? 1 : 0

  name                    = "observability/alertmanager-slack"
  description             = "Alertmanager Slack webhook URL"
  recovery_window_in_days = 7
}

resource "aws_secretsmanager_secret_version" "alertmanager_slack" {
  count = var.alertmanager_slack_webhook_url != "" ? 1 : 0

  secret_id = aws_secretsmanager_secret.alertmanager_slack[0].id
  secret_string = jsonencode({
    webhook_url = var.alertmanager_slack_webhook_url
  })
}
