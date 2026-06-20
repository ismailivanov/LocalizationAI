@tool
extends GraphNode

const PORT_TYPE := 0
const PORT_COLOR := Color(0.3, 0.9, 0.5)

signal log_message(text: String)
signal source_changed(path: String)

var _options: OptionButton
var _path_input: LineEdit
var _refresh_btn: Button
var _file_dialog: EditorFileDialog


func _init() -> void:
	title = "File Source"
	custom_minimum_size = Vector2(240, 0)


func _ready() -> void:
	var source_box := VBoxContainer.new()
	source_box.add_theme_constant_override("separation", 4)
	add_child(source_box)

	_options = OptionButton.new()
	_options.custom_minimum_size = Vector2(200, 0)
	_options.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_options.item_selected.connect(_on_option_selected)
	source_box.add_child(_options)

	var path_row := HBoxContainer.new()
	_path_input = LineEdit.new()
	_path_input.placeholder_text = "CSV/PO path (res:// or absolute)"
	_path_input.tooltip_text = "Selected source file path. You can paste a .csv or .po path here."
	_path_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_path_input.text_submitted.connect(_on_path_submitted)
	_path_input.focus_exited.connect(func() -> void: _on_path_submitted(_path_input.text))
	path_row.add_child(_path_input)
	var browse_btn := Button.new()
	browse_btn.text = "…"
	browse_btn.tooltip_text = "Choose CSV or PO file"
	browse_btn.pressed.connect(_open_file_dialog)
	path_row.add_child(browse_btn)
	source_box.add_child(path_row)

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
	if not _restore_selection(prev) and not prev.is_empty():
		_path_input.text = prev
	source_changed.emit(get_selected_file())
	log_message.emit("File Source: refreshed file list")


func _on_filesystem_changed() -> void:
	if not is_inside_tree():
		return
	var prev := get_selected_file()
	_scan_files()
	if not _restore_selection(prev) and not prev.is_empty():
		_path_input.text = prev
	source_changed.emit(get_selected_file())


func _restore_selection(prev_path: String) -> bool:
	if prev_path.is_empty():
		return false
	for i in _options.item_count:
		if str(_options.get_item_metadata(i)) == prev_path:
			_options.select(i)
			_path_input.text = prev_path
			return true
	return false


func _scan_files() -> void:
	_options.clear()
	var files := _find_files("res://", [".po", ".csv"])
	if files.is_empty():
		_options.add_item("No .po or .csv files found")
		_options.disabled = true
		return
	files.sort()
	_options.disabled = false
	for path in files:
		_options.add_item(path.get_file())
		_options.set_item_tooltip(_options.item_count - 1, path)
		_options.set_item_metadata(_options.item_count - 1, path)
	_path_input.text = str(_options.get_item_metadata(0))


func _find_files(dir_path: String, exts: Array) -> Array[String]:
	var result: Array[String] = []
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return result
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if dir.current_is_dir() and not entry.begins_with(".") \
				and not (dir_path == "res://" and entry.to_lower() == "addons"):
			result.append_array(_find_files(dir_path.path_join(entry), exts))
		else:
			for ext in exts:
				if entry.to_lower().ends_with(ext):
					result.append(dir_path.path_join(entry))
					break
		entry = dir.get_next()
	dir.list_dir_end()
	return result


func get_selected_file() -> String:
	if _path_input == null:
		return ""
	return _valid_path(_path_input.text)


func _on_option_selected(index: int) -> void:
	var path := str(_options.get_item_metadata(index))
	if path.is_empty():
		return
	_path_input.text = path
	source_changed.emit(path)


func _on_path_submitted(path: String) -> void:
	if path.strip_edges().is_empty():
		return
	var valid := _valid_path(path)
	if valid.is_empty():
		log_message.emit("File Source: path must point to an existing .csv or .po file")
		return
	_path_input.text = valid
	_restore_selection(valid)
	source_changed.emit(valid)


func _valid_path(path: String) -> String:
	var value := path.strip_edges()
	if value.is_empty():
		return ""
	var ext := value.get_extension().to_lower()
	if ext != "csv" and ext != "po":
		return ""
	var normalized := ProjectSettings.localize_path(value)
	return normalized if FileAccess.file_exists(normalized) else ""


func _open_file_dialog() -> void:
	if _file_dialog == null:
		_file_dialog = EditorFileDialog.new()
		_file_dialog.file_mode = EditorFileDialog.FILE_MODE_OPEN_FILE
		_file_dialog.access = EditorFileDialog.ACCESS_FILESYSTEM
		_file_dialog.add_filter("*.csv", "CSV translation files")
		_file_dialog.add_filter("*.po", "PO translation files")
		_file_dialog.file_selected.connect(_on_path_submitted)
		add_child(_file_dialog)
	_file_dialog.popup_centered(Vector2i(900, 600))


# ── Workflow save / load ─────────────────────────────────────────────────────

func save_state() -> Dictionary:
	return {"file": get_selected_file()}


func load_state(data: Dictionary) -> void:
	var target := str(data.get("file", ""))
	if target.is_empty():
		return
	_path_input.text = target
	_restore_selection(target)
