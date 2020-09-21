#!/bin/bash

mkluks() {
    local disk="${1:?first arg must be the disk}"
    local label="${2:?second arg must be the label for the disk}"
    local keyf="/run/${label}.key"

    keyf="/run/${label}.key"
    printf "%s%s" "$(pwmake 128)" "$(pwmake 128)" > "${keyf}"

    # create the uuid
    uuid=$(uuidgen)

    # format the disk
    cryptsetup luksFormat \
        -q \
        --pbkdf argon2i \
        --pbkdf-memory 524288 \
        --type luks2 \
        --tries=1 \
        --uuid="${uuid}" \
        --label="luks_${label}" \
        --key-file="${keyf}" "${disk}"

    udevadm trigger -w

    # bind to clevis
    clevis-luks-bind -d "/dev/disk/by-uuid/${uuid}" -k "${keyf}" sss "$(< /etc/clevis.json)"

    # whomp on the key
    cryptsetup luksKillSlot "/dev/disk/by-uuid/${uuid}"  0 -q

    # add the automatic unloc
    local raid_label="$(basename ${disk})"
    systemctl enable --now "clevis-unlock@${raid_label}.service"

    # create the file system
    mkfs.xfs "/dev/mapper/${raid_label}" -L "${label}"
}

mkscript() {
    (cat <<EOM
#!//bin/bash
set -xeu pipefail
modprobe -a dm_crypt loop

mkluks() $(type mkluks >&1 | tail -n +3)

run() {
    mkluks /dev/md/vlc-raid0 containers
    mkluks /dev/md/data-raid1 data
    udevadm trigger --settle
    rpm-ostree kargs --append=ip=dhcp --append=rd.neednet=1 --append=luks=yes
}
EOM
) | base64 -w0
}

mkmount() {
    cat <<EOM
        - name: $(systemd-escape --suffix=mount "${1}")
          enabled: true
          contents: |-
            [Unit]
            After=systemd-fsck@$(systemd-escape --suffix=device dev/mapper/${2})
            Requires=systemd-fsck@$(systemd-escape --suffix=device data/mapper/${2})
            After=prepare-disks.service

            [Install]
            WantedBy=remote-fs.target

            [Mount]
            Options=_netdev
            What=/dev/mapper/${2}
            Where=/${1}
            Type=xfs
            TimeoutSec=1800
EOM
}

mkclevis(){
    (cat <<EOM
{
  "t": 1,
  "pins": {
    "tang": [
      {
        "url": "https://tanger-rhcos-devel.svc.ci.openshift.org",
        "thp": "nt95BWah3yCktUUJC4_VVW0q7Jk"
      }
    ]
  }
}
EOM
) | jq -cM "."  | base64 -w0
}

mklogin() {
    cat <<"EOM"
        - name: serial-getty@ttyS0.service
          dropins:
          - name: autologin-core.conf
            contents: |-
                [Service]
                # Override Execstart in main unit
                ExecStart=
                # Add new Execstart with `-` prefix to ignore failure
                ExecStart=-/usr/sbin/agetty --autologin core --noclear %I $TERM
                TTYVTDisallocate=no
EOM
}

mkign() {
    cat <<END
    ---
    variant: fcos
    version: 1.0.0
END
}

mkunits() {
    cat <<END
    systemd:
      units:
END
    if [ "${1:-}" == "autologin" ]; then
    cat <<END
$(mklogin)
END
    fi
cat <<END
        - name: clevis-unlock@.service
          enabled: false
          contents: |-
            [Unit]
            Description=Clevis unlock for /dev/md/%i
            Wants=network.target NetworkManager.service NetworkManager-wait-online.service
            After=network.target NetworkManager.service NetworkManager-wait-online.service
            Before=remote-fs.target
            BindsTo=%i.device

            [Service]
            Type=oneshot
            RemainAfterExit=yes
            ExecStart=/bin/clevis-luks-unlock -d /dev/md/%i -n %i

            [Install]
            WantedBy=remote-fs.target

        - name: prepare-disks.service
          enabled: true
          contents: |-
            [Unit]
            Description=Prepare LUKS Volumes
            ConditionKernelCommandLine=ignition.firstboot

            Before=systemd-logind.service getty.target
            Before=cri-o.service kublet.service multi-user.target
            After=basic.target socket.target dbus.service

            Wants=network.target NetworkManager.service NetworkManager-wait-online.service
            After=network.target NetworkManager.service NetworkManager-wait-online.service

            [Service]
            Type=oneshot
            TimeoutSec=1800
            RemainAfterExit=yes
            # systemd is picky about allowing scripts to run
            ExecStart=/bin/bash -c "source /root/make-disks.sh; run;"
            ExecStart=/usr/bin/touch /root/data.done

            [Install]
            WantedBy=remote-fs.target
$(mkmount var/lib/containers vlc-raid0)
$(mkmount var/opt/data data-raid1)
    storage:
      directories:
        # mount path for data volume
        -  path: /var/opt/data
           overwrite: true
      files:
        - path: /root/make-disks.sh
          filesystem: root
          mode: 755
          contents:
            source: >-
              data:text/plain;base64,$(mkscript)
        - path: /etc/clevis.json
          filesystem: root
          mode: 420
          contents:
            source: >-
              data:text/plain;base64,$(mkclevis)
END
}

mkmco()  {
    cat <<END
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  name: 99-disk-encryption
  labels:
    machineconfiguration.openshift.io/role: worker
spec:
  kernelArguments:
    - "ip=dhcp"
    - "rd.neednet=1"
    - "luks=yes"
  config:
    ignition:
      version: 2.2.0
END
}


case ${1:-mco} in
    mco) mkmco; mkunits;;
    ign) (mkign; mkunits autologin) | sed -e "s/^    //g";
esac
