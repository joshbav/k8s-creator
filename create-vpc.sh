#!/bin/bash

# TODO: --availability-zone
# Does not select an availability zone when creating a subnet, let's AWS chose


# Creates a VPC, and a script to terminate it
# Revision 4-15-19, by Josh B @ Sysdig
# Requires AWS CLI already configured for region

# TODO: check if VPC already exists, because it'll create a duplicate

AWS_VPC_CIDR_BLOCK="10.9.0.0/16"
AWS_VPC_SUBNET_CIDR_BLOCK="10.9.1.0/24"
# !!!!!!!! NOTE YOUR CLI MUST BE CONFIGURED FOR US-EAST-1
AWS_AVAILABILITY_ZONE="us-east-1a"
MY_EMAIL=name@domain.com

# VPC
echo
echo "CREATING VPC"
aws ec2 create-vpc --cidr-block $AWS_VPC_CIDR_BLOCK > vpc.json
AWS_VPC_ID=$(jq '.Vpc.VpcId' -r vpc.json)
aws ec2 create-tags --resources $AWS_VPC_ID --tags Key=Name,Value=ClassLab Key=Owner,Value=$MY_EMAIL Key=CreationDate,Value="$(date)"
aws ec2 modify-vpc-attribute --vpc-id $AWS_VPC_ID --enable-dns-hostnames
echo "   Created VPC $AWS_VPC_ID"

# INTERNET GATEWAY
echo
echo "CREATING & ATTACHING INTERNET GATEWAY"
aws ec2 create-internet-gateway > internet-gateway.json
AWS_INTERNET_GATEWAY_ID=$(jq '.InternetGateway.InternetGatewayId' -r internet-gateway.json)
aws ec2 create-tags --resources $AWS_INTERNET_GATEWAY_ID --tags Key=Name,Value=ClassLab Key=Owner,Value=$MY_EMAIL Key=CreationDate,Value="$(date)"
aws ec2 attach-internet-gateway --internet-gateway-id $AWS_INTERNET_GATEWAY_ID --vpc-id $AWS_VPC_ID
echo "   Created Internet Gateway $AWS_INTERNET_GATEWAY_ID"

# SECURITY GROUP
# This is wide open to the world, which is good for a classroom, and is the reason
#  this is all being done in it's own VPC
echo
echo "CREATING SECURITY GROUP"
aws ec2 create-security-group --description ClassLab --group-name WideOpen --vpc-id $AWS_VPC_ID > security-group.json
AWS_SECURITY_GROUP_ID=$(jq '.GroupId' -r security-group.json)
aws ec2 create-tags --resources $AWS_SECURITY_GROUP_ID --tags Key=Name,Value=ClassLab Key=Owner,Value=$MY_EMAIL Key=CreationDate,Value="$(date)"
aws ec2 authorize-security-group-ingress --group-id $AWS_SECURITY_GROUP_ID --protocol all --port all --cidr 0.0.0.0/0
echo "   Created Security Group $AWS_SECURITY_GROUP_ID"

# SUBNET
echo
echo "CREATING SUBNET"
aws ec2 create-subnet --cidr-block $AWS_VPC_SUBNET_CIDR_BLOCK --vpc-id $AWS_VPC_ID --availability-zone $AWS_AVAILABILITY_ZONE > subnet.json
AWS_SUBNET_ID=$(jq '.Subnet.SubnetId' -r subnet.json)
aws ec2 create-tags --resources $AWS_SUBNET_ID --tags Key=Name,Value=ClassLab Key=Owner,Value=$MY_EMAIL Key=CreationDate,Value="$(date)"
aws ec2 modify-subnet-attribute --subnet-id $AWS_SUBNET_ID --map-public-ip-on-launch
echo "   Created Subnet $AWS_SUBNET_ID"

# ROUTE TABLE
echo
echo "CREATING ROUTE TABLE"
aws ec2 create-route-table --vpc-id $AWS_VPC_ID > route-table.json
AWS_ROUTE_TABLE_ID=$(jq '.RouteTable.RouteTableId' -r route-table.json)
aws ec2 create-tags --resources $AWS_ROUTE_TABLE_ID --tags Key=Name,Value=ClassLab Key=Owner,Value=$MY_EMAIL Key=CreationDate,Value="$(date)"
aws ec2 associate-route-table --route-table-id $AWS_ROUTE_TABLE_ID --subnet-id $AWS_SUBNET_ID
aws ec2 create-route --route-table-id $AWS_ROUTE_TABLE_ID --gateway-id $AWS_INTERNET_GATEWAY_ID --destination-cidr-block 0.0.0.0/0
##aws ec2 replace-route --internet-gateway-id $AWS_INTERNET_GATEWAY_ID --destination-cidr-block 0.0.0.0/0
echo "   Created Route Table $AWS_ROUTE_TABLE_ID"

# SSH KEY
echo
echo "CREATING SSH KEY CLASS-KEY, SAVED AS FILE class-key-priv.key"
aws ec2 create-key-pair --key-name class-key >class-key.json
jq '.KeyMaterial' -r class-key.json >class-key-priv.key
chmod 600 class-key-priv.key
echo

# CREATE CLEANUP SCRIPT
echo "CREATING VPC DELETION SCRIPT terminate-vpc.sh"
echo "#!/bin/bash">terminate-vpc.sh
chmod +x terminate-vpc.sh
echo "echo \"Deleting security group $AWS_SECURITY_GROUP_ID\"">>terminate-vpc.sh
echo "aws ec2 terminate-security-group --group-id $AWS_SECURITY_GROUP_ID">>terminate-vpc.sh
echo "echo \"Deleting subnet $AWS_SUBNET_ID\"">>terminate-vpc.sh
echo "aws ec2 terminate-subnet --subnet-id $AWS_SUBNET_ID">>terminate-vpc.sh
echo "echo \"Deleting route table $AWS_ROUTE_TABLE_ID\"">>terminate-vpc.sh
echo "aws ec2 terminate-route-table --route-table-id $AWS_ROUTE_TABLE_ID">>terminate-vpc.sh
echo "echo \"Detaching & deleting Internet Gateway $AWS_INTERNET_GATEWAY_ID\"">>terminate-vpc.sh
echo "aws ec2 detach-internet-gateway --internet-gateway-id $AWS_INTERNET_GATEWAY_ID --vpc-id $AWS_VPC_ID">>terminate-vpc.sh
echo "aws ec2 terminate-internet-gateway --internet-gateway-id $AWS_INTERNET_GATEWAY_ID">>terminate-vpc.sh
echo "echo \"Deleting VPC $AWS_VPC_ID\"">>terminate-vpc.sh
echo "aws ec2 terminate-vpc --vpc-id $AWS_VPC_ID">>terminate-vpc.sh
echo "echo \"Deleting key pair class-key\"">>terminate-vpc.sh
echo "aws ec2 terminate-key-pair --key-name class-key">>terminate-vpc.sh

