package collect

import (
	"bufio"
	"os"
	"strings"
)

// realFS lists filesystem types worth reporting; pseudo filesystems
// (proc, tmpfs, overlay, squashfs snaps, ...) are skipped.
var realFS = map[string]bool{
	"ext2": true, "ext3": true, "ext4": true, "xfs": true, "btrfs": true,
	"zfs": true, "vfat": true, "f2fs": true, "jfs": true, "reiserfs": true,
}

type mount struct{ device, point, fstype string }

func readMounts(path string) ([]mount, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()

	seen := map[string]bool{}
	var out []mount
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		fields := strings.Fields(sc.Text())
		if len(fields) < 3 || !realFS[fields[2]] {
			continue
		}
		// The same device can be bind-mounted many times; report it once.
		if seen[fields[0]] {
			continue
		}
		seen[fields[0]] = true
		out = append(out, mount{device: fields[0], point: unescapeMount(fields[1]), fstype: fields[2]})
	}
	return out, sc.Err()
}

// unescapeMount decodes the octal escapes /proc/mounts uses for spaces etc.
func unescapeMount(s string) string {
	r := strings.NewReplacer(`\040`, " ", `\011`, "\t", `\012`, "\n", `\134`, `\`)
	return r.Replace(s)
}

func readDisks(mountsPath string) ([]Disk, error) {
	mounts, err := readMounts(mountsPath)
	if err != nil {
		return nil, err
	}
	disks := make([]Disk, 0, len(mounts))
	for _, m := range mounts {
		total, free, avail, err := statfs(m.point)
		if err != nil || total == 0 {
			continue
		}
		disks = append(disks, Disk{
			Mount:       m.point,
			Device:      m.device,
			FSType:      m.fstype,
			TotalBytes:  total,
			FreeBytes:   avail,
			UsedPercent: usedPercent(total, free, avail),
		})
	}
	return disks, nil
}

// usedPercent matches df's Use%: used / (used + available to users), so the
// root-reserved blocks don't count as free space.
func usedPercent(total, free, avail uint64) float64 {
	used := total - min(free, total)
	if used+avail == 0 {
		return 0
	}
	return round2(100 * float64(used) / float64(used+avail))
}
