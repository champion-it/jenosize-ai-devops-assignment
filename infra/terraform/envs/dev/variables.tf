variable "region" {
  type    = string
  default = "ap-southeast-1"
}

variable "cluster_state" {
  description = "Where the cluster root keeps its state, so this environment can read what it created rather than being told."
  type = object({
    bucket = string
    key    = string
    region = string
  })
}

variable "image_tag" {
  description = "Set once to bootstrap; the deploy pipeline owns it afterwards."
  type        = string
  default     = "bootstrap"
}

variable "tags" {
  type = map(string)
  default = {
    Project   = "jenie-helpdesk-ai"
    ManagedBy = "terraform"
  }
}
