# S3 folder objects
locals {
  s3_folders = flatten([
    for bucket_key, bucket in var.s3_buckets : [
      for folder in bucket.folders : {
        bucket_key = bucket_key
        folder     = folder
      }
    ]
  ])
}
