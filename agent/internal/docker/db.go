package docker

import (
	"strconv"
	"strings"

	"github.com/Janderov/monitoring/agent/internal/collect"
)

// dbEngine tells PostgreSQL and MySQL/MariaDB containers apart by image.
func dbEngine(image string) string {
	img := strings.ToLower(image)
	if i := strings.LastIndex(img, "/"); i >= 0 {
		img = img[i+1:]
	}
	switch {
	case strings.HasPrefix(img, "postgres"), strings.HasPrefix(img, "postgis"), strings.Contains(img, "timescale"):
		return "postgresql"
	case strings.HasPrefix(img, "mysql"), strings.HasPrefix(img, "mariadb"), strings.HasPrefix(img, "percona"):
		return "mysql"
	}
	return ""
}

// The queries only read statistics. They run inside the container with the
// image's own admin account: PostgreSQL trusts local connections from its
// superuser, MySQL gets the root password from the container's environment.
// Neither the password nor any data leaves the container.
const (
	pgQuery = `psql -U "${POSTGRES_USER:-postgres}" -d postgres -AtF '|' -c "` +
		`select 'conn', count(*), current_setting('max_connections') from pg_stat_activity where datname is not null;` +
		` select 'db', datname, pg_database_size(datname) from pg_database where not datistemplate"`
	mysqlQuery = `P="${MYSQL_ROOT_PASSWORD:-$MARIADB_ROOT_PASSWORD}"; C=mysql; command -v mysql >/dev/null 2>&1 || C=mariadb; ` +
		`MYSQL_PWD="$P" $C -uroot -N -B -e "` +
		`select 'conn', variable_value, @@max_connections from performance_schema.global_status where variable_name = 'Threads_connected';` +
		` select 'db', table_schema, coalesce(sum(data_length + index_length), 0) from information_schema.tables` +
		` where table_schema not in ('mysql', 'sys', 'performance_schema', 'information_schema') group by table_schema"`
)

// Databases reads connections and sizes of every running database container.
func (c *Client) Databases(containers []collect.Container) []collect.Database {
	var out []collect.Database
	for _, ct := range containers {
		engine := dbEngine(ct.Image)
		if engine == "" || ct.State != "running" {
			continue
		}
		d := collect.Database{Container: ct.Name, Engine: engine}
		q, sep := pgQuery, "|"
		if engine == "mysql" {
			q, sep = mysqlQuery, "\t"
		}
		b, err := c.Exec(ct.Name, "sh", "-c", q)
		if err != nil {
			d.Error = "запрос статистики: " + err.Error()
		} else {
			parseDBStats(string(b), sep, &d)
		}
		out = append(out, d)
	}
	return out
}

// parseDBStats reads lines "conn|N|max" and "db|name|bytes".
func parseDBStats(s, sep string, d *collect.Database) {
	for _, line := range strings.Split(s, "\n") {
		f := strings.Split(strings.TrimSpace(line), sep)
		if len(f) != 3 {
			continue
		}
		switch f[0] {
		case "conn":
			d.Connections, _ = strconv.Atoi(f[1])
			d.MaxConnections, _ = strconv.Atoi(f[2])
		case "db":
			size, _ := strconv.ParseInt(f[2], 10, 64)
			d.Databases = append(d.Databases, collect.DBSize{Name: f[1], SizeBytes: size})
		}
	}
}
