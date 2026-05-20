
provider "google" {
  project = var.gcp_project_id
  region  = "asia-northeast3"  # 서울
  zone    = "asia-northeast3-a"
}