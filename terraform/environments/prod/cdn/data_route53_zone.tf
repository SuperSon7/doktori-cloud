# -----------------------------------------------------------------------------
# ACM Certificate — CloudFront용 (us-east-1 필수)
# zone entity: dns-zone 레이어 / cert + validation record: 리소스(CloudFront)가 있는 이 레이어에서 관리
# -----------------------------------------------------------------------------
data "aws_route53_zone" "public" {
  name = var.domain_name
}
