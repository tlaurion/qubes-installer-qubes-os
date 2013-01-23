#!/bin/bash

command -v unpack_img >/dev/null || . /lib/img-lib.sh

# config_get SECTION KEY < FILE
# read an .ini-style config file, find the KEY in the given SECTION, and return
# the value provided for that key.
# ex: product=$(config_get Main Product < /.buildstamp)
config_get() {
    local section="$1" key="$2" cursec="" k="" v=""
    while read line; do
        case "$line" in
            \#*) continue ;;
            \[*\]*) cursec="${line#[}"; cursec="${cursec%%]*}" ;;
            *=*) k=$(echo ${line%%=*}); v=$(echo ${line#*=}) ;;
        esac
        if [ "$cursec" = "$section" ] && [ "$k" == "$key" ]; then
            echo $v
            break
        fi
    done
}

find_iso() {
    local f="" iso="" isodir="$1" tmpmnt=$(mkuniqdir /run/install tmpmnt)
    for f in $isodir/*.iso; do
        [ -e $f ] || continue
        mount -o loop,ro $f $tmpmnt || continue
        [ -e $tmpmnt/.discinfo ] && iso=$f
        umount $tmpmnt
        if [ "$iso" ]; then echo "$iso"; return 0; fi
    done
    return 1
}

find_runtime() {
    [ -f "$1" ] && [ "${1%.iso}" == "$1" ] && echo "$1" && return
    local ti_img="" dir="$1"
    [ -e $dir/.treeinfo ] && \
        ti_img=$(config_get stage2 mainimage < $dir/.treeinfo)
    for f in $ti_img images/install.img LiveOS/squashfs.img; do
        [ -e "$dir/$f" ] && echo "$dir/$f" && return
    done
}

repodir="/run/install/repo"
isodir="/run/install/isodir"
rulesfile="/etc/udev/rules.d/90-anaconda.rules"

# try to find a usable runtime image from the repo mounted at $mnt.
# if successful, move the mount(s) to $repodir/$isodir.
anaconda_live_root_dir() {
    local img="" iso="" srcdir="" mnt="$1" path="$2"; shift 2
    img=$(find_runtime $mnt/$path)
    if [ -n "$img" ]; then
        info "anaconda: found $img"
        [ "$mnt" = "$repodir" ] || { mount --make-rprivate /; mount --move $mnt $isodir; }
        anaconda_auto_updates $repodir/$path/images
    else
        if [ "${path%.iso}" != "$path" ]; then
            iso=$path
            path=${path%/*.iso}
        else
            iso=$(find_iso $mnt/$path)
        fi
        [ -n "$iso" ] || { warn "no suitable images"; return 1; }
        info "anaconda: found $iso"
        mount --make-rprivate /
        mount --move $mnt $isodir
        iso=${isodir}/${iso#$mnt}
        mount -o loop,ro $iso $repodir
        img=$(find_runtime $repodir) || { warn "$iso has no suitable runtime"; }
        anaconda_auto_updates $isodir/$path/images
    fi
    # FIXME: make rd.live.ram clever enough to do this for us
    if [ "$1" = "--copy-to-ram" ]; then
        echo "Copying installer image to RAM..."
        echo "(this may take a few minutes)"
        cp $img /run/install/install.img
        img=/run/install/install.img
        umount $repodir
        [ -n "$iso" ] && umount $isodir
    fi
    [ -e "$img" ] && /sbin/dmsquash-live-root $img
}

# find updates.img/product.img/RHUpdates and unpack/copy them so they'll
# end up in the location(s) that anaconda expects them
anaconda_auto_updates() {
    local dir="$1"
    if [ -d $dir/RHupdates ]; then
        copytree $dir/RHupdates /updates
    fi
    if [ -e $dir/updates.img ]; then
        unpack_updates_img $dir/updates.img /updates
    fi
    if [ -e $dir/product.img ]; then
        unpack_updates_img $dir/product.img /updates/tmp/product
    fi
}

# Unpack an image into the given dir.
unpack_updates_img() {
    local img="$1" tmpdir="/tmp/${1##*/}.$$" outdir="${2:+/updates}"
    # NOTE: unpack_img $img $outdir can clobber existing subdirs in $outdir,
    # which is why we use a tmpdir and copytree (which doesn't clobber)
    unpack_img $img $tmpdir
    copytree $tmpdir $outdir
    rm -rf $tmpdir
}

# These could probably be in dracut-lib or similar

copytree() {
    local src="$1" dest="$2"
    mkdir -p "$dest"; dest=$(readlink -f -q "$dest")
    ( cd "$src"; cp -a . -t "$dest" )
}

disk_to_dev_path() {
    case "$1" in
        CDLABEL=*|LABEL=*) echo "/dev/disk/by-label/${1#*LABEL=}" ;;
        UUID=*) echo "/dev/disk/by-uuid/${1#UUID=}" ;;
        /dev/*) echo "$1" ;;
        *) echo "/dev/$1" ;;
    esac
}

find_mount() {
    local dev mnt etc wanted_dev="$(readlink -e -q $1)"
    while read dev mnt etc; do
        [ "$dev" = "$wanted_dev" ] && echo $mnt && return 0
    done < /proc/mounts
    return 1
}

when_diskdev_appears() {
    local dev="${1#/dev/}" cmd=""; shift
    cmd="/sbin/initqueue --settled --onetime --name $1 $*"
    {
        printf 'SUBSYSTEM=="block", KERNEL=="%s", RUN+="%s"\n' "$dev" "$cmd"
        printf 'SUBSYSTEM=="block", SYMLINK=="%s", RUN+="%s"\n' "$dev" "$cmd"
    } >> $rulesfile
}

# dracut doesn't bring up the network unless:
#   a) $netroot is set (i.e. you have a network root device), or
#   b) /tmp/net.ifaces exists.
# So for non-root things that need the network (like kickstart) we need to
# make sure /tmp/net.ifaces exists.
# For details see 40network/net-genrules.sh (and the rest of 40network).
set_neednet() {
    # if there's no netroot, make sure /tmp/net.ifaces exists
    [ -z "$netroot" ] && >> /tmp/net.ifaces
}

parse_kickstart() {
    /sbin/parse-kickstart $1 > /etc/cmdline.d/80-kickstart.conf
    unset CMDLINE  # re-read the commandline
    . /tmp/ks.info # save the parsed kickstart
    [ -e "$parsed_kickstart" ] && cp $parsed_kickstart /run/install/ks.cfg
}

# This is where we actually run the kickstart. Whee!
# We can't just add udev rules (we'll miss devices that are already active),
# and we can't just run the scripts manually (we'll miss devices that aren't
# yet active - think driver disks!).
#
# So: we have to write out the rules and then retrigger them.
#
# Really what we want to do here is just start over from the "cmdline"
# phase, but since we can't do that, we'll kind of fake it.
#
# XXX THIS IS KIND OF A GROSS HACK AND WE NEED A BETTER WAY TO DO IT
run_kickstart() {
    local do_disk="" do_net=""

    # kickstart's done - time to find a real root device
    [ "$root" = "anaconda-kickstart" ] && root=""

    # don't look for the kickstart again
    kickstart=""

    # re-parse new cmdline stuff from the kickstart
    . $hookdir/cmdline/*parse-anaconda-repo.sh
    # TODO: parse for other stuff ks might set (updates, dd, etc.)
    case "$repotype" in
        http*|ftp|nfs*) do_net=1 ;;
        cdrom|hd|bd)    do_disk=1 ;;
    esac
    [ "$root" = "anaconda-auto-cd" ] && do_disk=1

    # replay udev events to trigger actions
    if [ "$do_disk" ]; then
        . $hookdir/pre-udev/*repo-genrules.sh
        udevadm control --reload
        udevadm trigger --action=change --subsystem-match=block
    fi
    if [ "$do_net" ]; then
        udevadm trigger --action=online --subsystem-match=net
    fi

    # and that's it - we're back to the mainloop.
    > /tmp/ks.cfg.done # let wait_for_kickstart know that we're done.
}

wait_for_kickstart() {
    echo "[ -e /tmp/ks.cfg.done ]" > $hookdir/initqueue/finished/kickstart.sh
}

wait_for_updates() {
    echo "[ -e /tmp/liveupdates.done ]" > $hookdir/initqueue/finished/updates.sh
}
