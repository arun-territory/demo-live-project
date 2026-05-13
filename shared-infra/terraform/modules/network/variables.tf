variable "name_prefix" {
  type = string
}

variable "region" {
  type = string
}

variable "cidr_nodes" {
  type = string
}

variable "cidr_pods" {
  type = string
}

variable "cidr_services" {
  type = string
}

variable "labels" {
  type    = map(string)
  default = {}
}
