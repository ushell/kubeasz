#!/bin/bash
#--------------------------------------------------
# This script is used for: 
# 1. to download the scripts/binaries/images needed for installing a k8s cluster with kubeasz
# 2. to run kubeasz in a container (optional)
# @author:   gjmzj
# @usage:    ./ezdown
# @repo:     https://github.com/easzlab/kubeasz
# @ref:      https://github.com/kubeasz/dockerfiles
#--------------------------------------------------
set -o nounset
set -o errexit
#set -o xtrace

# default settings, can be overridden by cmd line options, see usage
DOCKER_VER=20.10.8
KUBEASZ_VER=3.1.1
K8S_BIN_VER=v1.22.2
EXT_BIN_VER=0.9.5
SYS_PKG_VER=0.4.1
HARBOR_VER=v2.1.3
REGISTRY_MIRROR=CN

# images needed by k8s cluster
calicoVer=v3.19.2
flannelVer=v0.14.0-amd64
dnsNodeCacheVer=1.17.0
corednsVer=1.8.4
dashboardVer=v2.3.1
dashboardMetricsScraperVer=v1.0.6
metricsVer=v0.5.0
pauseVer=3.5
nfsProvisionerVer=v4.0.1
export ciliumVer=v1.4.1
export kubeRouterVer=v0.3.1
export kubeOvnVer=v1.5.3
export promChartVer=12.10.6
export traefikChartVer=10.3.0

function usage() {
  echo -e "\033[33mUsage:\033[0m ezdown [options] [args]"
  cat <<EOF
  option: -{DdekSz}
    -C         stop&clean all local containers
    -D         download all into "$BASE"
    -P         download system packages for offline installing
    -R         download Registry(harbor) offline installer
    -S         start kubeasz in a container
    -d <ver>   set docker-ce version, default "$DOCKER_VER"
    -e <ver>   set kubeasz-ext-bin version, default "$EXT_BIN_VER"
    -k <ver>   set kubeasz-k8s-bin version, default "$K8S_BIN_VER"
    -m <str>   set docker registry mirrors, default "CN"(used in Mainland,China)
    -p <ver>   set kubeasz-sys-pkg version, default "$SYS_PKG_VER"
    -z <ver>   set kubeasz version, default "$KUBEASZ_VER"
EOF
}

function logger() {
  TIMESTAMP=$(date +'%Y-%m-%d %H:%M:%S')
  case "$1" in
    debug)
      echo -e "$TIMESTAMP \033[36mDEBUG\033[0m $2"
      ;;
    info)
      echo -e "$TIMESTAMP \033[32mINFO\033[0m $2"
      ;;
    warn)
      echo -e "$TIMESTAMP \033[33mWARN\033[0m $2"
      ;;
    error)
      echo -e "$TIMESTAMP \033[31mERROR\033[0m $2"
      ;;
    *)
      ;;
  esac
}

function download_docker() {
  if [[ "$REGISTRY_MIRROR" == CN ]];then
    DOCKER_URL="https://mirrors.tuna.tsinghua.edu.cn/docker-ce/linux/static/stable/x86_64/docker-${DOCKER_VER}.tgz"
  else
    DOCKER_URL="https://download.docker.com/linux/static/stable/x86_64/docker-${DOCKER_VER}.tgz"
  fi

  if [[ -f "$BASE/down/docker-${DOCKER_VER}.tgz" ]];then
    logger warn "docker binaries already existed"
  else
    logger info "downloading docker binaries, version $DOCKER_VER"
    if [[ -e /usr/bin/wget ]];then
      wget -c --no-check-certificate "$DOCKER_URL" || { logger error "downloading docker failed"; exit 1; }
    else
      curl -k -C- -O --retry 3 "$DOCKER_URL" || { logger error "downloading docker failed"; exit 1; }
    fi
    /bin/mv -f "./docker-$DOCKER_VER.tgz" "$BASE/down"
  fi

  tar zxf "$BASE/down/docker-$DOCKER_VER.tgz" -C "$BASE/down" && \
  /bin/cp -f "$BASE"/down/docker/* "$BASE/bin" && \
  /bin/mv -f "$BASE"/down/docker/* /opt/kube/bin && \
  ln -sf /opt/kube/bin/docker /bin/docker 
}

function install_docker() {
  # check if a container runtime is already installed
  systemctl status docker|grep Active|grep -q running && { logger warn "docker is already running."; return 0; }
 
  logger debug "generate docker service file"
  cat > /etc/systemd/system/docker.service << EOF
[Unit]
Description=Docker Application Container Engine
Documentation=http://docs.docker.io
[Service]
Environment="PATH=/opt/kube/bin:/bin:/sbin:/usr/bin:/usr/sbin"
ExecStartPre=/sbin/iptables -F
ExecStartPre=/sbin/iptables -X
ExecStartPre=/sbin/iptables -F -t nat
ExecStartPre=/sbin/iptables -X -t nat
ExecStartPre=/sbin/iptables -F -t raw
ExecStartPre=/sbin/iptables -X -t raw
ExecStartPre=/sbin/iptables -F -t mangle
ExecStartPre=/sbin/iptables -X -t mangle
ExecStart=/opt/kube/bin/dockerd
ExecStartPost=/sbin/iptables -P INPUT ACCEPT
ExecStartPost=/sbin/iptables -P OUTPUT ACCEPT
ExecStartPost=/sbin/iptables -P FORWARD ACCEPT
ExecReload=/bin/kill -s HUP \$MAINPID
Restart=on-failure
RestartSec=5
LimitNOFILE=infinity
LimitNPROC=infinity
LimitCORE=infinity
Delegate=yes
KillMode=process
[Install]
WantedBy=multi-user.target
EOF

  # configuration for dockerd
  mkdir -p /etc/docker
  DOCKER_VER_MAIN=$(echo "$DOCKER_VER"|cut -d. -f1)
  CGROUP_DRIVER="cgroupfs"
  ((DOCKER_VER_MAIN>=20)) && CGROUP_DRIVER="systemd"
  logger debug "generate docker config: /etc/docker/daemon.json"
  if [[ "$REGISTRY_MIRROR" == CN ]];then
    logger debug "prepare register mirror for $REGISTRY_MIRROR"
    cat > /etc/docker/daemon.json << EOF
{
  "exec-opts": ["native.cgroupdriver=$CGROUP_DRIVER"],
  "registry-mirrors": [
    "https://docker.mirrors.ustc.edu.cn",
    "http://hub-mirror.c.163.com"
  ],
  "max-concurrent-downloads": 10,
  "log-driver": "json-file",
  "log-level": "warn",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
    },
  "data-root": "/var/lib/docker"
}
EOF
  else
    logger debug "standard config without registry mirrors"
    cat > /etc/docker/daemon.json << EOF
{
  "exec-opts": ["native.cgroupdriver=$CGROUP_DRIVER"],
  "max-concurrent-downloads": 10,
  "log-driver": "json-file",
  "log-level": "warn",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
    },
  "data-root": "/var/lib/docker"
}
EOF
  fi

  # docker proxy setting
  http_proxy=${http_proxy:-}
  HTTP_PROXY=${HTTP_PROXY:-$http_proxy}
  https_proxy=${https_proxy:-}
  HTTPS_PROXY=${HTTPS_PROXY:-$https_proxy}
  USE_PROXY=0
  CONFIG="[Service]\n"

  if [[ ! -z ${HTTP_PROXY} ]]; then
    USE_PROXY=1
    CONFIG=${CONFIG}"Environment=HTTP_PROXY=${HTTP_PROXY}\n"
  fi
  if [[ ! -z ${HTTPS_PROXY} ]]; then
    USE_PROXY=1
    CONFIG=${CONFIG}"Environment=HTTPS_PROXY=${HTTPS_PROXY}\n"
  fi
  if [[ ${USE_PROXY} == 1 ]]; then
    logger debug "generate docker service http proxy file"
    mkdir -p /etc/systemd/system/docker.service.d
    c=$(echo -e ${CONFIG})
    cat > /etc/systemd/system/docker.service.d/http-proxy.conf << EOF
${c}
EOF
  fi

  if [[ -e /etc/centos-release || -e /etc/redhat-release ]]; then
    logger debug "turn off selinux in CentOS/Redhat"
    getenforce|grep Disabled || setenforce 0
    sed -i 's/^SELINUX=.*$/SELINUX=disabled/g' /etc/selinux/config
  fi

  logger debug "enable and start docker"
  systemctl enable docker
  systemctl daemon-reload && systemctl restart docker && sleep 4
}

function get_kubeasz() {
  # check if kubeasz already existed
  [[ -d "$BASE/roles/kube-node" ]] && { logger warn "kubeasz already existed"; return 0; }

  logger info "downloading kubeasz: $KUBEASZ_VER"
  logger debug " run a temporary container"
  docker run -d --name temp_easz easzlab/kubeasz:${KUBEASZ_VER} || { logger error "download failed."; exit 1; }

  [[ -f "$BASE/down/docker-${DOCKER_VER}.tgz" ]] && /bin/mv -f "$BASE/down/docker-${DOCKER_VER}.tgz" /tmp
  [[ -d "$BASE/bin" ]] && /bin/mv -f "$BASE/bin" /tmp

  rm -rf "$BASE" && \
  logger debug "cp kubeasz code from the temporary container" && \
  docker cp "temp_easz:$BASE" "$BASE" && \
  logger debug "stop&remove temporary container" && \
  docker rm -f temp_easz

  mkdir -p "$BASE/bin" "$BASE/down"
  [[ -f "/tmp/docker-${DOCKER_VER}.tgz" ]] && /bin/mv -f "/tmp/docker-${DOCKER_VER}.tgz" "$BASE/down"
  [[ -d "/tmp/bin" ]] && /bin/mv -f /tmp/bin/* "$BASE/bin"
  return 0
}

function get_k8s_bin() {
  [[ -f "$BASE/bin/kubelet" ]] && { logger warn "kubernetes binaries existed"; return 0; }
  
  logger info "downloading kubernetes: $K8S_BIN_VER binaries"
  docker pull easzlab/kubeasz-k8s-bin:"$K8S_BIN_VER" && \
  logger debug "run a temporary container" && \
  docker run -d --name temp_k8s_bin easzlab/kubeasz-k8s-bin:${K8S_BIN_VER} && \
  logger debug "cp k8s binaries" && \
  docker cp temp_k8s_bin:/k8s "$BASE/k8s_bin_tmp" && \
  /bin/mv -f "$BASE"/k8s_bin_tmp/* "$BASE/bin" && \
  logger debug "stop&remove temporary container" && \
  docker rm -f temp_k8s_bin && \
  rm -rf "$BASE/k8s_bin_tmp"
}

function get_ext_bin() {
  [[ -f "$BASE/bin/etcdctl" ]] && { logger warn "extra binaries existed"; return 0; }

  logger info "downloading extral binaries kubeasz-ext-bin:$EXT_BIN_VER"
  docker pull "easzlab/kubeasz-ext-bin:$EXT_BIN_VER" && \
  logger debug "run a temporary container" && \
  docker run -d --name temp_ext_bin "easzlab/kubeasz-ext-bin:$EXT_BIN_VER" && \
  logger debug "cp extral binaries" && \
  docker cp temp_ext_bin:/extra "$BASE/extra_bin_tmp" && \
  /bin/mv -f "$BASE"/extra_bin_tmp/* "$BASE/bin" && \
  logger debug "stop&remove temporary container" && \
  docker rm -f temp_ext_bin && \
  rm -rf "$BASE/extra_bin_tmp"
}

function get_sys_pkg() {
  [[ -f "$BASE/down/packages/chrony_xenial.tar.gz" ]] && { logger warn "system packages existed"; return 0; }

  logger info "downloading system packages kubeasz-sys-pkg:$SYS_PKG_VER"
  docker pull "easzlab/kubeasz-sys-pkg:$SYS_PKG_VER" && \
  logger debug "run a temporary container" && \
  docker run -d --name temp_sys_pkg "easzlab/kubeasz-sys-pkg:$SYS_PKG_VER" && \
  logger debug "cp system packages" && \
  docker cp temp_sys_pkg:/packages "$BASE/down" && \
  logger debug "stop&remove temporary container" && \
  docker rm -f temp_sys_pkg
}

function get_harbor_offline_pkg() {
  [[ -f "$BASE/down/harbor-offline-installer-$HARBOR_VER.tgz" ]] && { logger warn "harbor-offline existed"; return 0; }

  logger info "downloading harbor-offline:$HARBOR_VER"
  docker pull "easzlab/harbor-offline:$HARBOR_VER" && \
  logger debug "run a temporary container" && \
  docker run -d --name temp_harbor "easzlab/harbor-offline:$HARBOR_VER" && \
  logger debug "cp harbor-offline installer package" && \
  docker cp "temp_harbor:/harbor-offline-installer-$HARBOR_VER.tgz" "$BASE/down" && \
  logger debug "stop&remove temporary container" && \
  docker rm -f temp_harbor
}

function get_offline_image() {
  imageDir="$BASE/down"
  logger info "downloading offline images"

  if [[ ! -f "$imageDir/calico_$calicoVer.tar" ]];then
    docker pull "calico/cni:$calicoVer" && \
    docker pull "calico/pod2daemon-flexvol:$calicoVer" && \
    docker pull "calico/kube-controllers:$calicoVer" && \
    docker pull "calico/node:$calicoVer" && \
    docker save -o "$imageDir/calico_$calicoVer.tar" "calico/cni:$calicoVer" "calico/kube-controllers:$calicoVer" "calico/node:$calicoVer" "calico/pod2daemon-flexvol:$calicoVer"
  fi
  if [[ ! -f "$imageDir/coredns_$corednsVer.tar" ]];then
    docker pull "coredns/coredns:$corednsVer" && \
    docker save -o "$imageDir/coredns_$corednsVer.tar" "coredns/coredns:$corednsVer"
  fi
  if [[ ! -f "$imageDir/k8s-dns-node-cache_$dnsNodeCacheVer.tar" ]];then
    docker pull "easzlab/k8s-dns-node-cache:$dnsNodeCacheVer" && \
    docker save -o "$imageDir/k8s-dns-node-cache_$dnsNodeCacheVer.tar" "easzlab/k8s-dns-node-cache:$dnsNodeCacheVer" 
  fi
  if [[ ! -f "$imageDir/dashboard_$dashboardVer.tar" ]];then
    docker pull "kubernetesui/dashboard:$dashboardVer" && \
    docker save -o "$imageDir/dashboard_$dashboardVer.tar" "kubernetesui/dashboard:$dashboardVer"
  fi
  if [[ ! -f "$imageDir/flannel_$flannelVer.tar" ]];then
    docker pull "easzlab/flannel:$flannelVer" && \
    docker save -o "$imageDir/flannel_$flannelVer.tar" "easzlab/flannel:$flannelVer"
  fi
  if [[ ! -f "$imageDir/metrics-scraper_$dashboardMetricsScraperVer.tar" ]];then
    docker pull "kubernetesui/metrics-scraper:$dashboardMetricsScraperVer" && \
    docker save -o "$imageDir/metrics-scraper_$dashboardMetricsScraperVer.tar" "kubernetesui/metrics-scraper:$dashboardMetricsScraperVer"
  fi
  if [[ ! -f "$imageDir/metrics-server_$metricsVer.tar" ]];then
    docker pull "easzlab/metrics-server:$metricsVer" && \
    docker save -o "$imageDir/metrics-server_$metricsVer.tar" "easzlab/metrics-server:$metricsVer"
  fi
  if [[ ! -f "$imageDir/pause_$pauseVer.tar" ]];then
    docker pull "easzlab/pause-amd64:$pauseVer" && \
    docker save -o "$imageDir/pause_$pauseVer.tar" "easzlab/pause-amd64:$pauseVer"
    /bin/cp -u "$imageDir/pause_$pauseVer.tar" "$imageDir/pause.tar"
  fi
  if [[ ! -f "$imageDir/nfs-provisioner_$nfsProvisionerVer.tar" ]];then
    docker pull "easzlab/nfs-subdir-external-provisioner:$nfsProvisionerVer" && \
    docker save -o "$imageDir/nfs-provisioner_$nfsProvisionerVer.tar" "easzlab/nfs-subdir-external-provisioner:$nfsProvisionerVer"
  fi
  if [[ ! -f "$imageDir/kubeasz_$KUBEASZ_VER.tar" ]];then
    docker pull "easzlab/kubeasz:$KUBEASZ_VER" && \
    docker save -o "$imageDir/kubeasz_$KUBEASZ_VER.tar" "easzlab/kubeasz:$KUBEASZ_VER"
  fi
}

function download_all() {
  mkdir -p /opt/kube/bin "$BASE/down" "$BASE/bin"
  download_docker && \
  install_docker && \
  get_kubeasz && \
  get_k8s_bin && \
  get_ext_bin && \
  get_offline_image && \
  install_anisble 
}

function start_kubeasz_docker() {
  [[ -d "$BASE/roles/kube-node" ]] || { logger error "not initialized. try 'ezdown -D' first."; exit 1; }

  logger info "try to run kubeasz in a container"
  # get host's IP
  host_if=$(ip route|grep default|head -n1|cut -d' ' -f5)
  host_ip=$(ip a|grep "$host_if$"|head -n1|awk '{print $2}'|cut -d'/' -f1)
  logger debug "get host IP: $host_ip"

  # allow ssh login using key locally
  if [[ ! -e /root/.ssh/id_rsa ]]; then
    logger debug "generate ssh key pair"
    ssh-keygen -t rsa -b 2048 -N '' -f /root/.ssh/id_rsa > /dev/null
    cat /root/.ssh/id_rsa.pub >> /root/.ssh/authorized_keys
    ssh-keyscan -t ecdsa -H "$host_ip" >> /root/.ssh/known_hosts
  fi

  # create a link '/usr/bin/python' in Ubuntu1604
  if [[ ! -e /usr/bin/python && -e /usr/bin/python3 ]]; then
    logger debug "create a soft link '/usr/bin/python'"
    ln -s /usr/bin/python3 /usr/bin/python
  fi

  # 
  docker load -i "$BASE/down/kubeasz_$KUBEASZ_VER.tar"

  # run kubeasz docker container
  docker run --detach \
      --env HOST_IP="$host_ip" \
      --name kubeasz \
      --network host \
      --restart always \
      --volume "$BASE":"$BASE" \
      --volume /root/.kube:/root/.kube \
      --volume /root/.ssh:/root/.ssh \
      easzlab/kubeasz:${KUBEASZ_VER} sleep 36000
}

function clean_container() {
 logger info "clean all running containers"
 docker ps -a|awk 'NR>1{print $1}'|xargs docker rm -f 
} 

function install_anisble() {
  if [ [! -e /usr/bin/pip && -e /bin/pip && -e /usr/local/bin/pip ]; then
    logger debug "install pip..."
    apt install pip
  fi

  if [[ ! -e /usr/bin/ansible && -e /usr/local/bin/ansible ]]; then
    logger debug "install ansible..."
    pip install ansible -i http://mirrors.aliyun.com/pypi/simple/
  fi
}

### Main Lines ##################################################
function main() {
  BASE="/etc/kubeasz"

  # check if use bash shell
  readlink /proc/$$/exe|grep -q "dash" && { logger error "you should use bash shell, not sh"; exit 1; }
  # check if use with root
  [[ "$EUID" -ne 0 ]] && { logger error "you should run this script as root"; exit 1; }
  
  [[ "$#" -eq 0 ]] && { usage >&2; exit 1; }
  
  ACTION=""
  while getopts "CDPRSd:e:k:m:p:z:" OPTION; do
      case "$OPTION" in
        C)
          ACTION="clean_container"
          ;;
        D)
          ACTION="download_all"
          ;;
        P)
          ACTION="get_sys_pkg"
          ;;
        R)
          ACTION="get_harbor_offline_pkg"
          ;;
        S)
          ACTION="start_kubeasz_docker"
          ;;
        d)
          DOCKER_VER="$OPTARG"
          ;;
        e)
          EXT_BIN_VER="$OPTARG"
          ;;
        k)
          K8S_BIN_VER="$OPTARG"
          ;;
        m)
          REGISTRY_MIRROR="$OPTARG"
          ;;
        p)
          SYS_PKG_VER="$OPTARG"
          ;;
        z)
          KUBEASZ_VER="$OPTARG"
          ;;
        ?)
          usage
          exit 1
          ;;
      esac
  done
  
  [[ "$ACTION" == "" ]] && { logger error "illegal option"; usage; exit 1; }
  
  # excute cmd "$ACTION" 
  logger info "Action begin: $ACTION"
  ${ACTION} || { logger error "Action failed: $ACTION"; return 1; }
  logger info "Action successed: $ACTION"
}

main "$@"
