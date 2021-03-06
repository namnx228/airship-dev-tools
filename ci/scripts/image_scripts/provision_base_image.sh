#! /usr/bin/env bash

set -eux

# This script sets up fresh ubuntu 18.04+ installation
# to create a base image for our applications.

SCRIPTS_DIR="$(dirname "$(readlink -f "${0}")")"
# Upgrade all packages
sudo apt-get update
sudo apt-get upgrade -f -y

# Install required packages.
sudo apt install -y \
  vim \
  jq \
  git \
  coreutils \
  wget \
  curl \
  apt-transport-https \
  ca-certificates \
  tree \
  make \
  gnupg-agent \
  software-properties-common \
  openssl

# Install docker.
"${SCRIPTS_DIR}"/setup_docker_ubuntu.sh

# Configure chrony.
"${SCRIPTS_DIR}"/setup_chrony_ubuntu.sh

# Enable nested virtualization.
"${SCRIPTS_DIR}"/setup_qemu_ubuntu.sh

# Perform security hardening.
"${SCRIPTS_DIR}"/hardening_base_image.sh


# Reset cloud-init to run on next boot.
"${SCRIPTS_DIR}"/reset_cloud_init.sh
