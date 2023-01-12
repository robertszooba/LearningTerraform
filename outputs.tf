output "load-balancer-external_ip" {
  value = module.gce-lb-http.external_ip
}

output "external_ip_of_the_ssh_vm" {
  value = google_compute_instance.ssh-vm.network_interface.0.access_config.0.nat_ip
}
