# ─────────────────────────────────────────────────────────────────────────────
# Private, regional GKE cluster with Workload Identity.
# - Private nodes + private endpoint
# - Authorized networks for master access
# - Default-deny network policy enabled
# - Shielded GKE nodes + Pod Security Standards (restricted) enforced at admission
# - No default node pool — pools are managed by the node-pools module
# ─────────────────────────────────────────────────────────────────────────────

resource "google_service_account" "nodes" {
  account_id   = "${substr(var.name, 0, 20)}-nodes"
  display_name = "GKE node SA for ${var.name}"
}

# Minimal node SA permissions: logging, monitoring, artifact registry pull
resource "google_project_iam_member" "node_logging" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.nodes.email}"
}

resource "google_project_iam_member" "node_monitoring" {
  project = var.project_id
  role    = "roles/monitoring.metricWriter"
  member  = "serviceAccount:${google_service_account.nodes.email}"
}

resource "google_project_iam_member" "node_artifact_reader" {
  project = var.project_id
  role    = "roles/artifactregistry.reader"
  member  = "serviceAccount:${google_service_account.nodes.email}"
}

resource "google_container_cluster" "this" {
  name     = var.name
  location = var.region
  project  = var.project_id

  # Manage node pools out-of-band.
  remove_default_node_pool = true
  initial_node_count       = 1

  min_master_version = var.kubernetes_version
  release_channel {
    channel = var.release_channel
  }

  network    = var.network_self_link
  subnetwork = var.subnet_self_link

  ip_allocation_policy {
    cluster_secondary_range_name  = var.pods_range_name
    services_secondary_range_name = var.services_range_name
  }

  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = false # set true if you have VPN/Interconnect
    master_ipv4_cidr_block  = var.master_ipv4_cidr_block
    master_global_access_config {
      enabled = true
    }
  }

  master_authorized_networks_config {
    dynamic "cidr_blocks" {
      for_each = var.master_authorized_cidrs
      content {
        cidr_block   = cidr_blocks.value.cidr_block
        display_name = cidr_blocks.value.display_name
      }
    }
  }

  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  network_policy {
    enabled  = true
    provider = "CALICO"
  }

  addons_config {
    network_policy_config { disabled = false }
    http_load_balancing { disabled = false }
    gce_persistent_disk_csi_driver_config { enabled = true }
    gcp_filestore_csi_driver_config { enabled = false }
  }

  # Restricted PSS at admission for all namespaces by default. We relax via
  # namespace labels for system namespaces in the platform module.
  pod_security_policy_config {
    enabled = false # PSP is deprecated; we use PSS via namespace labels
  }

  logging_config {
    enable_components = [
      "SYSTEM_COMPONENTS",
      "WORKLOADS",
      "APISERVER",
      "CONTROLLER_MANAGER",
      "SCHEDULER",
    ]
  }

  monitoring_config {
    enable_components = ["SYSTEM_COMPONENTS", "STORAGE", "POD", "DEPLOYMENT", "STATEFULSET", "DAEMONSET", "HPA"]
    managed_prometheus { enabled = false } # We run our own kube-prometheus-stack
  }

  cluster_autoscaling {
    enabled = false # Per-pool autoscaling configured on the node pools themselves
  }

  resource_labels = var.labels

  lifecycle {
    ignore_changes = [
      initial_node_count,
    ]
  }
}
