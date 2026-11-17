# Segurança e regras do bucket de áudios. `terraform test` (sem conta AWS: provider mockado).
mock_provider "aws" {
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{}" }
  }
}

variables {
  bucket_name = "voxticket-test-audios"
}

run "bucket_seguro_por_padrao" {
  command = plan

  assert {
    condition = alltrue([
      aws_s3_bucket_public_access_block.this.block_public_acls,
      aws_s3_bucket_public_access_block.this.block_public_policy,
      aws_s3_bucket_public_access_block.this.ignore_public_acls,
      aws_s3_bucket_public_access_block.this.restrict_public_buckets,
    ])
    error_message = "O bucket não pode ser público."
  }

  assert {
    condition     = one(one(aws_s3_bucket_server_side_encryption_configuration.this.rule).apply_server_side_encryption_by_default).sse_algorithm == "AES256"
    error_message = "Criptografia em repouso obrigatória."
  }

  assert {
    condition     = one(aws_s3_bucket_versioning.this.versioning_configuration).status == "Enabled"
    error_message = "Versionamento deve estar ligado."
  }

  assert {
    condition     = length(aws_s3_bucket_policy.tls_only) == 1
    error_message = "Policy 'só HTTPS' deve existir por padrão."
  }

  assert {
    condition     = length(aws_s3_bucket_lifecycle_configuration.this) == 1
    error_message = "Lifecycle de failed/ deve existir por padrão."
  }
}

run "ministack_sem_tls_e_sem_lifecycle" {
  command = plan

  variables {
    enforce_tls      = false
    enable_lifecycle = false
  }

  assert {
    condition     = length(aws_s3_bucket_policy.tls_only) == 0 && length(aws_s3_bucket_lifecycle_configuration.this) == 0
    error_message = "Toggles do MiniStack não respeitados."
  }
}
