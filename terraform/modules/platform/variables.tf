variable "project_id" {
  type = string
}

variable "cluster_endpoint" {
  type = string
}

variable "cluster_ca_certificate" {
  type = string
}

variable "workload_identity_pool" {
  type = string
}

variable "enable_prometheus_stack" {
  type    = bool
  default = true
}

variable "enable_cert_manager" {
  type    = bool
  default = true
}

variable "enable_external_secrets" {
  type    = bool
  default = true
}

variable "enable_prometheus_adapter" {
  type    = bool
  default = true
}
