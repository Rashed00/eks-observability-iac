################################################################################
# ACM certificate for *.monitoring.<root_domain>
#
# Issued against the existing Route53 zone for var.root_domain. The NLB
# (provisioned by the AWS Load Balancer Controller in the cluster) consumes
# this cert via the `service.beta.kubernetes.io/aws-load-balancer-ssl-cert`
# annotation on the Envoy Gateway Service. The ARN is exposed in outputs.tf
# so the gitops repo can reference it.
################################################################################

data "aws_route53_zone" "root" {
  name         = "${var.root_domain}."
  private_zone = false
}

resource "aws_acm_certificate" "observability" {
  domain_name               = local.wildcard_domain
  validation_method         = "DNS"
  subject_alternative_names = [local.observability_domain]

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Name    = local.observability_domain
    Purpose = "TLS for observability services"
  }
}

resource "aws_route53_record" "cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.observability.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  allow_overwrite = true
  zone_id         = data.aws_route53_zone.root.zone_id
  name            = each.value.name
  type            = each.value.type
  ttl             = 60
  records         = [each.value.record]
}

resource "aws_acm_certificate_validation" "observability" {
  certificate_arn         = aws_acm_certificate.observability.arn
  validation_record_fqdns = [for r in aws_route53_record.cert_validation : r.fqdn]

  timeouts {
    create = "10m"
  }
}
