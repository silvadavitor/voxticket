include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

terraform {
  source = "${include.root.locals.modules_dir}//storage"
}

inputs = {
  # nome de bucket é global: sufixo com o account id
  bucket_name            = "${include.root.locals.name}-audios${include.root.locals.env_cfg.locals.bucket_suffix}"
  failed_expiration_days = 7
  enable_lifecycle       = true
}
