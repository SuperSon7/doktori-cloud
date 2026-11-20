# Pinned public upstream artifacts

- `karpenter-1.15.2.tgz`: `oci://public.ecr.aws/karpenter/karpenter:1.15.2`, fetched anonymously on 2026-11-20. Chart version and appVersion are both 1.15.2. Original chart contents are retained.
- `release-lock.json`: SHA-256 of fetched files plus OCI chart/controller manifest digests. The controller image supports Linux ARM64 and AMD64. No image was run.
- `cloudformation-v1.15.2.yaml`: [AWS Karpenter upstream IAM template](https://github.com/aws/karpenter-provider-aws/blob/v1.15.2/website/content/en/preview/getting-started/getting-started-with-karpenter/cloudformation.yaml). `build_policy.py` derives an account-scoped, precreated-profile, on-demand subset; it does not execute CloudFormation.
- `LICENSE`: upstream Apache-2.0 license. Copyright remains with the upstream authors. The downloaded template and chart are not project-authored code.

The policy derivation narrows AMI/subnet/SG/PassRole resources and omits EKS, interruption, dynamic instance-profile mutation, AMI-SSM lookup and reboot capabilities. See the implementation document for the deployment boundary. Hash verification is integrity checking, not a runtime compatibility or IAM authorization test.
