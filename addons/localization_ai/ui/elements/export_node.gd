@tool
extends GraphNode

const PORT_TYPE := 0
const PORT_COLOR := Color(0.3, 0.9, 0.5)

signal log_message(text: String)

var _input_label: Label      # [0] ← INPUT port
var _dest_input: LineEdit    # [1] (inside HBox with browse button)
var _name_input: LineEdit    # [2] custom file name (optional)
var _status: Label           # [3] → OUTPUT port

var _input_file: String = ""
var _output_file: String = ""
var _file_dialog: EditorFileDialog


func _init() -> void:
	title = "Export"
	custom_minimum_size = Vector2(260, 0)


func _ready() -> void:
	_input_label = Label.new()
	_input_label.text = "No file connected"
	_input_label.clip_text = true
	_input_label.custom_minimum_size = Vector2(240, 0)
	add_child(_input_label)

	var row := HBoxContainer.new()
	_dest_input = LineEdit.new()
	_dest_input.placeholder_text = "Export directory…"
	_dest_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(_dest_input)
	var browse := Button.new()
	browse.text = "…"
	browse.pressed.connect(_open_dir_dialog)
	row.add_child(browse)
	add_child(row)

	_name_input = LineEdit.new()
	_name_input.placeholder_text = "File name (leave blank to keep original)"
	_name_input.custom_minimum_size = Vector2(240, 0)
	add_child(_name_input)

	_status = Label.new()
	_status.text = "Ready"
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.custom_minimum_size = Vector2(240, 0)
	add_child(_status)

	set_slot(0, true,  PORT_TYPE, PORT_COLOR, false, PORT_TYPE, Color.WHITE)
	set_slot(3, false, PORT_TYPE, Color.WHITE, true,  PORT_TYPE, PORT_COLOR)


# ── Public API ────────────────────────────────────────────────────────────────

func set_pending_input() -> void:
	_input_label.text = "Waiting for translation…"
	_status.text = "Waiting for translation…"


func set_input_file(path: String) -> void:
	_input_file = path
	if path.is_empty():
		_input_label.text = "No file connected"
		_status.text = "Ready"
	else:
		_input_label.text = path.get_file()
		_status.text = "Ready to export"


func get_output_file() -> String:
	return _output_file


# ── Workflow save / load ─────────────────────────────────────────────────────

func save_state() -> Dictionary:
	return {
		"destination": _dest_input.text,
		"file_name": _name_input.text,
	}


func load_state(data: Dictionary) -> void:
	_dest_input.text = str(data.get("destination", ""))
	_name_input.text = str(data.get("file_name", ""))


func run() -> String:
	if _input_file.is_empty():
		return "no translated file (run Translate first)"
	if _dest_input.text.strip_edges().is_empty():
		return "no destination directory selected"

	var src := ProjectSettings.globalize_path(_input_file)
	var dest_dir := _dest_input.text.strip_edges()
	if not DirAccess.dir_exists_absolute(dest_dir):
		return "directory does not exist: " + dest_dir

	# Detect whether the incoming file is a partial / in-progress translation.
	var src_file := _input_file.get_file()                       # e.g. dialogues_progress.csv
	var ext := src_file.get_extension()
	var stem := src_file.get_basename()                          # e.g. dialogues_progress
	var is_progress := stem.ends_with("_progress")

	# Derive the project name: explicit override, else the input stem
	# stripped of routing suffixes.
	var project := stem.trim_suffix("_progress").trim_suffix("_translated")
	var custom_name := _name_input.text.strip_edges()
	if not custom_name.is_empty():
		var c_ext := custom_name.get_extension()
		project = custom_name.get_basename() if not c_ext.is_empty() else custom_name

	# Two-folder layout for a tidier export tree:
	#   <dest_dir>/<project>/<project>.<ext>             ← finished export
	#   <dest_dir>/<project>_progress/<project>_progress.<ext>  ← partial state
	var subfolder := project + ("_progress" if is_progress else "")
	var dest_subdir := dest_dir.path_join(subfolder)
	var dest_file := subfolder + "." + ext
	var dest := dest_subdir.path_join(dest_file)

	if not DirAccess.dir_exists_absolute(dest_subdir):
		if DirAccess.make_dir_recursive_absolute(dest_subdir) != OK:
			return "cannot create export folder: " + dest_subdir

	if FileAccess.file_exists(dest):
		var bak_err := _backup(dest, dest_subdir)
		if not bak_err.is_empty():
			return "backup failed: " + bak_err

	var err := DirAccess.copy_absolute(src, dest)
	if err != OK:
		return "copy failed (error %d)" % err

	_output_file = dest
	_status.text = "Exported:\n" + dest
	log_message.emit("Export: saved  →  " + dest)
	return ""


# ── Directory picker ──────────────────────────────────────────────────────────

func _open_dir_dialog() -> void:
	if _file_dialog == null:
		_file_dialog = EditorFileDialog.new()
		_file_dialog.file_mode = EditorFileDialog.FILE_MODE_OPEN_DIR
		_file_dialog.access = EditorFileDialog.ACCESS_FILESYSTEM
		_file_dialog.dir_selected.connect(func(dir: String) -> void:
			_dest_input.text = dir
		)
		get_tree().root.add_child(_file_dialog)
	_file_dialog.popup_centered(Vector2i(900, 600))


# ── Backup ────────────────────────────────────────────────────────────────────

func _backup(existing: String, base_dir: String) -> String:
	var backup_dir := base_dir.path_join("backup")
	if not DirAccess.dir_exists_absolute(backup_dir):
		if DirAccess.make_dir_absolute(backup_dir) != OK:
			return "cannot create backup directory"

	var ts := Time.get_datetime_string_from_system(true) \
		.replace(":", "-").replace(" ", "_")
	var stem := existing.get_file().get_basename()
	var ext := existing.get_extension()
	var bak := backup_dir.path_join("%s_%s.%s" % [stem, ts, ext])

	if DirAccess.copy_absolute(existing, bak) != OK:
		return "copy to backup failed"

	log_message.emit("Export: backup  →  " + bak.get_file())
	return ""
