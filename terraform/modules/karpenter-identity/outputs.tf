output "controller_role_arn" { value = aws_iam_role.controller.arn }
output "node_role_arn" { value = aws_iam_role.node.arn }
output "node_instance_profile" { value = aws_iam_instance_profile.node.name }
output "publisher_policy_arn" { value = aws_iam_policy.publisher.arn }
output "controller_policy" { value = aws_iam_policy.controller.policy }
output "node_policy" { value = aws_iam_role_policy.node.policy }
output "publisher_policy" { value = aws_iam_policy.publisher.policy }
