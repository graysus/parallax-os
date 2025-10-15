#!/usr/bin/env bash

info() {
	echo -e "  \x1b[94m(i) \x1b[97m$*\x1b[0m"
}

err() {
	echo -e "  \x1b[91m!!! \x1b[97m$*\x1b[0m"
}

cleanup() {
	[ -z "$(tr -d / <<< "$BUILD")" ] && return true

	for i in "${FILESYSTEMS[@]}"; do
		umount "$BUILD/$i"
	done

	rm -rf "$BUILD"
	
	[ -n "$OUTTAR" ] && rm -rf "$OUTTAR"
	[ -n "$OUTTAR" ] && rm -rf "$OUTTAR"	
}

fail() {
	err "$@"

	cleanup
	exit 1
}

if [ "${#@}" -ne 1 ]; then
	for i in "$@"; do
		"$0" "$i" || fail "One of the builds failed!"
	done
	exit 0
fi

PROFILE="$1"
declare -A APROFILES
PROFILES=("$PROFILE")
APROFILES["$PROFILE"]=1

any_added=1
while (( any_added )); do
	any_added=0
	for pf in "${PROFILES[@]}"; do
		if [ ! -f "profiles/$pf/meta" ]; then
			continue
		fi
		declare -a DEPS
		source "profiles/$pf/meta"
		for dep in "${DEPS[@]}"; do
			if (( APROFILES["$dep"] )); then
				continue
			fi
			PROFILES=("$dep" "${PROFILES[@]}")
			APROFILES["$dep"]=1
			any_added=1
		done
	done
done

VERSION="$(source "profiles/$PROFILE/os-release" && echo "$BUILD_ID")"

[ "$EUID" -ne 0 ] && {
	echo "Must be root!"
	exit 1
}
if [ "$1" = "debug" ]; then
	DEBUG=1
fi

FILESYSTEMS=(proc sys tmp run dev)

declare -a PACKAGES

for i in "${PROFILES[@]}"; do
	while read -ra PKGLINE; do
		PACKAGES+=("${PKGLINE[@]}")
	done < <(sed -e '/#.*/d' "profiles/$i/packages")
done

BUILD="$(mktemp -dp /var/tmp)"

[ -d "/var/tmp/pxos-build/" ] && rm -rf "/var/tmp/pxos-build/"
mkdir "/var/tmp/pxos-build/"
cp -a built-pkgs "/var/tmp/pxos-build/pkgs"

# make sure we aren't overwriting root here...
[ -z "$(tr -d / <<< "$BUILD")" ] && fail "Build directly was not set properly."


info "Preparing build directory..."
[ -d "$BUILD" ] && rm -rf "$BUILD"

mkdir "$BUILD"

for i in "${FILESYSTEMS[@]}"; do
	mkdir "$BUILD/$i"
	mount --bind "/$i" "$BUILD/$i"
done

mkdir --parents "$BUILD/var/lib/pacman" "$BUILD/etc" "$BUILD/data" "$BUILD/etc/sddm.conf.d" \
	|| fail "Failed to make directories!"

info "Installing packages from package list..."
pacman -Sy -b "$BUILD/var/lib/pacman" -r "$BUILD" --config ./pacman.conf --noconfirm $(cat pacman-flags.txt) -- "${PACKAGES[@]}" \
	|| fail "Failed to install packages!"

info "Copying new files..."
echo -e "-session\toptional\tpam_pxpam.so" >> "$BUILD/etc/pam.d/system-login"

cp "profiles/$PROFILE/os-release" "$BUILD/usr/lib/os-release" || die "Failed to copy OS release!"

for i in "${PROFILES[@]}"; do
	[ ! -f "profiles/$i/prepare" ] && continue
	pushd "profiles/$i"
	source "./prepare"
	popd
done
for i in "${PROFILES[@]}"; do
	[ ! -d "profiles/$i/licenses" ] && continue
	pushd "profiles/$i"
	cp licenses/* "$BUILD/usr/share/licenses/"
	popd
done

rm "$BUILD/boot/initramfs-"* &&\
rm -rf "$BUILD/usr/share/pixmaps/artixlinux-logo"* \
	|| fail "Failed to remove some files!"

echo "$VERSION" > "$BUILD/usr/lib/parallaxos-version"

if (( DEBUG )); then
	cp locale.gen.debug "$BUILD/etc/locale.gen"
else
	cp locale.gen "$BUILD/etc/locale.gen"
fi
echo parallaxos > "$BUILD/etc/hostname"

info "Generating locales..."
chroot "$BUILD" bash <<EOF
locale-gen
EOF
if [ $? -ne 0 ]; then
	fail "Failed to generate locales!"
fi

info "Applying finishing touches..."

for i in "${PROFILES[@]}"; do
	[ ! -f "profiles/$i/finalize" ] && continue
	pushd "profiles/$i"
	source "./finalize"
	popd
done

for i in "${FILESYSTEMS[@]}"; do
	umount "$BUILD/$i"
done

mkdir "$BUILD/boot" "$BUILD/mnt"
rm -rf "$BUILD/var/lib/pacman"
mv "$BUILD/sbin/openrc-init" "$BUILD/sbin/init"

mv "$BUILD/boot" "$BUILD/boot.def"
mv "$BUILD/etc" "$BUILD/etc.def"
mv "$BUILD/var" "$BUILD/var.def"

info "Packing image..."
mkdir --parents "out/$PROFILE"
OUTTAR=out/"$PROFILE"/pxos-"$VERSION".img
tar cf "$OUTTAR" --xattrs-include=\* -C "$BUILD" . --zstd

info "Cleaning up..."
rm -rf "$BUILD"

info "Done!"
