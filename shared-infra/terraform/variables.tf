variable "project_id" {
  description = "GCP project ID."
  type        = string
}

variable "region" {
  description = "GCP region. Must have L4 GPU availability."
  type        = string
  default     = "us-central1"
}

variable "environment" {
  description = "Environment label (dev / staging / prod). Used as a name prefix."
  type        = string
  default     = "dev"
  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of dev, staging, prod."
  }
}

variable "cluster_name" {
  description = "GKE cluster name."
  type        = string
  default     = "genai-inference"
}

variable "kubernetes_version" {
  description = "GKE master version (release channel will pin minor version)."
  type        = string
  default     = "1.29"
}

variable "release_channel" {
  description = "GKE release channel."
  type        = string
  default     = "REGULAR"
}

variable "master_authorized_cidrs" {
  description = "CIDRs allowed to reach the private GKE master API. Keep this tight."
  type = list(object({
    cidr_block   = string
    display_name = string
  }))
  default = [
    { cidr_block = "10.0.0.0/8", display_name = "rfc1918-internal" }
  ]
}

# ── VPC sizing ───────────────────────────────────────────────────────────────

variable "vpc_cidr_nodes" {
  description = "Primary subnet CIDR for cluster nodes."
  type        = string
  default     = "10.20.10.0/24"
}

variable "vpc_cidr_pods" {
  description = "Secondary range for pods (alias IP)."
  type        = string
  default     = "10.21.0.0/16"
}

variable "vpc_cidr_services" {
  description = "Secondary range for services."
  type        = string
  default     = "10.22.0.0/20"
}

variable "vpc_cidr_master" {
  description = "/28 reserved for the GKE master endpoint."
  type        = string
  default     = "172.16.0.0/28"
}

# ── Node pool configuration ──────────────────────────────────────────────────

variable "cpu_pool" {
  description = "CPU node pool config (system pods, gateway, monitoring)."
  type = object({
    machine_type = string
    min_nodes    = number
    max_nodes    = number
    disk_size_gb = number
    spot         = bool
  })
  default = {
    machine_type = "e2-standard-4"
    min_nodes    = 1
    max_nodes    = 5
    disk_size_gb = 50
    spot         = true
  }
}

variable "gpu_pool" {
  description = "GPU node pool config. min_nodes=0 enables scale-to-zero."
  type = object({
    machine_type    = string
    accelerator     = string
    accelerator_count = number
    min_nodes       = number
    max_nodes       = number
    disk_size_gb    = number
    spot            = bool
  })
  default = {
    machine_type      = "g2-standard-8"
    accelerator       = "nvidia-l4"
    accelerator_count = 1
    min_nodes         = 0
    max_nodes         = 4
    disk_size_gb      = 100
    spot              = true
  }
}

# ── Platform addons toggles ──────────────────────────────────────────────────

variable "enable_prometheus_stack" {
  description = "Install kube-prometheus-stack."
  type        = bool
  default     = true
}

variable "enable_cert_manager" {
  description = "Install cert-manager."
  type        = bool
  default     = true
}

variable "enable_external_secrets" {
  description = "Install External Secrets Operator."
  type        = bool
  default     = true
}

variable "enable_prometheus_adapter" {
  description = "Install Prometheus Adapter (for HPA on vllm:num_requests_waiting)."
  type        = bool
  default     = true
}
