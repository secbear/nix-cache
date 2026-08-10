locals {
  stack_slug = replace(lower(var.stack_name), "/[^a-z0-9-]/", "-")

  bucket_name = coalesce(var.r2_bucket_name, "${local.stack_slug}-niks3")

  cache_hostname   = "${var.cache_subdomain}.${var.zone_name}"
  cache_public_url = "https://${local.cache_hostname}"
  fly_public_url   = "https://${var.fly_app_name}.fly.dev"

  r2_s3_endpoint_host = (
    var.r2_jurisdiction == "default"
    ? "${var.cloudflare_account_id}.r2.cloudflarestorage.com"
    : "${var.cloudflare_account_id}.${var.r2_jurisdiction}.r2.cloudflarestorage.com"
  )

  # OIDC config written to the Fly guest via [[files]]. Deploy requires at least one exact trusted
  # subject; current niks3 rejects an empty provider set rather than treating it as disabled.
  oidc_config_json = jsonencode({
    providers = length(var.oidc_github_subject_patterns) == 0 ? {} : {
      github = {
        issuer        = "https://token.actions.githubusercontent.com"
        audience      = local.fly_public_url
        bound_subject = var.oidc_github_subject_patterns
      }
    }
  })
}
