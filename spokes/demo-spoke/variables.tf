variable "aws_region" {
  type    = string
  default = "eu-central-1"
}

variable "aws_profile" {
  type    = string
  default = "default"
}

variable "cluster_name" {
  type    = string
  default = "demo-spoke"
}

variable "cluster_version" {
  type    = string
  default = "1.34"
}

variable "vpc_cidr" {
  type    = string
  default = "10.1.0.0/16"
}

variable "single_az" {
  description = "Pin the spoke to a single AZ to minimize cost; this is a demo, not a HA workload."
  type        = string
  default     = "eu-central-1a"
}
