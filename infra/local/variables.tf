# Chart versions come from REALITY at import time: scripts/130-tf-import.sh writes
# chart-versions.auto.tfvars from `helm list -A`, and that file is committed. The PDF's
# resources carry no version, which means `terraform apply` would upgrade every chart
# to whatever is newest in the repo that day — the Day 8 lesson, five times over.
variable "chart_versions" {
  type        = map(string)
  description = "release name -> chart version, as installed (chart-versions.auto.tfvars)"
}

# Fluent Bit's values are rendered from k8s/fluent-bit-values.yaml.tmpl with the three
# things the template cannot know: Splunk's container IP (moves on every Docker restart),
# the HEC token (a secret, never in git), and whether HEC has TLS on. infra/local/tf.sh
# supplies them as TF_VAR_* from `docker inspect` and the gitignored rendered file.
variable "splunk_ip" {
  type        = string
  description = "Splunk container IP on the kind network (docker inspect)"
}
variable "splunk_hec_token" {
  type        = string
  sensitive   = true
  description = "HEC token from Day 3 — never committed, never printed"
}
variable "splunk_hec_tls" {
  type    = string
  default = "On"
}
