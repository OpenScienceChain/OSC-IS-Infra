resource "aws_s3_bucket" "edge" {
  #checkov:skip=CKV_AWS_18: Private OAC-only status origin; WAF and CloudFront provide request logging without a recursive log bucket.
  #checkov:skip=CKV_AWS_144: The authorized experiment is single-region us-west-2 and must leave zero cross-region residuals.
  #checkov:skip=CKV_AWS_145: AES256 encryption avoids a customer-managed KMS key whose deletion window would outlive teardown.
  #checkov:skip=CKV2_AWS_62: This bucket serves static status files and does not process object-created events.
  bucket        = "${local.name_prefix}-edge-${var.authorized_account_id}"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "edge" {
  bucket                  = aws_s3_bucket.edge.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "edge" {
  bucket = aws_s3_bucket.edge.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "edge" {
  bucket = aws_s3_bucket.edge.id
  rule {
    id     = "expire-demo-edge"
    status = "Enabled"
    abort_incomplete_multipart_upload { days_after_initiation = 1 }
    expiration { days = 30 }
    noncurrent_version_expiration { noncurrent_days = 7 }
  }
}

resource "aws_s3_bucket_versioning" "edge" {
  bucket = aws_s3_bucket.edge.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_object" "index" {
  bucket                 = aws_s3_bucket.edge.id
  key                    = "index.html"
  source                 = "${path.module}/templates/index.html"
  source_hash            = filemd5("${path.module}/templates/index.html")
  content_type           = "text/html; charset=utf-8"
  server_side_encryption = "AES256"
}

resource "aws_s3_object" "status" {
  bucket                 = aws_s3_bucket.edge.id
  key                    = "status.json"
  content                = replace(file("${path.module}/templates/status.json"), "__RUN_ID__", var.run_id)
  content_type           = "application/json"
  cache_control          = "no-store, max-age=0"
  server_side_encryption = "AES256"

  lifecycle { ignore_changes = [content] }
}

resource "aws_cloudfront_origin_access_control" "edge" {
  name                              = "${local.name_prefix}-edge"
  description                       = "Private OSC-IS demo status origin"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_response_headers_policy" "security" {
  name = "${local.name_prefix}-security"
  security_headers_config {
    content_security_policy {
      content_security_policy = "default-src 'self'; base-uri 'none'; frame-ancestors 'none'; form-action 'self'; object-src 'none'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; upgrade-insecure-requests"
      override                = true
    }
    content_type_options { override = true }
    frame_options {
      frame_option = "DENY"
      override     = true
    }
    referrer_policy {
      referrer_policy = "no-referrer"
      override        = true
    }
    strict_transport_security {
      access_control_max_age_sec = 31536000
      include_subdomains         = true
      override                   = true
      preload                    = true
    }
  }
}

resource "aws_cloudfront_cache_policy" "edge" {
  name        = "${local.name_prefix}-edge"
  default_ttl = 60
  max_ttl     = 300
  min_ttl     = 0
  parameters_in_cache_key_and_forwarded_to_origin {
    cookies_config { cookie_behavior = "none" }
    headers_config { header_behavior = "none" }
    query_strings_config { query_string_behavior = "none" }
    enable_accept_encoding_brotli = true
    enable_accept_encoding_gzip   = true
  }
}

resource "aws_cloudfront_cache_policy" "api" {
  name        = "${local.name_prefix}-api-disabled"
  default_ttl = 0
  max_ttl     = 0
  min_ttl     = 0
  parameters_in_cache_key_and_forwarded_to_origin {
    cookies_config { cookie_behavior = "none" }
    headers_config { header_behavior = "none" }
    query_strings_config { query_string_behavior = "none" }
    enable_accept_encoding_brotli = true
    enable_accept_encoding_gzip   = true
  }
}

resource "aws_cloudfront_origin_request_policy" "api" {
  name = "${local.name_prefix}-api-viewer"
  cookies_config { cookie_behavior = "all" }
  headers_config {
    header_behavior = "allExcept"
    headers { items = ["host"] }
  }
  query_strings_config { query_string_behavior = "all" }
}

resource "aws_acm_certificate" "edge" {
  provider          = aws.edge
  domain_name       = var.public_hostname
  validation_method = "DNS"
  lifecycle { create_before_destroy = true }
}

resource "aws_route53_record" "certificate" {
  for_each = {
    for option in aws_acm_certificate.edge.domain_validation_options : option.domain_name => {
      name   = option.resource_record_name
      record = option.resource_record_value
      type   = option.resource_record_type
    }
  }
  zone_id         = var.hosted_zone_id
  name            = each.value.name
  type            = each.value.type
  records         = [each.value.record]
  ttl             = 60
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "edge" {
  provider                = aws.edge
  certificate_arn         = aws_acm_certificate.edge.arn
  validation_record_fqdns = [for record in aws_route53_record.certificate : record.fqdn]
}

resource "aws_cloudwatch_log_group" "waf" {
  #checkov:skip=CKV_AWS_158: AWS-owned encryption avoids a KMS key whose deletion window would violate zero-residual teardown.
  #checkov:skip=CKV_AWS_338: Seven-day retention is proportionate for a disposable demo capped at 72 hours.
  provider          = aws.edge
  name              = "aws-waf-logs-${local.name_prefix}"
  retention_in_days = 7
}

resource "aws_wafv2_web_acl" "edge" {
  provider    = aws.edge
  name        = "${local.name_prefix}-edge"
  description = "Managed rules, payload bound, and shared-NAT-aware rate control"
  scope       = "CLOUDFRONT"

  default_action {
    allow {}
  }

  rule {
    name     = "AWSManagedCommon"
    priority = 10
    override_action {
      none {}
    }
    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "ManagedCommon"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "AWSManagedKnownBadInputs"
    priority = 15
    override_action {
      none {}
    }
    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
        vendor_name = "AWS"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "ManagedKnownBadInputs"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "RejectOversizeBody"
    priority = 20
    action {
      block {}
    }
    statement {
      size_constraint_statement {
        comparison_operator = "GT"
        size                = 11534336
        field_to_match {
          body { oversize_handling = "MATCH" }
        }
        text_transformation {
          priority = 0
          type     = "NONE"
        }
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "OversizeBody"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "SharedNatRateLimit"
    priority = 30
    action {
      challenge {}
    }
    statement {
      rate_based_statement {
        aggregate_key_type = "IP"
        limit              = 5000
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "SharedNatRate"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${local.name_prefix}-edge"
    sampled_requests_enabled   = true
  }
}

resource "aws_wafv2_web_acl_logging_configuration" "edge" {
  provider                = aws.edge
  log_destination_configs = [aws_cloudwatch_log_group.waf.arn]
  resource_arn            = aws_wafv2_web_acl.edge.arn
  redacted_fields {
    single_header { name = "cookie" }
  }
  redacted_fields {
    single_header { name = "authorization" }
  }
}

resource "aws_cloudfront_distribution" "edge" {
  #checkov:skip=CKV_AWS_86: WAF request logs are enabled with credential-bearing headers redacted; a second S3 log sink would create retained duplicate data.
  #checkov:skip=CKV_AWS_310: The bounded single-region demonstration uses a static fallback page instead of a second origin.
  #checkov:skip=CKV_AWS_374: Conference guests are intentionally supported without country restrictions.
  #checkov:skip=CKV2_AWS_47: AWSManagedRulesKnownBadInputsRuleSet is attached; this graph check does not resolve the managed rule group.
  enabled             = true
  aliases             = [var.public_hostname]
  default_root_object = "index.html"
  web_acl_id          = aws_wafv2_web_acl.edge.arn
  price_class         = "PriceClass_100"

  origin {
    domain_name              = aws_s3_bucket.edge.bucket_regional_domain_name
    origin_id                = "static-edge"
    origin_access_control_id = aws_cloudfront_origin_access_control.edge.id
  }

  default_cache_behavior {
    target_origin_id           = "static-edge"
    viewer_protocol_policy     = "redirect-to-https"
    allowed_methods            = ["GET", "HEAD", "OPTIONS"]
    cached_methods             = ["GET", "HEAD"]
    cache_policy_id            = aws_cloudfront_cache_policy.edge.id
    response_headers_policy_id = aws_cloudfront_response_headers_policy.security.id
    compress                   = true
  }

  custom_error_response {
    error_code            = 403
    response_code         = 200
    response_page_path    = "/index.html"
    error_caching_min_ttl = 0
  }
  custom_error_response {
    error_code            = 404
    response_code         = 200
    response_page_path    = "/index.html"
    error_caching_min_ttl = 0
  }

  restrictions {
    geo_restriction { restriction_type = "none" }
  }

  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate_validation.edge.certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }
}

data "aws_iam_policy_document" "edge_bucket" {
  statement {
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.edge.arn}/*"]
    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.edge.arn]
    }
  }
}

resource "aws_s3_bucket_policy" "edge" {
  bucket = aws_s3_bucket.edge.id
  policy = data.aws_iam_policy_document.edge_bucket.json
}

resource "aws_route53_record" "demo" {
  zone_id = var.hosted_zone_id
  name    = var.public_hostname
  type    = "A"
  alias {
    name                   = aws_cloudfront_distribution.edge.domain_name
    zone_id                = aws_cloudfront_distribution.edge.hosted_zone_id
    evaluate_target_health = false
  }
}
