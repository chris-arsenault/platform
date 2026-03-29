# Dynamic OpenGraph for SPAs

> **AUDIENCE**: AI agents adding per-route OpenGraph tags to SPA projects on the platform.

## Problem

SPAs serve one `index.html` for all routes. Social crawlers (Facebook, Slack, Discord, iMessage, X) don't execute JavaScript — they read raw HTML. Every shared link gets the same generic preview. We need per-route OG tags (title, description, hero image) without a persistent server.

## Solution

A per-project Lambda function acts as a CloudFront origin for HTML routes. On cache miss, it reads the request path, queries the shared RDS for entity metadata, stamps OG tags into an HTML template, and returns it. CloudFront caches at the edge. Static assets (JS, CSS, images) are served from a separate S3 origin.

The Lambda is only invoked on cache misses. For a personal site, this is a handful of invocations per day at most.

## Architecture

```
Browser/Crawler → CloudFront Distribution
                    ├─ /assets/*     → S3 Origin (hashed, immutable cache)
                    ├─ /config.js    → S3 Origin (no-cache)
                    ├─ *.png,svg,ico → S3 Origin
                    └─ * (default)   → Lambda Function URL Origin
                                       ├─ Cache HIT → serve from edge
                                       └─ Cache MISS → invoke Lambda
                                            ├─ Parse path (/recipes/:slug)
                                            ├─ Query RDS for metadata
                                            ├─ Stamp OG tags into HTML
                                            └─ Return (cached by CF)
```

## Prerequisites

- **Path-based routing** — hash routing (`#/recipes/:slug`) is invisible to crawlers. The SPA must use `history.pushState` with real paths (`/recipes/:slug`).
- **Shared RDS access** — the Lambda runs in the platform VPC with access to the project's database.

## Lambda Implementation

The Lambda is a small Rust crate in the project's backend workspace. It:

1. Parses the request path to identify the entity (e.g., `/recipes/:slug`)
2. Queries the database for metadata (title, description, hero image URL)
3. Returns HTML with OG tags and the SPA bootloader

```rust
// Pseudocode
async fn handle(path) -> HTML {
    let og = if let Some(slug) = path.strip_prefix("/recipes/") {
        let meta = db.query_recipe_by_slug(slug);
        OgTags { title: meta.title, description: meta.description, image: meta.image_url }
    } else {
        default_og_tags()
    };

    render_html(og, entry_js, entry_css)
}
```

### Asset Injection

The Lambda needs to reference the current hashed JS and CSS entry files. Terraform extracts these from the Vite build output and passes them as Lambda environment variables:

```hcl
locals {
  frontend_js  = one([for f in fileset(local.frontend_dir, "assets/*.js") : f])
  frontend_css = one([for f in fileset(local.frontend_dir, "assets/*.css") : f])
}

resource "aws_lambda_function" "og_server" {
  environment {
    variables = {
      ENTRY_JS  = "/${local.frontend_js}"
      ENTRY_CSS = "/${local.frontend_css}"
      SITE_URL  = "https://${local.frontend_hostname}"
    }
  }
}
```

No asset manifest, no extra fetch. The Lambda stamps the paths directly into `<script>` and `<link>` tags. Terraform updates the env vars on every deploy when asset hashes change.

### HTML Template

The Lambda returns HTML that loads the SPA the same way `index.html` would:

```html
<!DOCTYPE html>
<html lang="en">
<head>
  <meta property="og:title" content="{{title}}" />
  <meta property="og:description" content="{{description}}" />
  <meta property="og:image" content="{{image}}" />
  <meta property="og:url" content="{{url}}" />
  <link rel="stylesheet" href="{{ENTRY_CSS}}" />
</head>
<body>
  <div id="root"></div>
  <script src="/config.js"></script>
  <script type="module" src="{{ENTRY_JS}}"></script>
</body>
</html>
```

The `config.js` is served from S3 (managed by Terraform with runtime config values). The SPA boots and takes over routing client-side.

## Terraform Setup

### Lambda Function URL

The Lambda uses a Function URL (not the shared ALB) because it's a CloudFront origin, not an API endpoint:

```hcl
resource "aws_lambda_function_url" "og_server" {
  function_name      = aws_lambda_function.og_server.function_name
  authorization_type = "NONE"
}
```

### CloudFront Behaviors

Replace the single-origin SPA pattern with dual origins:

```hcl
# Origin 1: S3 for static assets
origin {
  domain_name              = aws_s3_bucket.frontend.bucket_regional_domain_name
  origin_id                = "S3-frontend"
  origin_access_control_id = aws_cloudfront_origin_access_control.frontend.id
}

# Origin 2: Lambda for HTML
origin {
  domain_name = replace(replace(aws_lambda_function_url.og_server.function_url, "https://", ""), "/", "")
  origin_id   = "Lambda-og"
  custom_origin_config {
    http_port              = 80
    https_port             = 443
    origin_protocol_policy = "https-only"
    origin_ssl_protocols   = ["TLSv1.2"]
  }
}
```

**Ordered cache behaviors** (evaluated in order, first match wins):

| Path pattern | Origin | Cache |
|-------------|--------|-------|
| `/assets/*` | S3 | Immutable (1 year) |
| `/config.js` | S3 | No-cache |
| `*.png`, `*.svg`, `*.ico` | S3 | 1 day |
| `*` (default) | Lambda | `s-maxage=3600` (CF caches 1h, browser revalidates) |

**Remove** the 404→index.html custom error responses — the Lambda handles all paths now. Remove `default_root_object` — the Lambda serves `/` directly.

### S3 Changes

**Stop uploading `index.html` to S3.** The Lambda generates it dynamically. Exclude it from the `site_files` fileset:

```hcl
site_files = {
  for file in fileset(local.frontend_dir, "**") :
  file => file
  if file != "config.js" && file != "index.html"
}
```

## Caching Strategy

| Route | Cache-Control | Rationale |
|-------|--------------|-----------|
| `/recipes/:slug` | `public, s-maxage=86400, max-age=0` | CF caches 24h. Browser revalidates. |
| `/`, `/recipes`, etc. | `public, s-maxage=3600, max-age=0` | Shorter cache for index pages. |
| `/assets/*` | `public, max-age=31536000, immutable` | Hashed filenames, never changes. |
| `/config.js` | `no-cache` | Must resolve to latest deploy. |

### Cache Invalidation

When content changes (recipe created/updated), invalidate the specific path:

```bash
aws cloudfront create-invalidation \
  --distribution-id $DIST_ID \
  --paths "/recipes/chimichurri-for-costco-beef"
```

First 1,000 invalidation paths/month are free. Terraform's `/*` invalidation on deploy handles asset changes.

## Deploy Process

These workflows are independent:

**SPA build (every deploy):**
1. Build SPA → hashed assets + config.js
2. Upload assets to S3 with immutable cache headers
3. Terraform updates Lambda env vars with new entry JS/CSS paths
4. CloudFront `/*` invalidation

**Lambda code change (rare — only if route patterns or template change):**
1. `cargo lambda build` builds the og-server crate alongside other Lambdas
2. Terraform deploys new Lambda code via `archive_file`

**Content change (recipe created/updated):**
1. Writes to RDS as usual (existing app behavior)
2. Optionally invalidate the CloudFront path for immediate OG update

## Cost

Effectively zero incremental cost:
- **Lambda**: ~50ms per invocation at 128MB. With CF caching, low hundreds of invocations/month.
- **CloudFront**: already paid for (same distribution as the SPA).
- **RDS**: already exists, one lightweight SELECT per cache miss.

## Reference Implementation

See `tastebase` for a working implementation:
- `backend/og-server/` — Rust Lambda crate
- `infrastructure/terraform/frontend.tf` — dual-origin CloudFront setup
