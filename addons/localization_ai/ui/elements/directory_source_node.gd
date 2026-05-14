@tool
extends GraphNode

const PORT_TYPE := 0
const PORT_COLOR := Color(0.3, 0.9, 0.5)

signal log_message(text: String)

var _dir_input: LineEdit
var _browse_btn: Button
var _recursive_chk: CheckBox
var _filter: OptionButton
var _refresh_btn: Button
var _status: Label

var _dir_dialog: EditorFileDialog
var _files: Array[String] = []


func _init() -> void:
	title = "Directory Source"
	custom_minimum_size = Vector2(280, 0)


func _ready() -> void:
	# Slot 0: directory row — OUTPUT only (right side feeds the translate node).
	var row := HBoxContainer.new()
	_dir_input = LineEdit.new()
	_dir_input.placeholder_text = "Directory (res:// or absolute)"
	_dir_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_dir_input.text_submitted.connect(func(_t: String) -> void: _scan())
	row.add_child(_dir_input)

	_browse_btn = Button.new()
	_browse_btn.text = "…"
	_browse_btn.pressed.connect(_open_dir_dialog)
	row.add_child(_browse_btn)
	add_child(row)

	var opts := HBoxContainer.new()
	_recursive_chk = CheckBox.new()
	_recursive_chk.text = "Recursive"
	_recursive_chk.button_pressed = true
	_recursive_chk.toggled.connect(func(_p: bool) -> void: _scan())
	opts.add_child(_recursive_chk)

	_filter = OptionButton.new()
	_filter.add_item("CSV + PO")
	_filter.add_item("CSV only")
	_filter.add_item("PO only")
	_filter.item_selected.connect(func(_i: int) -> void: _scan())
	opts.add_child(_filter)
	add_child(opts)

	_refresh_btn = Button.new()
	_refresh_btn.text = "🔄 Refresh"
	_refresh_btn.pressed.connect(_scan)
	add_child(_refresh_btn)

	_status = Label.new()
	_status.text = "Pick a directory"
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.custom_minimum_size = Vector2(260, 0)
	add_child(_status)

	# Output port on slot 0 (the directory row).
	set_slot(0, false, PORT_TYPE, Color.WHITE, true, PORT_TYPE, PORT_COLOR)


# ── Public API ────────────────────────────────────────────────────────────────

func get_files() -> Array[String]:
	# Always rescan on demand so edits to disk between connection and Run are picked up.
	_scan()
	return _files.duplicate()


func get_selected_file() -> String:
	# Used by main.gd at connection-time to populate the Translate node's
	# source-language dropdown. Return the first file as a representative sample.
	if _files.is_empty():
		_scan()
	return _files[0] if not _files.is_empty() else ""


# ── Scanning ─────────────────────────────────────────────────────────────────

func _allowed_exts() -> Array:
	match _filter.selected:
		1: return [".csv"]
		2: return [".po"]
		_: return [".csv", ".po"]


func _scan() -> void:
	_files.clear()
	var dir_text := _dir_input.text.strip_edges()
	if dir_text.is_empty():
		_status.text = "Pick a directory"
		return

	var abs := dir_text
	if dir_text.begins_with("res://") or dir_text.begins_with("user://"):
		abs = ProjectSettings.globalize_path(dir_text)

	if not DirAccess.dir_exists_absolute(abs):
		_status.text = "Directory does not exist"
		return

	var collected: Array[String] = []
	_collect_files(abs, _allowed_exts(), _recursive_chk.button_pressed, collected)
	collected.sort()
	_files = collected

	if _files.is_empty():
		_status.text = "No matching files in directory"
	else:
		_status.text = "%d file(s) found" % _files.size()

	_propagate_first_file()


# Push the first file to any downstream Translate node so its source-language
# dropdown populates even if the user picked the directory after wiring the edge.
func _propagate_first_file() -> void:
	if _files.is_empty():
		return
	var parent := get_parent()
	if parent == null or not parent.has_method("get_connection_list"):
		return
	for conn in parent.get_connection_list():
		if String(conn.from_node) != String(name):
			continue
		var dst := parent.get_node_or_null(NodePath(String(conn.to_node)))
		if dst and dst.has_method("set_input_file"):
			dst.set_input_file(_files[0])


func _collect_files(abs_dir: String, exts: Array, recursive: bool, out: Array[String]) -> void:
	var dir := DirAccess.open(abs_dir)
	if dir == null:
		return
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if entry == "." or entry == ".." or entry.begins_with("."):
			entry = dir.get_next()
			continue
		var full := abs_dir.path_join(entry)
		if dir.current_is_dir():
			if recursive:
				_collect_files(full, exts, true, out)
		else:
			var lower := entry.to_lower()
			for ext in exts:
				if lower.ends_with(ext):
					out.append(ProjectSettings.localize_path(full))
					break
		entry = dir.get_next()
	dir.list_dir_end()


# ── Directory picker ─────────────────────────────────────────────────────────

func _open_dir_dialog() -> void:
	if _dir_dialog == null:
		_dir_dialog = EditorFileDialog.new()
		_dir_dialog.file_mode = EditorFileDialog.FILE_MODE_OPEN_DIR
		_dir_dialog.access = EditorFileDialog.ACCESS_FILESYSTEM
		_dir_dialog.dir_selected.connect(func(d: String) -> void:
			_dir_input.text = d
			_scan()
		)
		get_tree().root.add_child(_dir_dialog)
	_dir_dialog.popup_centered(Vector2i(900, 600))


# ── Workflow save / load ─────────────────────────────────────────────────────

func save_state() -> Dictionary:
	return {
		"directory": _dir_input.text,
		"recursive": _recursive_chk.button_pressed,
		"filter":    _filter.selected,
	}


func load_state(data: Dictionary) -> void:
	_dir_input.text = str(data.get("directory", ""))
	_recursive_chk.button_pressed = bool(data.get("recursive", true))
	var f := int(data.get("filter", 0))
	if f >= 0 and f < _filter.item_count:
		_filter.select(f)
	if not _dir_input.text.is_empty():
		_scan()
