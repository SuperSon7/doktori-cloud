locals {
  issuer_key    = trimprefix(var.issuer_url, "https://")
  parameter_arn = "arn:aws:ssm:${var.region}:${var.account_id}:parameter${var.join_parameter_name}"
  launch_input_arns = concat(
    [for id in var.ami_ids : "arn:aws:ec2:${var.region}::image/${id}"],
    ["arn:aws:ec2:${var.region}::snapshot/*"],
    [for id in var.subnet_ids : "arn:aws:ec2:${var.region}:${var.account_id}:subnet/${id}"],
    [for id in var.security_group_ids : "arn:aws:ec2:${var.region}:${var.account_id}:security-group/${id}"]
  )
  kms_condition = {
    StringEquals = {
      "kms:ViaService"                      = "ssm.${var.region}.amazonaws.com"
      "kms:EncryptionContext:PARAMETER_ARN" = local.parameter_arn
    }
  }
}

resource "aws_iam_role" "node" {
  name = "${var.cluster_name}-karpenter-node"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = "sts:AssumeRole", Principal = { Service = "ec2.amazonaws.com" } }]
  })
}
resource "aws_iam_instance_profile" "node" {
  name = "${var.cluster_name}-karpenter-node"
  role = aws_iam_role.node.name
}
resource "aws_iam_role_policy" "node" {
  name = "join-and-image-pull"
  role = aws_iam_role.node.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat([
      { Sid = "ReadWorkerJoinOnly", Effect = "Allow", Action = ["ssm:GetParameter"], Resource = local.parameter_arn },
      { Sid = "DecryptWorkerJoinOnly", Effect = "Allow", Action = ["kms:Decrypt"], Resource = var.kms_key_arn, Condition = local.kms_condition }
      ], length(var.ecr_repository_arns) == 0 ? [] : [
      { Sid = "ECRToken", Effect = "Allow", Action = ["ecr:GetAuthorizationToken"], Resource = ["*"] },
      { Sid = "PullApprovedImages", Effect = "Allow", Action = ["ecr:BatchCheckLayerAvailability", "ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer"], Resource = sort(tolist(var.ecr_repository_arns)) }
    ])
  })
}

resource "aws_iam_role" "controller" {
  name = "${var.cluster_name}-karpenter-controller"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow", Action = "sts:AssumeRoleWithWebIdentity"
      Principal = { Federated = var.oidc_provider_arn }
      Condition = { StringEquals = {
        "${local.issuer_key}:aud" = "sts.amazonaws.com"
        "${local.issuer_key}:sub" = "system:serviceaccount:karpenter:karpenter"
      } }
    }]
  })
  lifecycle {
    precondition {
      condition     = var.oidc_provider_arn == "arn:aws:iam::${var.account_id}:oidc-provider/${local.issuer_key}"
      error_message = "OIDC provider account and issuer must match exactly."
    }
  }
}

resource "aws_iam_policy" "controller" {
  name = "${var.cluster_name}-karpenter-controller"
  policy = jsonencode(jsondecode(templatefile("${path.module}/controller-policy.json.tftpl", {
    partition         = "aws"
    region            = var.region
    account_id        = var.account_id
    cluster_name      = var.cluster_name
    launch_input_arns = local.launch_input_arns
    node_role_arn     = aws_iam_role.node.arn
    node_profile_arn  = aws_iam_instance_profile.node.arn
  })))
}
resource "aws_iam_role_policy_attachment" "controller" {
  role       = aws_iam_role.controller.name
  policy_arn = aws_iam_policy.controller.arn
}

# Attach this ONLY to the designated publisher master role in a reviewed app-layer change.
# It does not grant Kubernetes API access; the host already holds its admin.conf.
resource "aws_iam_policy" "publisher" {
  name = "${var.cluster_name}-karpenter-join-publisher"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Sid = "WriteWorkerJoinOnly", Effect = "Allow", Action = ["ssm:PutParameter"], Resource = local.parameter_arn },
      { Sid = "EncryptStandardJoinParameter", Effect = "Allow", Action = ["kms:Encrypt"], Resource = var.kms_key_arn, Condition = local.kms_condition }
    ]
  })
}
