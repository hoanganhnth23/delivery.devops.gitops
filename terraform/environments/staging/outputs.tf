output "node_pools" {
  value = { for k, p in google_container_node_pool.pool : k => p.node_config[0].machine_type }
}
