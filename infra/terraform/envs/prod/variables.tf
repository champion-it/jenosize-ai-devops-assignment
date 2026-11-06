variable "project_id" {
  type = string
}

variable "region" {
  type    = string
  default = "asia-southeast1"
}

variable "api_image" {
  description = "Set once by terraform; the deploy pipeline owns it afterwards."
  type        = string
}

variable "worker_image" {
  type = string
}

variable "alert_emails" {
  type    = list(string)
  default = []
}
