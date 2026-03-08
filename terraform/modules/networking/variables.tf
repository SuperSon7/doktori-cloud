variable "project_name" {
  type = string
}

variable "environment" {
  type = string
}

variable "aws_region" {
  type = string
}

variable "vpc_cidr" {
  type = string
}

variable "availability_zone" {
  type = string
}

variable "secondary_availability_zone" {
  type    = string
  default = ""
}

variable "subnets" {
  description = "Map of subnets to create"
  type = map(object({
    cidr   = string
    tier   = string # "public" | "private-app" | "private-db"
    az_key = string # "primary" | "secondary"
  }))
}

# --- NAT Instance ---

variable "nat_instance_type" {
  type    = string
  default = "t4g.nano"
}

variable "nat_ami_id" {
  description = "Override NAT instance AMI. If empty, uses Amazon Linux 2 ARM64."
  type        = string
  default     = ""
}

variable "nat_key_name" {
  type    = string
  default = ""
}

variable "nat_user_data" {
  description = "Custom user_data for NAT instance. If empty, uses default iptables MASQUERADE."
  type        = string
  default     = ""
}

variable "nat_subnet_key" {
  description = "Key of the subnet to place the NAT instance in"
  type        = string
  default     = "public"
}

variable "nat_extra_tags" {
  description = "Additional tags for the NAT instance"
  type        = map(string)
  default     = {}
}

# --- Route53 Private Hosted Zone ---

variable "internal_domain" {
  description = "Private hosted zone domain (e.g. prod.doktori.internal)"
  type        = string
}

# --- VPC Endpoints ---

variable "vpc_interface_endpoints" {
  description = "List of AWS service names for Interface VPC Endpoints (e.g. ssm, ecr.api)"
  type        = list(string)
  default     = []
}

variable "vpc_endpoint_subnet_key" {
  description = "Key of the subnet to place VPC Interface Endpoints in"
  type        = string
  default     = "private_app"
}
