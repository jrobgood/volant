import Foundation

var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ label: String) {
    guard condition() else { fputs("FAIL: \(label)\n", stderr); exit(1) }
    checks += 1
}
func rejects(_ label: String, expected: String, _ action: () throws -> Void) {
    do { try action(); check(false, label) } catch {
        check(expected == "file-exists" ? (error as NSError).code == NSFileWriteFileExistsError : error.localizedDescription.contains(expected), label + " returned the expected failure")
    }
}
func json(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) }
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let config = root.appendingPathComponent("config.json")
let notes = root.appendingPathComponent("Notes")
let base = try json(["snippets": [["name": "Existing", "keyword": ";existing", "body": "Keep", "futureSnippet": true]], "aliases": ["sa": "Safari"], "futureSetting": "preserved"])
try base.write(to: config)
let key = try RaycastScrypt.derive(password: [], salt: [], n: 16, r: 1, length: 64)
check(key.map { String(format: "%02x", $0) }.joined() == "77d6576238657b203b19ca42c18a0497f16b4844e3074ae8dfdffa3fede21442fcd0069ded0948f8326a753a0fc81f17e8d3e0fb2e0d3628cf35e20c38d18906", "RFC 7914 scrypt vector")
let archive = try Data(contentsOf: root.appendingPathComponent("fixture.rayconfig"))
let decoded = try RaycastArchive.decode(archive, password: "fictional-password")
check((try? JSONSerialization.jsonObject(with: decoded)) != nil, "independent Python AES-GCM/scrypt fixture")
rejects("wrong password", expected: "Couldn’t unlock") { _ = try RaycastArchive.decode(archive, password: "wrong") }
var tampered = archive; tampered[tampered.count - 1] ^= 1
rejects("tampered authentication tag", expected: "Couldn’t unlock") { _ = try RaycastArchive.decode(tampered, password: "fictional-password") }
for length in [0, 7, 11, 12, 30] { rejects("truncated archive \(length)", expected: length < 12 ? "Choose a Raycast" : "header is damaged") { _ = try RaycastArchive.decode(archive.prefix(length), password: "x") } }
var oversized = archive; for i in 8..<12 { oversized[i] = 255 }
rejects("oversized header before KDF", expected: "header is damaged") { _ = try RaycastArchive.decode(oversized, password: "x") }
let shortcut: [String: Any] = ["kind": ["shortcut": ["key": ["type": "LayoutIndependent", "code": 0], "modifiers": [["modifier": "Meta"], ["modifier": "Shift"]]]]]
let payload = try json([
    "snippets": ["snippets": [["title": "Existing", "text": "replace?"], ["title": "New", "text": "{cursor} {clipboard}", "keyword": ";new"], ["title": "Keyword collision", "text": "no", "keyword": ";existing"]]],
    "quicklinks": ["quicklinks": [["name": "Search", "link": "https://example.com/?q={Query}"], ["name": "Bad", "link": "file:///tmp/no"], ["name": "Complex", "link": "https://example.com/{Query|raw}"]]],
    "settings": ["commands": [["extensionId": "e:r:applications", "id": "app::=::/Applications/Fiction.app", "alias": "fx", "macosHotkey": shortcut], ["extensionId": "e:r:applications", "id": "app::=::/Applications/Fiction.app", "alias": "sa", "macosHotkey": shortcut]]],
    "notes": ["notes": [["title": "One", "markdown": "Hello"], ["title": "Rich", "content": ["type": "doc"]]]],
    "clipboardHistory": [:]
])
let resolve: (String) -> (id: String, name: String)? = { _ in ("test.fiction", "Fiction") }
let plan = try RaycastImportPlan.make(payload: payload, configURL: config, notesURL: notes, resolveApp: resolve)
check(plan.snippets.count == 1, "snippet name/keyword conflicts")
check(plan.snippets[0].body == "{cursor} {clipboard}", "unsupported token preserved")
check(plan.quicklinks.count == 1 && plan.quicklinks[0].url.hasSuffix("{query}"), "query translation and scheme rejection")
check(plan.aliases == ["fx": "/Applications/Fiction.app"] && plan.hotkeys.count == 1, "app mapping and internal conflicts")
check(plan.hotkeys.first?.path == "/Applications/Fiction.app", "imported hotkey targets the exported application copy")
check(plan.notes.count == 1 && plan.report.contains(where: { $0.contains("rich-text") }), "rich notes reported")
rejects("empty selection", expected: "Select at least") { _ = try plan.apply([]) }
let recovery = try plan.apply([.snippets, .quicklinks, .aliases, .notes])
check(try! Data(contentsOf: recovery.appendingPathComponent("config.json")) == base, "exact recovery backup")
let updated = try JSONSerialization.jsonObject(with: Data(contentsOf: config)) as! [String: Any]
check(updated["futureSetting"] as? String == "preserved", "unknown config field preserved")
check((updated["appHotKeys"] as? [Any]) == nil, "unchecked hotkeys untouched")
check((try! FileManager.default.contentsOfDirectory(atPath: notes.path)).count == 1, "notes added")
let again = try RaycastImportPlan.make(payload: payload, configURL: config, notesURL: notes, resolveApp: resolve)
check(again.snippets.isEmpty && again.quicklinks.isEmpty && again.aliases.isEmpty && again.notes.isEmpty, "reimport idempotent")
rejects("stale preview", expected: "Configuration changed") { _ = try plan.apply([.hotkeys]) }
// Cause a failure after one new note was written. Only this import's files may be rolled back.
try base.write(to: config)
let rollbackPayload = try json(["notes": ["notes": [["markdown": "A"], ["markdown": "B"]]]])
let rollback = try RaycastImportPlan.make(payload: rollbackPayload, configURL: config, notesURL: notes)
let names = rollback.notes.keys.sorted()
let collision = notes.appendingPathComponent(names[1])
try Data("Keep collision".utf8).write(to: collision)
rejects("note write collision rolls back", expected: "file-exists") { _ = try rollback.apply([.notes, .snippets]) }
check(!FileManager.default.fileExists(atPath: notes.appendingPathComponent(names[0]).path), "partial added note removed")
check(try! String(contentsOf: collision, encoding: .utf8) == "Keep collision", "existing note retained")
check(try! Data(contentsOf: config) == base, "config unchanged on note failure")
let malformed = try Data(contentsOf: root.appendingPathComponent("fixture.rayconfig.badhex"))
rejects("Non-ASCII encryption header", expected: "unsupported encryption header") { _ = try RaycastArchive.decode(malformed, password: "unused") }
let nested = updated["snippets"] as! [[String: Any]]
check(nested.first?["futureSnippet"] as? Bool == true, "nested unknown fields preserved")
let reservedPayload = try json(["snippets": ["snippets": [["title": "Agenda text", "text": "hello", "keyword": "cal"]]], "quicklinks": ["quicklinks": [["name": "note", "link": "https://example.com"]]], "settings": ["commands": [["extensionId": "e:r:applications", "id": "app::=::/Applications/Fiction.app", "alias": "FX"]]]])
let reserved = try RaycastImportPlan.make(payload: reservedPayload, configURL: config, notesURL: notes, resolveApp: resolve)
check(reserved.snippets.first?.keyword == "" && reserved.quicklinks.isEmpty, "reserved names are reported and cannot silently shadow commands")
check(reserved.aliases["fx"] == "/Applications/Fiction.app", "uppercase aliases normalize and bind exact app path")
print("PASS: \(checks) Raycast decoder, mapping, and persistence checks")
