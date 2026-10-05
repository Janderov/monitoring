package tlsutil

import (
	"crypto/tls"
	"crypto/x509"
	"path/filepath"
	"regexp"
	"testing"
)

func TestGenerateAndFingerprint(t *testing.T) {
	dir := t.TempDir()
	cert, key := filepath.Join(dir, "cert.pem"), filepath.Join(dir, "key.pem")
	if err := Generate(cert, key, "srv", []string{"203.0.113.5", "srv.example.com"}); err != nil {
		t.Fatal(err)
	}
	pair, err := tls.LoadX509KeyPair(cert, key)
	if err != nil {
		t.Fatalf("generated pair does not load: %v", err)
	}
	leaf, err := x509.ParseCertificate(pair.Certificate[0])
	if err != nil {
		t.Fatal(err)
	}
	if len(leaf.IPAddresses) != 1 || len(leaf.DNSNames) != 1 {
		t.Errorf("SANs not set: ip=%v dns=%v", leaf.IPAddresses, leaf.DNSNames)
	}
	fp, err := Fingerprint(cert)
	if err != nil {
		t.Fatal(err)
	}
	if !regexp.MustCompile(`^([0-9A-F]{2}:){31}[0-9A-F]{2}$`).MatchString(fp) {
		t.Errorf("fingerprint format: %s", fp)
	}
}
