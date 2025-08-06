output "site_bucket" {
  value = aws_s3_bucket.site.bucket
}

output "cloudfront_domain_name" {
  value = aws_cloudfront_distribution.cdn.domain_name
}

output "api_base_url" {
  value = "https://${aws_apigatewayv2_api.http.api_endpoint}/${var.api_stage_name}"
}

output "dynamodb_table" {
  value = aws_dynamodb_table.quiz.name
}
