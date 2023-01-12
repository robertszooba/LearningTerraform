data "external" "my_ip_addr" {
  program = ["/bin/bash", "${path.module}/getip.sh"]
}


resource "google_project_service" "project" {
  project = var.pro
  service = "iam.googleapis.com"
  disable_on_destroy = false
}

resource "google_service_account" "service-acc" {
  project = var.pro
  account_id = "X"
  display_name = "Service Account MIG test"
  depends_on = [google_project_service.project]
}

resource "google_compute_network" "vpc-network" {
  project = var.pro
  name = var.network_name
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "subnetwork" {
  name = "subnetwork"
  ip_cidr_range = "10.0.101.0/24"
  region = var.region
  project = var.pro
  stack_type = "IPV4_ONLY"
  network = google_compute_network.vpc-network.self_link
}

// allow internal traffic to test the connectivity between
// the ssh-vm and the VMs within the MIG
// Question: should this be applied to specific machines, i.e.
// should network tags be added here?
resource "google_compute_firewall" "allow-internal" {
  name    = "allow-internal"
  project = var.pro
  network = google_compute_network.vpc-network.self_link
  allow {
    protocol = "tcp"
    ports = ["80"]
  }
  source_ranges = ["10.0.101.0/24"]
}

resource "google_compute_firewall" "allow-ssh" {
  project = var.pro
  name          = "allow-ssh"
  direction     = "INGRESS"
  network       = google_compute_network.vpc-network.self_link
  allow {
    protocol = "tcp"
    ports = ["22"]
  }
  target_tags   = ["allow-ssh"] // Enables sshing from my own IP onto the VM that has this tag
  source_ranges = [format("%s/%s", data.external.my_ip_addr.result["internet_ip"], 32)]
}

resource "google_compute_address" "static" {
  project = var.pro
  region = var.region
  name = "ipv4-address"
}

// An extra instance for testing connectivity
// The idea is to ssh onto this VM 
// and then check whether one can access MIG's VMs
// via curl, f.e, curl 10.0.101.5:80
resource "google_compute_instance" "ssh-vm" {
  name = "ssh-vm"
  machine_type = "e2-standard-2"
  project = var.pro
  tags = ["allow-ssh"]
  zone = "europe-west1-b"

  boot_disk {
    initialize_params {
      image = "ubuntu-2004-focal-v20221213"
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.subnetwork.self_link
    access_config {
      nat_ip = google_compute_address.static.address
    }
  }

  metadata = {
    startup-script = <<-EOF
        #!/bin/bash
        sudo snap install docker
        sudo docker version > file1.txt
        sleep 5
        sudo docker run -d --rm -p ${var.server_port}:${var.server_port} \
        busybox sh -c "while true; do { echo -e 'HTTP/1.1 200 OK\r\n'; \
        echo 'yo'; } | nc -l -p ${var.server_port}; done"
        EOF
  }

}

module "instance_template" {
  source = "terraform-google-modules/vm/google//modules/instance_template"
  version = "7.9.0"
  region = var.region
  project_id = var.pro
  network = google_compute_network.vpc-network.self_link
  subnetwork = google_compute_subnetwork.subnetwork.self_link
  service_account = {
    email = google_service_account.service-acc.email
    scopes = ["cloud-platform"]
  }

  name_prefix = "webserver"
  tags = ["template-vm", "allow-ssh"]
  machine_type = "e2-standard-2"
  startup_script = <<-EOF
  #!/bin/bash
  sudo snap install docker
  sudo docker version > docker_version.txt
  sleep 5
  sudo docker run -d --rm -p ${var.server_port}:${var.server_port} \
  busybox sh -c "while true; do { echo -e 'HTTP/1.1 200 OK\r\n'; \
  echo 'yo'; } | nc -l -p ${var.server_port}; done"
  EOF
  source_image = "https://www.googleapis.com/compute/v1/projects/ubuntu-os-cloud/global/images/ubuntu-2004-focal-v20221213"
  disk_size_gb = 10
  disk_type = "pd-balanced"
  preemptible = true

}

/*
Remark for the future: 
It is not possible to set a range of external IPs for the autoscaling instances.
One workaround is to configure NAT gateway.
Thus, the autoscaled instances will have only one public IP when traffic is sent
to your gateway.
Steps to configure NAT: https://cloud.google.com/vpc/docs/vpc#natgateway
*/
module "vm_mig" {
  source  = "terraform-google-modules/vm/google//modules/mig"
  version = "7.9.0"
  project_id = var.pro
  region = var.region
  target_size = 3
  instance_template = module.instance_template.self_link
  // a load balancer sends incoming traffic to the group via the named ports
  // if a req comes to the LB, send it to the port named http on the vms
  named_ports = [{
    name = "http"
    port = 80
  }]
  health_check = {
    type = "http"
    initial_delay_sec = 30
    check_interval_sec = 30
    healthy_threshold = 1
    timeout_sec = 10
    unhealthy_threshold = 5
    response = ""
    proxy_header = "NONE"
    port = 80
    request = ""
    request_path = "/"
    host = ""
  }
  network = google_compute_network.vpc-network.self_link
  subnetwork = google_compute_subnetwork.subnetwork.self_link
}

module "gce-lb-http" {
  source            = "GoogleCloudPlatform/lb-http/google"
  version           = "~> 4.4"
  project           = var.pro
  name              = "group-http-lb"
  // This tag must match the tag from the instance template
  // This will create the default health check firewall rule
  // and apply it to the machines tagged with the "template-vm" tag
  target_tags       = ["template-vm"]
  // the name of the network where the default health check will be created
  firewall_networks = [google_compute_network.vpc-network.name]
  backends = {
    default = {
      description                     = null
      port                            = 80
      protocol                        = "HTTP"
      port_name                       = "http"
      timeout_sec                     = 10
      enable_cdn                      = false
      custom_request_headers          = null
      custom_response_headers         = null
      security_policy                 = null
      connection_draining_timeout_sec = null
      session_affinity                = null
      affinity_cookie_ttl_sec         = null

      health_check = {
        check_interval_sec  = null
        timeout_sec         = null
        healthy_threshold   = null
        unhealthy_threshold = null
        request_path        = "/"
        port                = 80
        host                = null
        logging             = null
      }

      log_config = {
        enable = true
        sample_rate = 1.0
      }

      groups = [
        {
          # Each node pool instance group should be added to the backend.
          group                        = module.vm_mig.instance_group
          balancing_mode               = null
          capacity_scaler              = null
          description                  = null
          max_connections              = null
          max_connections_per_instance = null
          max_connections_per_endpoint = null
          max_rate                     = null
          max_rate_per_instance        = null
          max_rate_per_endpoint        = null
          max_utilization              = null
        },
      ]

      iap_config = {
        enable               = false
        oauth2_client_id     = null
        oauth2_client_secret = null
      }
    }
  }
}
