# ─────────────────────────────────────────────────────────────────────────────
# Node pools — separate from the cluster so we can update them independently.
# - CPU pool: system pods, gateway, monitoring (no GPU). Spot in non-prod.
# - GPU pool: vLLM only. Tainted so general pods don't land here. min=0
#   enables true scale-to-zero — no GPU cost when idle.
# ─────────────────────────────────────────────────────────────────────────────

resource "google_container_node_pool" "cpu" {
  name     = "cpu-pool"
  cluster  = var.cluster_name
  location = var.region
  project  = var.project_id

  autoscaling {
    min_node_count = var.cpu_pool.min_nodes
    max_node_count = var.cpu_pool.max_nodes
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  upgrade_settings {
    max_surge       = 1
    max_unavailable = 0
  }

  node_config {
    machine_type = var.cpu_pool.machine_type
    disk_size_gb = var.cpu_pool.disk_size_gb
    disk_type    = "pd-balanced"
    image_type   = "COS_CONTAINERD"

    spot = var.cpu_pool.spot

    service_account = var.service_account
    oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"]

    workload_metadata_config {
      mode = "GKE_METADATA" # required for Workload Identity
    }

    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }

    labels = merge(var.labels, {
      pool = "cpu"
    })

    metadata = {
      disable-legacy-endpoints = "true"
    }
  }
}

resource "google_container_node_pool" "gpu" {
  name     = "gpu-pool"
  cluster  = var.cluster_name
  location = var.region
  project  = var.project_id

  autoscaling {
    min_node_count = var.gpu_pool.min_nodes  # 0 — true scale-to-zero
    max_node_count = var.gpu_pool.max_nodes
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  upgrade_settings {
    max_surge       = 1
    max_unavailable = 0
  }

  node_config {
    machine_type = var.gpu_pool.machine_type
    disk_size_gb = var.gpu_pool.disk_size_gb
    disk_type    = "pd-balanced"
    image_type   = "COS_CONTAINERD"

    spot = var.gpu_pool.spot

    service_account = var.service_account
    oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"]

    guest_accelerator {
      type  = var.gpu_pool.accelerator
      count = var.gpu_pool.accelerator_count

      gpu_driver_installation_config {
        gpu_driver_version = "LATEST"
      }
    }

    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }

    # Taint keeps non-GPU workloads off these expensive nodes.
    taint {
      key    = "nvidia.com/gpu"
      value  = "present"
      effect = "NO_SCHEDULE"
    }

    labels = merge(var.labels, {
      pool                = "gpu"
      "accelerator-type"  = var.gpu_pool.accelerator
    })

    metadata = {
      disable-legacy-endpoints = "true"
    }
  }

  # Prevent terraform from fighting the cluster autoscaler over node count.
  lifecycle {
    ignore_changes = [node_count]
  }
}
