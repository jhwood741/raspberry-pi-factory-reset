

# start and size of partitions on the source image
# these are used to create intermediate and restore images
ORIG_P1_START=""
ORIG_P1_SIZE=""
ORIG_P2_START=""
ORIG_P2_SIZE=""
ORIG_TOTAL_IMG_BYTES=""

# we only really care about the P2, ie root start/size here
# but plausibly we could validate features of the slim images
# in that it is compatible with the rootfs/boot partitions
SLIM_P1_START=""
SLIM_P1_SIZE=""
SLIM_P2_START=""
SLIM_P2_SIZE=""
SLIM_TOTAL_IMG_BYTES=""

# new part UIs for copy of original images
RESTORE_PTUUID_NEW=""
COPY_PARTUUID_NEW=""

# new UUIDs image
UUID_RESTORE=""
UUID_ROOTFS=""
UUID_COPY_ROOTFS=""
UUID_BOOT_SLIM=""


# get the start and size of each of the 2 partitions on the source image
function get_partitions_for_original(){

  pr_header "getting partition information for original image"

  pr_info "(sizes in sectors)"

  ORIG_P1_START=$(sfdisk --json $IMG_ORIG |
          jq ".partitiontable .partitions[] | select(.node == \"${IMG_ORIG}1\") .start ")

  ORIG_P1_SIZE=$(sfdisk --json $IMG_ORIG |
          jq ".partitiontable .partitions[] | select(.node == \"${IMG_ORIG}1\") .size ")

  ORIG_P2_START=$(sfdisk --json $IMG_ORIG |
          jq ".partitiontable .partitions[] | select(.node == \"${IMG_ORIG}2\") .start ")

  ORIG_P2_SIZE=$(sfdisk --json $IMG_ORIG |
          jq ".partitiontable .partitions[] | select(.node == \"${IMG_ORIG}2\") .size ")

  echo ""
  pr_kv "ORIG_P1_START     :   ${ORIG_P1_START}"
  pr_kv "ORIG_P1_SIZE      :   ${ORIG_P1_SIZE}"
  pr_kv "ORIG_P2_START     :   ${ORIG_P1_START}"
  pr_kv "ORIG_P2_SIZE      :   ${ORIG_P2_SIZE}"
  echo ""

  ORIG_TOTAL_IMG_BYTES="$(stat --format=\"%s\" $IMG_ORIG)"

  pr_p "Total bytes for original image  is $(stat --format=\"%s\" $IMG_ORIG)"

}

# set the start and size of the 2 partitions in the slim image
# this might be the same as the source image
function get_partitions_for_slim(){

  pr_header "getting partition information for recovery source root image"
  pr_info "this is either a copy of the orig p2, or a slim p2, depending in i option"

  SLIM_P1_START=$(sfdisk --json $IMG_SLIM |
          jq ".partitiontable .partitions[] | select(.node == \"${IMG_SLIM}1\") .start ")

  SLIM_P1_SIZE=$(sfdisk --json $IMG_SLIM |
          jq ".partitiontable .partitions[] | select(.node == \"${IMG_SLIM}1\") .size ")

  SLIM_P2_START=$(sfdisk --json $IMG_SLIM|
          jq ".partitiontable .partitions[] | select(.node == \"${IMG_SLIM}2\") .start ")

  SLIM_P2_SIZE=$(sfdisk --json $IMG_SLIM |
          jq ".partitiontable .partitions[] | select(.node == \"${IMG_SLIM}2\") .size ")

  echo ""
  pr_kv "SLIM_P1_START     :   ${SLIM_P1_START}"
  pr_kv "SLIM_P1_SIZE      :   ${SLIM_P1_SIZE}"
  pr_kv "SLIM_P2_START     :   ${SLIM_P2_START}"
  pr_kv "SLIM_P2_SIZE      :   ${SLIM_P2_SIZE}"
  echo ""
  echo ""

  SLIM_TOTAL_IMG_BYTES="$(stat --format=\"%s\" $IMG_SLIM)"

  pr_info "Total bytes for slim image  is $(stat --format=\"%s\" $IMG_SLIM)"
  echo ""
}





# generate new UUIDs for the copy of the original image
function make_uuids(){

  pr_header "make UUID/partuuids for restore filesystems"

  echo ""

  # partuuid seems to get reset by resize.sh, however UUID doesn't seem to work
  set +o pipefail
  RESTORE_PTUUID_NEW=$(tr -dc 'a-f0-9' < /dev/urandom 2>/dev/null | head -c8)
  set -o pipefail

  [ ! -z ${RESTORE_PTUUID_NEW} ] || {
    echo "RESTORE_PTUUID_NEW is empty '${RESTORE_PTUUID_NEW}'" && exit 99
  }

  set +o pipefail
  COPY_PARTUUID_NEW=$(tr -dc 'a-f0-9' < /dev/urandom 2>/dev/null | head -c8)
  set -o pipefail

  [ ! -z ${COPY_PARTUUID_NEW} ] || { echo "COPY_PARTUUID_NEW is empty '${COPY_PARTUUID_NEW}'" && exit 99;  }

  # because of cloning the images, need to generate new UUIDs
  UUID_RESTORE=$(uuidgen)
  [ ! -z "$UUID_RESTORE" ] || { echo "UUID_RESTORE Empty: can't proceed"; exit 99; }
  UUID_ROOTFS=$(uuidgen)
  [ ! -z "$UUID_ROOTFS" ] || { echo "UUID_ROOTFS Empty: can't proceed"; exit 99; }
  UUID_COPY_ROOTFS=$(uuidgen)
  [ ! -z "$UUID_COPY_ROOTFS" ] || { echo "UUID_COPY_ROOTFS Empty: can't proceed"; exit 99; }

  pr_kv "RESTORE_PTUUID_NEW: ${RESTORE_PTUUID_NEW}"
  pr_kv "COPY_PARTUUID_NEW:  ${COPY_PARTUUID_NEW}"
  pr_kv "UUID_RESTORE:       ${UUID_RESTORE}"
  pr_kv "UUID_ROOTFS:        ${UUID_ROOTFS}"
  pr_kv "UUID_COPY_ROOTFS:   ${UUID_COPY_ROOTFS}"

  echo ""
  # step_pause
}

# make a copy of the original img file
# mounts the partitions from the new img onto loopback devices
#
function make_loop_and_mount_original(){

  pr_header "mount the original image readonly on loopback"

  LOOP_ORIG=$(losetup \
        --read-only \
        --nooverlap \
        --show \
        --find \
        --partscan \
           "${IMG_ORIG}")

  [ ! -z "$LOOP_ORIG" ] || { echo "LOOP_ORIG Empty: can't proceed"; exit 99; }

  echo "The Original img is mounted readonly at ${LOOP_ORIG}"
  partprobe ${LOOP_ORIG}
  echo ""

  blkid $LOOP_ORIG

  inspect_loop_device $LOOP_ORIG ORIG
  #  | pr_section "inspect loop device orig"

  step_pause
}

function make_loop_and_mount_copy(){

  pr_header "make img copy and mount it on loopback device"

  get_bytes_to_contain_partition ${ORIG_P2_START} ${ORIG_P2_SIZE}

  echo "calculated copy size is : $REPLY"
  echo "bytes from ORIG img is $ORIG_TOTAL_IMG_BYTES"

  [[ -f "${IMG_COPY}" ]] && \
  {
    pr_warn "IMG_COPY file ${IMG_COPY} already, exists - overwriting"
  } || \
  {
    pr_ok "restore file ${IMG_COPY} creating"
    # touch ${IMG_COPY}
  }

  pr_ok "writing zeros to $IMG_COPY"

  bytes_to_blocks $REPLY

  echo "writing $REPLY blocks of 8192"

  (
  dd if=/dev/zero bs=8192 count=${REPLY} > "${IMG_COPY}"
  ) | pr_quote

  # fdisk -l ${IMG_RESTORE}

  echo ""
  echo "writing partition table"


  tmpfile=$(mktemp /tmp/reset_sfdisk.XXXXXX)

cat << EOF > ${tmpfile}
label: dos
label-id: 0x${COPY_PARTUUID_NEW}
unit: sectors

${IMG_COPY}1 : start=${ORIG_P1_START},  size=${ORIG_P1_SIZE},  type=c
${IMG_COPY}2 : start=${ORIG_P2_START},  size=${ORIG_P2_SIZE},  type=83

EOF

  cat "$tmpfile" | pr_section "writing table"

  (
  sfdisk "${IMG_COPY}" < "$tmpfile" | pr_quote
  ) 2> >(pr_quote)

  # fdisk -lu ${IMG_COPY}

  echo "========= here ============"

  LOOP_COPY=$(losetup -v  --show -f -P ${IMG_COPY})

  [ ! -z "$LOOP_COPY" ] || { echo "LOOP_COPY Empty: can't proceed"; exit 99; }

  pr_ok "partprobe the new loopback device - ${LOOP_COPY}"
  partprobe ${LOOP_COPY}

  # pr_ok "show the partitions"
  # losetup -a

  step_pause

}


function copy_original_to_copy(){

  pr_header "copy the filesystem partitions to the copy img"

  dd if=${LOOP_ORIG}p1 of=${LOOP_COPY}p1 bs=4M
  dd if=${LOOP_ORIG}p2 of=${LOOP_COPY}p2 bs=4M

  # make sure the partitions on the loop device are available
  partprobe ${LOOP_COPY}

  pr_ok "3.6 call tunefs to set label and UUID"

  # echo $UUID_RESTORE
  # echo $LOOP_RESTORE

  # this is giving the copied root another UUID to prevent clash with orig
  {
    tune2fs ${LOOP_COPY}p2 -U ${UUID_COPY_ROOTFS}
  } | pr_section "setting the stuff"

  e2label ${LOOP_COPY}p2 copyroot

  pr_ok "call partprobe"
  partprobe ${LOOP_COPY}

  echo

  pr_h3 "file checking the rootfs on the copy"
  (
  e2fsck -f -n -v ${LOOP_COPY}p2 | pr_quote
   ) 2> >(pr_crit)


   echo

  pr_h3 "list partitions of LOOP_COPY"
  fdisk -l ${LOOP_COPY} | pr_quote



  pr_header "mount the img copy loopback device on mnt/copy_rootfs"

  mkdir -p mnt/copy_rootfs

  mount ${LOOP_COPY}p2 mnt/copy_rootfs

  pr_h3 "make a temporary copy of the fstab for later comparison"

  cp mnt/copy_rootfs/etc/fstab "${DIR_TMP}/tmp_fstab"

  echo ""


  inspect_loop_device $LOOP_COPY COPY
  # | pr_section "inspect loop device copy"

  step_pause

}


# doesn't wait for error message
function fix_resize_script(){

  pr_header "fix_resize_script"

  pr_ok "copy the custom init_resize.sh into copy_rootfs"

  cp "${RESIZE_SCRIPT_SOURCE}" "mnt/copy_rootfs${RESIZE_SCRIPT_TARGET}"
  chmod +x "mnt/copy_rootfs${RESIZE_SCRIPT_TARGET}"

  # cat "mnt/copy_rootfs${RESIZE_SCRIPT_TARGET}" | pr_quote

  sync

  step_pause
}

function output_zipped_copy_rootfs(){

  pr_header "output_zipped_copy_rootfs"

  pr_h2 "dd the copy p2 out to the recovery.img"

  dd bs=4M if=${LOOP_COPY}p2 of="${DIR_TMP}/recovery.img"

  pr_h2 "zip the recovery.img"

  if [ -f "${DIR_TMP}/recovery.img.zip" ] ; then
    rm "${DIR_TMP}/recovery.img.zip"
  fi

  ( cd "${DIR_TMP}" && zip "recovery.img.zip" "recovery.img" )

  # protect rootfs from further changes
  # umount mnt/copy_rootfs
  mount -o remount,ro mnt/copy_rootfs

  step_pause

}


# if the slim image option was not provided, this will just be the same as
# the original image, losetup will resuse that loop device
function make_loop_and_mount_slim(){

  pr_header "mount the slimversion of img readonly on loopback"

  pr_ok "show source image partition (from sfdisk --dump)"

  sfdisk -d "$IMG_SLIM" | pr_quote

  LOOP_SLIM=$(losetup \
        --read-only \
        --nooverlap \
        --show \
        --find \
        --partscan \
           ${IMG_SLIM})

  [ ! -z "$IMG_SLIM" ] || { echo "IMG_SLIM Empty: can't proceed"; exit 99; }

  echo "The Original SLIM img is mounted readonly at ${LOOP_SLIM}"
  partprobe ${LOOP_SLIM}
  echo ""

  UUID_BOOT_SLIM="$(blkid -s UUID -o value ${LOOP_SLIM}p1)"
  [ ! -z "$UUID_BOOT_SLIM" ] || { echo "UUID_BOOT Empty: can't proceed"; exit 99; }

  # cat /proc/partitions
  # losetup -a
  # blkid
  # echo ""


  mkdir -p mnt/slim_rootfs

  if mount | grep mnt/slim_rootfs > /dev/null 2>&1; then
    echo "already mounted"
  else
    mount -r ${LOOP_SLIM}p2 mnt/slim_rootfs
  fi


  inspect_loop_device $LOOP_SLIM SLIM

  step_pause

}

function get_recovery_root_part_size(){

  pr_header "get recovery root part size"

  pr_h3 "show the size in bytes of the slim rootfs"
  df -B1 mnt/slim_rootfs | column -t | pr_quote
  pr_h3 "show the size in human of the slim rootfs"
  df -h mnt/slim_rootfs | column -t | pr_quote
  echo ""

  SLIM_SIZE_BYTES=$(df -B1 --output=size,used,avail mnt/slim_rootfs | tail -1 | awk '{print $1}')
  SLIM_USED_BYTES=$(df -B1 --output=size,used,avail mnt/slim_rootfs | tail -1 | awk '{print $2}')
  SLIM_FREE_BYTES=$(df -B1 --output=size,used,avail mnt/slim_rootfs | tail -1 | awk '{print $3}')

  pr_kv "SLIM_SIZE_BYTES :   $SLIM_SIZE_BYTES"
  pr_kv "SLIM_USED_BYTES :    $SLIM_USED_BYTES"
  pr_kv "SLIM_FREE_BYTES :    $SLIM_FREE_BYTES"
  pr_kv "SLIM_USED_BYTES(MB) : $(( SLIM_USED_BYTES / ( 1024 * 1024 ) ))"
  echo ""

  RECOVERY_IMG_BYTES=$(stat --format="%s" "${DIR_TMP}/recovery.img.zip")

  pr_kv "RECOVERY_IMG_BYTES : $RECOVERY_IMG_BYTES"
  pr_kv "RECOVERY_IMG_BYTES(GB) : $(( RECOVERY_IMG_BYTES / ( 1024 * 1024 ) ))"
  echo ""

  # used, plus zipped, plus 150Mib of free space for whatever reason
  RESTORE_P2_REQUIRED_BYTES=$(( SLIM_USED_BYTES + RECOVERY_IMG_BYTES + PADDING_BYTES ))

  pr_kv "RESTORE_P2_REQUIRED_BYTES : $RESTORE_P2_REQUIRED_BYTES"
  pr_kv "RESTORE_P2_REQUIRED_BYTES(GB) : $(( RESTORE_P2_REQUIRED_BYTES / ( 1024 * 1024 ) ))"
  echo ""

  round_bytes_to_sectors $RESTORE_P2_REQUIRED_BYTES

  pr_ok "bytes rounded to sectors is $REPLY"
  echo ""

  RESTORE_P2_SIZE="${REPLY}"

  find_boundary $ORIG_P1_START $ORIG_P1_SIZE

  RESTORE_P2_START="${REPLY}"

  pr_kv "RESTORE_P2_START : $RESTORE_P2_START"
  pr_kv "RESTORE_P2_SIZE : $RESTORE_P2_SIZE"

  # pr_kv "RESTORE_P2_START : $RESTORE_P2_START"
  # pr_kv "RESTORE_P2_SIZE : $RESTORE_P2_SIZE"

  find_boundary $RESTORE_P2_START $RESTORE_P2_SIZE

  # these vals are used in the fdisk table input
  RESTORE_P3_START="${REPLY}"
  RESTORE_P3_SIZE="${ORIG_P2_SIZE}"

  pr_kv "RESTORE_P3_START : $RESTORE_P3_START"
  pr_kv "RESTORE_P3_SIZE : $RESTORE_P3_SIZE"

  step_pause
}


# the restore img is the file that contains the partitions that will
# ultimately get written out to the sdcard
function make_loop_and_mount_restore(){

  pr_header "make img restore and mount it"

  pr_h2 "need to find the total size of restore image for file zero-ing"

  find_boundary $RESTORE_P3_START $RESTORE_P3_SIZE
  pr_kv "P3_END : $REPLY"

  sectors_to_bytes $REPLY
  TOTAL_SIZE_BYTES=$REPLY


  # final sector of filesystem
  BLOCKSIZE=$(( 1024 * 1024 * 4 ))
  BSCOUNT=$(( TOTAL_SIZE_BYTES / BLOCKSIZE ))
  pr_kv "BSCOUNT: $BSCOUNT"




  if [ $(( TOTAL_SIZE_BYTES % BLOCKSIZE )) -ne 0 ]; then
    BSCOUNT=$(( BSCOUNT + 1 ))
  else
    #BSCOUNT=$(( TOTAL_SIZE_BYTES / BLOCKSIZE ))
    echo "BS COUNT remainder was zero"
  fi

  pr_kv "remainder : $(( TOTAL_SIZE_BYTES % BLOCKSIZE ))"
  pr_kv "BLOCKSIZE : $BLOCKSIZE"
  pr_kv "TOTAL SIZE BYTES : $TOTAL_SIZE_BYTES"
  pr_kv "BSCOUNT : $BSCOUNT"

  [[ -f "${IMG_RESTORE}" ]] && \
  {
    pr_warn "restore file ${IMG_RESTORE} already, exists - overwriting"
  } || \
  {
    pr_ok "restore file ${IMG_RESTORE} creating"
    # touch ${IMG_RESTORE}
  }

  [ $VERBOSITY -gt 2 ] && echo "========== dd'ing zero to restore img file"
  dd if=/dev/zero bs=4M count=${BSCOUNT} > ${IMG_RESTORE}
  [ $VERBOSITY -gt 2 ] && echo "========== END dd'ing zero to restore img file"


  tmpfile=$(mktemp /tmp/reset_sfdisk.XXXXXX)

cat << EOF > ${tmpfile}
label: dos
label-id: 0x${RESTORE_PTUUID_NEW}
unit: sectors

${IMG_RESTORE}1 : start=${ORIG_P1_START},     size=${ORIG_P1_SIZE},     type=c
${IMG_RESTORE}2 : start=${RESTORE_P2_START},  size=${RESTORE_P2_SIZE},  type=83
${IMG_RESTORE}3 : start=${RESTORE_P3_START},  size=${RESTORE_P3_SIZE},  type=83

EOF

cat $tmpfile | pr_quote

  # fdisk -l ${IMG_RESTORE}

  [ $VERBOSITY -gt 2 ] && echo "========== writing partition table to IMG_RESTORE"
  sfdisk ${IMG_RESTORE} < "$tmpfile" | pr_quote
  [ $VERBOSITY -gt 2 ] && echo "========== END writing partition table to IMG_RESTORE"

  [ $VERBOSITY -gt 2 ] && echo "========== START dumping file containing new partition table ==="
  [ $VERBOSITY -gt 2 ] &&  cat "$tmpfile" | pr_quote
  [ $VERBOSITY -gt 2 ] && echo "========== END dumping file containing new partition table ==="


  [ $VERBOSITY -gt 2 ] && echo "========== START ================"
  [ $VERBOSITY -gt 2 ] && fdisk -lu ${IMG_RESTORE}  | pr_quote
  [ $VERBOSITY -gt 2 ] && echo "========== END ========="


  blkid ${IMG_RESTORE}  | pr_hl

  LOOP_RESTORE=$(losetup -v  --show -f -P ${IMG_RESTORE})
  [ ! -z "$LOOP_RESTORE" ] || { echo "LOOP_RESTORE Empty: can't proceed"; exit 99; }

  pr_ok "partprobe the new loopback device - ${LOOP_RESTORE}"
  partprobe ${LOOP_RESTORE}

  # pr_ok "show the partitions"
  # losetup -a

  step_pause

}

# populate the partitions of the restore image with the sources
# the boot partition comes straight from the original
# the recovery partition (p2) comes from the slim version, which might be
# the same as the original partition, if it wasn't provided
# the root is the modified copy of the rootfs partition
function copy_to_restore(){

  pr_header "3.4 copy the filesystem partitions to the restore img"

  dd if=${LOOP_ORIG}p1        of=${LOOP_RESTORE}p1    bs=4M
  dd if=${LOOP_SLIM}p2        of=${LOOP_RESTORE}p2    bs=4M
  dd if=${LOOP_COPY}p2        of=${LOOP_RESTORE}p3    bs=4M

  # make sure the partitions on the loop device are available
  partprobe ${LOOP_RESTORE}

  pr_ok "3.6 call tunefs to set label and UUID"

  # echo $UUID_RESTORE
  # echo $LOOP_RESTORE

  # reset the UUID to avoid clash with the source partition
  tune2fs ${LOOP_RESTORE}p2 -U ${UUID_RESTORE}
  e2label ${LOOP_RESTORE}p2 recoveryfs

  # reset UUID
  tune2fs ${LOOP_RESTORE}p3 -U ${UUID_ROOTFS}
  e2label ${LOOP_RESTORE}p3 rootfs

  pr_ok "3.7 call partprobe"
  partprobe ${LOOP_RESTORE}

  pr_ok "3.8 resize the fs on the recovery partition to fit the restore img"

  e2fsck -f -n -v ${LOOP_RESTORE}p2 | pr_quote

  echo ""
  pr_kv "SLIM_SIZE_BYTES :   $SLIM_SIZE_BYTES"
  pr_kv "SLIM_USED_BYTES :   $SLIM_USED_BYTES"
  pr_kv "SLIM_FREE_BYTES :   $SLIM_FREE_BYTES"
  pr_kv "SLIM_USED_BYTES(GB) : $(( SLIM_USED_BYTES / ( 1024 * 1024 ) ))"
  echo ""
  # RESTORE_P2_REQUIRED_BYTES=$(( SLIM_USED_BYTES + RECOVERY_IMG_BYTES + 152428800 ))

  pr_kv "RESTORE_P2_REQUIRED_BYTES : $RESTORE_P2_REQUIRED_BYTES"
  pr_kv "RESTORE_P2_REQUIRED_BYTES(GB) : $(( RESTORE_P2_REQUIRED_BYTES / ( 1024 * 1024 ) ))"
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

  fdisk -l ${LOOP_RESTORE} | pr_quote

  mkdir -p mnt/restore_boot
  mkdir -p mnt/restore_recovery
  mkdir -p mnt/restore_rootfs

  mount ${LOOP_RESTORE}p1 mnt/restore_boot
  mount ${LOOP_RESTORE}p2 mnt/restore_recovery
  mount ${LOOP_RESTORE}p3 mnt/restore_rootfs

  blkid ${LOOP_RESTORE} | pr_hl
  blkid ${LOOP_RESTORE}p1 | pr_hl

  inspect_loop_device $LOOP_RESTORE RESTORE

  step_pause

}

function fixup_fstab_in_recovery_rootfs(){

  pr_debug "existing  mnt/restore_rootfs/etc/fstab"
  echo ">>>>>"
  cat mnt/restore_rootfs/etc/fstab
  echo "<<<<<"

  fixup_fstab  mnt/restore_rootfs/etc/fstab \
      "${RESTORE_PARTUUID_BOOT}"  \
      "${RESTORE_UUID_BOOT}" \
      "${RESTORE_PARTUUID_ROOT}" \
      "${RESTORE_UUID_ROOT}"

  cat mnt/restore_rootfs/etc/fstab

}

function overwrite_cmdline_for_boot(){

  pr_header "current boot cmdline.txt"

  #if [ $VERBOSITY -gt 3 ] ; then
    pr_ok "current cmdline.txt is"
    cat mnt/restore_boot/cmdline.txt
  #fi

  pr_ok "saving original cmdline.txt"
  cp mnt/restore_boot/cmdline.txt mnt/restore_boot/cmdline.txt_from_pristine

  pr_ok "edit the cmdline.txt to point to the partition-3"

  if grep 'root=PARTUUID' mnt/restore_boot/cmdline.txt; then
    sed -i -E "s|(root=PARTUUID)=([^[:space:]]+)|root=PARTUUID=$RESTORE_PARTUUID_ROOT|" mnt/restore_boot/cmdline.txt
  elif grep 'root=UUID' mnt/restore_boot/cmdline.txt; then
    sed -i -E "s|(root=UUID)=([^[:space:]]+)|root=UUID=$RESTORE_BOOT_UUID|" mnt/restore_boot/cmdline.txt
  else
    echo "unable to find UUID or PARTUUID in cmdline.txt"
    echo "current cmdline.txt is"
    cat mnt/restore_boot/cmdline.txt
    exit 99
  fi

  pr_ok "cmdline.txt after is"
  cat mnt/restore_boot/cmdline.txt

  step_pause

}


function make_restore_script(){
#   ___        _               ___         _      _
#  | _ \___ __| |_ ___ _ _ ___/ __| __ _ _(_)_ __| |_
#  |   / -_|_-<  _/ _ \ '_/ -_)__ \/ _| '_| | '_ \  _|
#  |_|_\___/__/\__\___/_| \___|___/\__|_| |_| .__/\__|
#                                           |_|

  pr_header "create factory reset script in /boot directory"

  cp factory_reset mnt/restore_boot/factory_reset

  chmod +x mnt/restore_boot/factory_reset

  pr_ok "copy init_restore.sh to recovery"
  cp "${RECOVERY_SCRIPT_SOURCE}" "mnt/restore_recovery${RECOVERY_SCRIPT_TARGET}"
  chmod +x "mnt/restore_recovery${RECOVERY_SCRIPT_TARGET}"

  pr_ok "enable ssh on the image"
  touch mnt/restore_boot/ssh

  step_pause
}


function make_recovery_script(){

  pr_header "current recovery fstab"
  cat mnt/restore_recovery/etc/fstab | column -t | pr_quote

  pr_ok "indicate this is a recovery shell"

# not sure this is getting used on the console...?
tee mnt/restore_recovery/etc/motd << EOF
##     ____  _____ ____ _____     _______ ______   __
##    |  _ \| ____/ ___/ _ \ \   / / ____|  _ \ \ / /
##    | |_) |  _|| |  | | | \ \ / /|  _| | |_) \ V /
##    |  _ <| |__| |__| |_| |\ V / | |___|  _ < | |
##    |_| \_\_____\____\___/  \_/  |_____|_| \_\|_|
##
EOF

  pr_debug "existing  mnt/restore_recovery/etc/fstab"
  echo ">>>>>"
  cat mnt/restore_recovery/etc/fstab
  echo "<<<<<"



  fixup_fstab  mnt/restore_recovery/etc/fstab \
      "${RESTORE_PARTUUID_BOOT}"  \
      "${ORIG_UUID_BOOT}" \
      "${RESTORE_PARTUUID_RESTORE}" \
      "${RESTORE_UUID_RESTORE}"

  cat mnt/restore_recovery/etc/fstab

  pr_ok "copy the recovery image to the recovery /opt dir for restoring"

  sync

  #dd if=${LOOP_RESTORE}p3 of=mnt/restore_recovery/opt/recovery.img bs=4M
  cp "${DIR_TMP}/recovery.img.zip" mnt/restore_recovery/opt/recovery.img.zip

  # | zip mnt/restore_recovery/opt/recovery.img.zip -

}


function get_postbuild_summary(){

  pr_header "get_postbuild_summary"

  inspect_loop_device $LOOP_RESTORE FINAL

  pr_h2 "/boot/cmdline.txt from source image"
  cat mnt/restore_boot/cmdline.txt_from_pristine
  echo ""

  pr_h2 "/etc/fstab from source image"
  cat "${DIR_TMP}/tmp_fstab" | egrep -v '^#|^$' | column -t | pr_quote
  echo ""

  pr_h2 "/etc/fstab for recovery partition"
  cat mnt/restore_recovery/etc/fstab  | egrep -v '^#|^$' | column -t | pr_quote
  echo ""

  pr_h2 "/etc/fstab for root partition"
  cat mnt/restore_rootfs/etc/fstab  | egrep -v '^#|^$' | column -t | pr_quote
  echo ""

  pr_h2 "/boot/cmdline.txt for restore image"
  cat mnt/restore_boot/cmdline.txt
  echo ""

  pr_h2 "show filesystem size/used/free - recovery"
  df mnt/restore_recovery
  df -h mnt/restore_recovery
  pr_h2 "show filesystem size/used/free - rootfs"
  df mnt/restore_rootfs
  df -h mnt/restore_rootfs

}
