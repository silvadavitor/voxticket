include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

terraform {
  source = "${include.root.locals.modules_dir}//storage"
}

inputs = {
  bucket_name            = "${include.root.locals.name}-audios"
  failed_expiration_days = 7
  # TODO(infra): confirmar se o MiniStack suporta lifecycle; se não, false.
  enable_lifecycle = true
  # MiniStack é HTTP: a policy "só HTTPS" bloquearia tudo. Na AWS fica ligada.
  enforce_tls = false
}
