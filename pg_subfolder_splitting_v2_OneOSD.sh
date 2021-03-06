#!/bin/bash
set -xv
merge_num=-31
split_num=1
pool_name="COMMOBJECTS"
osd=1

# The original script which was modified as per our requirement : https://gist.github.com/drakonstein/cb76c7696e65522ab0e699b7ea1ab1c4
# Some method to set your ceph.conf file to the subfolder splitting settings you want.
# If you are not changing the ceph.conf settings, then you can start the osd at the end of the loop instead of at the end.
conf=/etc/ceph/ceph.conf
if ! grep -q '^\[global\]' $conf; then
  echo $conf is badly formed
  exit
fi
merge=$(grep -E filestore.merge.threshold $conf)
merge=${merge:-false}
split=$(grep -E filestore.split.multiple $conf)
split=${split:-false}
if [[ "$merge" != false ]]; then
  sudo sed -i "/filestore.merge.threshold/c filestore_merge_threshold = $merge_num" $conf
else
  sudo sed -i "/^\[global\]/a filestore_merge_threshold = $merge_num" $conf
fi
if [[ "$split" != false ]]; then
  sudo sed -i "/filestore.split.multiple/c filestore_split_multiple = $split_num" $conf
else
  sudo sed -i "/^\[global\]/a filestore_split_multiple = $split_num" $conf
fi

ceph osd set noout
ceph osd set norecover
ceph osd set nobackfill
ceph osd set noscrub
ceph osd set nodeep-scrub
ceph osd set norebalance
#sudo systemctl stop ceph.target && sleep 30
sudo systemctl stop ceph-osd@{osd} && sleep 30
  for run_in_background in true; do
    echo "Starting osd $osd"
    sudo -u ceph ceph-osd --flush-journal -i=${osd}
    sudo -u ceph ceph-objectstore-tool --data-path /var/lib/ceph/osd/ceph-${osd} \
        --journal-path /var/lib/ceph/osd/ceph-${osd}/journal \
        --log-file=/var/log/ceph/objectstore_tool.${osd}.log \
        --op apply-layout-settings \
        --pool $pool_name \
        --debug
    echo "Finished osd.${osd}"
    # sudo systemctl start ceph-osd@${osd}.service
  done &
wait

# set ceph.conf back to normal before starting the OSDs
if [[ "$merge" != false ]]; then
  sudo sed -i "/filestore.merge.threshold/c \\${merge}" $conf
else
  sudo sed -i "/filestore.merge.threshold/d" $conf
fi
if [[ "$merge" != false ]]; then
  sudo sed -i "/filestore.split.multiple/c \\${split}" $conf
else
  sudo sed -i "/filestore.merge.multiple/d" $conf
fi
echo starting OSDs
#sudo systemctl start ceph.target
sudo systemctl start ceph-osd@{osd}

while true; do
  stat=$(ceph osd stat)
  up=$(echo "$stat" | grep -Eo '[[:digit:]]+\s+up' | awk '{print $1}')
  in=$(echo "$stat" | grep -Eo '[[:digit:]]+\s+in' | awk '{print $1}')
  if (( $up == $in )); then
    ceph tell osd.\* injectargs --osd_max_backfills=3
    ceph osd unset noout
    ceph osd unset norecover
    ceph osd unset nobackfill
    ceph osd unset noscrub
    ceph osd unset nodeep-scrub
    ceph osd unset norebalance
    break
  else
    sleep 10
  fi
done
