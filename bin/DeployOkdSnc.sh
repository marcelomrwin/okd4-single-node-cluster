#!/bin/bash

set -x

# This script will set up the infrastructure to deploy a single node OKD 4.X cluster
CPU="4"
MEMORY="16384"
DISK="200"
FCOS_VER=32.20200601.3.0
FCOS_STREAM=stable

for i in "$@"
do
case $i in
    -c=*|--cpu=*)
    CPU="${i#*=}"
    shift
    ;;
    -m=*|--memory=*)
    MEMORY="${i#*=}"
    shift
    ;;
    -d=*|--disk=*)
    DISK="${i#*=}"
    shift
    ;;
    *)
          # unknown option
    ;;
esac
done

function configOkdNode() {
    
  local ip_addr=${1}
  local host_name=${2}
  local mac=${3}
  local role=${4}

cat << EOF > ${OKD4_SNC_PATH}/ignition/${role}.yml
variant: fcos
version: 1.1.0
ignition:
  config:
    merge:
      - local: ${role}.ign
storage:
  files:
    - path: /etc/zincati/config.d/90-disable-feature.toml
      mode: 0644
      contents:
        inline: |
          [updates]
          enabled = false
    - path: /etc/systemd/network/25-nic0.link
      mode: 0644
      contents:
        inline: |
          [Match]
          MACAddress=${mac}
          [Link]
          Name=nic0
    - path: /etc/NetworkManager/system-connections/nic0.nmconnection
      mode: 0600
      overwrite: true
      contents:
        inline: |
          [connection]
          type=ethernet
          interface-name=nic0

          [ethernet]
          mac-address=${mac}

          [ipv4]
          method=manual
          addresses=${ip_addr}/${SNC_NETMASK}
          gateway=${SNC_GATEWAY}
          dns=${SNC_NAMESERVER}
          dns-search=${SNC_DOMAIN}
    - path: /etc/hostname
      mode: 0420
      overwrite: true
      contents:
        inline: |
          ${host_name}
EOF

  cat ${OKD4_SNC_PATH}/ignition/${role}.yml | fcct -d ${OKD4_SNC_PATH}/okd4-install-dir/ -o ${OKD4_SNC_PATH}/ignition/${role}.ign
  coreos-installer iso embed --config ${OKD4_SNC_PATH}/ignition/${role}.ign /tmp/snc-${role}.iso

}

# Generate MAC addresses for the master and bootstrap nodes:
BOOT_MAC=$(date +%s | md5sum | head -c 6 | sed -e 's/\([0-9A-Fa-f]\{2\}\)/\1:/g' -e 's/\(.*\):$/\1/' | sed -e 's/^/52:54:00:/')
sleep 1
MASTER_MAC=$(date +%s | md5sum | head -c 6 | sed -e 's/\([0-9A-Fa-f]\{2\}\)/\1:/g' -e 's/\(.*\):$/\1/' | sed -e 's/^/52:54:00:/')

# Get the IP addresses for the master and bootstrap nodes:
BOOT_IP=$(dig okd4-snc-bootstrap.${SNC_DOMAIN} +short)
MASTER_IP=$(dig okd4-snc-master.${SNC_DOMAIN} +short)

# Pull the OKD release tooling identified by ${OKD_REGISTRY}:${OKD_RELEASE}.  i.e. OKD_REGISTRY=registry.svc.ci.openshift.org/origin/release, OKD_RELEASE=4.4.0-0.okd-2020-03-03-170958
mkdir -p ${OKD4_SNC_PATH}/okd-release-tmp
cd ${OKD4_SNC_PATH}/okd-release-tmp
oc adm release extract --command='openshift-install' ${OKD_REGISTRY}:${OKD_RELEASE}
oc adm release extract --command='oc' ${OKD_REGISTRY}:${OKD_RELEASE}
mv -f openshift-install ~/bin
mv -f oc ~/bin
cd -
rm -rf ${OKD4_SNC_PATH}/okd-release-tmp

# Retreive the FCOS live ISO
curl -o ${OKD4_SNC_PATH}/fcos-iso/images/fcos.iso https://builds.coreos.fedoraproject.org/prod/streams/${FCOS_STREAM}/builds/${FCOS_VER}/x86_64/fedora-coreos-${FCOS_VER}-live.x86_64.iso
cp -f ${OKD4_SNC_PATH}/fcos-iso/images/fcos.iso /tmp/snc-master.iso
cp -f ${OKD4_SNC_PATH}/fcos-iso/images/fcos.iso /tmp/snc-bootstrap.iso

# Create the OKD ignition files
rm -rf ${OKD4_SNC_PATH}/okd4-install-dir
mkdir -p ${OKD4_SNC_PATH}/okd4-install-dir
cp ${OKD4_SNC_PATH}/install-config-snc.yaml ${OKD4_SNC_PATH}/okd4-install-dir/install-config.yaml
OKD_PREFIX=$(echo ${OKD_RELEASE} | cut -d"." -f1,2)
OKD_VER=$(echo ${OKD_RELEASE} | sed  "s|${OKD_PREFIX}.0-0.okd|${OKD_PREFIX}|g")
sed -i "s|%%OKD_VER%%|${OKD_VER}|g" ${OKD4_SNC_PATH}/okd4-install-dir/install-config.yaml
openshift-install --dir=${OKD4_SNC_PATH}/okd4-install-dir create ignition-configs

# Generate the FCOS ignition files for bootstrap and master:
mkdir -p ${OKD4_SNC_PATH}/ignition
configOkdNode ${BOOT_IP} "okd4-snc-bootstrap" ${BOOT_MAC} "bootstrap"
configOkdNode ${MASTER_IP} "okd4-snc-master" ${MASTER_MAC} "master"

# Create the Bootstrap Node VM
mkdir -p /VirtualMachines/okd4-snc-bootstrap
virt-install --name okd4-snc-bootstrap --memory 14336 --vcpus 2 --disk size=100,path=/VirtualMachines/okd4-snc-bootstrap/rootvol,bus=sata --cdrom /tmp/bootstrap.iso --network bridge=br0 --mac=${BOOT_MAC} --graphics none --noautoconsole

# Create the OKD Node VM
mkdir -p /VirtualMachines/okd4-snc-master
virt-install --name okd4-snc-master --memory ${MEMORY} --vcpus ${CPU} --disk size=${DISK},path=/VirtualMachines/okd4-snc-master/rootvol,bus=sata --cdrom /tmp/snc-master.iso --network bridge=br0 --mac=${MASTER_MAC} --graphics none --noautoconsole

