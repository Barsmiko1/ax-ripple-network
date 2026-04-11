aws_region              = "us-east-1"
environment             = "dev"
validator_image_tag     = "latest"
api_node_image_tag      = "latest"
validator_desired_count = 3
api_node_desired_count  = 2
haproxy_instance_type   = "t3.small"
haproxy_key_pair_name   = ""
task_cpu                = "1024"
task_memory             = "2048"
enable_observability    = true

