locals {
  public_subnet_ids = sort(data.aws_subnets.public.ids)
}
