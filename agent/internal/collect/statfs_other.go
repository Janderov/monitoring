//go:build !linux

package collect

import "errors"

// The agent only runs on Linux; this stub keeps the package building on a Mac.
func statfs(string) (uint64, uint64, uint64, error) {
	return 0, 0, 0, errors.New("statfs: linux only")
}
