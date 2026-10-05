//go:build linux

package collect

import "syscall"

// statfs returns total size, free blocks (including root-reserved ones) and
// space available to unprivileged users, all in bytes.
func statfs(path string) (total, free, avail uint64, err error) {
	var st syscall.Statfs_t
	if err := syscall.Statfs(path, &st); err != nil {
		return 0, 0, 0, err
	}
	bs := uint64(st.Bsize)
	return st.Blocks * bs, st.Bfree * bs, st.Bavail * bs, nil
}
