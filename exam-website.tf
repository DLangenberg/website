locals {
  bucket_name = coalesce(var.site_bucket_name, "${var.project}-site-${random_id.rand.hex}")


  site_dir   = var.site_dir
  site_files = fileset(local.site_dir, "**/*")
  mime_types = {
    ".html"  = "text/html"
    ".htm"   = "text/html"
    ".css"   = "text/css"
    ".js"    = "application/javascript"
    ".json"  = "application/json"
    ".png"   = "image/png"
    ".jpg"   = "image/jpeg"
    ".jpeg"  = "image/jpeg"
    ".gif"   = "image/gif"
    ".svg"   = "image/svg+xml"
    ".ico"   = "image/x-icon"
    ".woff"  = "font/woff"
    ".woff2" = "font/woff2"
    ".ttf"   = "font/ttf"
    ".map"   = "application/json"
  }

}

resource "random_id" "rand" {
  byte_length = 4
}

resource "aws_s3_bucket" "site" {
  bucket        = local.bucket_name
  force_destroy = true
}

resource "aws_s3_bucket_ownership_controls" "site" {
  bucket = aws_s3_bucket.site.id
  rule { object_ownership = "BucketOwnerEnforced" }
}

resource "aws_s3_bucket_public_access_block" "site" {
  bucket                  = aws_s3_bucket.site.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# -------------------------
# CloudFront OAC + Distribution
# -------------------------
resource "aws_cloudfront_origin_access_control" "oac" {
  name                              = "${var.project}-oac"
  description                       = "OAC for ${aws_s3_bucket.site.bucket}"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

data "aws_s3_bucket" "site" {
  bucket = aws_s3_bucket.site.bucket
}

# Optional custom domain and certificate
resource "aws_route53_zone" "primary" {
  count = var.domain_name == null ? 0 : 1
  name  = var.domain_name
}

resource "aws_acm_certificate" "cert" {
  count             = var.domain_name == null ? 0 : 1
  domain_name       = var.domain_name
  validation_method = "DNS"
  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "cert_validation" {
  for_each = var.domain_name == null ? {} : {
    for dvo in aws_acm_certificate.cert[0].domain_validation_options :
    dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  zone_id = aws_route53_zone.primary[0].zone_id
  name    = each.value.name
  type    = each.value.type
  records = [each.value.record]
  ttl     = 60
}

resource "aws_acm_certificate_validation" "cert" {
  count                   = var.domain_name == null ? 0 : 1
  certificate_arn         = aws_acm_certificate.cert[0].arn
  validation_record_fqdns = [for record in aws_route53_record.cert_validation : record.fqdn]
}

resource "aws_cloudfront_distribution" "cdn" {
  enabled             = true
  comment             = "${var.project} static site"
  price_class         = var.cf_price_class
  default_root_object = "index.html"
  aliases             = var.domain_name == null ? [] : [var.domain_name]

  origin {
    domain_name              = data.aws_s3_bucket.site.bucket_regional_domain_name
    origin_id                = "site-o"
    origin_access_control_id = aws_cloudfront_origin_access_control.oac.id
  }

  default_cache_behavior {
    target_origin_id       = "site-o"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]

    compress = true

    forwarded_values {
      query_string = true
      cookies { forward = "none" }
    }
  }

  restrictions {
    geo_restriction { restriction_type = "none" }
  }

  viewer_certificate {
    acm_certificate_arn            = var.domain_name == null ? null : aws_acm_certificate_validation.cert[0].certificate_arn
    ssl_support_method             = var.domain_name == null ? null : "sni-only"
    minimum_protocol_version       = var.domain_name == null ? null : "TLSv1.2_2021"
    cloudfront_default_certificate = var.domain_name == null ? true : false
  }

  depends_on = [aws_s3_bucket_public_access_block.site]
}

# DNS records for the custom domain
resource "aws_route53_record" "root" {
  count   = var.domain_name == null ? 0 : 1
  zone_id = aws_route53_zone.primary[0].zone_id
  name    = var.domain_name
  type    = "A"
  alias {
    name                   = aws_cloudfront_distribution.cdn.domain_name
    zone_id                = aws_cloudfront_distribution.cdn.hosted_zone_id
    evaluate_target_health = false
  }
}

resource "aws_route53_record" "root_ipv6" {
  count   = var.domain_name == null ? 0 : 1
  zone_id = aws_route53_zone.primary[0].zone_id
  name    = var.domain_name
  type    = "AAAA"
  alias {
    name                   = aws_cloudfront_distribution.cdn.domain_name
    zone_id                = aws_cloudfront_distribution.cdn.hosted_zone_id
    evaluate_target_health = false
  }
}

resource "aws_route53domains_registered_domain" "domain" {
  count       = var.domain_name == null ? 0 : 1
  domain_name = var.domain_name
  name_server {
    name = aws_route53_zone.primary[0].name_servers[0]
  }
  name_server {
    name = aws_route53_zone.primary[0].name_servers[1]
  }
  name_server {
    name = aws_route53_zone.primary[0].name_servers[2]
  }
  name_server {
    name = aws_route53_zone.primary[0].name_servers[3]
  }
  tags = { Project = var.project }
}

resource "aws_s3_object" "site" {
  for_each = {
    for f in local.site_files :
    f => f
    if !endswith(f, "/") && fileexists("${local.site_dir}/${f}")
  }

  bucket = aws_s3_bucket.site.id
  key    = each.key
  source = "${local.site_dir}/${each.value}"
  etag   = filemd5("${local.site_dir}/${each.value}")

  content_type = lookup(local.mime_types,
    regex("\\.[^.]+$", each.value),
    "application/octet-stream"
  )

  # Tweak caching as you like
  cache_control = contains([".html", ".htm"], regex("\\.[^.]+$", each.value)) ? "no-cache" : "max-age=31536000,public"
}

# Bucket policy to allow CloudFront OAC
data "aws_iam_policy_document" "site_policy" {
  statement {
    sid    = "AllowCloudFrontServicePrincipalRead"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }

    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.site.arn}/*"]

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.cdn.arn]
    }
  }
}
resource "aws_s3_bucket_policy" "site" {
  bucket = aws_s3_bucket.site.id
  policy = data.aws_iam_policy_document.site_policy.json
}

# -------------------------
# DynamoDB: single-table
# -------------------------
resource "aws_dynamodb_table" "quiz" {
  name         = "${var.project}-table"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "PK"
  range_key    = "SK"

  attribute {
    name = "PK"
    type = "S"
  }

  attribute {
    name = "SK"
    type = "S"
  }

  attribute {
    name = "GSI1PK"
    type = "S"
  }

  attribute {
    name = "GSI1SK"
    type = "S"
  }

  global_secondary_index {
    name            = "GSI1"
    hash_key        = "GSI1PK"
    range_key       = "GSI1SK"
    projection_type = "ALL"
  }

  tags = { Project = var.project }
}

# -------------------------
# Lambda IAM role
# -------------------------
data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }

  }
}

resource "aws_iam_role" "lambda" {
  name               = "${var.project}-lambda-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_iam_role_policy_attachment" "basic_exec" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Inline policy: DynamoDB access
resource "aws_iam_role_policy" "ddb_access" {
  name = "${var.project}-ddb"
  role = aws_iam_role.lambda.id
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      { Effect = "Allow",
        Action = [
          "dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:BatchWriteItem",
          "dynamodb:Query", "dynamodb:Scan", "dynamodb:DeleteItem"
        ],
        Resource = [
          aws_dynamodb_table.quiz.arn,
          "${aws_dynamodb_table.quiz.arn}/index/GSI1"
        ]
      }
    ]
  })
}

# -------------------------
# Lambda packages (zip from source files)
# -------------------------
data "archive_file" "get_zip" {
  type        = "zip"
  source_dir  = "${path.module}/lambda/get"
  output_path = "${path.module}/lambda/get.zip"
}

data "archive_file" "put_zip" {
  type        = "zip"
  source_dir  = "${path.module}/lambda/put"
  output_path = "${path.module}/lambda/put.zip"
}

# -------------------------
# Lambdas
# -------------------------
resource "aws_lambda_function" "get_quiz" {
  function_name = "${var.project}-get-quiz"
  role          = aws_iam_role.lambda.arn
  runtime       = "nodejs20.x"
  handler       = "index.handler"
  filename      = data.archive_file.get_zip.output_path
  publish       = true

  environment {
    variables = {
      TABLE = aws_dynamodb_table.quiz.name
    }
  }
}

resource "aws_lambda_function" "put_quiz" {
  function_name = "${var.project}-put-quiz"
  role          = aws_iam_role.lambda.arn
  runtime       = "nodejs20.x"
  handler       = "index.handler"
  filename      = data.archive_file.put_zip.output_path
  publish       = true

  environment {
    variables = {
      TABLE = aws_dynamodb_table.quiz.name
    }
  }
}

# -------------------------
# API Gateway (HTTP API) + CORS
# -------------------------
resource "aws_apigatewayv2_api" "http" {
  name          = "${var.project}-api"
  protocol_type = "HTTP"

  cors_configuration {
    allow_headers = ["https://${var.domain_name}"]
    allow_methods = ["GET", "PUT", "OPTIONS"]
    allow_origins = ["*"]
  }
}

resource "aws_apigatewayv2_stage" "stage" {
  api_id      = aws_apigatewayv2_api.http.id
  name        = var.api_stage_name
  auto_deploy = true
}

# GET /v1/quiz
resource "aws_apigatewayv2_integration" "get_int" {
  api_id                 = aws_apigatewayv2_api.http.id
  integration_type       = "AWS_PROXY"
  payload_format_version = "2.0"
  integration_uri        = aws_lambda_function.get_quiz.arn
}

resource "aws_apigatewayv2_route" "get_route" {
  api_id    = aws_apigatewayv2_api.http.id
  route_key = "GET /v1/quiz"
  target    = "integrations/${aws_apigatewayv2_integration.get_int.id}"
}

resource "aws_lambda_permission" "get_invoke" {
  statement_id  = "AllowInvokeGet"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.get_quiz.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.http.execution_arn}/*/*/v1/quiz"
}

# PUT /v1/quiz
resource "aws_apigatewayv2_integration" "put_int" {
  api_id                 = aws_apigatewayv2_api.http.id
  integration_type       = "AWS_PROXY"
  payload_format_version = "2.0"
  integration_uri        = aws_lambda_function.put_quiz.arn
}

resource "aws_apigatewayv2_route" "put_route" {
  api_id    = aws_apigatewayv2_api.http.id
  route_key = "PUT /v1/quiz"
  target    = "integrations/${aws_apigatewayv2_integration.put_int.id}"
}

resource "aws_lambda_permission" "put_invoke" {
  statement_id  = "AllowInvokePut"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.put_quiz.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.http.execution_arn}/*/*/v1/quiz"
}
