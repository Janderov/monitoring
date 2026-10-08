package docker

import (
	"bytes"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
)

// maxExecOutput bounds how much command output is read back.
const maxExecOutput = 4 << 20

// Exec runs cmd inside a running container and returns its stdout. It is used
// only for read-only commands (`wg show`, `cat`); a non-zero exit is an error.
func (c *Client) Exec(container string, cmd ...string) ([]byte, error) {
	var created struct {
		ID string `json:"Id"`
	}
	err := c.postJSON("/containers/"+url.PathEscape(container)+"/exec", map[string]any{
		"AttachStdout": true,
		"AttachStderr": true,
		"Cmd":          cmd,
	}, &created)
	if err != nil {
		return nil, err
	}

	resp, err := c.post("/exec/"+created.ID+"/start", map[string]any{"Detach": false, "Tty": false})
	if err != nil {
		return nil, err
	}
	stdout, stderr, err := demux(io.LimitReader(resp.Body, maxExecOutput))
	resp.Body.Close()
	if err != nil {
		return nil, err
	}

	var info struct{ ExitCode int }
	if err := c.getJSON("/exec/"+created.ID+"/json", &info); err != nil {
		return nil, err
	}
	if info.ExitCode != 0 {
		msg := bytes.TrimSpace(stderr)
		if len(msg) > 200 {
			msg = msg[:200]
		}
		return nil, fmt.Errorf("exit code %d: %s", info.ExitCode, msg)
	}
	return stdout, nil
}

// demux splits Docker's multiplexed stream: each frame has an 8-byte header
// (stream type, 3 zero bytes, big-endian payload length).
func demux(r io.Reader) (stdout, stderr []byte, err error) {
	var out, errb bytes.Buffer
	hdr := make([]byte, 8)
	for {
		if _, err := io.ReadFull(r, hdr); err != nil {
			if errors.Is(err, io.EOF) {
				return out.Bytes(), errb.Bytes(), nil
			}
			return nil, nil, err
		}
		dst := &out
		if hdr[0] == 2 {
			dst = &errb
		}
		if _, err := io.CopyN(dst, r, int64(binary.BigEndian.Uint32(hdr[4:]))); err != nil {
			return nil, nil, err
		}
	}
}

func (c *Client) post(path string, body any) (*http.Response, error) {
	b, err := json.Marshal(body)
	if err != nil {
		return nil, err
	}
	resp, err := c.do(http.MethodPost, path, bytes.NewReader(b))
	if err != nil {
		return nil, err
	}
	if resp.StatusCode >= 300 {
		resp.Body.Close()
		return nil, fmt.Errorf("docker API %s: %s", path, resp.Status)
	}
	return resp, nil
}

func (c *Client) postJSON(path string, body, out any) error {
	resp, err := c.post(path, body)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	return json.NewDecoder(resp.Body).Decode(out)
}

func (c *Client) getJSON(path string, out any) error {
	resp, err := c.do(http.MethodGet, path, nil)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("docker API %s: %s", path, resp.Status)
	}
	return json.NewDecoder(resp.Body).Decode(out)
}
