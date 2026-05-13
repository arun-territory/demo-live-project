# ─────────────────────────────────────────────────────────────────────────────
# Platform addons installed via Helm. These are foundations every workload on
# this cluster depends on:
#   - kube-prometheus-stack  (Prometheus + Grafana + Alertmanager + CRDs)
#   - prometheus-adapter     (exposes vLLM metrics to the HPA API)
#   - cert-manager           (Let's Encrypt cert issuance)
#   - external-secrets       (pulls Secret Manager values into K8s Secrets)
# ─────────────────────────────────────────────────────────────────────────────

resource "kubernetes_namespace" "monitoring" {
  count = var.enable_prometheus_stack ? 1 : 0
  metadata {
    name = "monitoring"
    labels = {
      "pod-security.kubernetes.io/enforce" = "baseline"
      "pod-security.kubernetes.io/audit"   = "restricted"
      "pod-security.kubernetes.io/warn"    = "restricted"
    }
  }
}

resource "kubernetes_namespace" "platform" {
  metadata {
    name = "platform"
    labels = {
      "pod-security.kubernetes.io/enforce" = "baseline"
      "pod-security.kubernetes.io/audit"   = "restricted"
      "pod-security.kubernetes.io/warn"    = "restricted"
    }
  }
}

resource "helm_release" "kube_prometheus_stack" {
  count      = var.enable_prometheus_stack ? 1 : 0
  name       = "kube-prom-stack"
  namespace  = kubernetes_namespace.monitoring[0].metadata[0].name
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-prometheus-stack"
  version    = "58.5.0"

  values = [
    yamlencode({
      prometheus = {
        prometheusSpec = {
          serviceMonitorSelectorNilUsesHelmValues = false
          podMonitorSelectorNilUsesHelmValues     = false
          ruleSelectorNilUsesHelmValues           = false
          retention                               = "15d"
          resources = {
            requests = { cpu = "200m", memory = "1Gi" }
            limits   = { memory = "2Gi" }
          }
        }
      }
      grafana = {
        adminPassword = "REPLACE_ME_VIA_SECRET_MANAGER"
        sidecar = {
          dashboards = { enabled = true, label = "grafana_dashboard" }
        }
      }
      alertmanager = {
        alertmanagerSpec = {
          resources = {
            requests = { cpu = "50m", memory = "128Mi" }
          }
        }
      }
    })
  ]

  timeout = 600
}

resource "helm_release" "prometheus_adapter" {
  count      = var.enable_prometheus_adapter ? 1 : 0
  name       = "prometheus-adapter"
  namespace  = kubernetes_namespace.monitoring[0].metadata[0].name
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "prometheus-adapter"
  version    = "4.10.0"

  values = [
    yamlencode({
      prometheus = {
        url  = "http://kube-prom-stack-kube-prometheu-prometheus.monitoring.svc"
        port = 9090
      }
      rules = {
        default = false
        custom = [
          {
            seriesQuery = "vllm:num_requests_waiting{namespace!=\"\",pod!=\"\"}"
            resources = {
              overrides = {
                namespace = { resource = "namespace" }
                pod       = { resource = "pod" }
              }
            }
            name = {
              matches = "vllm:num_requests_waiting"
              as      = "vllm_num_requests_waiting"
            }
            metricsQuery = "avg(<<.Series>>{<<.LabelMatchers>>}) by (<<.GroupBy>>)"
          },
        ]
      }
    })
  ]

  depends_on = [helm_release.kube_prometheus_stack]
}

resource "helm_release" "cert_manager" {
  count            = var.enable_cert_manager ? 1 : 0
  name             = "cert-manager"
  namespace        = "cert-manager"
  create_namespace = true
  repository       = "https://charts.jetstack.io"
  chart            = "cert-manager"
  version          = "v1.14.5"

  set {
    name  = "installCRDs"
    value = "true"
  }

  values = [
    yamlencode({
      global = {
        leaderElection = { namespace = "cert-manager" }
      }
      resources = {
        requests = { cpu = "10m", memory = "32Mi" }
      }
    })
  ]
}

resource "helm_release" "external_secrets" {
  count            = var.enable_external_secrets ? 1 : 0
  name             = "external-secrets"
  namespace        = kubernetes_namespace.platform.metadata[0].name
  repository       = "https://charts.external-secrets.io"
  chart            = "external-secrets"
  version          = "0.9.19"

  set {
    name  = "installCRDs"
    value = "true"
  }
}
