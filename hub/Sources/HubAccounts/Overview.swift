import Foundation
import HubCore
import Logging
import PostgresNIO

/// What a person sees on the cabinet's first page: servers, sites and open
/// problems, only those they may view.
public struct Overview: Sendable {
    public let access: Access
    var db: Database { access.db }

    public init(access: Access) { self.access = access }

    public func json(for a: Account) async throws -> String {
        let owner = a.isOwner
        return try await db.scalar("""
            WITH vs AS (
              SELECT s.* FROM inv.server s
              WHERE s.archived_at IS NULL
                AND (\(owner) OR acc.permission_mode(\(a.id), 'view', 'server', s.id) <> 'deny')
            ), vt AS (
              SELECT t.* FROM inv.site t
              WHERE t.archived_at IS NULL
                AND (\(owner) OR acc.permission_mode(\(a.id), 'view', 'site', t.id) <> 'deny')
            ), inc AS (
              SELECT i.* FROM ops.incident i
              WHERE i.ended_at IS NULL
                AND (i.object_id IN (SELECT id FROM vs) OR i.object_id IN (SELECT id FROM vt)
                     OR (\(owner) AND i.object_type IN ('hub', 'domain', 'vpn_key')))
            )
            SELECT json_build_object(
              'servers', coalesce((SELECT json_agg(json_build_object(
                  'id', s.id, 'name', s.name, 'host', s.host, 'country', s.country, 'role', s.role, 'paused', s.paused,
                  'clients', (SELECT coalesce(json_agg(c.name ORDER BY c.name), '[]') FROM inv.client_asset ca
                              JOIN inv.client c ON c.id = ca.client_id
                              WHERE ca.asset_type = 'server' AND ca.asset_id = s.id AND ca.until IS NULL),
                  'seen_at', l.ts,
                  'cpu', (l.snapshot #>> '{cpu,usage_percent}')::float,
                  'mem', (l.snapshot #>> '{memory,used_percent}')::float,
                  'disk', (SELECT max((d->>'used_percent')::float) FROM jsonb_array_elements(l.snapshot->'disks') d),
                  'problems', (SELECT count(*) FROM inc WHERE inc.object_id = s.id),
                  'severity', (SELECT max(severity) FROM inc WHERE inc.object_id = s.id))
                ORDER BY s.position, s.name)
                FROM vs s LEFT JOIN mon.latest_snapshot l ON l.server_id = s.id), '[]'),
              'sites', coalesce((SELECT json_agg(json_build_object(
                  'id', t.id, 'name', t.name, 'url', t.url, 'paused', t.paused,
                  'clients', (SELECT coalesce(json_agg(c.name ORDER BY c.name), '[]') FROM inv.client_asset ca
                              JOIN inv.client c ON c.id = ca.client_id
                              WHERE ca.asset_type = 'site' AND ca.asset_id = t.id AND ca.until IS NULL),
                  'problems', (SELECT count(*) FROM inc WHERE inc.object_id = t.id),
                  'severity', (SELECT max(severity) FROM inc WHERE inc.object_id = t.id))
                ORDER BY t.position, t.name) FROM vt t), '[]'),
              'incidents', coalesce((SELECT json_agg(json_build_object(
                  'id', i.id, 'object_type', i.object_type, 'object_id', i.object_id, 'object_name', i.object_name,
                  'kind', i.kind, 'severity', i.severity, 'message', i.message, 'started_at', i.started_at,
                  'acked_by', (SELECT coalesce(json_agg(a2.display_name), '[]') FROM ops.incident_ack k
                               JOIN acc.account a2 ON a2.id = k.account_id WHERE k.incident_id = i.id))
                ORDER BY i.severity DESC, i.started_at) FROM inc i), '[]'),
              'now', now())::text
            """, as: String.self) ?? "{}"
    }

    /// "I'm on it": stops reminders for everyone and shows who took it.
    public func ack(_ actor: Actor, incident id: UUID) async throws {
        guard let a = actor.account else { throw AccountError.unauthorized("Войдите заново") }
        var found: (String, UUID?, String)?
        for try await r in try await db.query("""
            SELECT object_type, object_id, object_name FROM ops.incident WHERE id = \(id) AND ended_at IS NULL
            """).decode((String, UUID?, String).self) { found = r }
        guard let (type, oid, name) = found else { throw AccountError.notFound("Проблема уже решена или не найдена") }
        _ = try await access.authorize(actor, "alerts_ack", on: .init(type: type, id: oid, name: name), code: nil)
        try await db.query("""
            INSERT INTO ops.incident_ack (incident_id, account_id, via) VALUES (\(id), \(a.id), 'web')
            ON CONFLICT DO NOTHING
            """)
        await access.audit.write(.init("alerts_ack", objectType: type, objectID: oid, objectName: name,
                                       detail: ["incident": id.uuidString]), by: actor)
    }

    /// The audit log: the owner (and managers) see everyone, others their own lines.
    public struct AuditFilter: Sendable {
        public var actor: UUID?
        public var object: UUID?
        public var client: UUID?
        public var action: String?
        public var result: String?
        public var search: String?
        public var before: Date?
        public var limit: Int

        public init(actor: UUID? = nil, object: UUID? = nil, client: UUID? = nil, action: String? = nil,
                    result: String? = nil, search: String? = nil, before: Date? = nil, limit: Int = 200) {
            self.actor = actor; self.object = object; self.client = client; self.action = action
            self.result = result; self.search = search; self.before = before; self.limit = limit
        }
    }

    public func auditJSON(_ viewer: Actor, _ f: AuditFilter) async throws -> String {
        guard let a = viewer.account else { throw AccountError.unauthorized("Войдите заново") }
        let all = try await access.mode(a, "manage_staff") != .deny
        let onlyMine: UUID? = all ? nil : a.id
        let like = f.search.map { "%" + $0.replacingOccurrences(of: "%", with: "") + "%" }
        return try await db.scalar("""
            SELECT coalesce(json_agg(json_build_object(
                'id', l.id, 'ts', l.ts, 'actor_id', l.actor_id, 'actor_kind', l.actor_kind, 'actor_name', l.actor_name,
                'ip', host(l.ip), 'device', l.device, 'action', l.action,
                'action_title', (SELECT title FROM acc.permission WHERE code = l.action),
                'object_type', l.object_type, 'object_id', l.object_id, 'object_name', l.object_name,
                'detail', l.detail, 'result', l.result, 'error', l.error, 'approval_id', l.approval_id)
              ORDER BY l.ts DESC), '[]')::text
            FROM (SELECT * FROM ops.audit_log l
                  WHERE (\(onlyMine)::uuid IS NULL OR l.actor_id = \(onlyMine))
                    AND (\(f.actor)::uuid IS NULL OR l.actor_id = \(f.actor))
                    AND (\(f.object)::uuid IS NULL OR l.object_id = \(f.object))
                    AND (\(f.client)::uuid IS NULL OR \(f.client) = ANY (l.client_ids))
                    AND (\(f.action)::text IS NULL OR l.action = \(f.action))
                    AND (\(f.result)::text IS NULL OR l.result = \(f.result))
                    AND (\(like)::text IS NULL OR l.object_name ILIKE \(like) OR l.actor_name ILIKE \(like)
                         OR l.action ILIKE \(like) OR l.detail::text ILIKE \(like))
                    AND (\(f.before)::timestamptz IS NULL OR l.ts < \(f.before))
                  ORDER BY l.ts DESC LIMIT \(min(max(f.limit, 1), 500))) l
            """, as: String.self) ?? "[]"
    }

    /// Clients with their servers and sites, for choosing where rights apply.
    public func scopesJSON() async throws -> String {
        try await db.scalar("""
            SELECT json_build_object(
              'clients', coalesce((SELECT json_agg(json_build_object('id', c.id, 'name', c.name, 'internal', c.is_internal,
                  'servers', (SELECT coalesce(json_agg(json_build_object('id', s.id, 'name', s.name) ORDER BY s.name), '[]')
                              FROM inv.client_asset ca JOIN inv.server s ON s.id = ca.asset_id
                              WHERE ca.client_id = c.id AND ca.asset_type = 'server' AND ca.until IS NULL
                                AND s.archived_at IS NULL),
                  'sites', (SELECT coalesce(json_agg(json_build_object('id', t.id, 'name', t.name) ORDER BY t.name), '[]')
                            FROM inv.client_asset ca JOIN inv.site t ON t.id = ca.asset_id
                            WHERE ca.client_id = c.id AND ca.asset_type = 'site' AND ca.until IS NULL
                              AND t.archived_at IS NULL))
                ORDER BY c.is_internal DESC, c.name)
                FROM inv.client c WHERE c.archived_at IS NULL AND c.status <> 'ended'), '[]'),
              'servers', coalesce((SELECT json_agg(json_build_object('id', id, 'name', name) ORDER BY name)
                                   FROM inv.server WHERE archived_at IS NULL), '[]'),
              'sites', coalesce((SELECT json_agg(json_build_object('id', id, 'name', name) ORDER BY name)
                                 FROM inv.site WHERE archived_at IS NULL), '[]'))::text
            """, as: String.self) ?? "{}"
    }
}
