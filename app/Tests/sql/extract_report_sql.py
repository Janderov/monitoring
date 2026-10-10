"""Prints each query of Sources/MonitorReports/ReportSQL.swift as `name<TAB>sql`
(one per record, separated by NUL), so the check runs exactly what the hub runs."""
import re, sys, textwrap
src = open(sys.argv[1], encoding="utf-8").read()
blocks = dict()
for m in re.finditer(r'static let (\w+) = (assets \+ )?"""\n(.*?)\n\s*"""', src, re.S):
    name, prefix, body = m.group(1), m.group(2), textwrap.dedent(m.group(3))
    body = body.replace("\\\\", "\\")
    blocks[name] = (blocks["assets"] + "\n" if prefix else "") + body
for name, sql in blocks.items():
    if name != "assets":
        sys.stdout.write(f"{name}\t{sql}\0")
