#!/bin/bash
# Bootstrap run by cloud-init on EVERY instance the ASG launches (including
# scale-out and replacement instances, which Terraform provisioners can't reach).
# It gets NGINX up quickly so the load balancer health check can pass.
# The Terraform remote-exec provisioner then re-verifies / finishes the setup.
set -euxo pipefail

dnf install -y nginx
systemctl enable --now nginx

# IMDSv2 token -> instance id, for a page that shows which server answered
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 60")
INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id)

echo "<h1>${environment}</h1><p>Served by $INSTANCE_ID (bootstrap)</p>" > /usr/share/nginx/html/index.html
