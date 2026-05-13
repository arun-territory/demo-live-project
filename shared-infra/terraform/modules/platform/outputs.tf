output "monitoring_namespace" {
  value = var.enable_prometheus_stack ? kubernetes_namespace.monitoring[0].metadata[0].name : null
}

output "platform_namespace" {
  value = kubernetes_namespace.platform.metadata[0].name
}
