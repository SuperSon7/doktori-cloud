#!/usr/bin/env bash
set -euo pipefail

set +e
terraform plan -detailed-exitcode -no-color
exitcode=$?
set -e

case "$exitcode" in
  0)
    echo "Post-apply plan is clean."
    ;;
  1)
    echo "::error::Post-apply plan failed."
    exit 1
    ;;
  2)
    echo "::error::Post-apply plan still has changes. Terraform apply succeeded but the state did not converge."
    exit 1
    ;;
  *)
    echo "::error::Unexpected terraform plan exit code: ${exitcode}"
    exit 1
    ;;
esac
