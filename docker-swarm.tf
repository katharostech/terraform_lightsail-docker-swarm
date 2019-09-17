provider "aws" {
    region      = "us-east-1"
    version = "~> 2.6"
}
provider "null" {
    version = "~> 2.1"
}
provider "local" {
    version = "~> 1.2"
}

# Configuration
locals {
    # The "manager" or "worker" status of each node in the cluster ( please make
    # the first one a "manager", the swarm will be initialized on that node )
    cluster_topology =  [ "manager", "worker", "worker" ]
    # Ports allowed between nodes in the cluster
    cluster_ports = {
        tcp = [ 2377, 7946, "9419:9428" ]
        udp = [ 7946, 4789 ]
    }

    # Ports to be opened to the internet ( port 9000 is used for Portainer )
    world_ports = [ 9000 ]
}

# Cluster connection key pair
resource "aws_lightsail_key_pair" "test-cluster-key-pair" {
    name = "test-swarm-key-pair"

    # Create private key locally for convenience when remoting into the server
    provisioner "local-exec" {
        command = "echo '${aws_lightsail_key_pair.test-cluster-key-pair.private_key}' > local-resources/id_rsa"
    }
    provisioner "local-exec" {
        command = "chmod 600 local-resources/id_rsa"
    }
    provisioner "local-exec" {
        when = "destroy"
        command = "rm -f local-resources/id_rsa"
    }
}

# Cluster instances
resource "aws_lightsail_instance" "test-swarm-cluster" {
    count = "${length(local.cluster_topology)}"
    name = "test-swarm-${element(local.cluster_topology, count.index)}-${count.index}"

    availability_zone = "us-east-1a"
    blueprint_id = "ubuntu_16_04_2"
    bundle_id = "nano_2_0"
    key_pair_name = "${aws_lightsail_key_pair.test-cluster-key-pair.name}"

    connection {
        type = "ssh"
        host = "${self.public_ip_address}"
        user = "ubuntu"
        private_key = "${aws_lightsail_key_pair.test-cluster-key-pair.private_key}"
    }

    provisioner "remote-exec" {
        inline = [
            "echo y | sudo ufw enable", # Enable Firewall
            "sudo ufw allow 22",
            "sudo apt update",
            "sudo apt install -y docker.io",
            "sudo sysctl net.ipv4.conf.all.arp_accept=1" # For LizardFS
        ]
    }

    # Open up all lightsail ports ( UFW will be used instead )
    provisioner "local-exec" {
        command = "aws --no-verify-ssl --region us-east-1 lightsail put-instance-public-ports --port-infos fromPort=0,toPort=65535,protocol=all --instance-name ${self.name}"
    }
}

# Cluster node firewall rules
resource "null_resource" "cluster-firewall-rules" {
    count = "${length(local.cluster_topology)}"

    triggers {
        manager_private_ips = "${join(",", aws_lightsail_instance.test-swarm-cluster.*.private_ip_address)}"
    }

    connection {
        type = "ssh"
        host = "${element(aws_lightsail_instance.test-swarm-cluster.*.public_ip_address, count.index)}"
        user = "ubuntu"
        private_key = "${aws_lightsail_key_pair.test-cluster-key-pair.private_key}"
    }

    provisioner "remote-exec" {
        inline = [
            "mkdir -p terraform-state",
            "printf '${join(" ", aws_lightsail_instance.test-swarm-cluster.*.private_ip_address)}' > terraform-state/cluster-ips.txt",
            "printf '${join(" ", local.cluster_ports["tcp"])}' > terraform-state/cluster-tcp-ports.txt",
            "printf '${join(" ", local.cluster_ports["udp"])}' > terraform-state/cluster-udp-ports.txt",
            "printf '${join(" ", local.world_ports)}' > terraform-state/world-ports.txt",
            "for ip in $(cat terraform-state/cluster-ips.txt); do",
            "   for tcp_port in $(cat terraform-state/cluster-tcp-ports.txt); do",
            "       sudo ufw allow in proto tcp from $ip to any port $tcp_port",
            "   done",
            "   for udp_port in $(cat terraform-state/cluster-udp-ports.txt); do",
            "       sudo ufw allow in proto udp from $ip to any port $udp_port",
            "   done",
            "done",
            "for port in $(cat terraform-state/world-ports.txt); do",
            "   sudo ufw allow $port",
            "done"
        ]
    }

    provisioner "remote-exec" {
        when = "destroy"
        inline = [
            "for ip in $(cat terraform-state/cluster-ips.txt); do",
            "   for tcp_port in $(cat terraform-state/cluster-tcp-ports.txt); do",
            "       sudo ufw delete allow in proto tcp from $ip to any port $tcp_port",
            "   done",
            "   for udp_port in $(cat terraform-state/cluster-udp-ports.txt); do",
            "       sudo ufw delete allow in proto udp from $ip to any port $udp_port",
            "   done",
            "done",
            "for port in $(cat terraform-state/world-ports.txt); do",
            "   sudo ufw delete allow $port",
            "done"
        ]
    }
}

# Intialize swarm on node 1
resource "null_resource" "initialize-swarm" {
    connection {
        type = "ssh"
        host = "${aws_lightsail_instance.test-swarm-cluster.0.public_ip_address}"
        user = "ubuntu"
        private_key = "${aws_lightsail_key_pair.test-cluster-key-pair.private_key}"
    }

    # Set hostname
    provisioner "remote-exec" {
        inline = [
            "sudo hostnamectl set-hostname ${aws_lightsail_instance.test-swarm-cluster.0.name}",
            "sudo bash -c 'echo 127.0.0.1 ${aws_lightsail_instance.test-swarm-cluster.0.name} >> /etc/hosts'"
        ]
    }

    # Init swarm and generate tokens
    provisioner "remote-exec" {
        inline = [
            "sudo docker swarm init --advertise-addr ${aws_lightsail_instance.test-swarm-cluster.0.private_ip_address}",
            "sudo docker swarm join-token manager -q | tr -d '\\n' > swarm-manager-join-token.txt",
            "sudo docker swarm join-token worker -q  | tr -d '\\n' > swarm-worker-join-token.txt",
        ]
    }

    # Copy tokens to local workstation, used when joining other servers to cluster
    provisioner "local-exec" {
        command = "scp -i local-resources/id_rsa -o StrictHostKeyChecking=no ubuntu@${aws_lightsail_instance.test-swarm-cluster.0.public_ip_address}:swarm-manager-join-token.txt local-resources"
    }
    provisioner "local-exec" {
        command = "scp -i local-resources/id_rsa -o StrictHostKeyChecking=no ubuntu@${aws_lightsail_instance.test-swarm-cluster.0.public_ip_address}:swarm-worker-join-token.txt local-resources"
    }
    provisioner "local-exec" {
        when = "destroy"
        command = "rm -f local-resources/swarm-manager-join-token.txt"
    }
    provisioner "local-exec" {
        when = "destroy"
        command = "rm -f local-resources/swarm-worker-join-token.txt"
    }
    provisioner "remote-exec" {
        when = "destroy"
        inline = [
            "sudo docker swarm leave --force"
        ]
    }
}

# Join token data source
data "local_file" "join-token" {
    depends_on = [ "null_resource.initialize-swarm" ]
    count = "${length(local.cluster_topology)}"
    filename = "${path.module}/local-resources/swarm-${element(local.cluster_topology, count.index)}-join-token.txt"
}

# Join other servers to the cluster
resource "null_resource" "join-swarm" {
    depends_on = [ "null_resource.initialize-swarm" ]
    count = "${length(local.cluster_topology) - 1}"

    connection {
        type = "ssh"
        host = "${element(aws_lightsail_instance.test-swarm-cluster.*.public_ip_address, count.index+1)}"
        user = "ubuntu"
        private_key = "${aws_lightsail_key_pair.test-cluster-key-pair.private_key}"
    }

    # Set hostname
    provisioner "remote-exec" {
        inline = [
            "sudo hostnamectl set-hostname ${element(aws_lightsail_instance.test-swarm-cluster.*.name, count.index+1)}",
            "sudo bash -c 'echo 127.0.0.1 ${element(aws_lightsail_instance.test-swarm-cluster.*.name, count.index+1)} >> /etc/hosts'"
        ]
    }

    provisioner "remote-exec" {
        inline = [
            <<EOT
            sudo docker swarm join --token \
            ${element(data.local_file.join-token.*.content, count.index+1)} \
            ${aws_lightsail_instance.test-swarm-cluster.0.private_ip_address}:2377
            EOT
        ]
    }

    # provisioner "remote-exec" {
    #     when = "destroy"
    #     inline = [
    #         "sudo docker swarm leave --force"
    #     ]
    # }
}


# Start portainer
resource "null_resource" "portainer" {
    count = 1
    depends_on = [ "null_resource.join-swarm" ]

    connection {
        type = "ssh"
        host = "${aws_lightsail_instance.test-swarm-cluster.0.public_ip_address}"
        user = "ubuntu"
        private_key = "${aws_lightsail_key_pair.test-cluster-key-pair.private_key}"
    }

    provisioner "remote-exec" {
        inline = [
            # Deploy portainer on port 9000 on the swarm
            "curl -L https://downloads.portainer.io/portainer-agent-stack.yml -o portainer-agent-stack.yml",
            "sudo docker stack deploy --compose-file=portainer-agent-stack.yml portainer"
        ]
    }
}


# Point a Domain at the server
resource "aws_route53_record" "portainer" {
    count = 1
    zone_id = "FILL IN YOUR ZONE ID"
    name    = "swarm-lab.example.com"
    type    = "A"
    ttl     = "30"
    records = ["${aws_lightsail_instance.test-swarm-cluster.*.public_ip_address}"]
}

# Print server IPs for convenience
output "server_ips" {
    value = ["${formatlist("%s: %v", local.cluster_topology, aws_lightsail_instance.test-swarm-cluster.*.public_ip_address)}"]
}

