#!/bin/bash -v
export DEBIAN_FRONTEND=noninteractive

add-apt-repository "ppa:wireguard/wireguard"
apt-get update -y
apt-get upgrade -y -o Dpkg::Options::="--force-confnew"
apt-get install -y wireguard-dkms wireguard-tools python3-pip

# aws cli
pip3 install --upgrade --user rsa awscli
export PATH=/root/.local/bin:$PATH
mkdir /root/.aws/
touch /root/.aws/config
cat << 'EOF' > /root/.aws/config
[profile wireguard]
role_arn = ${role_arn}
source_profile = default

[default]
region=${region}
EOF

# fetch the VPN server private key
wg_server_private_key=$(aws ssm get-parameter \
    --name "${wg_server_private_key_param}" \
    --with-decryption \
    --query 'Parameter.Value' \
    --output text)

cat << EOF > /etc/wireguard/wg0.conf
[Interface]
Address = ${wg_server_net}
PrivateKey = $wg_server_private_key
ListenPort = ${wg_server_port}
PostUp   = iptables -A FORWARD -i %i -j ACCEPT; iptables -A FORWARD -o %i -j ACCEPT; iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
PostDown = iptables -D FORWARD -i %i -j ACCEPT; iptables -D FORWARD -o %i -j ACCEPT; iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE

${peers}
EOF

# we go with the eip if it is provided
if [ "${eip_id}" != "disabled" ]; then
  export INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
  export REGION=$(curl -fsq http://169.254.169.254/latest/meta-data/placement/availability-zone | sed 's/[a-z]$//')
  aws --region $${REGION} ec2 associate-address --allocation-id ${eip_id} --instance-id $${INSTANCE_ID}
fi

chown -R root:root /etc/wireguard/
chmod -R og-rwx /etc/wireguard/*
sed -i 's/#net.ipv4.ip_forward=1/net.ipv4.ip_forward=1/' /etc/sysctl.conf
sysctl -p
ufw allow ssh
ufw allow ${wg_server_port}/udp
ufw --force enable
systemctl enable wg-quick@wg0.service
systemctl start wg-quick@wg0.service
