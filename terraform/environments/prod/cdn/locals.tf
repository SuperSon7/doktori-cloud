locals {
  # front.doktori.kr → ALB: CloudFront가 이 도메인으로 TLS 핸드셰이크
  # ALB에 front.doktori.kr ACM 인증서(ap-northeast-2)가 등록되어 있어야 함 (prod/app 레이어)
  ssr_origin = data.terraform_remote_state.app.outputs.frontend_alb_fqdn
}
