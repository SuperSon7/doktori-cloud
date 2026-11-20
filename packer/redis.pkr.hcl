# =============================================================================
# Redis AMI — Redis server + Alloy + AWS CLI + SSM Agent
# =============================================================================

source "amazon-ebs" "redis" {
  ami_name        = "${var.project_name}-redis-arm64-${local.timestamp}-${var.data_ha_build_id}"
  ami_description = "Redis ${var.redis_version}, Grafana Alloy, AWS CLI v2, SSM Agent"
  instance_type   = "t4g.small"
  region          = var.aws_region

  source_ami = var.data_ha_source_ami != "" ? var.data_ha_source_ami : null

  dynamic "source_ami_filter" {
    for_each = var.data_ha_source_ami == "" ? [1] : []
    content {
      filters = {
        name                = "ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-arm64-server-*"
        root-device-type    = "ebs"
        virtualization-type = "hvm"
      }
      most_recent = true
      owners      = ["099720109477"]
    }
  }

  vpc_id    = var.data_ha_vpc_id != "" ? var.data_ha_vpc_id : null
  subnet_id = var.data_ha_subnet_id != "" ? var.data_ha_subnet_id : null

  dynamic "vpc_filter" {
    for_each = var.data_ha_vpc_id == "" ? [1] : []
    content {
      filters = {
        "tag:Name" = var.vpc_filter_name
      }
    }
  }

  dynamic "subnet_filter" {
    for_each = var.data_ha_subnet_id == "" ? [1] : []
    content {
      filters = {
        "tag:Name" = var.subnet_filter_name
      }
      most_free = true
    }
  }

  associate_public_ip_address               = true
  ssh_username                              = "ubuntu"
  temporary_security_group_source_public_ip = true

  run_tags = {
    Project         = var.project_name
    ManagedBy       = "Packer"
    DoktoriBuildRun = var.data_ha_build_id
    DataService     = "redis"
  }
  run_volume_tags = {
    Project         = var.project_name
    ManagedBy       = "Packer"
    DoktoriBuildRun = var.data_ha_build_id
    DataService     = "redis"
  }
  launch_block_device_mappings {
    device_name           = "/dev/sda1"
    volume_size           = 12
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  tags = {
    Name         = "${var.project_name}-redis-arm64-${local.timestamp}-${var.data_ha_build_id}"
    Project      = var.project_name
    AMI_Type     = "redis"
    Redis        = var.redis_version
    Architecture = "arm64"
    BuildDate    = local.timestamp
  }
}

build {
  sources = ["source.amazon-ebs.redis"]

  provisioner "shell" {
    script = "packer/scripts/redis-setup.sh"
    environment_vars = [
      "REDIS_VERSION=${var.redis_version}",
      "ALLOY_VERSION=${var.alloy_version}",
      "DEBIAN_FRONTEND=noninteractive",
    ]
    execute_command = "sudo -S env {{ .Vars }} bash '{{ .Path }}'"
  }

  provisioner "shell" {
    script           = "packer/scripts/data-ha-finalize.sh"
    environment_vars = ["DOKTORI_IMAGE_BUILD=1", "DATA_SERVICE=redis"]
    execute_command  = "sudo -S env {{ .Vars }} bash '{{ .Path }}'"
  }

  post-processor "manifest" {
    output     = "${var.data_ha_manifest_dir}/manifest-redis.json"
    strip_path = true
    custom_data = {
      data_ha_service = "redis"
      architecture    = "arm64"
      base_ami        = var.data_ha_source_ami
      build_run       = var.data_ha_build_id
    }
  }
}
