variable "project" {
  description = "Project name prefix"
  type        = string
  default     = "quiz"
}

variable "region" {
  description = "AWS region"
  type        = string
  default     = "eu-central-1"
}

variable "site_bucket_name" {
  description = "S3 bucket name for the website (must be globally unique)"
  type        = string
  default     = null
}

variable "cf_price_class" {
  description = "CloudFront price class"
  type        = string
  default     = "PriceClass_100" # cheapest: NA+EU
}

variable "api_stage_name" {
  description = "HTTP API stage name"
  type        = string
  default     = "v1"
}

variable "site_dir" {
  description = "Directory with your built static site"
  type        = string
  default     = "./site" # adjust
}

variable "tfc_aws_dynamic_credentials" {
  description = "Object containing AWS dynamic credentials configuration"
  type = object({
    default = object({
      shared_config_file = string
    })
    aliases = map(object({
      shared_config_file = string
    }))
  })
}
