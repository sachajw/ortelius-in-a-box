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

resource "null_resource" "kubectl_ortelius" {
  depends_on = [kind_cluster.ortelius]

  provisioner "local-exec" {
    command = <<EOF
      kubectl create namespace ortelius
      kubectl create secret generic pgcred --from-literal=DBUserName=postgres --from-literal=DBPassword=postgres --from-literal=DBHost=localhost --from-literal=DBPort=5432 --from-literal=DBName=postgres -n ortelius
    EOF
  }
}

resource "time_sleep" "wait_45_seconds" {
  create_duration = "45s"
}

resource "null_resource" "kind_copy_container_images" {
  depends_on = [time_sleep.wait_45_seconds]
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
  kubernetes {
    host                   = kind_cluster.ortelius.endpoint
    cluster_ca_certificate = kind_cluster.ortelius.cluster_ca_certificate
    client_certificate     = kind_cluster.ortelius.client_certificate
    client_key             = kind_cluster.ortelius.client_key
    config_path            = pathexpand(var.kind_cluster_config_path)
  }
}

resource "helm_release" "argocd" {
  name             = "argocd"
  chart            = "argo-cd"
  namespace        = "argocd"
  create_namespace = true
  depends_on       = [kind_cluster.ortelius]

  values = [
    file("argo-cd/values.yaml"),
  ]
}

resource "helm_release" "keptn" {
  name             = "keptn"
  repository       = "https://ortelius.github.io/keptn-ortelius-service"
  chart            = "keptn-ortelius-service"
  namespace        = "keptn"
  create_namespace = true
  depends_on       = [kind_cluster.ortelius]

  values = [
    file("keptn-ortelius-service/values.yaml"),
  ]
}

resource "helm_release" "kube_arangodb" {
  name             = "kube-arangodb"
  chart            = "kube-arangodb"
  namespace        = "arangodb"
  create_namespace = true
  depends_on       = [kind_cluster.ortelius]
  timeout          = 600

  values = [
    file("kube-arangodb/values.yaml"),
  ]
}

#resource "null_resource" "kubectl_arangodb_crd" {
#  depends_on = [helm_release.kube_arangodb]
#  provisioner "local-exec" {
#    command = <<EOF
#    kubectl create -f https://operatorhub.io/install/kube-arangodb.yaml
#
#    EOF
#  }
#}

#resource "helm_release" "kube_arangodb_crd" {
#  name             = "kube-arangodb_crd"
#  chart            = "kube-arangodb_crd"
#  version          = "1.2.20"
#  namespace        = "arangodb"
#  create_namespace = false
#  depends_on       = [helm_release.kube_arangodb]
#  #timeout          = 600
#
#  values = [
#    file("kube-arangodb-crd/values.yaml"),
#  ]
#}

#resource "helm_release" "kube_arangodb_ingress_proxy" {
#  name             = "arangodb-ingress-proxy"
#  chart            = "arangodb-ingress-proxy"
#  namespace        = "arangodb"
#  create_namespace = false
#  depends_on       = [helm_release.kube_arangodb]
#  #timeout          = 600
#
#  values = [
#    file("kube-arangodb/chart/arangodb-ingress-proxy/values.yaml"),
#  ]
#}

#resource "helm_release" "ortelius" {
#  name             = "ortelius"
#  chart            = "ortelius"
#  namespace        = "ortelius"
#  create_namespace = false
#  depends_on       = [helm_release.keptn]
#  timeout          = 600
#
#  values = [
#    file("ortelius/values.yaml"),
#  ]
#}

resource "helm_release" "istio_base" {
  name             = "istio"
  chart            = "base"
  repository       = "https://istio-release.storage.googleapis.com/charts"
  namespace        = "istio-system"
  create_namespace = true
  timeout          = 600
  depends_on       = [kind_cluster.ortelius]
}

resource "helm_release" "istio_operator_banzaicloud" {
  name             = "banzaicloud"
  chart            = "istio-operator"
  namespace        = "istio-system"
  create_namespace = false
  timeout          = 600
  depends_on       = [helm_release.istio_base]

  values = [
    file("istio-operator/values.yaml"),
  ]
}

resource "helm_release" "istio_istiod" {
  name             = "istiod"
  chart            = "istiod"
  namespace        = "istio-system"
  create_namespace = false
  timeout          = 600
  depends_on       = [helm_release.istio_base]

  values = [
    file("istiod/values.yaml"),
  ]

  set {
    name  = "meshConfig.accessLogFile"
    value = "/dev/stdout"
  }
}

resource "helm_release" "istio_gateway" {
  name             = "gateway"
  chart            = "gateway"
  namespace        = "istio-system"
  create_namespace = false
  depends_on       = [helm_release.istio_istiod]
  #timeout          = 600

  values = [
    file("gateway/values.yaml"),
  ]

}

resource "helm_release" "istio_egress" {
  name             = "istio-egress"
  chart            = "gateway"
  repository       = "https://istio-release.storage.googleapis.com/charts"
  namespace        = "istio-system"
  create_namespace = false
  depends_on       = [helm_release.istio_gateway]
  timeout          = 600
}

resource "helm_release" "istio_ingress" {
  name             = "istio-ingress"
  chart            = "gateway"
  repository       = "https://istio-release.storage.googleapis.com/charts"
  namespace        = "istio-system"
  create_namespace = false
  depends_on       = [helm_release.istio_gateway]
  timeout          = 600
}
