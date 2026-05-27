variable "region" {
  type    = string
  default = "eu-central-1"
}

variable "cluster_name" {
  type    = string
  default = "sme-eks-cluster"
}

variable "domain_name" {
  type    = string
  default = "example.com"
}

variable "node_instance_type" {
  type    = string
  default = "t3.small"
}

variable "desired_node_count" {
  type    = number
  default = 2
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "public_subnets_count" {
  type    = number
  default = 2
}

variable "private_subnets_count" {
  type    = number
  default = 2
}

variable "tags" {
  type = map(string)
  default = {
    Project = "sme-app"
    Owner   = "dev-team"
  }
}
