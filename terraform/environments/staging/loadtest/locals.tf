locals {
  net = {
    vpc_id = data.aws_vpc.main.id
    subnet_ids = {
      public = data.aws_subnet.public.id
    }
  }

  runner_names = [
    "k6-runner-1",
    "k6-runner-2",
    "k6-runner-3",
  ]

  public_subnet_ids = compact([
    try(local.net.subnet_ids["public"], null),
    try(local.net.subnet_ids["public_c"], null),
    try(local.net.subnet_ids["public_b"], null),
  ])

  runners = {
    for idx, name in local.runner_names : name => {
      subnet_id = local.public_subnet_ids[idx % length(local.public_subnet_ids)]
    }
  }
}
