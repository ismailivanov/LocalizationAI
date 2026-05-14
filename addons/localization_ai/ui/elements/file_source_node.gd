@tool
extends GraphNode

const PORT_TYPE := 0
const PORT_COLOR := Color(0.3, 0.9, 0.5)

signal log_message(text: String)

var _options: OptionButton
var _refresh_btn: Button


func _init() -> void:
	title = "File Source"
	custom_minimum_size = Vector2(240, 0)


func _ready() -> void:
	_options = OptionButton.new()
	_options.custom_minimum_size = Vector2(200, 0)
	_options.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(_options)

	# Slot 0 = the OptionButton row, OUTPUT only (right side)
	set_slot(0, false, PORT_TYPE, Color.WHITE, true, PORT_TYPE, PORT_COLOR)

	_refresh_btn = Button.new()
	_refresh_btn.text = "🔄 Refresh"
	_refresh_btn.pressed.connect(_on_refresh)
	add_child(_refresh_btn)

	_scan_files()

	# Auto-rescan when editor filesystem changes
	if Engine.is_editor_hint():
		var efs := EditorInterface.get_resource_filesystem()
		if efs and not efs.filesystem_changed.is_connected(_on_filesystem_changed):
			efs.filesystem_changed.connect(_on_filesystem_changed)


func _on_refresh() -> void:
	var prev := get_selected_file()
	_scan_files()
	_restore_selection(prev)
	log_message.emit("File Source: refreshed file list")


func _on_filesystem_changed() -> void:
	if not is_inside_tree():
		return
	var prev := get_selected_file()
	_scan_files()
	_restore_selection(prev)


func _restore_selection(prev_path: String) -> void:
	if prev_path.is_empty():
		return
	for i in _options.item_count:
		if str(_options.get_item_metadata(i)) == prev_path:
			_options.select(i)
			return


func _scan_files() -> void:
	_options.clear()
	var files := _find_files("res://", [".po", ".csv"])
	if files.is_empty():
		_options.add_item("No .po or .csv files found")
		_options.disabled = true
		return
	_options.disabled = false
	for path in files:
		_options.add_item(path.get_file())
		_options.set_item_metadata(_options.item_count - 1, path)


func _find_files(dir_path: String, exts: Array) -> Array[String]:
	var result: Array[String] = []
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return result
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if dir.current_is_dir() and not entry.begins_with("."):
			result.append_array(_find_files(dir_path.path_join(entry), exts))
		else:
			for ext in exts:
				if entry.ends_with(ext):
					result.append(dir_path.path_join(entry))
					break
		entry = dir.get_next()
	dir.list_dir_end()
	return result


func get_selected_file() -> String:
	if _options == null or _options.item_count == 0 or _options.disabled:
		return ""
	var meta = _options.get_item_metadata(_options.selected)
	return str(meta) if meta != null else ""


# ── Workflow save / load ─────────────────────────────────────────────────────

func save_state() -> Dictionary:
	return {"file": get_selected_file()}


func load_state(data: Dictionary) -> void:
	var target := str(data.get("file", ""))
	if target.is_empty():
		return
	for i in _options.item_count:
		if str(_options.get_item_metadata(i)) == target:
			_options.select(i)
			return
