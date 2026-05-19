data "aws_ami" "dev_app_golden" {
  owners = ["self"]

  filter {
    name   = "image-id"
    values = [var.dev_app_ami_id]
  }

  filter {
    name   = "tag:AMI_Type"
    values = ["dev-app"]
  }
}

data "aws_ami" "dev_ai_golden" {
  count  = var.dev_ai_ami_id == "" ? 0 : 1
  owners = ["self"]

  filter {
    name   = "image-id"
    values = [var.dev_ai_ami_id]
  }

  filter {
    name   = "tag:AMI_Type"
    values = ["dev-ai"]
  }
}

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
