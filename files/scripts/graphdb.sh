#!/usr/bin/env bash

set -eu

function waitService() {
  address=$1
  token=$2

  attempt_counter=0
  max_attempts=100

  echo "Waiting for ${address}"
  until $(curl --output /dev/null -H "Authorization: Basic ${token}" --silent --fail ${address}); do
    if [[ ${attempt_counter} -eq ${max_attempts} ]];then
      echo "Max attempts reached"
      exit 1
    fi

    printf '.'
    attempt_counter=$(($attempt_counter+1))
    sleep 5
  done
}

waitMasters() {
  masters_count=$1
  master_repo=$2
  token=$3

  for (( c=1; c<=$masters_count; c++ ))
  do
    master_address=http://graphdb-master-$c:7200
    waitService "${master_address}/rest/repositories" $token
    waitService "${master_address}/rest/repositories/${master_repo}/size" $token
    waitService "${master_address}/rest/cluster/masters/${master_repo}" $token
  done
}

waitWorkers() {
  workers_count=$1
  workers_repo=$2
  token=$3

  for (( c=1; c<=$workers_count; c++ ))
  do
    workers_address=http://graphdb-worker-$c:7200
    waitService "${workers_address}/rest/repositories" $token
    waitService "${workers_address}/rest/repositories/${workers_repo}/size" $token
  done
}

linkWorkerToMaster() {
  master_address=http://$1:7200
  master_repo=$2
  worker_address=http://$3:7200
  worker_repository=$4
  token=$5

  worker_repo_endpoint="${worker_address}/repositories/${worker_repository}"
  waitService "${worker_address}/rest/repositories" $token
  waitService "${worker_address}/rest/repositories/${worker_repository}/size" $token

  waitService "${master_address}/rest/repositories" $token
  waitService "${master_address}/rest/repositories/${worker_repository}/size" $token

  addInstanceAsRemoteLocation $1 $3 $token

  echo "Linking worker with repo endpoint ${worker_repo_endpoint}"
  curl -o response.json -sf -X POST -H "Authorization: Basic ${token}" ${master_address}/jolokia/ \
    --header 'Content-Type: multipart/form-data' \
    --data-raw "{
      \"type\": \"exec\",
      \"mbean\": \"ReplicationCluster:name=ClusterInfo/${master_repo}\",
      \"operation\": \"addClusterNode\",
      \"arguments\": [
        \"${worker_repo_endpoint}\", 0, true
      ]
    }"
   if grep -q '"status":200' "response.json"; then
      echo "Linking successfull for worker $worker_address"
  else
      echo "Linking failed for worker ${worker_address}"
      exit 1
  fi

  echo "Worker linked successfully!"
}

setInstanceReadOnly() {
  instance_address=http://$1:7200
  repository=$2
  token=$3

  echo "Setting instance $instance_address as readonly"

  curl -o response.json -H 'content-type: application/json' -H "Authorization: Basic $token" -d "{\"type\":\"write\",\"mbean\":\"ReplicationCluster:name=ClusterInfo\/$repository\",\"attribute\":\"ReadOnly\",\"value\":true}" $instance_address/jolokia

  if grep -q '"status":200' "response.json"; then
      echo "Successfully set instance $instance_address as read only"
  else
      echo "Failed setting instance read only $instance_address"
      exit 1
  fi
}

setInstanceMuted() {
  instance_address=http://$1:7200
  repository=$2
  token=$3

  echo "Setting instance $instance_address as muted"

  curl -o response.json -H 'content-type: application/json' -H "Authorization: Basic $token" -d "{\"type\":\"write\",\"mbean\":\"ReplicationCluster:name=ClusterInfo\/$repository\",\"attribute\":\"Mode\",\"value\":\"MUTE\"}" $instance_address/jolokia/

  if grep -q '"status":200' "response.json"; then
      echo "Successfully set instance $instance_address as muted"
  else
      echo "Failed setting instance muted $instance_address"
      exit 1
  fi
}

addInstanceAsRemoteLocation() {
  master_address=http://$1:7200
  worker_address=http://$2:7200
  token=$3
  username=$(echo $token | base64 -d | cut -d':' -f1)
  password=$(echo $token | base64 -d | cut -d':' -f2)

  echo "Adding worker $worker_address as remote location of $master_address"

  curl ${master_address}/rest/locations -o response.json -H "Authorization: Basic $token" -H 'Content-Type:application/json' -H 'Accept: application/json, text/plain, */*' --data-raw "{\"uri\":\"${worker_address}\",\"username\":\"${username}\", \"authType\":\"basic\", \"password\":\"${password}\", \"active\":\"false\"}"

  if grep -q 'Success\|connected' "response.json"; then
      echo "Successfully added $worker_address as remote location of $master_address"
  else
      echo "Failed adding instance $worker_address as remote location of $master_address"
      exit 1
  fi
}

setSyncPeer() {
  instance1_address=http://$1:7200
  instance2_address=http://$3:7200
  instance1_repository=$2
  instance2_repository=$4
  token=$5

  addInstanceAsRemoteLocation $1 $3 $token

  echo "Setting $instance2_address as sync peer for $instance1_address"

  curl -o response.json -H 'content-type: application/json' -H "Authorization: Basic $token" -d "{\"type\":\"exec\",\"mbean\":\"ReplicationCluster:name=ClusterInfo\/$instance1_repository\",\"operation\":\"addSyncPeer\",\"arguments\":[\"$instance2_address/repositories/$instance2_repository\",\"$instance2_address/repositories/$instance2_repository\"]}"   $instance1_address/jolokia/
  if grep -q '"status":200' "response.json"; then
      echo "Successfully set sync peer between $instance1_address and $instance2_address"
  else
      echo "Failed setting sync peer between $instance1_address and $instance2_address"
      exit 1
  fi
}

linkAllWorkersToMaster() {
  worker_repository=$4
  master_repo=$2
  workers_count=$3
  token=$5

  for (( c=1; c<=$workers_count; c++ ))
  do
    worker_address=graphdb-worker-$c
    linkWorkerToMaster $1 $master_repo $worker_address $worker_repository $token
  done

  echo "Cluster linked successfully!"
}

unlinkWorker() {
  master_repo=$1
  master_address=$2
  worker_address=$3
  worker_repo=$4
  token=$5

  echo "Unlinking $worker_address from $master_address"
  curl -X 'DELETE' "http://$master_address:7200/graphdb/rest/cluster/masters/$master_repo/workers?masterLocation=local" -H "Authorization: Basic $token" --data-urlencode "workerURL=http://$worker_address:7200/repositories/$worker_repo"
  curl -o response.json -H 'content-type: application/json' -H "Authorization: Basic $token" -d "{\"type\":\"exec\",\"mbean\":\"ReplicationCluster:name=ClusterInfo\/$instance1_repository\",\"operation\":\"addSyncPeer\",\"arguments\":[\"$instance2_address/repositories/$instance2_repository\",\"$instance2_address/repositories/$instance2_repository\"]}"   $instance1_address/jolokia/
  if grep -q '"status":200' "response.json"; then
      echo "Successfully unlinked $master_address from $worker_address"
  else
      echo "Failed unlinking $master_address from $worker_address"
      exit 1
  fi
}

unlinkDownScaledInstances() {
  master_repo=$1
  masters_count=$2
  workers_count=$3
  worker_repo=$4
  token=$5

  for (( c=1; c<=$masters_count; c++ ))
  do
    master_address=graphdb-master-$c
    curl -o response.json -H 'content-type: application/json'  -H "Authorization: Basic $token" -d "{\"type\":\"read\",\"mbean\":\"ReplicationCluster:name=ClusterInfo\/$master_repo\",\"attribute\":\"NodeStatus\"}"   http://$master_address:7200/jolokia/
    linked_workers_count=$(grep -ow ON "response.json" | wc -l)
    missing_workers_count=$(grep -ow ON "response.json" | wc -l)

    if $linked_workers_count != $workers_count ; then
      echo "The cluster has instances that are not connected, but they should be. Can't determine workers which must be disconnected from the cluster, please do it manually!"
    else
      worker_to_be_unlinked=$linked_workers_count+$missing_workers_count
      for (( x=1; x<=$missing_workers_count; x++ ))
      do
        unlinkWorker $master_repo $master_address graphdb-worker-$worker_to_be_unlinked $worker_repo $token
        worker_to_be_unlinked=$worker_to_be_unlinked-1
      done
    fi
    linkWorkerToMaster $1 $master_repo $worker_address $worker_repository $token
  done

  echo "Cluster linked successfully!"
}

waitAllInstances() {
  #workersCount, workerRepo, token
  waitWorkers $3 $4 $5
  #mastersCount, mastersRepo, token
  waitMasters $1 $2 $5
}

link_1m_3w() {
  #masters count, master repo, workers count, worker repo, token
  waitAllInstances $1 $2 $3 $4 $5

  #1 master, multiple workers. Args: master to link to, master repo, workers count, workers repo, token
  linkAllWorkersToMaster graphdb-master-1 $2 $3 $4 $5
}

"$@"
