terraform {
  # 1. Configure the Terraform Cloud backend
  cloud {
    organization = "smdevops96_org"

    workspaces {
      name = "gcp-infra"
    }
  }

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.12"
    }
  }
}

data "google_client_config" "default" {}

data "google_client_openid_userinfo" "terraform_sa" {}

provider "helm" {
  kubernetes {
    host                   = "https://${google_container_cluster.primary.endpoint}"
    token                  = data.google_client_config.default.access_token
    cluster_ca_certificate = base64decode(google_container_cluster.primary.master_auth[0].cluster_ca_certificate)
  }
}

provider "google" {
  project     = "project-fa63d718-a27d-4c5b-b6b"
  region      = "europe-west2"
  zone        = "europe-west2-c"
}

# 1. Cluster Control Plane (Zonal = Free Tier)
resource "google_container_cluster" "primary" {
  name     = "argocd-test-cluster"
  # MUST be a zone (e.g., -a, -b), not a region, to qualify for the Free Tier
  location = "europe-west2-c" 
  
  # We can't create a cluster with no node pool defined, but we want a custom one.
  remove_default_node_pool = true
  initial_node_count       = 1

  # Use default VPC for simplicity
  network    = "default"
  subnetwork = "default"

  deletion_protection = false
}

# 2. Node Pool (Spot Instance = ~60-90% Discount)
resource "google_container_node_pool" "primary_nodes" {
  name       = "cheap-node-pool"
  cluster    = google_container_cluster.primary.id
  location   = google_container_cluster.primary.location
  
  # 1 node is plenty for a lightweight ArgoCD deployment
  node_count = 1

  node_config {
    machine_type = "e2-medium" # 2 vCPU, 4GB RAM
    spot         = true        # Slashes compute costs

    disk_size_gb = 20          # Reduced from the default 100GB to save on storage costs
    disk_type    = "pd-standard"

    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform"
    ]
  }
}

# 3. Enable Artifact Registry API
resource "google_project_service" "artifact_registry" {
  service            = "artifactregistry.googleapis.com"
  disable_on_destroy = false
}

# 4. Grant the Terraform SA permission to create Artifact Registry repositories
resource "google_project_iam_member" "terraform_sa_artifact_registry_admin" {
  project = var.project_id
  role    = "roles/artifactregistry.admin"
  member  = "serviceAccount:${var.gcp_service_account_email}"
}

# 5. Docker container registry (Artifact Registry)
resource "google_artifact_registry_repository" "docker" {
  location      = "europe-west2"
  repository_id = "docker"
  description   = "Docker container registry"
  format        = "DOCKER"

  depends_on = [
    google_project_service.artifact_registry,
    google_project_iam_member.terraform_sa_artifact_registry_admin,
  ]
}

# 6. Deploy ArgoCD using the Helm provider
resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  namespace        = "argocd"
  create_namespace = true
  version          = "6.7.11" # It is best practice to pin a specific chart version

  # Ensures the compute nodes actually exist before deploying ArgoCD
  depends_on = [google_container_node_pool.primary_nodes]

  # Example of how you can override default values in the chart
  set {
    name  = "server.service.type"
    value = "ClusterIP"
  }
}