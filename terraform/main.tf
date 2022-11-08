provider "kind" {}

resource "kind_cluster" "ortelius" {
  name            = var.kind_cluster_name
  node_image      = "kindest/node:v1.25.3"
  kubeconfig_path = pathexpand(var.kind_cluster_config_path)
  wait_for_ready  = true

  kind_config {
    kind        = "Cluster"
    api_version = "kind.x-k8s.io/v1alpha4"

    node {
      role = "control-plane"
      kubeadm_config_patches = [
        "kind: InitConfiguration\nnodeRegistration:\n  kubeletExtraArgs:\n    node-labels: \"ingress-ready=true\"\n"
      ]
      extra_port_mappings {
        container_port = 80
        host_port      = 80
        listen_address = "0.0.0.0"
      }
      extra_port_mappings {
        container_port = 443
        host_port      = 443
        listen_address = "0.0.0.0"
      }
    }
    node {
      role = "worker"
    }
  }
}

resource "null_resource" "kubectl" {
  depends_on = [kind_cluster.ortelius]
  #create_duration = "45"
  triggers = {
    key = uuid()
  }

  provisioner "local-exec" {
    command = <<EOF
      kubectl create namespace istio-system
      kubectl create namespace istio-ingress
      kubectl label namespace istio-ingress istio-injection=enabled
      sleep 45
      kubectl patch deployment keptn-keptn-ortelius-service --patch-file keptn-patch-image.yaml -n keptn
    EOF
  }
}

resource "null_resource" "kind_container_images" {
  depends_on = [kind_cluster.ortelius]
  #create_duration = "60"
  triggers = {
    key = uuid()
  }

  provisioner "local-exec" {
    command = <<EOF
      kind load docker-image --name ortelius-in-a-box --nodes ortelius-in-a-box-control-plane,ortelius-in-a-box-worker quay.io/ortelius/ortelius
      kind load docker-image --name ortelius-in-a-box --nodes ortelius-in-a-box-control-plane,ortelius-in-a-box-worker ghcr.io/ortelius/keptn-ortelius-service:0.0.2-dev
      kind load docker-image --name ortelius-in-a-box --nodes ortelius-in-a-box-control-plane,ortelius-in-a-box-worker docker.io/istio/base:1.16-2022-11-02T13-31-52
    EOF
  }
}

provider "kubectl" {
  host                   = kind_cluster.ortelius.endpoint
  cluster_ca_certificate = kind_cluster.ortelius.cluster_ca_certificate
  client_certificate     = kind_cluster.ortelius.client_certificate
  client_key             = kind_cluster.ortelius.client_key
  load_config_file       = false
}

provider "helm" {
  #debug = true
  kubernetes {
    host                   = kind_cluster.ortelius.endpoint
    cluster_ca_certificate = kind_cluster.ortelius.cluster_ca_certificate
    client_certificate     = kind_cluster.ortelius.client_certificate
    client_key             = kind_cluster.ortelius.client_key

  }
}

resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  namespace        = "argocd"
  version          = "5.6.2"
  create_namespace = true
  depends_on       = [kind_cluster.ortelius]
}

resource "helm_release" "keptn" {
  name             = "keptn"
  repository       = "https://ortelius.github.io/keptn-ortelius-service"
  chart            = "keptn-ortelius-service"
  namespace        = "keptn"
  version          = "0.0.1"
  create_namespace = true
  depends_on       = [kind_cluster.ortelius]
}

resource "helm_release" "istio_base" {
  name            = "istio"
  repository      = "https://istio-release.storage.googleapis.com/charts"
  chart           = "base"
  timeout         = 120
  cleanup_on_fail = true
  force_update    = false
  namespace       = "istio-system"
  #depends_on      = [kind_cluster.ortelius]
  create_duration = "20"
}

resource "helm_release" "istio_istiod" {
  name            = "istio"
  repository      = "https://istio-release.storage.googleapis.com/charts"
  chart           = "istiod"
  timeout         = 120
  cleanup_on_fail = true
  force_update    = false
  namespace       = "istio-system"

  set {
    name  = "meshConfig.accessLogFile"
    value = "/dev/stdout"
  }
  #depends_on = [helm_release.istio_base]
  create_duration = "40"
}

resource "helm_release" "istio_ingress" {
  name            = "istio-ingress"
  repository      = "https://istio-release.storage.googleapis.com/charts"
  chart           = "gateway"
  #timeout         = 300
  cleanup_on_fail = true
  force_update    = false
  namespace       = "istio-ingress"
  #depends_on      = [helm_release.istio_istiod]
  create_duration = "60"
}
