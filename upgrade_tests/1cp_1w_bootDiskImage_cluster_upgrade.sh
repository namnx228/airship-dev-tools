#!/bin/bash

set -x

source ./common.sh
echo '' > ~/.ssh/known_hosts

start_logging "${0}"

# TODO: cleanup
set_number_of_node_replicas 1
set_number_of_master_node_replicas 1
set_number_of_worker_node_replicas 1

# provision a controlplane node
provision_controlplane_node
wait_for_ctrlplane_provisioning_start

sleep 30

CP_NODE=$(kubectl get bmh -n metal3 | grep control | grep -v ready | cut -f1 -d' ')
echo "BareMetalHost ${CP_NODE} is in provisioning or provisioned state"
CP_NODE_IP=$(virsh net-dhcp-leases baremetal | grep "${CP_NODE}"  | awk '{{print $5}}' | cut -f1 -d\/)

wait_for_ctrlplane_provisioning_complete ${CP_NODE} ${CP_NODE_IP} "controlplane node"
# apply CNI
ssh -o PasswordAuthentication=no -o "StrictHostKeyChecking no" "${UPGRADE_USER}@${CP_NODE_IP}" -- kubectl apply -f https://docs.projectcalico.org/manifests/calico.yaml

provision_worker_node

# Verify that provisioning of a worker node is started.
for i in {1..3600};do
  count=$(kubectl get bmh -n metal3 | awk 'NR>1'| grep -i 'provision' | wc -l)
  if [ $count -lt 2 ]; then
	  echo "Waiting for start of provisioning of a worker node"
	  sleep 1
	  if [[ "${i}" -ge 3600 ]];then
		  echo "Error: provisioning of a worker node took too long to start"
		  exit 1
    fi
	  continue
  else
    echo "provisioning of a worker node has started"
	  break
  fi
done

WR_NODE=$(kubectl get bmh -n metal3 | grep 'provision' | grep -v ${CP_NODE} | cut -f1 -d' ')
WR_NODE_IP=$(sudo virsh net-dhcp-leases baremetal | grep "${WR_NODE}"  | awk '{{print $5}}' | cut -f1 -d\/)

# Wait until the worker joins AND the state is ready
# Workers' upgrade requires CNI and kubernetes nodes' status should be ready.
for i in {1..3600};do
  r_count=$(ssh -o PasswordAuthentication=no -o "StrictHostKeyChecking no" "${UPGRADE_USER}@${CP_NODE_IP}" -- kubectl get nodes | grep Ready | wc -l)
  if [[ "$r_count" == '2' ]]; then
    echo "The worker has joined and all kubernetes nodes are in Ready state"
    break
  fi
  echo "Waiting for worker to join the cluster"
  if [[ "${i}" -ge 3600 ]]; then
	  echo "Error: It took too long for a worker to join the cluster"
	  exit 1
  fi
done

echo "Create a new metal3MachineTemplate with new node image for both controlplane and worker nodes"
cp_Metal3MachineTemplate_OUTPUT_FILE="/tmp/cp_new_image.yaml"
wr_Metal3MachineTemplate_OUTPUT_FILE="/tmp/wr_new_image.yaml"
CLUSTER_UID=$(kubectl get clusters -n metal3 test1 -o json |jq '.metadata.uid' | cut -f2 -d\")
IMG_CHKSUM=$(curl -s https://cloud-images.ubuntu.com/bionic/current/MD5SUMS | grep bionic-server-cloudimg-amd64.img | cut -f1 -d' ')
generate_metal3MachineTemplate "test1-new-controlplane-image" "${CLUSTER_UID}" "${cp_Metal3MachineTemplate_OUTPUT_FILE}" "${IMG_CHKSUM}"
generate_metal3MachineTemplate "test1-new-workers-image" "${CLUSTER_UID}" "${wr_Metal3MachineTemplate_OUTPUT_FILE}" "${IMG_CHKSUM}"

kubectl apply -f "${cp_Metal3MachineTemplate_OUTPUT_FILE}"
kubectl apply -f "${wr_Metal3MachineTemplate_OUTPUT_FILE}"

kubectl get kcp -n metal3 test1 -o json | jq '.spec.infrastructureTemplate.name="test1-new-controlplane-image"' | kubectl apply -f-

kubectl get machinedeployment -n metal3 test1 -o json | jq '.spec.strategy.rollingUpdate.maxSurge=1|.spec.strategy.rollingUpdate.maxUnavailable=0' | kubectl apply -f-
sleep 10
kubectl get machinedeployment -n metal3 test1 -o json | jq '.spec.template.spec.infrastructureRef.name="test1-new-workers-image"' | kubectl apply -f-

# Wait for the start of provisioning of new controlplane and worker nodes
for i in {1..3600};do

  # provisioning of both a worker nodes has started.
  kubectl get bmh -n metal3 | grep 'new-workers-image' | awk '{{print $1}}'

  if [[ "$?" == '0' ]]; then
    kubectl get bmh -n metal3 | grep 'new-controlplane-image' | awk '{{print $1}}'
    if [[ "$?" != '0' ]]; then
      # provisioning of both a controller plane has not started yet.
      continue
    fi
    # It is possible that multiple controlplane nodes exist at a given time (up to 3)
    NEW_CP_NODE=$(kubectl get bmh -n metal3 | grep 'new-controlplane-image' | awk '{{print $1}}')
    NEW_CP_NODE_IP=$(sudo virsh net-dhcp-leases baremetal | grep "${NEW_CP_NODE}"  | awk '{{print $5}}' | cut -f1 -d\/)

    NEW_WR_NODE=$(kubectl get bmh -n metal3 | grep 'new-workers-image' | awk '{{print $1}}')
    NEW_WR_NODE_IP=$(sudo virsh net-dhcp-leases baremetal | grep "${NEW_WR_NODE}"  | awk '{{print $5}}' | cut -f1 -d\/)
    wait_for_ctrlplane_provisioning_complete ${NEW_CP_NODE} ${NEW_CP_NODE_IP} "upgraded controlplane node"

    # Verify that the new CP and Worker are in the same cluster
    count_upgraded_nodes=$(ssh -o PasswordAuthentication=no -o "StrictHostKeyChecking no" "${UPGRADE_USER}@${NEW_CP_NODE_IP}" -- kubectl get nodes | egrep "${NEW_CP_NODE}|${NEW_WR_NODE}"| wc -l)
    if [[ "$count_upgraded_nodes" == '2' ]]; then
     echo "The worker has joined the new controlplane node"
     break
    fi
  fi
  echo "Waiting for completion of provisioning of new controlplane and worker nodes"
  if [[ "${i}" -ge 3600 ]]; then
		  echo "Error: Provisioning of new controlplane and worker nodes too too long to start"
		  exit 1
  fi
  sleep 5
done
NEW_CP_NODE=$(kubectl get bmh -n metal3 | grep 'new-controlplane-image' | awk '{{print $1}}')
NEW_WR_NODE=$(kubectl get bmh -n metal3 | grep 'new-workers-image' | awk '{{print $1}}')

NEW_CP_NODE_IP=$(sudo virsh net-dhcp-leases baremetal | grep "${NEW_CP_NODE}"  | awk '{{print $5}}' | cut -f1 -d\/)
NEW_WR_NODE_IP=$(sudo virsh net-dhcp-leases baremetal | grep "${NEW_WR_NODE}"  | awk '{{print $5}}' | cut -f1 -d\/)

echo $NEW_CP_NODE_IP
echo $NEW_WR_NODE_IP

wait_for_ctrlplane_provisioning_complete ${NEW_CP_NODE} ${NEW_CP_NODE_IP} "upgraded controlplane node"
echo "Upgraded controlplane node is ready."
echo "Verifying worker is also upgraded and joined the new cluster"

# We expect two free nodes at the end. However, this may take longer as there could be upto three masters.
for i in {1..3600};do
  worker_count=$(ssh -o "UserKnownHostsFile=/dev/null" -o PasswordAuthentication=no -o "StrictHostKeyChecking no" "${UPGRADE_USER}@${NEW_CP_NODE_IP}" -- kubectl get nodes | grep ${NEW_WR_NODE} | grep Ready | wc -l)
  if [[ "${worker_count}" == '1' ]]; then
    echo "Successfully upgraded worker node"
	  break
  else
	  echo "Waiting for upgraded worker to join the new cluster"
  fi
  sleep 5
  if [[ "${i}" -ge 3600 ]];then
		  echo "Error: It took too long for upgraded worker to join the new cluster"
		  exit 1
  fi
done

# Verify that original nodes are deprovisioned.
for i in {1..3600};do
  count_freed_nodes=$(kubectl get bmh -n metal3 | awk '{{print $3}}' | grep ready | wc -l)
  if [[ "${count_freed_nodes}" == '2' ]]; then
    echo "Successfully deprovisioned original controlplane and worker nodes"
	  break
  else
	  echo "Waiting for the deprovisioning of original controlplane and worker nodes"
  fi
  sleep 5
  if [[ "${i}" -ge 3600 ]];then
		  echo "Error: deprovisioning of the original controlplane and worker nodes took too long"
		  exit 1
  fi
done

echo "Boot disk upgrade of both controlplane and worker nodes has succeeded."
echo "successfully run 1cp_1w_bootDiskImage_cluster_upgrade.sh" >> /tmp/$(date +"%Y.%m.%d_upgrade.result.txt")

deprovision_cluster
wait_for_cluster_deprovisioned

set -x

