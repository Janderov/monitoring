#!/bin/bash
# Runs every query of ReportSQL against the approved schema on PostgreSQL 18
# with sample rows, and checks the answers. Needs Docker.
#   app/Tests/sql/reports-check.sh /path/to/db-schema.sql
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
schema=${1:?path to db-schema.sql (the first migration)}
name=monitor-report-sql-check
docker rm -f $name >/dev/null 2>&1 || true
docker run -d --name $name -e POSTGRES_PASSWORD=x postgres:18 >/dev/null
trap 'docker rm -f $name >/dev/null' EXIT
until docker exec $name pg_isready -U postgres -q 2>/dev/null; do sleep 1; done
sleep 1
psql() { docker exec -i $name psql -U postgres -v ON_ERROR_STOP=1 -qAtX "$@"; }
psql < "$schema" >/dev/null
psql < "$here/reports-seed.sql" >/dev/null

client=00000000-0000-0000-0000-00000000c001
month="'$client'::uuid, '2026-09-01'::date, '2026-09-30'::date, '2026-09-01 00:00+03'::timestamptz, '2026-10-01 00:00+03'::timestamptz"
declare -A got
while IFS=$'\t' read -r -d '' qname sql; do
  case $qname in
    insertDraft|setComment|approve|markSent|insertLink|revokeLink|openLink|linkArchive|recipients|dueClients|drafts) continue ;;
  esac
  got[$qname]=$(psql -c "PREPARE q(uuid, date, date, timestamptz, timestamptz) AS $sql;" -c "EXECUTE q($month);" </dev/null)
done < <(python3 "$here/extract_report_sql.py" "$here/../../Sources/MonitorReports/ReportSQL.swift")

fail=0
check() { if [[ "$2" != "$3" ]]; then echo "FAIL $1: got [$2] want [$3]"; fail=1; else echo "ok   $1"; fi; }
check client         "$(head -1 <<<"${got[client]}" | cut -d"|" -f1,2,3,4,5,9,10)" "ООО «Пример»|Europe/Moscow|t|1|review|99.900|Михаил Дмитраков"
check sites          "${got[sites]}" $'00000000-0000-0000-0000-0000000000d2|moved.example.com|https://moved.example.com||2026-11-16 09:00:00+00|f\n00000000-0000-0000-0000-0000000000d1|shop.example.com|https://shop.example.com/catalog|2026-12-19 09:00:00+00|2026-11-16 09:00:00+00|t'
check siteDays       "$(wc -l <<<"${got[siteDays]}")" "30"
check servers        "${got[servers]}" "00000000-0000-0000-0000-0000000000b1|app.example.com||t"
check serverDays     "$(wc -l <<<"${got[serverDays]}")" "30"
check diskDays       "$(wc -l <<<"${got[diskDays]}")" "60"
check incidents      "$(cut -d'|' -f1,4 <<<"${got[incidents]}")" "shop.example.com|Не открывался"
check forecasts      "$(cut -d'|' -f1,3,7 <<<"${got[forecasts]}")" $'app.example.com|disk_full|prevented\nshop.example.com|domain_expiry|open'
check backups        "$(wc -l <<<"${got[backups]}")" "30"
check work           "$(cut -d'|' -f2 <<<"${got[work]}")" "Очищены журналы"

# Writing: draft, regenerate, approve, link, open, revoke.
sql() { python3 "$here/extract_report_sql.py" "$here/../../Sources/MonitorReports/ReportSQL.swift" | python3 -c "import sys; d=dict(r.split('\t',1) for r in sys.stdin.read().split('\0') if r); print(d['$1'])"; }
draft="'$client'::uuid, '2026-09-01'::date, '2026-09-30'::date, 1, 'issues', '{\"v\":1}'::jsonb, NULL::uuid"
r1=$(psql -c "PREPARE d(uuid,date,date,int,text,jsonb,uuid) AS $(sql insertDraft);" -c "EXECUTE d($draft);")
psql -c "PREPARE c(uuid,text) AS $(sql setComment);" -c "EXECUTE c('$r1', 'Спокойный месяц');"
r2=$(psql -c "PREPARE d(uuid,date,date,int,text,jsonb,uuid) AS $(sql insertDraft);" -c "EXECUTE d($draft);")
check supersede      "$(psql -c "SELECT status FROM rep.client_report WHERE id = '$r1'")|$(psql -c "SELECT supersedes_id, admin_comment FROM rep.client_report WHERE id = '$r2'")" "superseded|$r1|Спокойный месяц"
check drafts         "$(psql -c "$(sql drafts)" | cut -d'|' -f1,2)" "$r2|ООО «Пример»"
hash="'\\x$(printf 'token' | sha256sum | cut -c1-64)'::bytea"
psql -c "PREPARE l(text,uuid,uuid,bytea,uuid,int) AS $(sql insertLink);" -c "EXECUTE l('report', '$r2', NULL, $hash, NULL, 365);" >/dev/null
check draftHidden    "$(psql -c "PREPARE o(bytea) AS $(sql openLink);" -c "EXECUTE o($hash);")" ""
check approve        "$(psql -c "PREPARE a(uuid,uuid) AS $(sql approve);" -c "EXECUTE a('$r2', NULL);")" "$r2"
check approveTwice   "$(psql -c "PREPARE a(uuid,uuid) AS $(sql approve);" -c "EXECUTE a('$r2', NULL);")" ""
psql -c "PREPARE s(uuid) AS $(sql markSent);" -c "EXECUTE s('$r2');"
check openLink       "$(psql -c "PREPARE o(bytea) AS $(sql openLink);" -c "EXECUTE o($hash);" | cut -d'|' -f1,3,4,5)" "$r2|{\"v\": 1}|Спокойный месяц|Europe/Moscow"
check openCount      "$(psql -c "SELECT open_count FROM rep.report_link")" "2"
chash="'\\x$(printf 'client' | sha256sum | cut -c1-64)'::bytea"
psql -c "PREPARE l(text,uuid,uuid,bytea,uuid,int) AS $(sql insertLink);" -c "EXECUTE l('client', NULL, '$client', $chash, NULL, 365);" >/dev/null
check clientLink     "$(psql -c "PREPARE o(bytea) AS $(sql openLink);" -c "EXECUTE o($chash);" | cut -d'|' -f1)" "$r2"
check archive        "$(psql -c "PREPARE h(bytea) AS $(sql linkArchive);" -c "EXECUTE h($chash);")" "$r2|2026-09-01"
lid=$(psql -c "SELECT id FROM rep.report_link WHERE scope = 'report'")
psql -c "PREPARE v(uuid,uuid) AS $(sql revokeLink);" -c "EXECUTE v('$lid', NULL);"
check revoked        "$(psql -c "PREPARE o(bytea) AS $(sql openLink);" -c "EXECUTE o($hash);")" ""
check recipients     "$(psql -c "PREPARE p(uuid) AS $(sql recipients);" -c "EXECUTE p('$client');" | cut -d'|' -f2,3)" "Анна|anna@example.com"
check dueSeptember   "$(psql -c "PREPARE u(date) AS $(sql dueClients);" -c "EXECUTE u('2026-10-01');")" ""
check dueOctober     "$(psql -c "PREPARE u(date) AS $(sql dueClients);" -c "EXECUTE u('2026-11-01');")" "$client|Europe/Moscow|1"
exit $fail
