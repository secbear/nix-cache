resource "cloudflare_r2_bucket" "cache" {
  account_id    = var.cloudflare_account_id
  name          = local.bucket_name
  jurisdiction  = var.r2_jurisdiction
  location      = var.r2_location
  storage_class = var.r2_storage_class
}

resource "cloudflare_r2_custom_domain" "cache" {
  account_id   = var.cloudflare_account_id
  bucket_name  = cloudflare_r2_bucket.cache.name
  domain       = local.cache_hostname
  enabled      = true
  jurisdiction = var.r2_jurisdiction
  min_tls      = "1.2"
  zone_id      = var.cloudflare_zone_id
}

# Edge-cache the binary cache. Cloudflare does NOT cache .narinfo/.nar.zst by default (non-standard
# extensions -> cf-cache-status: DYNAMIC/MISS on every pull, ~275KB/s from R2 origin). NARs and
# narinfos are content-addressed and effectively immutable, so cache hits for 7 days; 404s (every
# narinfo probe for a path not yet pushed) only for 60s so a fresh push isn't masked by a cached miss.
resource "cloudflare_ruleset" "cache_edge" {
  zone_id = var.cloudflare_zone_id
  name    = "niks3 edge caching"
  kind    = "zone"
  phase   = "http_request_cache_settings"

  rules = [{
    ref         = "cache_nix_store_objects"
    description = "Edge-cache narinfo/NARs from the nix cache"
    expression  = "(http.host eq \"${local.cache_hostname}\")"
    action      = "set_cache_settings"
    action_parameters = {
      cache = true
      edge_ttl = {
        mode    = "override_origin"
        default = 604800 # 7d: store paths are content-addressed, safe to pin
        status_code_ttl = [{
          status_code = 404
          value       = 60
        }]
      }
    }
  }]
}
