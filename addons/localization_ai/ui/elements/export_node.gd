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
var _source_file: String = ""  # original CSV/PO, used as fallback if dest_dir vanished
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


func set_source_file(path: String) -> void:
	# Original source file (the .csv/.po fed into the chain). Used as a fallback
	# location if the user-chosen destination disappears between Run-start and
	# export time, so the translated file isn't lost in user://.
	_source_file = path


func prepare_partial_path(source_path: String, ext: String) -> String:
	# Resolve where the live partial should be written for `source_path`, and
	# make sure the project folder tree exists. Returns "" if the destination
	# isn't usable so the Translate node can fall back to user://.
	#
	# Layout:
	#   <dest>/<project>/progress/<project>_progress.<ext>   ← live partial
	#   <dest>/<project>/recovery/                            ← partial snapshots
	#   <dest>/<project>/done/<project>.<ext>                 ← final output
	#   <dest>/<project>/backup/                              ← prior done versions
	var dest_dir := _dest_input.text.strip_edges()
	if dest_dir.is_empty() or not DirAccess.dir_exists_absolute(dest_dir):
		return ""
	_source_file = source_path
	var project := _snapshot_project_name(source_path)
	var progress_dir := dest_dir.path_join(project).path_join("progress")
	if not DirAccess.dir_exists_absolute(progress_dir):
		if DirAccess.make_dir_recursive_absolute(progress_dir) != OK:
			return ""
	_mark_ignored(progress_dir)
	return progress_dir.path_join("%s_progress.%s" % [project, ext])


static func _mark_ignored(dir: String) -> void:
	# Keep Godot's importer out of the intermediates. The export destination
	# normally lives inside res://, and without this marker every partial and
	# every backup CSV gets imported into a full set of .translation resources
	# — tens of MB per run, plus junk entries in the project's translation list.
	var marker := dir.path_join(".gdignore")
	if FileAccess.file_exists(marker):
		return
	var f := FileAccess.open(marker, FileAccess.WRITE)
	if f != null:
		f.close()


func save_snapshot(partial_src: String) -> void:
	# Periodic snapshot of the live partial into the project's backup folder
	# (last 2 kept). Crash-recovery state itself lives in progress/<project>_progress.<ext>;
	# these snapshots are a safety net in case that file gets corrupted mid-write.
	if partial_src.is_empty() or not FileAccess.file_exists(partial_src):
		return
	var dest_dir := _dest_input.text.strip_edges()
	if dest_dir.is_empty() or not DirAccess.dir_exists_absolute(dest_dir):
		return  # silent — pre-flight + run() handle hard errors

	var ext := partial_src.get_extension()
	var project := _snapshot_project_name(partial_src)
	var project_dir := dest_dir.path_join(project)
	var progress_dir := project_dir.path_join("progress")
	var snap_file := progress_dir.path_join("%s_progress.%s" % [project, ext])
	var backup_dir := project_dir.path_join("backup")

	if not DirAccess.dir_exists_absolute(progress_dir):
		if DirAccess.make_dir_recursive_absolute(progress_dir) != OK:
			return
	if not DirAccess.dir_exists_absolute(backup_dir):
		DirAccess.make_dir_recursive_absolute(backup_dir)
	_mark_ignored(progress_dir)
	_mark_ignored(backup_dir)

	# When Python is writing the live partial directly into snap_file (the
	# common path now), partial_src == snap_file. We only need to rotate a
	# backup; the file itself is already up to date.
	if FileAccess.file_exists(snap_file):
		var ts := Time.get_datetime_string_from_system(true) \
				.replace(":", "-").replace(" ", "_")
		var bak := backup_dir.path_join("%s_%s.%s" % [project, ts, ext])
		DirAccess.copy_absolute(snap_file, bak)
		_prune_backups(backup_dir, project, ext, 2)

	if partial_src != snap_file:
		DirAccess.copy_absolute(partial_src, snap_file)


func _snapshot_project_name(partial_src: String) -> String:
	var custom_name := _name_input.text.strip_edges()
	if not custom_name.is_empty():
		var c_ext := custom_name.get_extension()
		return custom_name.get_basename() if not c_ext.is_empty() else custom_name
	if not _source_file.is_empty():
		return _strip_generated_suffixes(_source_file.get_file().get_basename())
	return _strip_generated_suffixes(partial_src.get_file().get_basename())


static func _strip_generated_suffixes(stem: String) -> String:
	# Resuming a run feeds one of our own outputs back in as the source. A
	# single trim_suffix() pass wasn't enough, so the project name compounded:
	#   dialogues → dialogues_2026-07-21T09-22-16 → …T09-22-16_36389
	# and every variant grew its own progress/ + backup/ tree.
	var re := RegEx.new()
	re.compile("(_progress|_translated|_\\d{4}-\\d{2}-\\d{2}T[0-9\\-]+)$")
	var s := stem
	while true:
		var m := re.search(s)
		if m == null:
			break
		s = s.substr(0, m.get_start())
	return s if not s.is_empty() else stem


func _prune_backups(backup_dir: String, project: String, ext: String, keep: int) -> void:
	# Keep only the `keep` newest backups for this project; delete the rest.
	var d := DirAccess.open(backup_dir)
	if d == null:
		return
	var entries: Array = []
	d.list_dir_begin()
	while true:
		var name := d.get_next()
		if name.is_empty():
			break
		if d.current_is_dir():
			continue
		if not name.begins_with(project + "_") or not name.ends_with("." + ext):
			continue
		var full := backup_dir.path_join(name)
		entries.append({"path": full, "mtime": FileAccess.get_modified_time(full)})
	d.list_dir_end()
	if entries.size() <= keep:
		return
	entries.sort_custom(func(a, b): return a["mtime"] > b["mtime"])
	for i in range(keep, entries.size()):
		DirAccess.remove_absolute(entries[i]["path"])


func validate_destination() -> String:
	var dest_dir := _dest_input.text.strip_edges()
	if dest_dir.is_empty():
		return "Export node has no destination directory selected"
	if not DirAccess.dir_exists_absolute(dest_dir):
		return "Export destination does not exist: " + dest_dir
	return ""


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
		# Destination vanished mid-run — drop the translated file next to the
		# original source so it isn't lost in user://.
		var fallback_dir := ""
		if not _source_file.is_empty():
			fallback_dir = ProjectSettings.globalize_path(_source_file).get_base_dir()
		if fallback_dir.is_empty() or not DirAccess.dir_exists_absolute(fallback_dir):
			return "destination missing and no fallback directory: " + dest_dir
		log_message.emit("Export: destination gone (%s) — falling back to source folder %s"
				% [dest_dir, fallback_dir])
		dest_dir = fallback_dir

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

	# Per-project tree with three subfolders for a tidy single root per source:
	#   <dest_dir>/<project>/done/<project>.<ext>              ← final output
	#   <dest_dir>/<project>/progress/<project>_progress.<ext> ← live partial (resume from here)
	#   <dest_dir>/<project>/backup/                           ← rotating snapshots
	#                                                            (prior done versions +
	#                                                            periodic partial snapshots)
	var project_dir := dest_dir.path_join(project)
	var dest_subdir := project_dir.path_join("progress" if is_progress else "done")
	var dest_file := ("%s_progress.%s" % [project, ext]) if is_progress \
			else "%s.%s" % [project, ext]
	var dest := dest_subdir.path_join(dest_file)

	if not DirAccess.dir_exists_absolute(dest_subdir):
		if DirAccess.make_dir_recursive_absolute(dest_subdir) != OK:
			return "cannot create export folder: " + dest_subdir

	# Python may already have written straight into the export folder (live
	# partial path). In that case src == dest and we must not copy-then-delete
	# the file onto itself — that would wipe it.
	if src != dest:
		if FileAccess.file_exists(dest):
			var bak_err := _backup(dest, project_dir)
			if not bak_err.is_empty():
				return "backup failed: " + bak_err

		var err := DirAccess.copy_absolute(src, dest)
		if err != OK:
			return "copy failed (error %d)" % err

		var src_lower := src_file.to_lower()
		if src_lower.ends_with("_translated." + ext) or src_lower.ends_with("_progress." + ext):
			DirAccess.remove_absolute(src)

	_output_file = dest
	_status.text = "Exported:\n" + dest
	log_message.emit("Export: saved  →  " + dest)
	_rescan_filesystem()
	return ""


func _rescan_filesystem() -> void:
	if not Engine.is_editor_hint():
		return
	var fs := EditorInterface.get_resource_filesystem()
	if fs:
		fs.scan()


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
