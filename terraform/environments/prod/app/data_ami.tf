# -----------------------------------------------------------------------------
# AMI guards — prod/app must use Packer-built golden images
# -----------------------------------------------------------------------------
data "aws_ami" "frontend_golden" {
  owners = ["self"]

  filter {
    name   = "image-id"
    values = [var.frontend_ami_id]
  }

  filter {
    name   = "tag:AMI_Type"
    values = ["frontend"]
  }
}

data "aws_ami" "k8s_golden" {
  owners = ["self"]

  filter {
    name   = "image-id"
    values = [var.k8s_ami_id]
  }

  filter {
    name   = "tag:AMI_Type"
    values = ["k8s-node"]
  }
}

data "aws_ami" "rds_monitoring_golden" {
  owners = ["self"]

  filter {
    name   = "image-id"
    values = [var.rds_monitoring_ami_id]
  }

  filter {
    name   = "tag:AMI_Type"
    values = ["rds-monitoring"]
  }
}
