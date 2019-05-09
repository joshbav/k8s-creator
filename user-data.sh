#!/bin/bash

# TODO: %wheel  ALL=(ALL)       NOPASSWD: ALL

# K8s 1.13 only has 18.06 as a validated version, not newer
# kubespray installs 18.06.2 instead of .3, so using it
#### COMMENTED OUT SINCE WE'LL LET KUBESPRAY INSTALL DOCKER
#DOCKER_PACKAGE=docker-ce-18.06.2.ce-3.el7  #docker-ce-18.09.2-3.el7

echo
echo CHANGING MACHINE-ID SINCE THEY ARE ALL THE SAME
echo   WHEN USING AMIs, AND IT SHOWS UP IN K8S
echo
sudo rm -f /etc/machine-id
sudo /usr/bin/systemd-firstboot --setup-machine-id

echo
echo DISABLING SELINUX
echo
# For a lab Kubernetes envioronment it makes things simpler
sudo sed -i s/SELINUX=enforcing/SELINUX=permissive/g /etc/selinux/config
# Disable it right now, just in case it interferes with other commands
sudo setenforce 0

echo
echo UINSTALLING POSTFIX
echo
# Why is it even installed by default in CentOS?
sudo yum remove -y postfix
echo

echo
echo "DISABLING FIREWALLD (ignore service not found errors)"
echo
# Required for Kubernetes
# TODO: check if it exists then disable
sudo systemctl stop firewalld
sudo systemctl disable firewalld

echo
echo ENABLING IP FORWARDING
echo
# Required for Kubernetes
# TODO: check if it already exists, if so use sed
sudo bash -c "echo 1 > /proc/sys/net/ipv4/ip_forward"
echo "   Step 2"
sudo bash -c "echo \"net.ipv4.ip_forward=1\" >> /etc/sysctl.conf"

echo
echo SETTING USER AND SYSTEM-LEVEL MAX OPEN FILES TO 500,000
echo
# for elastic search
sudo bash -c "echo 500000 > /proc/sys/fs/file-max"
sudo bash -c "echo \"* hard nofile 500000\" >> /etc/security/limits.conf"
sudo bash -c "echo \"* soft nofile 500000\" >> /etc/security/limits.conf"
echo "   Step 2"
sudo bash -c "echo \"fs.file-max = 500000\" >> /etc/sysctl.conf"
# also for elastic search
sudo bash -c "echo \"vm.max_map_count = 262144\" >> /etc/sysctl.conf"

echo
echo "DISABLING SWAP FILE USAGE (K8S REQUIREMENT)"
echo
# Required for Kubernetes
sudo swapoff -a -v

echo
echo SETTING SOME ENV VARIABLES FOR ALL USERS
echo
sudo bash -c "sudo echo \"LANG=en_US.UTF-8\" >> /etc/environment"
export LANG en_US.UTF-8
sudo bash -c "sudo echo \"LANGUAGE=en_US:en\" >> /etc/environment"
export LANGUAGE en_US:en
bash -c "sudo echo \"LC_ALL=en_US.UTF-8\" >> /etc/environment"
export LC_ALL en_US.UTF-8
bash -c "sudo echo \"TERM=xterm-256color\" >> /etc/environment"
export xterm-256color

echo
echo ADDING ALIASES TO /ETC/BASHRC
echo
# These are just my personal preferences
sudo bash -c "echo \"alias s='sudo systemctl' j='journalctl' k='kubectl' kdump='kubectl get all --all-namespaces'\" >>/etc/bashrc"
# Note kdump won't show config maps, secrets, and ingress objects TODO: how to add?
echo
# Note K8s kubectl 1.14 uses -A for all name spaces

echo
echo YUM INSTALL OF MY MAIN PACKAGES
echo
sudo yum install -y epel-release yum-utils deltarpm
sudo yum makecache -y
sudo yum update --security -y
# sudo yum update -y
# Much of this is in a base CentOS & RHEL install, but not necessarily in a container,
#  although I wouldn't necessarily install all of it in a container.
sudo yum install -y ansible autofs bash-completion binutils bind-utils bzip2 ca-certificates centos-release coreutils cpio curl device-mapper-persistent-data diffutils ethtool expect findutils ftp gawk grep gettext git gzip hardlink hostname iftop info iproute ipset iputils jq less lua lvm2 make man nano net-tools nfs-utils nload nmap openssh-clients passwd procps-ng rsync sed sudo sysstat tar tcpdump tcping traceroute unzip util-linux vim wget which xz zip
# removed kubernetes-cli

# FETCH MY NTP CONFIG
sudo curl -o /etc/chrony.conf -sSLO https://raw.githubusercontent.com/joshbav/k8s-creator/master/chrony.conf
# Not going to restart chrony since a reboot will happen at the end
sudo timedatectl set-timezone UTC

echo
echo INSTALLING KUBECTL
echo
sudo bash -c 'cat <<EOF > /etc/yum.repos.d/kubernetes.repo
[kubernetes]
name=Kubernetes
baseurl=https://packages.cloud.google.com/yum/repos/kubernetes-el7-x86_64
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=https://packages.cloud.google.com/yum/doc/yum-key.gpg https://packages.cloud.google.com/yum/doc/rpm-package-key.gpg
EOF'
sudo yum install -y kubectl
# autocompletion per https://kubernetes.io/docs/tasks/tools/install-kubectl/#enabling-shell-autocompletion
sudo bash -c 'echo "source <(kubectl completion bash)" >> /etc/bashrc'
echo

echo
echo INSTALING .VIMRC FILE TO SET VI DEFAULTS
echo
sudo curl -o /root/.vimrc -sSLO https://raw.githubusercontent.com/joshbav/k8s-creator/master/vimrc
sudo cp /root/.vimrc ~
echo

# Fetch systemd unit that Installs kernel headers
sudo curl -o /etc/systemd/system/install-kernel-headers.service -sSLO https://raw.githubusercontent.com/joshbav/k8s-creator/master/install-kernel-headers.rhel.service

# Fetch systemd units that shuts down instance after specified time
sudo curl -o /etc/systemd/system/shutdown-timer.timer -sSLO https://raw.githubusercontent.com/joshbav/k8s-creator/master/shutdown-timer.timer
sudo curl -o /etc/systemd/system/shutdown-via-timer.service -sSLO https://raw.githubusercontent.com/joshbav/k8s-creator/master/shutdown-via-timer.service

sudo systemctl daemon-reload
sudo systemctl enable shutdown-timer.timer
# going to reboot, no need sudo systemctl start shutdown-timer.timer
# going to reboot, no need sudo systemctl status shutdown-timer.timer
sudo systemctl enable install-kernel-headers

echo
echo INSTALLING DOCKER
echo
#### COMMENTED OUT SINCE WE'LL LET KUBESPRAY INSTALL DOCKER
# Required by Kubernetes
#sudo yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
#sudo yum install -y $DOCKER_PACKAGE
#sudo systemctl enable docker
#sudo systemctl start docker
sudo usermod -aG docker centos
#sudo docker run hello-world
#sudo docker version

# Running last so no change of the yum dbase being locked
# going to reboot, no need sudo systemctl start install-kernel-headers

sudo reboot now
