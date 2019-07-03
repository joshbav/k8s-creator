#!/bin/bash

# TODO:
# BUG: release elastic ip's by allocation id
# rename private key to .key  no -priv
# check for private key before starting
# kube_version  not working? how to do 1.14
# make ssh scripts
# heapster not working, can't do k top node
# cluster name is not correct, defaults to kubernetes?
# tag ebs volumes, give them names too
# creatinstance() var for disk size
# quotes around all vars

#helm_version: "v2.9.1"
#helm_enabled: true
# preinstall_selinux_state = disabled per https://github.com/kubernetes-sigs/kubespray/blob/master/docs/vars.md
#   

# FOR CREATING K8S CLUSTERS IN IN AWS WITH KUBESPRAY
# REVISION 4-15-19
# PREREQUISITES: AWS CLI INSTALLED AND CONFIGURED, JQ INSTALLED

#### VARIABLES YOU MUST CONFIGURE

MY_EMAIL=name@domain.com                    # Will be used in AWS tags
#AWS_SSH_KEY=/users/josh/joshb.pem          # Must be absolute path, don't use ~
# NOTE, USING CLASS KEY CREATED BY CREATE-VPC.SH
AWS_SSH_KEY=class-key-priv.key              # Best if you don't modify
SSH_USER_LOGIN=centos                       # Don't modify

MASTER_NODE_COUNT=1                         # Must be 1 or 3. Master #1 gets an Elastic IP
PUBLIC_NODE_COUNT=1                         # Must be >0. Public nodes are just workers with an extra label
                                            #   Public node #1 gets an Elastic IP
WORKER_NODE_COUNT=1                         # Can be 0-any. For a 2 node cluster have 1 master and 1 public node

# TODO ENABLE, IS CURRENTLY HARD CODED
SHUTDOWN_TIMER_HOURS=12                      # How long instances will run before powering off (not terminating)
# TODO ENABLE THESE 2, IS HARD CODED
NODE_DISK_SIZE=120                          # Size in GB for EBS volume for each node, same for master & worker
K8S_NODE_NAME_PREFIX=k8s                    # Don't modify. Used by this script, not kubespray

K8S_VERSION=v1.14.0
# https://kubernetes.io/docs/reference/command-line-tools-reference/feature-gates/
# https://kubernetes.io/docs/tasks/debug-application-cluster/audit/#dynamic-backend
# (This is one of the main reasons this script was created)
## troubleshooting K8S_FEATURE_GATES="'DynamicAuditing=true'" # changed 5-7: removed   Initializers=true
K8S_CNI_PLUGIN=calico
K8S_PODS_SUBNET=10.233.64.0/18              # K8s pod IP block, must be currently unused
K8S_KUBE_NETWORK_PREFIX=24                  # The IP CIDR size allocated to each node on your network
K8S_KUBE_SERVICE_ADDRESSES=10.233.0.0/18    # K8s services IP block, must be currently unused
K8S_KUBE_PROXY_MODE=ipvs                    # Kubeproxy to use IPVS (instead of iptables)
# TODO: MAKE SCRIPT ACCEPT AS ARGUMENT, NAME LAB1, LAB2, ETC
K8S_CLUSTER_NAME=cluster.local              # Name of the K8s cluster, in K8s
K8S_CONTAINER_MANAGER=docker                # Container runtime. "docker" or "crio"
K8S_CONTAINER_IMAGE_PULL_POLICY=IfNotPresent # K8s cluster default image pull policy (imagePullPolicy)
# TODO: enable
K8S_AUDIT=false                             # K8s audit log (not dynamic auditing)
# TODO: enable
K8S_POD_SECURITY_POLICY=false               # K8s pod security policy, requires RBAC authorization_modes
K8S_AUTHORIZATION_MODES="'Node','RBAC'"     # The API server auth policy

# AWS CONFIG
# TODO:  A VPC, SUBNET, SECURITY GROUP, & INTERNET GATEWAY WILL BE CREATED
AWS_VPC="vpc-0071631a67b307f09"             # YOU MUST CHANGE THIS
AWS_KEY_PAIR=class-key                      # YOU MUST CHANGE THIS
AWS_AMI=ami-01ed306a12b7d1c96               # CHANGE THIS Standard CentOS 7 AMI, US-WEST-2 REGION, NOTHING ELSE TESTED
AWS_SECURITY_GROUP="sg-0627938c5f25e0bbb"   # YOU MUST CHANGE THIS
AWS_SUBNET="subnet-00d568025bde2514b"       # YOU MUST CHANGE THIS

AWS_K8S_MASTER_INSTANCE_TYPE=m5.large       # Fine for an average lab
AWS_K8S_WORKER_INSTANCE_TYPE=m5.xlarge      #

#### DONE WITH VARIABLES

#### The arrays for the nodes, used to build configs for kubespray
# We will ignore the first element of 0 and avoid a fence post issue
K8S_MASTER_AWS_INSTANCE=()
K8S_MASTER_PRIVATE_IP=()
K8S_MASTER_PUBLIC_IP=()
K8S_MASTER_PUBLIC_DNS=()
K8S_MASTER_NODE_NAME=()

K8S_PUBLIC_AWS_INSTANCE=()
K8S_PUBLIC_PRIVATE_IP=()
K8S_PUBLIC_PUBLIC_IP=()
K8S_PUBLIC_PUBLIC_DNS=()
K8S_PUBLIC_NODE_NAME=()

K8S_WORKER_AWS_INSTANCE=()
K8S_WORKER_PRIVATE_IP=()
K8S_WORKER_PUBLIC_IP=()
K8S_WORKER_PUBLIC_DNS=()
K8S_WORKER_NODE_NAME=()
####

createnode() {
    local K8S_NODE_TYPE=$1
    local NODE_NUMBER=$2
    local AWS_INSTANCE_TYPE=$3
    local NODE_NAME=$K8S_NODE_NAME_PREFIX-$K8S_NODE_TYPE$NODE_NUMBER  # ex: k8s-m1  for master #1

    printf "CREATING INSTANCE FOR $NODE_NAME - "

    # Note the tags used below. By using ower and use-case you can find all your instances and volumes made by this script

    aws ec2 run-instances \
    --image-id $AWS_AMI \
    --count 1 \
    --instance-type $AWS_INSTANCE_TYPE \
    --security-group-ids $AWS_SECURITY_GROUP \
    --subnet-id $AWS_SUBNET \
    --key-name $AWS_KEY_PAIR \
    --associate-public-ip-address \
    --block-device-mappings file://node-ebs.json \
    --user-data file://user-data.sh \
    --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value='"$NODE_NAME"'},{Key=owner,Value='"$MY_EMAIL"'}, {Key=description,Value=My temporary K8s cluster}, {Key=terminationdate,Value=DO NOT DELETE without checking with owner}, {Key=use-case,Value=k8s-builder}]' 'ResourceType=volume,Tags=[{Key=owner,Value='"$MY_EMAIL"'}, {Key=description,Value=My temporary K8s cluster}, {Key=terminationdate,Value=DO NOT DELETE without checking with owner}, {Key=use-case,Value=k8s-builder}]' \
    > $NODE_NAME.first.json

    # Get the AWS instance ID
    local INSTANCE_ID=$(jq '.Instances[].InstanceId' -r $NODE_NAME.first.json)

    printf "INSTANCE ID: $INSTANCE_ID"

    # Save the instance_id in an array
    case $K8S_NODE_TYPE in
        m)      # masters
            K8S_MASTER_AWS_INSTANCE[NODE_NUMBER]=$INSTANCE_ID
            K8S_MASTER_NODE_NAME[NODE_NUMBER]=$NODE_NAME
            echo " A K8S MASTER NODE"
            ;;
        public) # public nodes
            K8S_PUBLIC_AWS_INSTANCE[NODE_NUMBER]=$INSTANCE_ID
            K8S_PUBLIC_NODE_NAME[NODE_NUMBER]=$NODE_NAME
            echo " A K8S PUBLIC NODE"
            ;;
        w)      # worker nodes
            K8S_WORKER_AWS_INSTANCE[NODE_NUMBER]=$INSTANCE_ID
            K8S_WORKER_NODE_NAME[NODE_NUMBER]=$NODE_NAME
            echo " A K8S WORKER NODE"
            ;;
    esac
}

#######################
###### BEGINNING ######
#######################

if ! [ -x "$(command -v jq)" ]; then
  echo "ABORTING: jq IS NOT INSTALLED"
  exit 1
fi

if ! [ -x "$(command -v aws)" ]; then
  echo "ABORTING: AWS CLI IS NOT INSTALLED"
  exit 1
fi


if [ -d ./inventory/mycluster ];
then
    echo
    echo "DIRECTORY ./inventory/mycluster ALREADY EXISTS, SO THIS IS NOT THE FRIST TIME THIS SCRIPT HAS BEEN RAN"
    echo "  IN THIS DIRECTORY. THEREFORE SKIPPING COPYING OF SAMPLE INVENTORY DIRECTORY TO MYCLUSTER DIRECTORY"
else
    echo
    echo "DIRECTORY ./inventory/mycluster DOES NOT EXIST, THIS IS THE FIRST RUN OF THIS SCRIPT"
    echo "COPYING ./inventory/sample TO ./inventory/mycluster PER KUBESPRAY REQUIREMENT"
    cp -rfp ./inventory/sample ./inventory/mycluster
fi

echo

# Create EBS json files for master and worker nodes
echo "[{\"DeviceName\": \"/dev/sda1\",\"Ebs\": {\"DeleteOnTermination\": true,\"VolumeSize\": $NODE_DISK_SIZE,\"VolumeType\": \"gp2\"}}]" > node-ebs.json

# node types must be m, public, or w   (master, public, worker)
#### MASTERS
for ((i=1; i<=$MASTER_NODE_COUNT; i++))
do
    createnode m $i $AWS_K8S_MASTER_INSTANCE_TYPE
done

### PUBLIC NODE(S)
for ((i=1; i<=$PUBLIC_NODE_COUNT; i++))
do
    createnode public $i $AWS_K8S_WORKER_INSTANCE_TYPE
done

### WORKER / PRIVATE NODES
for ((i=1; i<=$WORKER_NODE_COUNT; i++))
do
    createnode w $i $AWS_K8S_WORKER_INSTANCE_TYPE
done

### DONE CREATING INSTANCES

echo
echo
echo SLEEPING FOR 8 SECONDS TO WAIT FOR AWS TO ASSIGN PUBLIC RESOURCES TO ALL INSTANCES
echo "    SUCH AS PUBLIC IP ADDRESSES, BEFORE QUERYING THE API"
echo
sleep 8

#### Create pause, resume, delete, and setup-kubectl scripts
    rm -f stop-cluster.sh  > /dev/null 2>&1
    rm -f terminate-cluster.sh > /dev/null 2>&1
    rm -f start-cluster.sh  > /dev/null 2>&1
    rm -f cluster-control-template.sh > /dev/null 2>&1
    rm -f setup-kubectl.sh > /dev/null 2>&1             # This script just sets the KUBECONFIG env var

    echo "#!/bin/bash" > cluster-control-template.sh
    echo "# This tests if the script was ran with source, which is needed since" >> cluster-control-template.sh
    echo "#  it needs to add or remove an exported environment variable" >> cluster-control-template.sh
    echo "# https://stackoverflow.com/questions/2683279/how-to-detect-if-a-script-is-being-sourced" >> cluster-control-template.sh
    echo "(return 0 2>/dev/null) && sourced=1 || sourced=0" >> cluster-control-template.sh
    echo 'if [[ $sourced -eq 0 ]];' >> cluster-control-template.sh
    echo "then" >> cluster-control-template.sh
    echo "    echo ABORTING: THIS SCRIPT MUST BE RAN VIA SOURCE" >> cluster-control-template.sh
    echo "    echo BECAUSE IT MODIFIES ENVIRONMENT VARIABLES" >> cluster-control-template.sh
    echo "    echo RERUN THE SCRIPT PREFIXED WITH THE SOURCE COMMAND" >> cluster-control-template.sh
    echo "    exit 0" >> cluster-control-template.sh
    echo "fi" >> cluster-control-template.sh
    echo "echo" >> cluster-control-template.sh

    cp cluster-control-template.sh stop-cluster.sh
    cp cluster-control-template.sh terminate-cluster.sh
    cp cluster-control-template.sh start-cluster.sh
    cp cluster-control-template.sh setup-kubectl.sh     
    rm -f cluster-control-template.sh > /dev/null 2>&1
    chmod +x stop-cluster.sh
    chmod +x terminate-cluster.sh
    chmod +x start-cluster.sh
    chmod +x setup-kubectl.sh

    echo 'echo "UNSETTING KUBECONFIG VARIABLE"' >> stop-cluster.sh
    echo "unset KUBECONFIG" >> stop-cluster.sh
    echo 'echo "UNSETTING KUBECONFIG VARIABLE"' >> terminate-cluster.sh
    echo "unset KUBECONFIG" >> terminate-cluster.sh
    # for start-cluster.sh this ^^^ is differently, later
#### DONE CREATING CONTROL SCRIPTS

# The processing of the masters, public, and worker nodes are their own loops since they might diverge in the future

# PROCESS MASTERS
for ((i=1; i<=$MASTER_NODE_COUNT; i++))
do
    # Required for Calico in AWS
    aws ec2 modify-instance-attribute --instance-id ${K8S_MASTER_AWS_INSTANCE[i]} --source-dest-check "{\"Value\": false}"

    # Make updated json files that now have AWS public attributes such as public IP
    rm -f ${K8S_MASTER_NODE_NAME[i]}.second.json > /dev/null 2>&1
    aws ec2 describe-instances --instance-id ${K8S_MASTER_AWS_INSTANCE[i]} > ${K8S_MASTER_NODE_NAME[i]}.second.json

    echo "INSTANCE" ${K8S_MASTER_AWS_INSTANCE[i]} "DETAILS:"
    echo "    A K8S MASTER NODE"
    echo "    NODE NAME:      " ${K8S_MASTER_NODE_NAME[i]}

    K8S_MASTER_PUBLIC_IP[i]=$(jq '.Reservations[].Instances[].PublicIpAddress' -r ${K8S_MASTER_NODE_NAME[i]}.second.json)

    # Master #1 is sepecial because it has an Elastic IP
    if [[ $i -eq 1 ]]; 
    then
        aws ec2 allocate-address --domain vpc > master1-elastic-ip.json
        AWS_MASTER1_ELASTIC_IP=$(jq '.PublicIp' -r master1-elastic-ip.json)
        # NOT USED AWS_MASTER1_ELASTIC_IP_ALLOCATION=$(jq '.AllocationId' -r master1-elastic-ip.json)
        aws ec2 associate-address --public-ip $AWS_MASTER1_ELASTIC_IP --instance-id ${K8S_MASTER_AWS_INSTANCE[i]} > ${K8S_MASTER_NODE_NAME[i]}-elastic-ip-association.json

        # Since an elastic IP has been assigned the public_ip has changed
        echo "    ELASTIC IP:     " $AWS_MASTER1_ELASTIC_IP
        # Overwrite what was already set, with Elastic IP
        K8S_MASTER_PUBLIC_IP[i]=$AWS_MASTER1_ELASTIC_IP
    else
        K8S_MASTER_PUBLIC_IP[i]=$(jq '.Reservations[].Instances[].PublicIpAddress' -r ${K8S_MASTER_NODE_NAME[i]}.second.json)
    fi

    K8S_MASTER_PRIVATE_IP[i]=$(jq '.Reservations[].Instances[].PrivateIpAddress' -r ${K8S_MASTER_NODE_NAME[i]}.second.json)
    echo "    PRIVATE IP:     " ${K8S_MASTER_PRIVATE_IP[i]}

    echo "    PUBLIC IP:      " ${K8S_MASTER_PUBLIC_IP[i]}

    K8S_MASTER_PUBLIC_DNS[i]=$(jq '.Reservations[].Instances[].PublicDnsName' -r ${K8S_MASTER_NODE_NAME[i]}.second.json)
    echo "    PUBLIC DNS:     " ${K8S_MASTER_PUBLIC_DNS[i]}

    echo

    # pause, resume, delete scripts
    echo "# Master" ${K8S_MASTER_NODE_NAME[i]} "PRIVATE IP:" ${K8S_MASTER_PRIVATE_IP[i]} >> stop-cluster.sh
    echo "# Master" ${K8S_MASTER_NODE_NAME[i]} "PRIVATE IP:" ${K8S_MASTER_PRIVATE_IP[i]} >> terminate-cluster.sh
    echo "# Master" ${K8S_MASTER_NODE_NAME[i]} "PRIVATE IP:" ${K8S_MASTER_PRIVATE_IP[i]} >> start-cluster.sh
    echo "aws ec2 stop-instances --instance-id" ${K8S_MASTER_AWS_INSTANCE[i]} >> stop-cluster.sh
    echo "aws ec2 terminate-instances --instance-id" ${K8S_MASTER_AWS_INSTANCE[i]} >> terminate-cluster.sh
    echo "aws ec2 start-instances --instance-id" ${K8S_MASTER_AWS_INSTANCE[i]} >> start-cluster.sh
    # For Master 1 only since it has an Elastic IP
    echo "aws ec2 disassociate-address --public-ip $AWS_MASTER1_ELASTIC_IP" >> terminate-cluster.sh
    echo "aws ec2 release-address --public-ip $AWS_MASTER1_ELASTIC_IP" >> terminate-cluster.sh
done

# PROCESS PUBLIC NODE(S)
for ((i=1; i<=$PUBLIC_NODE_COUNT; i++))
do
    # Required for Calico in AWS
    aws ec2 modify-instance-attribute --instance-id ${K8S_PUBLIC_AWS_INSTANCE[i]} --source-dest-check "{\"Value\": false}"

    # Make updated json files that now have AWS public attributes such as public IP
    rm -f ${K8S_PUBLIC_NODE_NAME[i]}.second.json > /dev/null 2>&1
    aws ec2 describe-instances --instance-id ${K8S_PUBLIC_AWS_INSTANCE[i]} > ${K8S_PUBLIC_NODE_NAME[i]}.second.json

    echo "INSTANCE" ${K8S_PUBLIC_AWS_INSTANCE[i]} "DETAILS:"
    echo "    A K8S PUBLIC NODE"
    echo "    NODE NAME:      " ${K8S_PUBLIC_NODE_NAME[i]}

    # Public #1 is sepecial because it has an Elastic IP
    if [[ $i -eq 1 ]];
    then
        aws ec2 allocate-address --domain vpc > public1-elastic-ip.json
        AWS_PUBLIC1_ELASTIC_IP=$(jq '.PublicIp' -r public1-elastic-ip.json)
        # NOT USED AWS_PUBLIC1_ELASTIC_IP_ALLOCATION=$(jq '.AllocationId' -r public1-elastic-ip.json)
        aws ec2 associate-address --public-ip $AWS_PUBLIC1_ELASTIC_IP --instance-id ${K8S_PUBLIC_AWS_INSTANCE[i]} > ${K8S_PUBLIC_NODE_NAME[i]}-elastic-ip-association.json
        # Since an elastic IP has been assigned the public_ip has changed
        echo "    ELASTIC IP:     " $AWS_PUBLIC1_ELASTIC_IP
        K8S_PUBLIC_PUBLIC_IP[i]=$AWS_PUBLIC1_ELASTIC_IP
    else
        K8S_PUBLIC_PUBLIC_IP[i]=$(jq '.Reservations[].Instances[].PublicIpAddress' -r ${K8S_PUBLIC_NODE_NAME[i]}.second.json)
    fi

    K8S_PUBLIC_PRIVATE_IP[i]=$(jq '.Reservations[].Instances[].PrivateIpAddress' -r ${K8S_PUBLIC_NODE_NAME[i]}.second.json)
    echo "    PRIVATE IP:     " ${K8S_PUBLIC_PRIVATE_IP[i]}

    echo "    PUBLIC IP:      " ${K8S_PUBLIC_PUBLIC_IP[i]}

    K8S_PUBLIC_PUBLIC_DNS[i]=$(jq '.Reservations[].Instances[].PublicDnsName' -r ${K8S_PUBLIC_NODE_NAME[i]}.second.json)
    echo "    PUBLIC DNS:     " ${K8S_PUBLIC_PUBLIC_DNS[i]}

    echo

    # pause, resume, delete scripts
    echo "# Public" ${K8S_PUBLIC_NODE_NAME[i]} "PRIVATE IP: "${K8S_PUBLIC_PRIVATE_IP[i]} >> stop-cluster.sh
    echo "# Public" ${K8S_PUBLIC_NODE_NAME[i]} "PRIVATE IP:" ${K8S_PUBLIC_PRIVATE_IP[i]} >> terminate-cluster.sh
    echo "# Public" ${K8S_PUBLIC_NODE_NAME[i]} "PRIVATE IP:" ${K8S_PUBLIC_PRIVATE_IP[i]} >> start-cluster.sh
    echo "aws ec2 stop-instances --instance-id" ${K8S_PUBLIC_AWS_INSTANCE[i]} >> stop-cluster.sh
    echo "aws ec2 terminate-instances --instance-id" ${K8S_PUBLIC_AWS_INSTANCE[i]} >> terminate-cluster.sh
    echo "aws ec2 start-instances --instance-id" ${K8S_PUBLIC_AWS_INSTANCE[i]} >> start-cluster.sh
    # For Public 1 only since it has an Elastic IP, and there should only be 1 public node
    echo "aws ec2 disassociate-address --public-ip $AWS_PUBLIC1_ELASTIC_IP" >> terminate-cluster.sh
    echo "aws ec2 release-address --public-ip $AWS_PUBLIC1_ELASTIC_IP" >> terminate-cluster.sh
done

# PROCESS WORKER / PRIVATE NODES
for ((i=1; i<=$WORKER_NODE_COUNT; i++))
do
    # Required for Calico in AWS
    aws ec2 modify-instance-attribute --instance-id ${K8S_WORKER_AWS_INSTANCE[i]} --source-dest-check "{\"Value\": false}"

    # Make updated json files that now have AWS public attributes such as public IP
    rm -f ${K8S_WORKER_NODE_NAME[i]}.second.json > /dev/null 2>&1
    aws ec2 describe-instances --instance-id ${K8S_WORKER_AWS_INSTANCE[i]} > ${K8S_WORKER_NODE_NAME[i]}.second.json

    echo "INSTANCE" ${K8S_WORKER_AWS_INSTANCE[i]} "DETAILS:"
    echo "    A K8S WORKER NODE"
    echo "    NODE NAME:      " ${K8S_WORKER_NODE_NAME[i]}

    # These are set here instead of createnode() because it takes time for AWS to assign public resources

    K8S_WORKER_PRIVATE_IP[i]=$(jq '.Reservations[].Instances[].PrivateIpAddress' -r ${K8S_WORKER_NODE_NAME[i]}.second.json)
    echo "    PRIVATE IP:     " ${K8S_WORKER_PRIVATE_IP[i]}

    K8S_WORKER_PUBLIC_IP[i]=$(jq '.Reservations[].Instances[].PublicIpAddress' -r ${K8S_WORKER_NODE_NAME[i]}.second.json)
    echo "    PUBLIC IP:      " ${K8S_WORKER_PUBLIC_IP[i]}

    K8S_WORKER_PUBLIC_DNS[i]=$(jq '.Reservations[].Instances[].PublicDnsName' -r ${K8S_WORKER_NODE_NAME[i]}.second.json)
    echo "    PUBLIC DNS:     " ${K8S_WORKER_PUBLIC_DNS[i]}

    echo

    # pause, resume, delete scripts
    echo "# Worker" ${K8S_WORKER_NODE_NAME[i]} "PRIVATE IP: "${K8S_WORKER_PRIVATE_IP[i]} >> stop-cluster.sh
    echo "# Worker" ${K8S_WORKER_NODE_NAME[i]} "PRIVATE IP:" ${K8S_WORKER_PRIVATE_IP[i]} >> terminate-cluster.sh
    echo "# Worker" ${K8S_WORKER_NODE_NAME[i]} "PRIVATE IP:" ${K8S_WORKER_PRIVATE_IP[i]} >> start-cluster.sh
    echo "aws ec2 stop-instances --instance-id" ${K8S_WORKER_AWS_INSTANCE[i]} >> stop-cluster.sh
    echo "aws ec2 terminate-instances --instance-id" ${K8S_WORKER_AWS_INSTANCE[i]} >> terminate-cluster.sh
    echo "aws ec2 start-instances --instance-id" ${K8S_WORKER_AWS_INSTANCE[i]} >> start-cluster.sh
done

echo "ALL NODES WERE CREATED IN VPC:" $AWS_VPC

#### DONE PROCESSING ALL NODES

#### CREATE KUBESPRAY'S HOSTS.INI FILE (FOR ANSIBLE)
# Options are documented here: https://github.com/kubernetes-sigs/kubespray/blob/master/docs/vars.md

# Build header
   echo
   echo "CREATING KUBESPRAY'S hosts.ini FILE"
   echo
   rm -f ./inventory/mycluster/hosts.ini > /dev/null 2>&1
   echo "# This is kubespray's inventory file, used by ansible" >> ./inventory/mycluster/hosts.ini
   echo >> ./inventory/mycluster/hosts.ini
   echo "# These options are per https://github.com/kubernetes-sigs/kubespray/blob/master/docs/vars.md" >> ./inventory/mycluster/hosts.ini
   echo "[all:vars]" >> ./inventory/mycluster/hosts.ini
   echo "ansible_user=$SSH_USER_LOGIN" >> ./inventory/mycluster/hosts.ini
   echo "ansible_ssh_private_key_file=$AWS_SSH_KEY" >> ./inventory/mycluster/hosts.ini
   echo "ansible_ssh_extra_args=\"-o StrictHostKeyChecking=no\"" >> ./inventory/mycluster/hosts.ini
   echo "kube_version=$K8S_VERSION" >> ./inventory/mycluster/hosts.ini
   echo "kube_feature_gates=$K8S_FEATURE_GATES" >> ./inventory/mycluster/hosts.ini
   echo "kube_network_plugin=$K8S_CNI_PLUGIN" >> ./inventory/mycluster/hosts.ini
   echo "kube_pods_subnet=$K8S_PODS_SUBNET" >> ./inventory/mycluster/hosts.ini
   echo "kube_network_node_prefix=$K8S_KUBE_NETWORK_PREFIX" >> ./inventory/mycluster/hosts.ini
   echo "kube_service_addresses=$K8S_KUBE_SERVICE_ADDRESSES" >> ./inventory/mycluster/hosts.ini
   echo "kube_proxy_mode=$K8S_KUBE_PROXY_MODE" >> ./inventory/mycluster/hosts.ini
   echo "cluster_name=$K8S_CLUSTER_NAME" >> ./inventory/mycluster/hosts.ini
   echo "container_manager=$K8S_CONTAINER_MANAGER" >> ./inventory/mycluster/hosts.ini
   echo "k8s_image_pull_policy=$K8S_CONTAINER_IMAGE_PULL_POLICY" >> ./inventory/mycluster/hosts.ini
   echo "kubernetes_audit=$K8S_AUDIT" >> ./inventory/mycluster/hosts.ini
   echo "podsecuritypolicy_enabled=$K8S_POD_SECURITY_POLICY" >> ./inventory/mycluster/hosts.ini
   echo "authorization_modes=$K8S_AUTHORIZATION_MODES" >> ./inventory/mycluster/hosts.ini
   # A K8s option to allow the kubelet to load kernel modules, sometimes needed for storage drivers and such.
   echo "kubelet_load_modules=true" >> ./inventory/mycluster/hosts.ini
   echo "# Allows kubectl's TLS to work with the public IPs of Master 1 and Public node 1" >> ./inventory/mycluster/hosts.ini
   echo "supplementary_addresses_in_ssl_keys='${K8S_MASTER_PUBLIC_IP[1]}','${K8S_PUBLIC_PUBLIC_IP[1]}'" >> ./inventory/mycluster/hosts.ini
   echo "# This instructs kubespray to download kubectl's config file" >> ./inventory/mycluster/hosts.ini
   echo "#  it's saved to ./inventory/mycluster/artifacts/admin.conf" >> ./inventory/mycluster/hosts.ini
   echo "#  the script changes the private IP of the master to its public IP, and saves it as mycluster.conf" >> ./inventory/mycluster/hosts.ini
   echo "kubeconfig_localhost=true" >> ./inventory/mycluster/hosts.ini
   echo "" >> ./inventory/mycluster/hosts.ini

   # OTHER OPTIONS PER https://github.com/kubernetes-sigs/kubespray/blob/master/docs/vars.md
   # apiserver_custom_flags
        #audit-dynamic-configuration
        #--runtime-config=auditregistration.k8s.io/v1alpha1=true
   # controller_mgr_custom_flags
   # scheduler_custom_flags
   # kubelet_custom_flags
   # kubelet_node_custom_flags

   echo "[bastion]" >> ./inventory/mycluster/hosts.ini
   echo "# No bastion hosts in use, using workstation" >> ./inventory/mycluster/hosts.ini
   echo "" >> ./inventory/mycluster/hosts.ini
   echo "[calico-rr]" >> ./inventory/mycluster/hosts.ini
   echo "# Placed here just to avoid a warning message" >>  ./inventory/mycluster/hosts.ini
   echo "" >> ./inventory/mycluster/hosts.ini
# Done building header

# Build [all] section
  echo "[all]" >> ./inventory/mycluster/hosts.ini

  for ((i=1; i<=$MASTER_NODE_COUNT; i++))
  do
      echo ${K8S_MASTER_NODE_NAME[i]} "ansible_host="${K8S_MASTER_PUBLIC_IP[i]} "ip="${K8S_MASTER_PRIVATE_IP[i]} "etcd_member_name="${K8S_MASTER_NODE_NAME[i]} " # A MASTER NODE, INSTANCE ID:" ${K8S_MASTER_AWS_INSTANCE[i]} >> ./inventory/mycluster/hosts.ini
  done

  for ((i=1; i<=$PUBLIC_NODE_COUNT; i++))
  do
      echo ${K8S_PUBLIC_NODE_NAME[i]} "ansible_host="${K8S_PUBLIC_PUBLIC_IP[i]} "ip="${K8S_PUBLIC_PRIVATE_IP[i]} "  # A PUBLIC NODE, INSTANCE ID:" ${K8S_PUBLIC_AWS_INSTANCE[i]}  >> ./inventory/mycluster/hosts.ini
  done

  for ((i=1; i<=$WORKER_NODE_COUNT; i++))
  do
      echo ${K8S_WORKER_NODE_NAME[i]} "ansible_host="${K8S_WORKER_PUBLIC_IP[i]} "ip="${K8S_WORKER_PRIVATE_IP[i]} "  # A WORKER NODE, INSTANCE ID:" ${K8S_WORKER_AWS_INSTANCE[i]}>> ./inventory/mycluster/hosts.ini
  done
  echo "" >> ./inventory/mycluster/hosts.ini
# Finished building [all] section

# Build [kube-master] section
  echo "[kube-master]" >> ./inventory/mycluster/hosts.ini
  for ((i=1; i<=$MASTER_NODE_COUNT; i++))
  do
      echo ${K8S_MASTER_NODE_NAME[i]} >> ./inventory/mycluster/hosts.ini
  done
  echo "" >> ./inventory/mycluster/hosts.ini
# Finished building [kube-master] section

# Build [etcd] section
  echo "[etcd]" >> ./inventory/mycluster/hosts.ini
  for ((i=1; i<=$MASTER_NODE_COUNT; i++))
  do
      echo ${K8S_MASTER_NODE_NAME[i]} >> ./inventory/mycluster/hosts.ini
  done
  echo "" >> ./inventory/mycluster/hosts.ini
# Finished building [etcd] section

# Build [kube-node] section, the worker nodes
  echo "[kube-node]" >> ./inventory/mycluster/hosts.ini
  for ((i=1; i<=$WORKER_NODE_COUNT; i++))
  do
      echo ${K8S_WORKER_NODE_NAME[i]} >> ./inventory/mycluster/hosts.ini
  done

  # A public node is still a worker node
  for ((i=1; i<=$PUBLIC_NODE_COUNT; i++))
  do
      echo ${K8S_PUBLIC_NODE_NAME[i]} >> ./inventory/mycluster/hosts.ini
  done
  echo "" >> ./inventory/mycluster/hosts.ini
# Finished building [kube-node] section

# Build [k8s-cluster:children] section
  echo "[k8s-cluster:children]" >> ./inventory/mycluster/hosts.ini
  echo "kube-master" >> ./inventory/mycluster/hosts.ini
  echo "kube-node" >> ./inventory/mycluster/hosts.ini
  echo "" >> ./inventory/mycluster/hosts.ini
# Finished building [k8s-cluster:children] section

echo "CREATED ./inventory/mycluster/hosts.ini FOR KUBESPRAY"
echo "    LINKING ./hosts.ini TO IT FOR EASIER ACCESS"
rm -f hosts.ini > /dev/null 2>&1
ln -s ./inventory/mycluster/hosts.ini hosts.ini

echo
echo "SLEEPING FOR 5 MIN 30 SEC BEFORE RUNNING KUBESPRAY, TO ALLOW INSTANCES TO BOOT, RUN user-data.sh SCRIPT, AND REBOOT"
echo
sleep 330

# BEGIN KUBESPRAY
echo
echo "LAUNCHING KUBESPRAY"
echo
sleep 2

ansible-playbook -i inventory/mycluster/hosts.ini --become --become-user=root cluster.yml

echo
echo
echo
#TODO: what to look for
echo "DONE RUNNING KUBESPRAY, CHECK THAT IT WAS SUCCESSFUL"
echo "  Look above in the play recap section of kubespray at each node"
echo "  and ensure there were no unreachable or faileds"
echo
echo "SUBSTITUTING MASTER 1'S PRIVATE IP IN THE KUBECTL CONFIG FILE"
echo "  SAVING AS ./inventory/mycluster/artifacts/mycluster.conf"
echo

# BEGIN PROCESSING KUBECONFIG FILE

sed -e "s|${K8S_MASTER_PRIVATE_IP[1]}|${K8S_MASTER_PUBLIC_IP[1]}|g" ./inventory/mycluster/artifacts/admin.conf > ./inventory/mycluster/artifacts/mycluster.conf

echo "EXPORTING KUBECONFIG VARIABLE AS" $(pwd)"/inventory/mycluster/artifacts/mycluster.conf"
echo "   THIS MEANS YOUR EXISTING ~/.kube/config FILE WILL BE IGNORED"
export KUBECONFIG=$(pwd)"/inventory/mycluster/artifacts/mycluster.conf"

# For when the workstation is rebooted
echo 'echo "EXPORTING KUBECONFIG VARIABLE"' >> start-cluster.sh
echo 'export KUBECONFIG='$KUBECONFIG >> start-cluster.sh

# For when a new terminal window is created and the KUBECONFIG env var needs to be set
echo 'echo "EXPORTING KUBECONFIG VARIABLE"' >> setup-kubectl.sh
echo 'export KUBECONFIG='$KUBECONFIG >> start-cluster.sh >> setup-kubectl.sh

# DONE PROCESSING KUBECONFIG FILE

echo
echo "RUNNING kubectl get nodes"
echo "NOTE: UNLESS YOU RAN THIS SCRIPT VIA THE SOURCE COMMAND, YOU STILL NEED TO RUN"
echo "   source ./setup-kubectl.sh TO SET THE KUBECONFIG ENVIRONMENT VARIABLE"
echo
kubectl get nodes

echo
echo "LABELING k8s-public1 NODE WITH public-node=yes"
kubectl label node k8s-public1 public-node=yes
echo

echo
echo "UNTAINTING MASTER NODES SO THEY CAN ACCEPT PODS"
kubectl taint nodes --all node-role.kubernetes.io/master-
echo

echo
echo
echo "DONE! NOW RUN source ./setup-kubectl.sh"
echo

