package docker

import (
	"testing"

	"github.com/Janderov/monitoring/agent/internal/collect"
)

func TestDBEngine(t *testing.T) {
	for img, want := range map[string]string{
		"postgres:16-alpine": "postgresql", "postgis/postgis:15": "postgresql",
		"timescale/timescaledb:latest-pg16": "postgresql", "mysql:8": "mysql",
		"library/mariadb:11": "mysql", "nginx:latest": "", "amnezia-awg2": "",
	} {
		if got := dbEngine(img); got != want {
			t.Errorf("dbEngine(%q) = %q, want %q", img, got, want)
		}
	}
}

func TestDatabasesEndToEnd(t *testing.T) {
	sock := fakeDocker(t, map[string]string{
		"psql":  "conn|7|100\ndb|postgres|7700000\ndb|shop|52428800\n",
		"MYSQL": "conn\t3\t151\ndb\tcrm\t1048576\n",
	})
	got := New(sock).Databases([]collect.Container{
		{Name: "shop-db", Image: "postgres:16", State: "running"},
		{Name: "crm-db", Image: "mysql:8", State: "running"},
		{Name: "old-db", Image: "postgres:13", State: "exited"},
		{Name: "web", Image: "nginx", State: "running"},
	})
	if len(got) != 2 {
		t.Fatalf("databases = %+v", got)
	}
	pg := got[0]
	if pg.Engine != "postgresql" || pg.Connections != 7 || pg.MaxConnections != 100 || len(pg.Databases) != 2 ||
		pg.Databases[1] != (collect.DBSize{Name: "shop", SizeBytes: 52428800}) {
		t.Errorf("postgres = %+v", pg)
	}
	my := got[1]
	if my.Engine != "mysql" || my.Connections != 3 || my.MaxConnections != 151 || my.Databases[0].Name != "crm" {
		t.Errorf("mysql = %+v", my)
	}
}
