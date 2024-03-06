terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
    }
  }
}

provider "aws" {
  region = var.region
  alias  = "provider"
}

provider "aws" {
  region = "us-east-1"
  alias  = "us-east-1"
}

locals {
  default_certs = []
  acm_certs     = ["acm"]
  domain_name   = [var.domain_name]
  rediredct_domain_name   = ["www.${var.domain_name}"]
}

data "aws_acm_certificate" "acm_cert" {
  domain   = "${var.hosted_zone}"
  provider = aws.us-east-1
  statuses = [
    "ISSUED",
  ]
}

data "aws_iam_policy_document" "s3_bucket_policy" {
  statement {
    sid = "1"

    actions = [
      "s3:GetObject",
    ]

    resources = [
      "arn:aws:s3:::${var.domain_name}/*",
    ]

    principals {
      type = "AWS"

      identifiers = [
        aws_cloudfront_origin_access_identity.origin_access_identity.iam_arn,
      ]
    }
  }
}

resource "aws_s3_bucket" "s3_bucket" {
  bucket = var.domain_name
}

resource "aws_s3_bucket_policy" "s3_bucket_policy" {
  bucket = aws_s3_bucket.s3_bucket.id
  policy = data.aws_iam_policy_document.s3_bucket_policy.json

}

resource "aws_s3_bucket_website_configuration" "s3_bucket" {
  bucket = aws_s3_bucket.s3_bucket.id

  index_document {
    suffix = "index.html"
  }

  error_document {
    key = "error.html"
  }
}

resource "aws_s3_bucket_versioning" "s3_bucket" {
  bucket = var.domain_name
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_object" "index" {
  bucket       = aws_s3_bucket.s3_bucket.bucket
  key          = "index.html"
  source       = "${path.module}/../web/index.html"
  content_type = "text/html"
  etag         = filemd5("${path.module}/../web/index.html")
}

resource "aws_s3_object" "error" {
  bucket       = aws_s3_bucket.s3_bucket.bucket
  key          = "error.html"
  source       = "${path.module}/../web/error.html"
  content_type = "text/html"
  etag         = filemd5("${path.module}/../web/error.html")
}

resource "aws_s3_object" "img" {
  bucket       = aws_s3_bucket.s3_bucket.bucket
  key          = "businesscard.png"
  source       = "${path.module}/../web/businesscard.png"
  content_type = "image/png"
  etag         = filemd5("${path.module}/../web/businesscard.png")
}

resource "aws_s3_object" "icon" {
  bucket       = aws_s3_bucket.s3_bucket.bucket
  key          = "favicon.ico"
  source       = "${path.module}/../web/favicon.ico"
  content_type = "image/x-icon"
  etag         = filemd5("${path.module}/../web/favicon.ico")
}

resource "aws_s3_object" "css" {
  bucket       = aws_s3_bucket.s3_bucket.bucket
  key          = "style.css"
  source       = "${path.module}/../web/style.css"
  content_type = "text/css"
  etag         = filemd5("${path.module}/../web/style.css")
}

// bucket for static redirect of www subdomain to root domain
resource "aws_s3_bucket" "s3_redirect_bucket" {
  bucket = "www.${var.domain_name}"
}

resource "aws_s3_bucket_website_configuration" "bucket_redirect" {
  bucket = aws_s3_bucket.s3_redirect_bucket.id
  
  redirect_all_requests_to {
    host_name = aws_s3_bucket.s3_bucket.bucket
    protocol  = "https"
  }
}

### ROUTE53 ###

data "aws_route53_zone" "domain_name" {
  name         = var.hosted_zone
  private_zone = false
}


resource "aws_route53_record" "route53_record" {
  depends_on = [
    aws_cloudfront_distribution.s3_distribution
  ]

  zone_id = data.aws_route53_zone.domain_name.zone_id
  name    = var.domain_name
  type    = "A"

  alias {
    name    = aws_cloudfront_distribution.s3_distribution.domain_name
    zone_id = "Z2FDTNDATAQYW2"

    //HardCoded value for CloudFront
    evaluate_target_health = false
  }
}

resource "aws_route53_record" "route53_redirect_record" {
  depends_on = [
    aws_cloudfront_distribution.s3_redirect_distribution
  ]

  zone_id = data.aws_route53_zone.domain_name.zone_id
  name    = "www.${var.domain_name}"
  type    = "A"

  alias {
    name    = aws_cloudfront_distribution.s3_redirect_distribution.domain_name
    //HardCoded value for CloudFront
    zone_id = "Z2FDTNDATAQYW2"
    evaluate_target_health = false
  }
}

resource "aws_cloudfront_distribution" "s3_distribution" {
  depends_on = [
    aws_s3_bucket.s3_bucket
  ]

  origin {
    domain_name = aws_s3_bucket.s3_bucket.bucket_regional_domain_name
    origin_id   = "s3-cloudfront"

    s3_origin_config {
      origin_access_identity = aws_cloudfront_origin_access_identity.origin_access_identity.cloudfront_access_identity_path
    }
  }

  enabled             = true
  is_ipv6_enabled     = true
  default_root_object = "index.html"

  aliases = local.domain_name

  default_cache_behavior {
    allowed_methods = [
      "GET",
      "HEAD",
    ]

    cached_methods = [
      "GET",
      "HEAD",
    ]

    target_origin_id = "s3-cloudfront"

    forwarded_values {
      query_string = false

      cookies {
        forward = "none"
      }
    }

    viewer_protocol_policy = "redirect-to-https"

    # https://stackoverflow.com/questions/67845341/cloudfront-s3-etag-possible-for-cloudfront-to-send-updated-s3-object-before-t
    min_ttl     = var.cloudfront_min_ttl
    default_ttl = var.cloudfront_default_ttl
    max_ttl     = var.cloudfront_max_ttl
  }

  price_class = var.price_class

  restrictions {
    geo_restriction {
      restriction_type = "none"
      locations = []
    }
  }
  dynamic "viewer_certificate" {
    for_each = local.default_certs
    content {
      cloudfront_default_certificate = true
    }
  }

  dynamic "viewer_certificate" {
    for_each = local.acm_certs
    content {
      acm_certificate_arn      = data.aws_acm_certificate.acm_cert.arn
      ssl_support_method       = "sni-only"
      minimum_protocol_version = "TLSv1"
    }
  }

  custom_error_response {
    error_code            = 403
    response_code         = 200
    error_caching_min_ttl = 0
    response_page_path    = "/index.html"
  }

  wait_for_deployment = false
}

resource "aws_cloudfront_distribution" "s3_redirect_distribution" {
  depends_on = [
    aws_s3_bucket.s3_redirect_bucket
  ]

  origin {
    domain_name = aws_s3_bucket_website_configuration.bucket_redirect.website_endpoint
    origin_id   = "s3-cloudfront"

    custom_origin_config {
      http_port                = 80
      https_port               = 443
      origin_keepalive_timeout = 5
      origin_protocol_policy   = "http-only"
      origin_read_timeout      = 30
      origin_ssl_protocols = [
        "TLSv1.2",
      ]
    }
  }

  enabled             = true
  is_ipv6_enabled     = true

  aliases = local.rediredct_domain_name

  default_cache_behavior {
    allowed_methods = [
      "GET",
      "HEAD",
    ]

    cached_methods = [
      "GET",
      "HEAD",
    ]

    target_origin_id = "s3-cloudfront"

    forwarded_values {
      query_string = false

      cookies {
        forward = "none"
      }
    }

    viewer_protocol_policy = "redirect-to-https"

    # https://stackoverflow.com/questions/67845341/cloudfront-s3-etag-possible-for-cloudfront-to-send-updated-s3-object-before-t
    min_ttl     = var.cloudfront_min_ttl
    default_ttl = var.cloudfront_default_ttl
    max_ttl     = var.cloudfront_max_ttl
  }

  price_class = var.price_class

  restrictions {
    geo_restriction {
      restriction_type = "none"
      locations = []
    }
  }
  dynamic "viewer_certificate" {
    for_each = local.default_certs
    content {
      cloudfront_default_certificate = true
    }
  }

  dynamic "viewer_certificate" {
    for_each = local.acm_certs
    content {
      acm_certificate_arn      = data.aws_acm_certificate.acm_cert.arn
      ssl_support_method       = "sni-only"
      minimum_protocol_version = "TLSv1"
    }
  }
  wait_for_deployment = false
}

resource "aws_cloudfront_origin_access_identity" "origin_access_identity" {
  comment = "access-identity-${var.domain_name}.s3.amazonaws.com"
}