output "vpc_id" {
  value = google_compute_network.vpc.id
}

output "vpc_self_link" {
  value = google_compute_network.vpc.self_link
}

output "nodes_subnet_self_link" {
  value = google_compute_subnetwork.nodes.self_link
}

output "pods_range_name" {
  value = google_compute_subnetwork.nodes.secondary_ip_range[0].range_name
}

output "services_range_name" {
  value = google_compute_subnetwork.nodes.secondary_ip_range[1].range_name
}
