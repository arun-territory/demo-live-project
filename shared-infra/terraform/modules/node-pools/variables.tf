variable "cluster_name" {
  type = string
}

variable "project_id" {
  type = string
}

variable "region" {
  type = string
}

variable "service_account" {
  type = string
}

variable "cpu_pool" {
  type = object({
    machine_type = string
    min_nodes    = number
    max_nodes    = number
    disk_size_gb = number
    spot         = bool
  })
}

variable "gpu_pool" {
  type = object({
    machine_type      = string
    accelerator       = string
    accelerator_count = number
    min_nodes         = number
    max_nodes         = number
    disk_size_gb      = number
    spot              = bool
  })
}

variable "labels" {
  type    = map(string)
  default = {}
}
