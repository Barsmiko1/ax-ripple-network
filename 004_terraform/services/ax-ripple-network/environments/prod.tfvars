aws_region              = "us-east-1"
environment             = "prod"
validator_image_tag     = "latest"
api_node_image_tag      = "latest"
validator_desired_count = 4
api_node_desired_count  = 3
haproxy_instance_type   = "t3.medium"
haproxy_key_pair_name   = ""
task_cpu                = "2048"
task_memory             = "4096"
enable_observability    = true

