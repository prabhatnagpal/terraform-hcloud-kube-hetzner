resource "hcloud_server" "first_control_plane" {
  name = "k3s-control-plane-0"

  image              = data.hcloud_image.linux.name
  rescue             = "linux64"
  server_type        = var.control_plane_server_type
  location           = var.location
  ssh_keys           = [hcloud_ssh_key.k3s.id]
  firewall_ids       = [hcloud_firewall.k3s.id]
  placement_group_id = hcloud_placement_group.k3s.id

  labels = {
    "provisioner" = "terraform",
    "engine"      = "k3s"
  }

  connection {
    user           = "root"
    private_key    = local.ssh_private_key
    agent_identity = local.ssh_identity
    host           = self.ipv4_address
  }

  provisioner "file" {
    content = templatefile("${path.module}/templates/config.ign.tpl", {
      name           = self.name
      ssh_public_key = local.ssh_public_key
    })
    destination = "/root/config.ign"
  }

  # Install MicroOS
  provisioner "remote-exec" {
    inline = local.MicroOS_install_commands
  }

  # Issue a reboot command
  provisioner "local-exec" {
    command = "ssh ${local.ssh_args} root@${self.ipv4_address} '(sleep 2; reboot)&'; sleep 3"
  }

  # Wait for MicroOS to reboot and be ready
  provisioner "local-exec" {
    command = <<-EOT
      until ssh ${local.ssh_args} -o ConnectTimeout=2 root@${self.ipv4_address} true 2> /dev/null
      do
        echo "Waiting for MicroOS to reboot and become available..."
        sleep 2
      done
    EOT
  }

  # Generating k3s master config file
  provisioner "file" {
    content = yamlencode({
      node-name                = self.name
      cluster-init             = true
      disable-cloud-controller = true
      disable                  = ["servicelb", "local-storage"]
      flannel-iface            = "eth1"
      kubelet-arg              = "cloud-provider=external"
      node-ip                  = local.first_control_plane_network_ip
      advertise-address        = local.first_control_plane_network_ip
      token                    = random_password.k3s_token.result
      node-taint               = var.allow_scheduling_on_control_plane ? [] : ["node-role.kubernetes.io/master:NoSchedule"]
    })
    destination = "/etc/rancher/k3s/config.yaml"
  }

  # Run the first control plane
  provisioner "remote-exec" {
    inline = [
      # set the hostname in a persistent fashion
      "hostnamectl set-hostname ${self.name}",
      # first we disable automatic reboot (after transactional updates), and configure the reboot method as kured
      "rebootmgrctl set-strategy off && echo 'REBOOT_METHOD=kured' > /etc/transactional-update.conf",
      # prepare a directory for our post-installation kustomizations
      "mkdir -p /tmp/post_install",
      # then we initiate the cluster
      "systemctl enable k3s-server",
      # wait for k3s to get ready
      <<-EOT
      timeout 120 bash <<EOF
        until systemctl status k3s-server > /dev/null; do
          systemctl start k3s-server
          echo "Initiating the cluster..."
          sleep 1
        done
        until [ -e /etc/rancher/k3s/k3s.yaml ]; do
          echo "Waiting for kubectl config..."
          sleep 1
        done
        until [[ "\$(kubectl get --raw='/readyz' 2> /dev/null)" == "ok" ]]; do
          echo "Waiting for cluster to become ready..."
          sleep 1
        done
      EOF
      EOT
    ]
  }

  # Upload kustomization.yaml, containing Hetzner CSI & CSM, as well as kured.
  provisioner "file" {
    content = yamlencode({
      apiVersion = "kustomize.config.k8s.io/v1beta1"
      kind       = "Kustomization"
      resources = [
        "https://github.com/hetznercloud/hcloud-cloud-controller-manager/releases/download/${local.ccm_version}/ccm-networks.yaml",
        "https://raw.githubusercontent.com/hetznercloud/csi-driver/${local.csi_version}/deploy/kubernetes/hcloud-csi.yml",
        "https://github.com/weaveworks/kured/releases/download/${local.kured_version}/kured-${local.kured_version}-dockerhub.yaml",
        "./traefik.yaml"
      ]
      patchesStrategicMerge = [
        file("${path.module}/patches/kured.yaml"),
        local.ccm_latest ? file("${path.module}/patches/ccm_latest.yaml") : file("${path.module}/patches/ccm.yaml"),
        local.csi_latest ? file("${path.module}/patches/csi_latest.yaml") : null,
      ]
    })
    destination = "/tmp/post_install/kustomization.yaml"
  }

  # Upload traefik config
  provisioner "file" {
    content = templatefile(
      "${path.module}/templates/traefik_config.yaml.tpl",
      {
        lb_disable_ipv6    = var.lb_disable_ipv6
        lb_server_type     = var.lb_server_type
        location           = var.location
        traefik_acme_tls   = var.traefik_acme_tls
        traefik_acme_email = var.traefik_acme_email
    })
    destination = "/tmp/post_install/traefik.yaml"
  }

  # Deploy secrets, logging is automatically disabled due to sensitive variables
  provisioner "remote-exec" {
    inline = [
      "kubectl -n kube-system create secret generic hcloud --from-literal=token=${var.hcloud_token} --from-literal=network=${hcloud_network.k3s.name}",
      "kubectl -n kube-system create secret generic hcloud-csi --from-literal=token=${var.hcloud_token}",
    ]
  }

  # Deploy our post-installation kustomization
  provisioner "remote-exec" {
    inline = [
      # This ugly hack is here, because terraform serializes the
      # embedded yaml files with "- |2", when there is more than
      # one yamldocument in the embedded file. Kustomize does not understand
      # that syntax and tries to parse the blocks content as a file, resulting
      # in weird errors. so gnu sed with funny escaping is used to
      # replace lines like "- |3" by "- |" (yaml block syntax).
      # due to indendation this should not changes the embedded
      # manifests themselves
      "sed -i 's/^- |[0-9]\\+$/- |/g' /tmp/post_install/kustomization.yaml",
      "kubectl apply -k /tmp/post_install",
    ]
  }

  network {
    network_id = hcloud_network.k3s.id
    ip         = local.first_control_plane_network_ip
  }

  depends_on = [
    hcloud_network_subnet.k3s,
    hcloud_firewall.k3s
  ]
}
