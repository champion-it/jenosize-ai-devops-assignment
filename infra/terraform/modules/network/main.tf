# Private networking for the platform.
#
# Cloud SQL is reachable only over private IP. Cloud Run reaches it through
# Direct VPC egress, which avoids the extra hop and cost of a Serverless VPC
# Access connector.

resource "google_compute_network" "main" {
  name                    = "${var.name_prefix}-vpc"
  auto_create_subnetworks = false
  routing_mode            = "REGIONAL"
}

resource "google_compute_subnetwork" "main" {
  name          = "${var.name_prefix}-subnet"
  ip_cidr_range = var.subnet_cidr
  region        = var.region
  network       = google_compute_network.main.id

  # Flow logs give the audit trail enterprise and government work expects.
  log_config {
    aggregation_interval = "INTERVAL_10_MIN"
    flow_sampling        = 0.5
    metadata             = "INCLUDE_ALL_METADATA"
  }

  private_ip_google_access = true
}

# Range handed to Google for the managed Cloud SQL instance.
resource "google_compute_global_address" "private_service_range" {
  name          = "${var.name_prefix}-psa"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 16
  network       = google_compute_network.main.id
}

resource "google_service_networking_connection" "private_service_access" {
  network                 = google_compute_network.main.id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.private_service_range.name]
}

# Default deny. Nothing talks to anything until a rule below allows it.
resource "google_compute_firewall" "deny_all_ingress" {
  name      = "${var.name_prefix}-deny-all-ingress"
  network   = google_compute_network.main.name
  direction = "INGRESS"
  priority  = 65534

  deny {
    protocol = "all"
  }

  source_ranges = ["0.0.0.0/0"]
}

resource "google_compute_firewall" "allow_internal_postgres" {
  name      = "${var.name_prefix}-allow-internal-postgres"
  network   = google_compute_network.main.name
  direction = "INGRESS"
  priority  = 1000

  allow {
    protocol = "tcp"
    ports    = ["5432"]
  }

  source_ranges = [var.subnet_cidr]
}

# Edge protection for the public entry point. Rate limiting here is the
# primary control; the application level limiter is the fallback.
resource "google_compute_security_policy" "edge" {
  count = var.enable_cloud_armor ? 1 : 0
  name  = "${var.name_prefix}-edge-policy"

  rule {
    action   = "rate_based_ban"
    priority = 1000

    match {
      versioned_expr = "SRC_IPS_V1"
      config {
        src_ip_ranges = ["*"]
      }
    }

    rate_limit_options {
      conform_action = "allow"
      exceed_action  = "deny(429)"
      enforce_on_key = "IP"

      rate_limit_threshold {
        count        = var.rate_limit_per_minute
        interval_sec = 60
      }

      ban_duration_sec = 300
    }

    description = "Per IP rate limit"
  }

  rule {
    action   = "deny(403)"
    priority = 900

    match {
      expr {
        expression = "evaluatePreconfiguredExpr('sqli-v33-stable')"
      }
    }

    description = "Block SQL injection signatures"
  }

  rule {
    action   = "deny(403)"
    priority = 901

    match {
      expr {
        expression = "evaluatePreconfiguredExpr('xss-v33-stable')"
      }
    }

    description = "Block cross site scripting signatures"
  }

  rule {
    action   = "allow"
    priority = 2147483647

    match {
      versioned_expr = "SRC_IPS_V1"
      config {
        src_ip_ranges = ["*"]
      }
    }

    description = "Default allow"
  }
}
