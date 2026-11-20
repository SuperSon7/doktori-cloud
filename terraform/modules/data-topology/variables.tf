variable "networking" {
  type = object({
    internal_zone_name = string
    subnet_cidrs       = map(string)
  })
}

variable "enable_data_ha" {
  type    = bool
  default = false
}
variable "enable_redis_ha" {
  type    = bool
  default = false
}
variable "enable_rabbitmq_ha" {
  type    = bool
  default = false
}
variable "enable_mongodb_ha" {
  type    = bool
  default = false
}
variable "mongodb_replica_set_name" {
  type    = string
  default = "doktori-rs"
}
