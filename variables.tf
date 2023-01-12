variable "pro" {
  description = "project name"
  type = string
  default = ""
}

variable "region" {
  description = "project region"
  type = string
  default = "europe-west1"
}

variable "network_name" {
  description = "the name of the network"
  type = string
  default = "vpc-network"
}

variable "server_port" {
  description = "the port the server will use for http reqs"
  type = number
  default = 80
}
