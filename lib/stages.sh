

# rmeove any of the mounts of loopback devices
# also unmount images from loopback devices
function cleanup()
{

  pr_header "cleanup devices, mounts, etc"

  pr_section "sync'ing filesystem"
  # no idea if this makes any difference???
  sync

  pr_section "unmounting restore filesystems"

  umount -d mnt/copy_rootfs > /dev/null 2>&1 || true
  umount -d mnt/lite_rootfs > /dev/null 2>&1 || true

  umount -d mnt/restore_boot > /dev/null 2>&1 || true
  umount -d mnt/restore_rootfs > /dev/null 2>&1 || true
  umount -d mnt/restore_recovery > /dev/null 2>&1 || true
  

  pr_section "detaching any loopback devices"

  for imgname in $IMG_RESTORE $IMG_ORIG $IMG_ORIG_LITE $IMG_COPY; do
    # echo "unounting $imgname"
    if [ -e "$IMG_ORIG_LITE" ] ; then
      while losetup -a | grep "${imgname}" > /dev/null 2>&1; do
        TMPLOOP="$(losetup -a | grep "${imgname}" | head -1| awk '{ print $1 }')"
        TMPLOOP=${TMPLOOP%:}
        # echo $TMPLOOP
        losetup --detach ${TMPLOOP}
        echo "detached ${TMPLOOP}"
      done
    fi
  done

  # Perform a garbage collection pass on the blkid cache to remove devices
  # which no longer exist
  blkid --garbage-collect

  [ -z "${OPTION_STEPS}" ] || { echo ""; read -p "${MSG_CONTINUE}"; }

}



# get the start and size of each of the 2 partitions on the source image
function get_partitions_for_original(){

  pr_header "getting partition information for original image"

  ORIG_P1_START=$(sfdisk --json $BASE.img |
          jq ".partitiontable .partitions[] | select(.node == \"${BASE}.img1\") .start ")

  ORIG_P1_SIZE=$(sfdisk --json $BASE.img |
          jq ".partitiontable .partitions[] | select(.node == \"${BASE}.img1\") .size ")

  ORIG_P2_START=$(sfdisk --json $BASE.img |
          jq ".partitiontable .partitions[] | select(.node == \"${BASE}.img2\") .start ")

  ORIG_P2_SIZE=$(sfdisk --json $BASE.img |
          jq ".partitiontable .partitions[] | select(.node == \"${BASE}.img2\") .size ")

  echo ""
  echo "ORIG_P1_START     :   ${ORIG_P1_START}" 
  echo "ORIG_P1_SIZE      :   ${ORIG_P1_SIZE}" 
  echo "ORIG_P2_START     :   ${ORIG_P1_START}" 
  echo "ORIG_P2_SIZE      :   ${ORIG_P2_SIZE}" 
  echo ""

  ORIG_TOTAL_IMG_BYTES="$(stat --format=\"%s\" $BASE.img)"

  echo "Total bytes for original image  is $(stat --format=\"%s\" $BASE.img)"
}

# set the start and size of the 2 partitions in the lite image
# this might be the same as the source image
function get_partitions_for_lite(){

  pr_header "getting partition information for lite image"

  LITE_P1_START=$(sfdisk --json ${LITE}.img |
          jq ".partitiontable .partitions[] | select(.node == \"${LITE}.img1\") .start ")

  LITE_P1_SIZE=$(sfdisk --json $LITE.img |
          jq ".partitiontable .partitions[] | select(.node == \"${LITE}.img1\") .size ")

  LITE_P2_START=$(sfdisk --json $LITE.img |
          jq ".partitiontable .partitions[] | select(.node == \"${LITE}.img2\") .start ")

  LITE_P2_SIZE=$(sfdisk --json $LITE.img |
          jq ".partitiontable .partitions[] | select(.node == \"${LITE}.img2\") .size ")

  echo ""
  echo "LITE_P1_START     :   ${LITE_P1_START}" 
  echo "LITE_P1_SIZE      :   ${LITE_P1_SIZE}" 
  echo "LITE_P2_START     :   ${LITE_P2_START}" 
  echo "LITE_P2_SIZE      :   ${LITE_P2_SIZE}" 
  echo ""
  echo ""

  LITE_TOTAL_IMG_BYTES="$(stat --format=\"%s\" $LITE.img)"

  echo "Total bytes for lite image  is $(stat --format=\"%s\" $LITE.img)"
}





# generate new UUIDs for the copy of the original image
function make_uuids(){

  pr_header "make UUID/partuuids for restore filesystems"
  
  echo ""

  # partuuid seems to get reset by resize.sh, however UUID doesn't seem to work
  set +o pipefail
  PARTUUID=$(tr -dc 'a-f0-9' < /dev/urandom 2>/dev/null | head -c8)
  set -o pipefail

  [ ! -z ${PARTUUID} ] || { echo "PARTUUID is empty '${PARTUUID}'" && exit 99;  }

  set +o pipefail
  COPY_PARTUUID=$(tr -dc 'a-f0-9' < /dev/urandom 2>/dev/null | head -c8)
  set -o pipefail

  [ ! -z ${COPY_PARTUUID} ] || { echo "COPY_PARTUUID is empty '${COPY_PARTUUID}'" && exit 99;  }

  # because of cloning the images, need to generate new UUIDs
  UUID_RESTORE=$(uuidgen)
  [ ! -z "$UUID_RESTORE" ] || { echo "UUID_RESTORE Empty: can't proceed"; exit 99; }
  UUID_ROOTFS=$(uuidgen)
  [ ! -z "$UUID_ROOTFS" ] || { echo "UUID_ROOTFS Empty: can't proceed"; exit 99; }
  UUID_COPY_ROOTFS=$(uuidgen)
  [ ! -z "$UUID_COPY_ROOTFS" ] || { echo "UUID_COPY_ROOTFS Empty: can't proceed"; exit 99; }

  pr_ok "PARTUUID:          ${PARTUUID}"
  pr_ok "COPY_PARTUUID:     ${COPY_PARTUUID}"
  pr_ok "UUID_RESTORE:      ${UUID_RESTORE}"
  pr_ok "UUID_ROOTFS:       ${UUID_ROOTFS}"
  pr_ok "UUID_COPY_ROOTFS:  ${UUID_COPY_ROOTFS}"

  [ -z "${OPTION_STEPS}" ] || { echo ""; read -p "${MSG_CONTINUE}"; }
}

# make a copy of the original img file
# mounts the partitions from the new img onto loopback devices
#
function make_loop_and_mount_original(){

  pr_header "mount the original img readonly on loopback"

  pr_ok "show source image partition (from sfdisk --dump"
  # sfdisk -d $IMG_ORIG

  echo "sector size: $(sfdisk --json ${IMG_ORIG} |  jq ".partitiontable .sectorsize ")"


  # $(sfdisk --json $LITE.img |
  #         jq ".partitiontable .partitions[] | select(.node == \"${LITE}.img1\") .size ")

  LOOP_ORIG=$(losetup \
        --read-only \
        --nooverlap \
        --show \
        --find \
        --partscan \
           ${IMG_ORIG})

  [ ! -z "$LOOP_ORIG" ] || { echo "LOOP_ORIG Empty: can't proceed"; exit 99; }

  echo "The Original img is mounted readonly at ${LOOP_ORIG}"
  partprobe ${LOOP_ORIG}
  echo ""

  ORIG_UUID_BOOT="$(blkid -s UUID -o value ${LOOP_ORIG}p1)"
  [ ! -z "$ORIG_UUID_BOOT" ] || { echo "ORIG_UUID_BOOT Empty: can't proceed"; exit 99; }

  echo "Original Boot UUID is :${ORIG_UUID_BOOT}"

  # cat /proc/partitions
  # losetup -a
  # blkid
  # echo ""

  [ -z "${OPTION_STEPS}" ] || { echo ""; read -p "${MSG_CONTINUE}"; }
}

function make_loop_and_mount_copy(){

  pr_header "make img copy and mount it"


  tmpfile=$(mktemp /tmp/reset_sfdisk.XXXXXX)

cat << EOF > ${tmpfile}
label: dos
label-id: 0x${COPY_PARTUUID}
unit: sectors

${IMG_COPY}1 : start=${ORIG_P1_START},  size=${ORIG_P1_SIZE},  type=c
${IMG_COPY}2 : start=${ORIG_P2_START},  size=${ORIG_P2_SIZE},  type=83

EOF

  get_bytes_to_contain_partition ${ORIG_P2_START} ${ORIG_P2_SIZE}

  echo "calculated copy size is : $REPLY"
  echo "bytes from ORIG img is $ORIG_TOTAL_IMG_BYTES"

  [[ -f "${IMG_COPY}" ]] && \
  {
    pr_warn "IMG_COPY file ${IMG_COPY} already, exists - overwriting"
  } || \
  {
    pr_ok "restore file ${IMG_RESTORE} creating"
    # touch ${IMG_RESTORE}
  }

  pr_ok "writing zeros to $IMG_COPY" 

  bytes_to_blocks $REPLY

  echo "writing $REPLY blocks of 8192"

  dd if=/dev/zero bs=8192 count=${REPLY} > ${IMG_COPY}

  # fdisk -l ${IMG_RESTORE}

  echo ""
  echo "writing partition table"
  cat "$tmpfile"

  sfdisk ${IMG_COPY} < "$tmpfile"

  # fdisk -lu ${IMG_COPY}

  LOOP_COPY=$(losetup -v  --show -f -P ${IMG_COPY})

  [ ! -z "$LOOP_COPY" ] || { echo "LOOP_COPY Empty: can't proceed"; exit 99; }

  pr_ok "partprobe the new loopback device - ${LOOP_COPY}"
  partprobe ${LOOP_COPY}

  pr_ok "show the partitions"
  # losetup -a

  [ -z "${OPTION_STEPS}" ] || { echo ""; read -p "${MSG_CONTINUE}"; }

}


function copy_original_to_copy(){

  pr_header "3.4 copy the filesystem partitions to the copy img"

  dd if=${LOOP_ORIG}p1 of=${LOOP_COPY}p1 bs=4M
  dd if=${LOOP_ORIG}p2 of=${LOOP_COPY}p2 bs=4M

  # make sure the partitions on the loop device are available
  partprobe ${LOOP_COPY}

  pr_ok "3.6 call tunefs to set label and UUID"

  # echo $UUID_RESTORE
  # echo $LOOP_RESTORE

  tune2fs ${LOOP_COPY}p2 -U ${UUID_COPY_ROOTFS}
  e2label ${LOOP_COPY}p2 copyroot

  pr_ok "3.7 call partprobe"
  partprobe ${LOOP_COPY}

  e2fsck -f ${LOOP_COPY}p2

  fdisk -l ${LOOP_COPY}

  mkdir -p mnt/copy_rootfs

  mount ${LOOP_COPY}p2 mnt/copy_rootfs

  [ -z "${OPTION_STEPS}" ] || { echo ""; read -p "${MSG_CONTINUE}"; }

}


function fix_copy_rootfs_fstab(){

  pr_header "fixing root fstab"

  pr_ok "current live fstab"
  cat mnt/copy_rootfs/etc/fstab

  pr_ok "map the live fstab to the 3rd partition"

tee mnt/copy_rootfs/etc/fstab << EOF
proc                     /proc  proc    defaults          0       0
UUID=${ORIG_UUID_BOOT}  /boot  vfat    defaults          0       2
UUID=${UUID_ROOTFS}  /      ext4    defaults,noatime  0       1
EOF

  sync

}

# doesn't wait for error message
function fix_resize_script(){

  pr_header "fix_resize_script"

  pr_ok "copy the custom init_resize.sh into copy_rootfs"

  cp "${RESIZE_SCRIPT_SOURCE}" "mnt/copy_rootfs${RESIZE_SCRIPT_TARGET}"
  chmod +x "mnt/copy_rootfs${RESIZE_SCRIPT_TARGET}"

  sync

  [ -z "${OPTION_STEPS}" ] || { echo ""; read -p "${MSG_CONTINUE}"; }
}

function output_zipped_copy_rootfs(){

  pr_header "output_zipped_copy_rootfs"

  dd bs=4M if=${LOOP_COPY}p2 of=recovery.img
  zip recovery.img.zip recovery.img

}



function make_loop_and_mount_lite(){

  pr_header "mount the liteversion of img readonly on loopback"

  pr_ok "show source image partition (from sfdisk --dump)"
  sfdisk -d $IMG_ORIG_LITE

  LOOP_LITE=$(losetup \
        --read-only \
        --nooverlap \
        --show \
        --find \
        --partscan \
           ${IMG_ORIG_LITE})
  [ ! -z "$IMG_ORIG_LITE" ] || { echo "IMG_ORIG_LITE Empty: can't proceed"; exit 99; }

  echo "The Original LITE img is mounted readonly at ${LOOP_LITE}"
  partprobe ${LOOP_LITE}
  echo ""

  UUID_BOOT_LITE="$(blkid -s UUID -o value ${LOOP_LITE}p1)"
  [ ! -z "$UUID_BOOT_LITE" ] || { echo "UUID_BOOT Empty: can't proceed"; exit 99; }

  # cat /proc/partitions
  # losetup -a
  # blkid
  # echo ""


  mkdir -p mnt/lite_rootfs

  if mount | grep mnt/lite_rootfs > /dev/null 2>&1; then
    echo "already mounted"
  else
    mount -r ${LOOP_LITE}p2 mnt/lite_rootfs
  fi

}

function get_recovery_root_part_size(){

  pr_header "get_recovery_root_part_size"

  echo ""
  df -B1 mnt/lite_rootfs
  df -h mnt/lite_rootfs
  echo ""

  LITE_SIZE_BYTES=$(df -B1 --output=size,used,avail mnt/lite_rootfs | tail -1 | awk '{print $1}')
  LITE_USED_BYTES=$(df -B1 --output=size,used,avail mnt/lite_rootfs | tail -1 | awk '{print $2}')

  LITE_FREE_BYTES=$(df -B1 --output=size,used,avail mnt/lite_rootfs | tail -1 | awk '{print $3}')

  echo "LITE_SIZE_BYTES is    $LITE_SIZE_BYTES"
  echo "LITE_USED_BYTES is    $LITE_USED_BYTES"
  echo "LITE_FREE_BYTES is    $LITE_FREE_BYTES"
  echo "LITE_USED_BYTES in GB is $(( LITE_USED_BYTES / ( 1024 * 1024 ) ))"
  echo ""

  RECOVERY_IMG_BYTES=$(stat --format="%s" recovery.img.zip)

  echo "RECOVERY_IMG_BYTES is $RECOVERY_IMG_BYTES"
  echo "RECOVERY_IMG_BYTES in GB is $(( RECOVERY_IMG_BYTES / ( 1024 * 1024 ) ))"
  echo ""

  # used, plus zipped, plus 50Mib of free space for whatever reason
  RESTORE_P2_REQUIRED_BYTES=$(( LITE_USED_BYTES + RECOVERY_IMG_BYTES + 152428800 ))

  echo "RESTORE_P2_REQUIRED_BYTES $RESTORE_P2_REQUIRED_BYTES"
  echo "RESTORE_P2_REQUIRED_BYTES in GB $(( RESTORE_P2_REQUIRED_BYTES / ( 1024 * 1024 ) ))"
  echo ""

  round_bytes_to_sectors $RESTORE_P2_REQUIRED_BYTES

  echo "bytes rounded to sectors is $REPLY"
  echo ""

  RESTORE_P2_SIZE="${REPLY}"

  find_boundary $ORIG_P1_START $ORIG_P1_SIZE

  RESTORE_P2_START="${REPLY}"

  echo "start recovery p2 at $RESTORE_P2_START"
  echo "size recovery p2 at $RESTORE_P2_SIZE"

  echo RESTORE_P2_START $RESTORE_P2_START
  echo RESTORE_P2_SIZE $RESTORE_P2_SIZE

  find_boundary $RESTORE_P2_START $RESTORE_P2_SIZE

  RESTORE_P3_START="${REPLY}"
  RESTORE_P3_SIZE="${ORIG_P2_SIZE}"

  [ -z "${OPTION_STEPS}" ] || { echo ""; read -p "${MSG_CONTINUE}"; }
}


# the restore img is the file that contains the partitions that will
# ultimately get written out to the sdcard
function make_loop_and_mount_restore(){

  pr_header "make img restore and mount it"

  tmpfile=$(mktemp /tmp/reset_sfdisk.XXXXXX)

cat << EOF > ${tmpfile}
label: dos
label-id: 0x${PARTUUID}
unit: sectors

${IMG_RESTORE}1 : start=${ORIG_P1_START},     size=${ORIG_P1_SIZE},    type=c
${IMG_RESTORE}2 : start=${RESTORE_P2_START},  size=${RESTORE_P2_SIZE},   type=83
${IMG_RESTORE}3 : start=${RESTORE_P3_START},  size=${RESTORE_P3_SIZE},   type=83

EOF

cat $tmpfile

  pr_h2 "need to find the total size of restore img"

  find_boundary $RESTORE_P3_START $RESTORE_P3_SIZE
  echo "end start sector = $REPLY"

  sectors_to_bytes $REPLY
  TOTAL_SIZE_BYTES=$REPLY


  # final sector of filesystem
  BLOCKSIZE=$(( 1024 * 1024 * 4 ))
  BSCOUNT=$(( TOTAL_SIZE_BYTES / BLOCKSIZE ))
  echo "BSCOUNT: $BSCOUNT"




  if [ $(( TOTAL_SIZE_BYTES % BLOCKSIZE )) -ne 0 ]; then
    BSCOUNT=$(( BSCOUNT + 1 ))
  else
    #BSCOUNT=$(( TOTAL_SIZE_BYTES / BLOCKSIZE ))
    echo "BS COUNT remainder was zero"
  fi

  echo "remainder: $(( TOTAL_SIZE_BYTES % BLOCKSIZE ))"
  echo "BLOCKSIZE: $BLOCKSIZE"
  echo "TOTAL SIZE BYTES: $TOTAL_SIZE_BYTES"
  echo "BSCOUNT: $BSCOUNT"

  [[ -f "${IMG_RESTORE}" ]] && \
  {
    pr_warn "restore file ${IMG_RESTORE} already, exists - overwriting"
  } || \
  {
    pr_ok "restore file ${IMG_RESTORE} creating"
    # touch ${IMG_RESTORE}
  }



  dd if=/dev/zero bs=4M count=${BSCOUNT} > ${IMG_RESTORE}


  # fdisk -l ${IMG_RESTORE}

  sfdisk ${IMG_RESTORE} < "$tmpfile"

  cat "$tmpfile"
  #rm "$tmpfile"

  fdisk -lu ${IMG_RESTORE}

  LOOP_RESTORE=$(losetup -v  --show -f -P ${IMG_RESTORE})
  [ ! -z "$LOOP_RESTORE" ] || { echo "LOOP_RESTORE Empty: can't proceed"; exit 99; }

  pr_ok "partprobe the new loopback device - ${LOOP_RESTORE}"
  partprobe ${LOOP_RESTORE}

  # pr_ok "show the partitions"
  # losetup -a

  [ -z "${OPTION_STEPS}" ] || { echo ""; read -p "${MSG_CONTINUE}"; }

}


function copy_to_restore(){

  pr_header "3.4 copy the filesystem partitions to the restore img"

  dd if=${LOOP_ORIG}p1        of=${LOOP_RESTORE}p1    bs=4M
  dd if=${LOOP_LITE}p2        of=${LOOP_RESTORE}p2    bs=4M
  dd if=${LOOP_COPY}p2        of=${LOOP_RESTORE}p3    bs=4M

  # make sure the partitions on the loop device are available
  partprobe ${LOOP_RESTORE}

  pr_ok "3.6 call tunefs to set label and UUID"

  # echo $UUID_RESTORE
  # echo $LOOP_RESTORE

  tune2fs ${LOOP_RESTORE}p2 -U ${UUID_RESTORE}
  e2label ${LOOP_RESTORE}p2 recoveryfs

  tune2fs ${LOOP_RESTORE}p3 -U ${UUID_ROOTFS}

  pr_ok "3.7 call partprobe"
  partprobe ${LOOP_RESTORE}

  pr_ok "3.8 resize the fs on the recovery partition to fit the restore img"

  e2fsck -f ${LOOP_RESTORE}p2

  echo ""
  echo "LITE_SIZE_BYTES is    $LITE_SIZE_BYTES"
  echo "LITE_USED_BYTES is    $LITE_USED_BYTES"
  echo "LITE_FREE_BYTES is    $LITE_FREE_BYTES"
  echo "LITE_USED_BYTES in GB is $(( LITE_USED_BYTES / ( 1024 * 1024 ) ))"
  echo ""
  # RESTORE_P2_REQUIRED_BYTES=$(( LITE_USED_BYTES + RECOVERY_IMG_BYTES + 152428800 ))

  echo "RESTORE_P2_REQUIRED_BYTES $RESTORE_P2_REQUIRED_BYTES"
  echo "RESTORE_P2_REQUIRED_BYTES in GB $(( RESTORE_P2_REQUIRED_BYTES / ( 1024 * 1024 ) ))"
  echo ""


  dumpe2fs ${LOOP_RESTORE}p2 | egrep '^Block count:'
  dumpe2fs ${LOOP_RESTORE}p2 | egrep '^Free blocks:'

  BEFORE_BLOCK_COUNT="$(dumpe2fs ${LOOP_RESTORE}p2 | egrep '^Block count:' | awk '{print $3}')"
  BEFORE_FREE_BLOCKS="$(dumpe2fs ${LOOP_RESTORE}p2 | egrep '^Free blocks:' | awk '{print $3}')"

  echo "BEFORE_BLOCK_COUNT   : $BEFORE_BLOCK_COUNT"
  echo "BEFORE_FREE_BLOCKS   : $BEFORE_FREE_BLOCKS"

  dumpe2fs ${LOOP_RESTORE}p2 | egrep '^Block size:'
  echo "BEFORE_BLOCK_COUNT in bytes $(( BEFORE_BLOCK_COUNT * 4096 ))"
  echo "BEFORE_FREE_BLOCKS in bytes $(( BEFORE_FREE_BLOCKS * 4096 ))"
  echo "before free blocks in GB : $(( ( BEFORE_FREE_BLOCKS * 4096 ) / ( 1024 * 1024 ) ))"
  
  # this is necessary to make the space for the recovery.zip
  resize2fs -p ${LOOP_RESTORE}p2

  AFTER_BLOCK_COUNT="$(dumpe2fs ${LOOP_RESTORE}p2 | egrep '^Block count:' | awk '{print $3}')"
  AFTER_FREE_BLOCKS="$(dumpe2fs ${LOOP_RESTORE}p2 | egrep '^Free blocks:' | awk '{print $3}')"

  echo "AFTER_BLOCK_COUNT   : $AFTER_BLOCK_COUNT"
  echo "AFTER_FREE_BLOCKS   : $AFTER_FREE_BLOCKS"

  echo "AFTER_BLOCK_COUNT in bytes :  $(( AFTER_BLOCK_COUNT * 4096 ))"
  echo "AFTER_FREE_BLOCKS in bytes :  $(( AFTER_FREE_BLOCKS * 4096 ))"
  echo "after free blocks in GB : $(( ( AFTER_FREE_BLOCKS * 4096 ) / ( 1024 * 1024 ) ))"
  echo ""

  echo "RECOVERY_IMG_BYTES is $RECOVERY_IMG_BYTES"
  echo "RECOVERY_IMG_BYTES in GB is $(( RECOVERY_IMG_BYTES / ( 1024 * 1024 ) ))"
  echo ""
  

  dumpe2fs ${LOOP_RESTORE}p2 | egrep '^Free blocks:'
  dumpe2fs ${LOOP_RESTORE}p2 | egrep '^Block size:'

  fdisk -l ${LOOP_RESTORE}

  mkdir -p mnt/restore_boot
  mkdir -p mnt/restore_recovery
  mkdir -p mnt/restore_rootfs

  mount ${LOOP_RESTORE}p1 mnt/restore_boot
  mount ${LOOP_RESTORE}p2 mnt/restore_recovery
  mount ${LOOP_RESTORE}p3 mnt/restore_rootfs

  [ -z "${OPTION_STEPS}" ] || { echo ""; read -p "${MSG_CONTINUE}"; }

}



function overwrite_cmdline_for_boot(){

  pr_header "4.0 current boot cmdline.txt"

  pr_ok "current cmdline.txt is"
  cat mnt/restore_boot/cmdline.txt

  pr_ok "saving original cmdline.txt"
  cp mnt/restore_boot/cmdline.txt mnt/restore_boot/cmdline.txt_from_pristine

  pr_ok "4.1 create the boot from live rootfs cmdline.txt"

tee mnt/restore_boot/cmdline.txt << EOF
console=serial0,115200 console=tty1 root=PARTUUID=${PARTUUID}-03 rootfstype=ext4 elevator=deadline fsck.repair=yes rootwait init=/usr/lib/raspi-config/init_resize.sh
EOF

  pr_ok "4.3 create alt cmd file for recovery boot"

tee mnt/restore_boot/cmdline.txt_recovery << EOF
console=serial0,115200 console=tty1 root=PARTUUID=XXXYYYXXX rootfstype=ext4 elevator=deadline fsck.repair=yes rootwait quiet init=${RECOVERY_SCRIPT_TARGET}
EOF

  [ -z "${OPTION_STEPS}" ] || { echo ""; read -p "${MSG_CONTINUE}"; }

}


function make_restore_script(){
#   ___        _               ___         _      _
#  | _ \___ __| |_ ___ _ _ ___/ __| __ _ _(_)_ __| |_
#  |   / -_|_-<  _/ _ \ '_/ -_)__ \/ _| '_| | '_ \  _|
#  |_|_\___/__/\__\___/_| \___|___/\__|_| |_| .__/\__|
#                                           |_|

  pr_header "4.4 create factory reset script in /boot directory"

tee mnt/restore_boot/factory_reset > /dev/null << EOF
#!/bin/bash

echo "factory restore script"

[[ "\$1" == "--reset" ]] && \
{
  echo "resetting"

  if [[ \$(/usr/bin/id -u) -ne 0 ]]; then
    echo "This needs to run as root"
    exit 99
  fi

  sleep 5

  echo "show original cmdline.txt"
  cat /boot/cmdline.txt
  echo ""

  cp -f /etc/fstab /boot/fstab_original

  cp -f /boot/cmdline.txt /boot/cmdline.txt_original
  cp -f /boot/cmdline.txt_recovery /boot/cmdline.txt

  sed -i "s/XXXYYYXXX/\$(blkid -o export  \
        /dev/disk/by-label/recoveryfs | \
         egrep '^PARTUUID=' | cut -d'=' -f2)/g" /boot/cmdline.txt

  # echo "show blkid"
  # blkid
  # echo ""

  echo "show rootfs fstab"
  cat /etc/fstab
  echo ""

  # echo "show recoveryfs fstab"
  # mkdir -p /mnt/recoveryfs
  # mount /dev/disk/by-label/recoveryfs /mnt/recoveryfs
  # cat /mnt/recoveryfs/etc/fstab

  umount -f /mnt/recoveryfs
  echo ""

  echo "show current cmdline.txt"
  cat /boot/cmdline.txt
  echo ""

  echo "rebooting..."
  reboot
  exit 0
}

EOF

  chmod +x mnt/restore_boot/factory_reset

  pr_ok "copy init_restore.sh to recovery"
  cp "${RECOVERY_SCRIPT_SOURCE}" "mnt/restore_recovery${RECOVERY_SCRIPT_TARGET}"
  chmod +x "mnt/restore_recovery${RECOVERY_SCRIPT_TARGET}"

  pr_ok "current boot cmdline.txt"
  cat mnt/restore_boot/cmdline.txt

  pr_ok "current boot cmdline.txt txt_recovery"
  cat mnt/restore_boot/cmdline.txt_recovery

  pr_ok "enable ssh on the image"
  touch mnt/restore_boot/ssh

  [ -z "${OPTION_STEPS}" ] || { echo ""; read -p "${MSG_CONTINUE}"; }
}


function make_recovery_script(){

  pr_header "current recovery fstab"
  cat mnt/restore_recovery/etc/fstab

  pr_ok "indicate this is a recovery shell"

# not sure this is getting used on the console...?
tee mnt/restore_recovery/etc/motd << EOF
##    ____  _____ ____ _____     _______ ______   __
##   |  _ \| ____/ ___/ _ \ \   / / ____|  _ \ \ / /
##   | |_) |  _|| |  | | | \ \ / /|  _| | |_) \ V /
##   |  _ <| |__| |__| |_| |\ V / | |___|  _ < | |
##   |_| \_\_____\____\___/  \_/  |_____|_| \_\|_|
##
EOF

pr_ok "map the recovery fstab to the 2nd partition"
tee mnt/restore_recovery/etc/fstab << EOF
proc                    /proc  proc    defaults          0       0
UUID=${ORIG_UUID_BOOT}       /boot  vfat    defaults          0       2
UUID=${UUID_RESTORE}    /      ext4    defaults,noatime  0       1
EOF

pr_ok "copy the recovery image to the recovery /opt dir for restoring"

sync

#dd if=${LOOP_RESTORE}p3 of=mnt/restore_recovery/opt/recovery.img bs=4M
cp recovery.img.zip mnt/restore_recovery/opt/recovery.img.zip

# | zip mnt/restore_recovery/opt/recovery.img.zip -

}


function get_postbuild_summary(){

  

}
