output "project_id" {
  value = var.project_id
}

output "region" {
  value = var.region
}

output "cluster_name" {
  value = module.gke.cluster_name
}

output "cluster_endpoint" {
  value     = module.gke.endpoint
  sensitive = true
}

output "vpc_id" {
  value = module.network.vpc_id
}

output "workload_identity_pool" {
  value = module.gke.workload_identity_pool
}

output "configure_kubectl" {
  description = "Run this to point kubectl at the new cluster."
  value       = "gcloud container clusters get-credentials ${module.gke.cluster_name} --region=${var.region} --project=${var.project_id}"
}
