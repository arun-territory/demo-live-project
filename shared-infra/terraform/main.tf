locals {
  name_prefix = "${var.environment}-${var.cluster_name}"
  common_labels = {
    project     = "genai-inference"
    environment = var.environment
    managed_by  = "terraform"
  }
}

module "network" {
  source = "./modules/network"

  name_prefix       = local.name_prefix
  region            = var.region
  cidr_nodes        = var.vpc_cidr_nodes
  cidr_pods         = var.vpc_cidr_pods
  cidr_services     = var.vpc_cidr_services
  labels            = local.common_labels
}

module "gke" {
  source = "./modules/gke"

  name               = local.name_prefix
  project_id         = var.project_id
  region             = var.region
  kubernetes_version = var.kubernetes_version
  release_channel    = var.release_channel

  network_self_link    = module.network.vpc_self_link
  subnet_self_link     = module.network.nodes_subnet_self_link
  pods_range_name      = module.network.pods_range_name
  services_range_name  = module.network.services_range_name

  master_ipv4_cidr_block  = var.vpc_cidr_master
  master_authorized_cidrs = var.master_authorized_cidrs

  labels = local.common_labels
}

module "node_pools" {
  source = "./modules/node-pools"

  cluster_name = module.gke.cluster_name
  project_id   = var.project_id
  region       = var.region
  service_account = module.gke.node_service_account_email

  cpu_pool = var.cpu_pool
  gpu_pool = var.gpu_pool

  labels = local.common_labels
}

module "platform" {
  source = "./modules/platform"

  project_id                = var.project_id
  cluster_endpoint          = module.gke.endpoint
  cluster_ca_certificate    = module.gke.cluster_ca_certificate

  enable_prometheus_stack   = var.enable_prometheus_stack
  enable_cert_manager       = var.enable_cert_manager
  enable_external_secrets   = var.enable_external_secrets
  enable_prometheus_adapter = var.enable_prometheus_adapter

  workload_identity_pool = module.gke.workload_identity_pool

  depends_on = [module.node_pools]
}

# Note: Project 3 (RAG) infrastructure (GCS buckets, IAM, service accounts)
# is a SEPARATE terraform stack in ../../project-3-rag/terraform/.
# It does not need to be deployed at the same time as this one. Apply it
# only when you're ready to add the RAG project on top of the cluster.
