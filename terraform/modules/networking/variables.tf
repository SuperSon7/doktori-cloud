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

variable "tertiary_availability_zone" {
  type    = string
  default = ""
}

variable "subnets" {
  description = "Map of subnets to create"
  type = map(object({
    cidr   = string
    tier   = string # "public" | "private-app" | "private-db"
    az_key = string # "primary" | "secondary" | "tertiary"
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
  description = "Key of the subnet to place the NAT instance in (used when nat_instances is not set)"
  type        = string
  default     = "public"
}

variable "nat_instances" {
  description = "NAT instances per AZ. Key = identifier, value = { subnet_key }. If null, creates single NAT using nat_subnet_key."
  type = map(object({
    subnet_key = string
  }))
  default = null
}

variable "nat_volume_size" {
  description = "Root volume size for NAT instance (GB)"
  type        = number
  default     = 8
}

variable "nat_iam_instance_profile" {
  description = "IAM instance profile name for NAT instances (SSM access)"
  type        = string
  default     = ""
}

variable "nat_extra_tags" {
  description = "Additional tags for the NAT instance (overrides default Name/Service)"
  type        = map(string)
  default     = {}
}

variable "nat_extra_ingress" {
  description = "Additional ingress rules for NAT SG (e.g. WireGuard)"
  type = list(object({
    description = string
    from_port   = number
    to_port     = number
    protocol    = string
    cidr_blocks = list(string)
  }))
  default = []
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
