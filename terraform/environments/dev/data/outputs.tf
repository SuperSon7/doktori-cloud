output "storage" {
  description = "Storage outputs for downstream layers"
  value = {
    bucket_names = module.storage.bucket_names
    bucket_arns  = module.storage.bucket_arns
  }
}
