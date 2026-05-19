variable "project_name" {
  type    = string
  default = "doktori"
}

variable "environment" {
  type    = string
  default = "prod"
}

variable "aws_region" {
  type    = string
  default = "ap-northeast-2"
}

variable "nat_ami_id" {
  description = "AMI ID for prod NAT instances. Must be a concrete Packer NAT AMI ID."
  type        = string
  # packer:nat_ami_id
  default = "ami-080a5bddc89527fb2"

  validation {
    condition     = can(regex("^ami-[0-9a-f]{8,17}$", var.nat_ami_id))
    error_message = "nat_ami_id must be a concrete Packer NAT AMI ID; do not fall back to a raw Ubuntu AMI."
  }
}
