output "node_pools" {
  value = { for k, p in google_container_node_pool.pool : k => p.node_config[0].machine_type }
}

output "k6_job" {
  value = google_cloud_run_v2_job.k6.name
}

output "loadtest_bucket" {
  value = google_storage_bucket.loadtest.url
}
