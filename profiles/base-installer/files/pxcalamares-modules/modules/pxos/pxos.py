
import libcalamares
import os
import subprocess

def run():
    # create /data/partitions (imperative)
    root = libcalamares.globalstorage.value("rootMountPoint")

    assert os.system(f"mountpoint {root}") == 0

    parts: list[dict[str, object]] = libcalamares.globalstorage.value("partitions")
    devByLabel: dict[str, str] = {}
    for i in parts:
        val = i.get("device", "")
        if val:
            with subprocess.Popen(("blkid", val, "-s", "UUID" "-o" "value"),
                                  stdout=subprocess.PIPE) as p:
                curuuid = p.stdout.read().decode()
                if curuuid:
                    val = f"UUID={curuuid}"
        devByLabel[i.get("partlabel", "")] = val

    root1, root2, data = devByLabel["rootfs"], devByLabel["rootfs2"], devByLabel["data"]
    assert root1 and root2 and data

    with open(os.path.join(root, "data/partitions"), "w") as f:
        f.write(f"ROOT1={root1}\n")
        f.write(f"ROOT2={root2}\n")
        f.write(f"DATA={data}\n")
        f.write(f"CURRENT=1")

    # then, install the packages
    os.putenv("SERVER", "http://192.168.122.1:8000/pxos-repo")
    os.putenv("BRANCH", "VERSION")
    os.putenv("TIMEZONE", "n")
    assert os.system(f"pxos-install {root}") == 0

