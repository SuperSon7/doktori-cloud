mock_provider "aws" {}
override_resource {
  target = aws_iam_policy.controller
  values = { arn = "arn:aws:iam::123456789012:policy/test-karpenter-controller" }
}
override_resource {
  target = aws_iam_role.node
  values = { arn = "arn:aws:iam::123456789012:role/test-karpenter-node" }
}
override_resource {
  target = aws_iam_instance_profile.node
  values = { arn = "arn:aws:iam::123456789012:instance-profile/test-karpenter-node" }
}
variables {
  account_id          = "123456789012"
  region              = "ap-northeast-2"
  cluster_name        = "test"
  issuer_url          = "https://oidc.example.invalid/test"
  oidc_provider_arn   = "arn:aws:iam::123456789012:oidc-provider/oidc.example.invalid/test"
  join_parameter_name = "/doktori/test/karpenter/join-config"
  kms_key_arn         = "arn:aws:kms:ap-northeast-2:123456789012:key/00000000-0000-0000-0000-000000000000"
  ami_ids             = ["ami-00000000000000000"]
  subnet_ids          = ["subnet-00000000000000001"]
  security_group_ids  = ["sg-00000000000000000"]
  ecr_repository_arns = ["arn:aws:ecr:ap-northeast-2:123456789012:repository/doktori/backend-api"]
}
run "roles_have_distinct_scopes" {
  command = apply # Mock provider only; no real resource creation.
  assert {
    condition     = !strcontains(output.node_policy, "ssm:PutParameter") && !strcontains(output.node_policy, "ssm:GetParametersByPath") && !strcontains(output.node_policy, "s3:")
    error_message = "Worker must not write join state or inherit app privileges."
  }
  assert {
    condition     = !strcontains(output.controller_policy, "iam:CreateInstanceProfile") && !strcontains(output.controller_policy, "eks:DescribeCluster") && !strcontains(output.controller_policy, "ssm:PutParameter")
    error_message = "Precreated profile and non-EKS controller must not manage shared identity or join state."
  }
  assert {
    condition = alltrue([for s in jsondecode(output.controller_policy).Statement :
      s.Condition.StringEquals["aws:ResourceTag/kubernetes.io/cluster/test"] == "owned"
      if s.Sid == "AllowScopedDeletion"
    ])
    error_message = "Deletion must be bound to owned cluster resources."
  }
  assert {
    condition     = length(output.controller_policy) < 6144
    error_message = "Controller managed policy exceeds AWS size limit."
  }
  assert {
    condition     = strcontains(output.publisher_policy, "ssm:PutParameter") && !strcontains(output.publisher_policy, "ssm:Delete") && !strcontains(output.publisher_policy, "kms:Decrypt")
    error_message = "Publisher only writes the short-lived worker bundle."
  }
}
run "reject_cross_account_oidc" {
  command = plan
  variables { oidc_provider_arn = "arn:aws:iam::999999999999:oidc-provider/oidc.example.invalid/test" }
  expect_failures = [aws_iam_role.controller]
}
