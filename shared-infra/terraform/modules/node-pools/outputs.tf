output "cpu_pool_name" {
  value = google_container_node_pool.cpu.name
}

output "gpu_pool_name" {
  value = google_container_node_pool.gpu.name
}
