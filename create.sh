#!/bin/bash

set -o errexit
set -o nounset
set -o xtrace

#required variables:
vpcCidrBlock="10.0.0.0/16"
publicSubnetCidrBlock="10.0.1.0/24"
privateSubnetCidrBlock="10.0.2.0/24"
ubuntuImage="ami-df8406b0"
destinationCidrBlock="0.0.0.0/0"


# create vpc and subnets
create_vpc_subnets() {
  #vpc
  vpcId=$( aws ec2 create-vpc --cidr-block ${vpcCidrBlock}\
  --query Vpc.VpcId --output text )
  echo VPC ID: ${vpcId}

  # overwrite the default VPC DNS settings
  aws ec2 modify-vpc-attribute --vpc-id ${vpcId} --enable-dns-support "{\"Value\":true}"
  aws ec2 modify-vpc-attribute --vpc-id ${vpcId} --enable-dns-hostnames "{\"Value\":true}"

  #subnets
  publicSubnetId=$( aws ec2 create-subnet --vpc-id ${vpcId}\
  --cidr-block ${publicSubnetCidrBlock} --query Subnet.SubnetId --output text )
  privateSubnetId=$( aws ec2 create-subnet --vpc-id ${vpcId}\
  --cidr-block ${privateSubnetCidrBlock} --query Subnet.SubnetId --output text )
  echo Public Subnet ID: ${publicSubnetId}
  echo Private Subnet ID: ${privateSubnetId}
} 

# make one subnet public:
# After creating the VPC and subnets, you can make one subnet public by:
# attaching an internet gateway to your VPC
# creating a custom route table, and
# configuring routing for the subnet to the Internet gateway.
create_igw() {
  igwId=$( aws ec2 create-internet-gateway\
  --query InternetGateway.InternetGatewayId --output text )
  echo IGW ID: ${igwId}
  aws ec2 attach-internet-gateway --vpc-id ${vpcId} --internet-gateway-id ${igwId}
}

create_public_rt() {
  # Create a custom public route table for your VPC
  publicRouteTableId=$( aws ec2 create-route-table --vpc-id ${vpcId}\
  --query RouteTable.RouteTableId --output text )
  echo Public RT ID: ${publicRouteTableId}
}

configure_routing_to_igw() {
  # Create a route in the RT that points all traffic (0.0.0.0/0) to the IGW
  igwRouteStatus=$( aws ec2 create-route --route-table-id ${publicRouteTableId}\
  --destination-cidr-block ${destinationCidrBlock} --gateway-id ${igwId}\
  --query Return --output text)
  echo IGW route created: ${igwRouteStatus}

  # confirm that route was created
  publicRouteTable=$( aws ec2 describe-route-tables --route-table-id ${publicRouteTableId} )
  echo -e "Public Route Table:\n${publicRouteTable}"
}

make_subnet_public() {
  create_igw
  create_public_rt
  configure_routing_to_igw

  # associate the public subnet with the public route table
  aws ec2 associate-route-table  --subnet-id ${publicSubnetId}\
  --route-table-id ${publicRouteTableId}

  # enable public ip on subnet
  aws ec2 modify-subnet-attribute --subnet-id ${publicSubnetId} --map-public-ip-on-launch
}

launch_public_instance() {
  #create security group
  publicSgId=$( aws ec2 create-security-group --group-name CliPublicAccess\
  --description "Security group for public access" --vpc-id ${vpcId}\
  --query GroupId --output text )

  # add rules that allow SSH and HTTP access
  aws ec2 authorize-security-group-ingress --group-id ${publicSgId} --protocol tcp --port 22 --cidr ${vpcCidrBlock}
  aws ec2 authorize-security-group-ingress --group-id ${publicSgId} --protocol tcp --port 80 --cidr ${destinationCidrBlock}

  # launch instance
  publicInstaceId=$( aws ec2 run-instances --image-id ${ubuntuImage} --count 1\
  --instance-type t2.micro --key-name CliKeyPair\
  --security-group-ids ${publicSgId} --subnet-id ${publicSubnetId}\
  --query 'Instances[0].InstanceId' --output text )
  publicIp=$( aws ec2 describe-instances --instance-ids ${publicInstaceId}\
  --query 'Reservations[*].Instances[*].PublicIpAddress' --output text )
  publicInstanceState=$( aws ec2 describe-instance-status --instance-id=${publicInstaceId}\
  --query 'Reservations[*].Instances[*].State.Name' --output text )

  echo Public Instance ID: ${publicInstaceId}
  echo Public IP: ${publicIp}
  echo Instance State: ${publicInstanceState}
}

create_ngw() {
  #allocate elastic ip to vpc
  allocationId=$( aws ec2 allocate-address --domain vpc\
  --query AllocationId --output text )
  echo Elastic IP Allocation ID: ${allocationId}

  #ngw
  ngwId=$( aws ec2 create-nat-gateway --subnet-id ${privateSubnetId}\
  --allocation-id ${allocationId} --query NatGateway.NatGatewayId --output text  )
}

create_private_rt() {
  # Create a private route table for your VPC
  privateRouteTableId=$( aws ec2 create-route-table --vpc-id ${vpcId}\
  --query RouteTable.RouteTableId --output text )
  echo Private RT ID: ${privateRouteTableId}
}

configure_routing_to_ngw() {
  # Create a route in the RT that points all traffic (0.0.0.0/0) to the NGW
  ngwRouteStatus=$( aws ec2 create-route --route-table-id ${privateRouteTableId}\
  --destination-cidr-block ${destinationCidrBlock} --gateway-id ${ngwId}\
  --query Return --output text)
  echo NGW route created: ${ngwRouteStatus}

  # confirm that route was created
  privateRouteTable=$( aws ec2 describe-route-tables --route-table-id ${privateRouteTableId} )
  echo -e "Private Route Table:\n${privateRouteTable}"
}

make_subnet_private() {
  create_ngw
  create_private_rt
  configure_routing_to_ngw

  # associate the private subnet with the private route table
  aws ec2 associate-route-table  --subnet-id ${privateSubnetId}\
  --route-table-id ${privateRouteTable}
}

launch_private_instance() {
  #create security group
  privateSgId=$( aws ec2 create-security-group --group-name CliPrivateAccess\
  --description "Security group for private access" --vpc-id ${vpcId}\
  --query GroupId --output text )

  # add rules that allow SSH, HTTP and Postgres access
  aws ec2 authorize-security-group-ingress --group-id ${privateSgId}\
  --protocol tcp --port 22 --cidr ${vpcCidrBlock}
  aws ec2 authorize-security-group-ingress --group-id ${privateSgId}\
  --protocol tcp --port 80 --cidr ${vpcCidrBlock}
  aws ec2 authorize-security-group-ingress --group-id ${privateSgId}\
  --protocol tcp --port 5432 --cidr ${publicSubnetCidrBlock}

  # launch instance
  privateInstaceId=$( aws ec2 run-instances --image-id ${ubuntuImage} --count 1\
  --instance-type t2.micro --key-name CliKeyPair\
  --security-group-ids ${privateSgId} --subnet-id ${privateSubnetId}\
  --query 'Instances[0].InstanceId' --output text )
  privateInstanceState=$( aws ec2 describe-instance-status --instance-id=${publicInstaceId}\
  --query 'Reservations[*].Instances[*].State.Name' --output text )

  echo Private Instance ID: ${privateInstaceId}
  echo Instance State: ${privateInstanceState}
}

create() {
  echo VPC provisioning in progress...
  create_vpc_subnets
  make_subnet_publicv
  launch_public_instance
  make_subnet_private
  launch_private_instance
  echo VPC provisioning completed!
}

create