variable "stack_name" {
  description = "Short identifier used for derived resource names."
  type        = string
}

variable "cloudflare_account_id" {
  description = "Cloudflare account ID that owns R2."
  type        = string
}

variable "cloudflare_zone_id" {
  description = "Cloudflare zone ID for the public cache hostname."
  type        = string
}

variable "zone_name" {
  description = "Authoritative DNS zone name, for example example.com."
  type        = string
}

variable "cache_subdomain" {
  description = "Subdomain used for the public binary cache endpoint."
  type        = string
  default     = "cache"
}

variable "r2_bucket_name" {
  description = "Optional explicit R2 bucket name. Null derives from stack_name."
  type        = string
  default     = null
  nullable    = true
}

variable "r2_location" {
  description = "Cloudflare R2 bucket location."
  type        = string
  default     = "enam"

  validation {
    condition     = contains(["apac", "eeur", "enam", "weur", "wnam", "oc"], var.r2_location)
    error_message = "r2_location must be one of apac, eeur, enam, weur, wnam, or oc."
  }
}

variable "r2_jurisdiction" {
  description = "Cloudflare R2 jurisdiction."
  type        = string
  default     = "default"

  validation {
    condition     = contains(["default", "eu", "fedramp"], var.r2_jurisdiction)
    error_message = "r2_jurisdiction must be one of default, eu, or fedramp."
  }
}

variable "r2_storage_class" {
  description = "Default storage class for new objects."
  type        = string
  default     = "Standard"

  validation {
    condition     = contains(["Standard", "InfrequentAccess"], var.r2_storage_class)
    error_message = "r2_storage_class must be Standard or InfrequentAccess."
  }
}

variable "r2_s3_region" {
  description = "Region string passed to niks3 for the R2 S3 client."
  type        = string
  default     = "auto"
}

variable "fly_app_name" {
  description = "Fly app name used for the write/admin API plane."
  type        = string
}

variable "fly_org_slug" {
  description = "Optional Fly organization slug used when creating the app. If null, deploy auto-detects a single accessible org."
  type        = string
  default     = null
  nullable    = true
}

variable "fly_primary_region" {
  description = "Fly primary region for the app."
  type        = string
  default     = "iad"
}

variable "fly_vm_cpu_kind" {
  description = "Fly VM cpu_kind."
  type        = string
  default     = "shared"
}

variable "fly_vm_cpus" {
  description = "Fly VM CPU count."
  type        = number
  default     = 1
}

variable "fly_vm_memory" {
  description = "Fly VM memory value, for example 256mb or 512mb."
  type        = string
  default     = "256mb"
}

variable "fly_swap_size_mb" {
  description = "Fly swap size in MB."
  type        = number
  default     = 512
}

variable "niks3_s3_concurrency" {
  description = "Maximum concurrent S3 operations for niks3."
  type        = number
  default     = 20

  validation {
    condition     = var.niks3_s3_concurrency >= 1
    error_message = "niks3_s3_concurrency must be at least 1."
  }
}

variable "niks3_enable_read_proxy" {
  description = "Whether the Fly write plane also exposes a low-volume fallback read path."
  type        = bool
  default     = true
}

variable "oidc_github_subject_patterns" {
  description = "Exact GitHub Actions OIDC subjects allowed to administer the cache. Use trusted main refs; do not use owner/repository wildcards."
  type        = list(string)

  validation {
    condition     = length(var.oidc_github_subject_patterns) > 0
    error_message = "oidc_github_subject_patterns must contain at least one exact trusted subject."
  }
}
