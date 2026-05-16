@tool
extends Node

# Self-contained auto-updater that drives the whole check → download → extract
# → restart flow with its own dialogs. Used by the plugin's Tool menu entry so
# a user can recover from a broken main scene by triggering an update without
# the main panel needing to load successfully.

const GITHUB_REPO := "ismailivanov/LocalizationAI"
const GITHUB_API_RELEASES := "https://api.github.com/repos/" + GITHUB_REPO + "/releases?per_page=10"
const GITHUB_RELEASES_URL := "https://github.com/" + GITHUB_REPO + "/releases"
const PLUGIN_CFG_PATH := "res://addons/localization_ai/plugin.cfg"
const _PREFS_FILE := "user://localization_ai/prefs.cfg"
const _PREFS_SECTION := "updates"

var _check_http: HTTPRequest
var _download_http: HTTPRequest
var _status_dlg: AcceptDialog
var _latest_tag: String = ""
var _latest_url: String = ""
var _zipball_url: String = ""
var _is_prerelease: bool = false


func _ready() -> void:
	_check_http = HTTPRequest.new()
	_check_http.request_completed.connect(_on_check_done)
	add_child(_check_http)

	_download_http = HTTPRequest.new()
	_download_http.max_redirects = 10
	_download_http.request_completed.connect(_on_download_done)
	add_child(_download_http)


# ── Public entry point ───────────────────────────────────────────────────────

func run_update_flow(host: Control) -> void:
	_status_dlg = AcceptDialog.new()
	_status_dlg.title = "LocalizationAI — Update"
	_status_dlg.dialog_text = "Checking GitHub for updates…"
	_status_dlg.get_ok_button().text = "Cancel"
	_status_dlg.confirmed.connect(_dispose)
	_status_dlg.canceled.connect(_dispose)
	host.add_child(_status_dlg)
	_status_dlg.popup_centered(Vector2i(480, 0))

	var headers := ["Accept: application/vnd.github+json", "User-Agent: LocalizationAI"]
	var err := _check_http.request(GITHUB_API_RELEASES, headers)
	if err != OK:
		_show_message("Request failed to start (error %d)." % err)


# ── Version helpers ──────────────────────────────────────────────────────────

func current_version() -> String:
	var cfg := ConfigFile.new()
	if cfg.load(PLUGIN_CFG_PATH) != OK:
		return "0.0.0"
	return str(cfg.get_value("plugin", "version", "0.0.0"))


# Same rules as main.gd — strips leading 'v', ignores semver pre-release (-beta)
# so tags like v1.0.0-rc1 compare as 1.0.0.
static func compare_versions(a: String, b: String) -> int:
	var ap := _parse_version(a)
	var bp := _parse_version(b)
	var n: int = max(ap.size(), bp.size())
	for i in n:
		var av: int = ap[i] if i < ap.size() else 0
		var bv: int = bp[i] if i < bp.size() else 0
		if av > bv:
			return 1
		if av < bv:
			return -1
	return 0


static func _parse_version(s: String) -> Array:
	var t := s.strip_edges().to_lower()
	if t.begins_with("v"):
		t = t.substr(1)
	var dash := t.find("-")
	if dash >= 0:
		t = t.substr(0, dash)
	var plus := t.find("+")
	if plus >= 0:
		t = t.substr(0, plus)
	var parts := t.split(".")
	var out: Array = []
	for p in parts:
		out.append(int(p))
	return out


# ── Check flow ───────────────────────────────────────────────────────────────

func _on_check_done(result: int, code: int, _h: PackedStringArray, body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS:
		_show_message("Network error (result %d)." % result)
		return
	if code != 200:
		_show_message("Server returned HTTP %d." % code)
		return

	var parser := JSON.new()
	if parser.parse(body.get_string_from_utf8()) != OK:
		_show_message("Could not parse GitHub response.")
		return
	var arr = parser.get_data()
	if typeof(arr) != TYPE_ARRAY or (arr as Array).is_empty():
		_show_message("No releases published yet on GitHub.")
		return

	var stable_only := bool(_pref_get("stable_only", false))
	var data: Dictionary = {}
	for entry in arr:
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		if bool(entry.get("draft", false)):
			continue
		if stable_only and bool(entry.get("prerelease", false)):
			continue
		data = entry
		break
	if data.is_empty():
		_show_message("No matching releases found.")
		return

	_latest_tag = str(data.get("tag_name", "")).strip_edges()
	_latest_url = str(data.get("html_url", GITHUB_RELEASES_URL))
	_zipball_url = str(data.get("zipball_url", ""))
	_is_prerelease = bool(data.get("prerelease", false))
	if _zipball_url.is_empty() and not _latest_tag.is_empty():
		_zipball_url = "https://github.com/" + GITHUB_REPO + "/archive/refs/tags/" + _latest_tag + ".zip"

	var current := current_version()
	var cmp := compare_versions(_latest_tag, current)
	var prerelease_suffix := "  (pre-release)" if _is_prerelease else ""
	if cmp <= 0:
		_show_message("You are on the latest version (%s)%s." % [current, prerelease_suffix])
		return

	_status_dlg.queue_free()
	_status_dlg = null
	var confirm := ConfirmationDialog.new()
	confirm.title = "Install LocalizationAI %s" % _latest_tag
	confirm.dialog_text = ("Download %s%s and replace the plugin in res://addons/localization_ai/?\n\n" \
			+ "• Your saved workflows are preserved.\n" \
			+ "• API keys live in user:// and are not touched.\n" \
			+ "• Save unrelated work — a restart is recommended after install.") \
			% [_latest_tag, prerelease_suffix]
	confirm.confirmed.connect(_do_install.bind(confirm))
	confirm.canceled.connect(func() -> void:
		confirm.queue_free()
		_dispose()
	)
	EditorInterface.get_base_control().add_child(confirm)
	confirm.popup_centered(Vector2i(560, 0))


# ── Install flow ─────────────────────────────────────────────────────────────

func _do_install(prev_dlg: AcceptDialog) -> void:
	prev_dlg.queue_free()
	_status_dlg = AcceptDialog.new()
	_status_dlg.title = "LocalizationAI — Update"
	_status_dlg.dialog_text = "Downloading %s…" % _latest_tag
	_status_dlg.get_ok_button().text = "Cancel"
	_status_dlg.confirmed.connect(_dispose)
	_status_dlg.canceled.connect(_dispose)
	EditorInterface.get_base_control().add_child(_status_dlg)
	_status_dlg.popup_centered(Vector2i(480, 0))

	var staging := ProjectSettings.globalize_path("user://localization_ai")
	DirAccess.make_dir_recursive_absolute(staging)
	var zip_abs := staging.path_join("update.zip")
	if FileAccess.file_exists(zip_abs):
		DirAccess.remove_absolute(zip_abs)
	_download_http.download_file = zip_abs
	var err := _download_http.request(_zipball_url, ["User-Agent: LocalizationAI"])
	if err != OK:
		_show_message("Download failed to start (error %d)." % err)


func _on_download_done(result: int, code: int, _h: PackedStringArray, _b: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS:
		_show_message("Network error (result %d)." % result)
		return
	if code >= 400:
		_show_message("Server returned HTTP %d." % code)
		return
	_status_dlg.dialog_text = "Installing…"

	var zip_abs := ProjectSettings.globalize_path("user://localization_ai").path_join("update.zip")
	var err := _apply_zip(zip_abs)
	if not err.is_empty():
		_show_message("Install failed: " + err)
		return

	_status_dlg.queue_free()
	_status_dlg = AcceptDialog.new()
	_status_dlg.title = "Update installed"
	_status_dlg.dialog_text = ("LocalizationAI %s was installed in res://addons/localization_ai/.\n\n" \
			+ "Close and reopen Godot for the changes to fully apply.") % _latest_tag
	_status_dlg.get_ok_button().text = "Later"
	_status_dlg.add_button("Restart now", true, "restart")
	_status_dlg.custom_action.connect(func(action: String) -> void:
		if action == "restart":
			_status_dlg.hide()
			EditorInterface.restart_editor(true)
	)
	_status_dlg.confirmed.connect(_dispose)
	_status_dlg.canceled.connect(_dispose)
	EditorInterface.get_base_control().add_child(_status_dlg)
	_status_dlg.popup_centered(Vector2i(560, 0))


func _apply_zip(zip_abs: String) -> String:
	if not FileAccess.file_exists(zip_abs):
		return "downloaded file is missing"

	var reader := ZIPReader.new()
	if reader.open(zip_abs) != OK:
		return "cannot open downloaded zip"

	var files: PackedStringArray = reader.get_files()
	var addon_zip_prefix := ""
	for f in files:
		var idx := f.find("/addons/localization_ai/")
		if idx >= 0:
			addon_zip_prefix = f.substr(0, idx + 1) + "addons/localization_ai/"
			break
	if addon_zip_prefix.is_empty():
		reader.close()
		return "zip is missing addons/localization_ai/"

	var addon_abs := ProjectSettings.globalize_path("res://addons/localization_ai")
	var workflows_src := addon_abs.path_join("workflows")
	var workflows_backup := ProjectSettings.globalize_path("user://localization_ai/workflows_backup")

	if DirAccess.dir_exists_absolute(workflows_src):
		_delete_recursive(workflows_backup)
		DirAccess.make_dir_recursive_absolute(workflows_backup)
		_copy_dir_recursive(workflows_src, workflows_backup)

	_delete_recursive(addon_abs)
	DirAccess.make_dir_recursive_absolute(addon_abs)

	for f in files:
		if not f.begins_with(addon_zip_prefix):
			continue
		var rel := f.substr(addon_zip_prefix.length())
		if rel.is_empty() or rel.ends_with("/"):
			continue
		var out_abs := addon_abs.path_join(rel)
		DirAccess.make_dir_recursive_absolute(out_abs.get_base_dir())
		var fo := FileAccess.open(out_abs, FileAccess.WRITE)
		if fo == null:
			reader.close()
			return "cannot write " + out_abs
		fo.store_buffer(reader.read_file(f))
		fo.close()

	reader.close()

	if DirAccess.dir_exists_absolute(workflows_backup):
		var workflows_dest := addon_abs.path_join("workflows")
		DirAccess.make_dir_recursive_absolute(workflows_dest)
		_copy_dir_recursive(workflows_backup, workflows_dest)

	DirAccess.remove_absolute(zip_abs)
	return ""


# ── Filesystem helpers ───────────────────────────────────────────────────────

func _delete_recursive(abs_path: String) -> void:
	if not DirAccess.dir_exists_absolute(abs_path):
		return
	var d := DirAccess.open(abs_path)
	if d == null:
		return
	d.list_dir_begin()
	var entry := d.get_next()
	while entry != "":
		if entry != "." and entry != "..":
			var full := abs_path.path_join(entry)
			if d.current_is_dir():
				_delete_recursive(full)
			else:
				DirAccess.remove_absolute(full)
		entry = d.get_next()
	d.list_dir_end()
	DirAccess.remove_absolute(abs_path)


func _copy_dir_recursive(src_abs: String, dst_abs: String) -> void:
	DirAccess.make_dir_recursive_absolute(dst_abs)
	var d := DirAccess.open(src_abs)
	if d == null:
		return
	d.list_dir_begin()
	var entry := d.get_next()
	while entry != "":
		if entry != "." and entry != "..":
			var src := src_abs.path_join(entry)
			var dst := dst_abs.path_join(entry)
			if d.current_is_dir():
				_copy_dir_recursive(src, dst)
			else:
				DirAccess.copy_absolute(src, dst)
		entry = d.get_next()
	d.list_dir_end()


# ── Dialog plumbing ──────────────────────────────────────────────────────────

func _show_message(text: String) -> void:
	if _status_dlg == null:
		_status_dlg = AcceptDialog.new()
		_status_dlg.title = "LocalizationAI — Update"
		EditorInterface.get_base_control().add_child(_status_dlg)
		_status_dlg.confirmed.connect(_dispose)
		_status_dlg.canceled.connect(_dispose)
	_status_dlg.dialog_text = text
	_status_dlg.get_ok_button().text = "OK"
	if not _status_dlg.visible:
		_status_dlg.popup_centered(Vector2i(480, 0))


func _dispose() -> void:
	if _check_http != null and _check_http.get_http_client_status() != HTTPClient.STATUS_DISCONNECTED:
		_check_http.cancel_request()
	if _download_http != null and _download_http.get_http_client_status() != HTTPClient.STATUS_DISCONNECTED:
		_download_http.cancel_request()
	if _status_dlg != null:
		_status_dlg.queue_free()
		_status_dlg = null
	queue_free()


func _pref_get(k: String, fallback: Variant) -> Variant:
	var cfg := ConfigFile.new()
	if cfg.load(_PREFS_FILE) != OK:
		return fallback
	return cfg.get_value(_PREFS_SECTION, k, fallback)
