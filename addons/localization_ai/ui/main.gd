@tool
extends PanelContainer

const FileSourceScript      = preload("res://addons/localization_ai/ui/elements/file_source_node.gd")
const DirectorySourceScript = preload("res://addons/localization_ai/ui/elements/directory_source_node.gd")
const TranslateScript       = preload("res://addons/localization_ai/ui/elements/translate_node.gd")
const ExportScript          = preload("res://addons/localization_ai/ui/elements/export_node.gd")
const PromptScript          = preload("res://addons/localization_ai/ui/elements/prompt_node.gd")

@onready var _graph: GraphEdit       = $Tabs/Graph/GraphEdit
@onready var _log: RichTextLabel     = $Tabs/Graph/OutputTabs/Log/LogOutput
@onready var _preview: TextEdit      = $Tabs/Graph/OutputTabs/Preview/PreviewEdit
@onready var _preview_label: Label   = $Tabs/Graph/OutputTabs/Preview/PreviewHeader/PreviewLabel
@onready var _output_tabs: TabContainer = $Tabs/Graph/OutputTabs
@onready var _run_btn:    Button     = $Tabs/Graph/Toolbar/RunBtn
@onready var _pause_btn:  Button     = $Tabs/Graph/Toolbar/PauseBtn
@onready var _stop_btn:   Button     = $Tabs/Graph/Toolbar/StopBtn
@onready var _clear_btn:  Button     = $Tabs/Graph/OutputHeader/ClearBtn
@onready var _parallel_spin:     SpinBox = $Tabs/Graph/Toolbar/ParallelSpin
@onready var _eta_lbl:           Label   = $Tabs/Graph/Toolbar/EtaLbl
@onready var _save_btn:          Button = $Tabs/Graph/Toolbar/SaveBtn
@onready var _load_btn:          Button = $Tabs/Graph/Toolbar/LoadBtn
@onready var _clear_graph_btn:   Button = $Tabs/Graph/Toolbar/ClearGraphBtn
@onready var _hint_lbl:          Label  = $Tabs/Graph/Toolbar/HintLbl

const WORKFLOW_DIR := "res://addons/localization_ai/workflows"
const NODE_KIND_FILE := "file_source"
const NODE_KIND_DIRECTORY := "directory_source"
const NODE_KIND_TRANSLATE := "translate"
const NODE_KIND_EXPORT := "export"
const NODE_KIND_PROMPT := "prompt"

var _context_menu: PopupMenu
var _spawn_pos := Vector2.ZERO
var _node_counter := 0
var _save_dialog: EditorFileDialog
var _load_dialog: EditorFileDialog
var _current_workflow_path: String = ""

# Parallel chain scheduler + ETA tracker
var _chains_queue: Array = []
var _active_chains: int = 0
var _run_active: bool = false
var _eta_start_ms: int = 0
var _eta_baseline_done: int = 0
# Per-translate-node progress snapshots:  name → {"current": int, "total": int}
var _node_progress: Dictionary = {}
var _eta_timer: Timer


func _ready() -> void:
	print("[LocalizationAI] main.gd _ready called")
	if _graph == null:
		push_error("LocalizationAI: GraphEdit not found")
		print("[LocalizationAI] ERROR: GraphEdit is null")
		return
	print("[LocalizationAI] GraphEdit found: ", _graph)

	_run_btn.pressed.connect(_run_pipeline)
	_pause_btn.pressed.connect(_on_pause_all)
	_stop_btn.pressed.connect(_on_stop_all)
	_pause_btn.disabled = true
	_stop_btn.disabled = true
	_clear_btn.pressed.connect(func() -> void: _log.clear())

	# Make the log selectable & copyable (Ctrl+C, right-click → Copy).
	_log.selection_enabled = true
	_log.context_menu_enabled = true
	_log.focus_mode = Control.FOCUS_CLICK
	_log.shortcut_keys_enabled = true

	# Add a "Copy Log" button next to "Clear Log".
	var copy_btn := Button.new()
	copy_btn.text = "Copy Log"
	copy_btn.tooltip_text = "Copy the entire log to clipboard"
	copy_btn.pressed.connect(_on_copy_log)
	_clear_btn.get_parent().add_child(copy_btn)
	_clear_btn.get_parent().move_child(copy_btn, _clear_btn.get_index())
	_save_btn.pressed.connect(_save_workflow)
	_load_btn.pressed.connect(_load_workflow)
	_clear_graph_btn.pressed.connect(_clear_graph)
	print("[LocalizationAI] Button signals connected")

	_graph.connection_request.connect(_on_connection_request)
	_graph.disconnection_request.connect(_on_disconnection_request)
	_graph.delete_nodes_request.connect(_on_delete_nodes_request)
	_graph.gui_input.connect(_on_graph_gui_input)

	_context_menu = PopupMenu.new()
	_context_menu.add_item("Add File Source",      0)
	_context_menu.add_item("Add Directory Source", 4)
	_context_menu.add_item("Add Translate",        1)
	_context_menu.add_item("Add Export",           2)
	_context_menu.add_item("Add Prompt",           3)
	_context_menu.id_pressed.connect(_on_context_item)
	add_child(_context_menu)

	_eta_timer = Timer.new()
	_eta_timer.wait_time = 1.0
	_eta_timer.timeout.connect(_refresh_eta)
	add_child(_eta_timer)

	_build_settings_button()

	_log_line("[color=gray]=== Localization AI ready ===[/color]")
	_log_line("[color=gray]Right-click the graph to add nodes.[/color]")


# ── Pause / Stop (toolbar) ───────────────────────────────────────────────────

func _on_pause_all() -> void:
	var any_running := false
	var all_paused := true
	for child in _graph.get_children():
		if child.has_method("is_running") and child.is_running():
			any_running = true
			if child.has_method("is_paused") and not child.is_paused():
				all_paused = false

	for child in _graph.get_children():
		if not child.has_method("is_running") or not child.is_running():
			continue
		if all_paused:
			if child.has_method("resume_translation"):
				child.resume_translation()
		else:
			if child.has_method("pause_translation"):
				child.pause_translation()

	if all_paused:
		_pause_btn.text = "⏸  Pause"
		_log_line("[color=cyan]▶  All translations resumed[/color]")
	else:
		_pause_btn.text = "▶  Resume"
		_log_line("[color=yellow]⏸  All translations paused[/color]")


func _on_stop_all() -> void:
	# Drop queued chains so finishing the current file doesn't kick off the next.
	var dropped := _chains_queue.size()
	_chains_queue.clear()
	_run_active = false
	for child in _graph.get_children():
		if child.has_method("is_running") and child.is_running():
			if child.has_method("stop_translation"):
				child.stop_translation()
	if dropped > 0:
		_log_line("[color=red]⏹  Stop — discarded %d queued file(s)[/color]" % dropped)
	_log_line("[color=red]⏹  Stop requested for all translations[/color]")
	_pause_btn.disabled = true
	_stop_btn.disabled = true


func _update_toolbar_buttons() -> void:
	var any_running := false
	for child in _graph.get_children():
		if child.has_method("is_running") and child.is_running():
			any_running = true
			break
	_pause_btn.disabled = not any_running
	_stop_btn.disabled = not any_running
	_run_btn.disabled = any_running
	if not any_running:
		_pause_btn.text = "⏸  Pause"


# ── Right-click handler ───────────────────────────────────────────────────────

func _on_graph_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton \
			and event.button_index == MOUSE_BUTTON_RIGHT \
			and event.pressed:
		_spawn_pos = event.position / _graph.zoom + _graph.scroll_offset
		var screen_pos := Vector2i(_graph.get_screen_position() + event.position)
		_context_menu.popup(Rect2i(screen_pos, Vector2i.ZERO))


func _on_context_item(id: int) -> void:
	match id:
		0: _spawn_node(FileSourceScript,      _spawn_pos)
		1: _spawn_node(TranslateScript,       _spawn_pos)
		2: _spawn_node(ExportScript,          _spawn_pos)
		3: _spawn_node(PromptScript,          _spawn_pos)
		4: _spawn_node(DirectorySourceScript, _spawn_pos)


# ── Spawn ─────────────────────────────────────────────────────────────────────

func _spawn_node(script: GDScript, pos: Vector2) -> void:
	print("[LocalizationAI] _spawn_node called, script=", script, " pos=", pos)
	if script == null:
		_log_line("[color=red]Error: script is null[/color]")
		print("[LocalizationAI] ERROR: script null")
		return

	var node: Object = script.new()
	print("[LocalizationAI] script.new() returned: ", node)
	if node == null:
		_log_line("[color=red]Error: script.new() returned null[/color]")
		return
	if not (node is GraphNode):
		_log_line("[color=red]Error: spawned object is not a GraphNode (got %s)[/color]" % node.get_class())
		print("[LocalizationAI] ERROR: not a GraphNode, got ", node.get_class())
		return

	_graph.add_child(node)
	node.position_offset = pos
	print("[LocalizationAI] Node added. Child count of GraphEdit: ", _graph.get_child_count())

	_connect_node_signals(node)
	_log_line("[color=green]✓ Added %s at %s[/color]" % [node.title, str(pos)])


func _connect_node_signals(node: Object) -> void:
	if node.has_signal("log_message"):
		node.log_message.connect(_log_info)
	if node.has_signal("translation_done"):
		node.translation_done.connect(func(p: String) -> void:
			_propagate_to_exports(node.name, p)
			_show_preview(p)
			_update_toolbar_buttons()
		)
	if node.has_signal("progress_updated"):
		node.progress_updated.connect(_on_progress.bind(String(node.name)))
	if node.has_signal("translation_paused"):
		node.translation_paused.connect(func() -> void:
			_pause_btn.text = "▶  Resume"
		)
	if node.has_signal("translation_resumed"):
		node.translation_resumed.connect(func() -> void:
			_pause_btn.text = "⏸  Pause"
		)
	if node.has_signal("translation_stopped"):
		node.translation_stopped.connect(func() -> void:
			_update_toolbar_buttons()
		)


func _next_pos() -> Vector2:
	_node_counter += 1
	return Vector2(80 + (_node_counter % 6) * 30, 80 + (_node_counter % 4) * 30)


# ── Connections ───────────────────────────────────────────────────────────────

func _on_connection_request(from_node: StringName, from_port: int,
		to_node: StringName, to_port: int) -> void:
	_graph.connect_node(from_node, from_port, to_node, to_port)

	var src := _graph.get_node_or_null(NodePath(from_node))
	var dst := _graph.get_node_or_null(NodePath(to_node))
	if src == null or dst == null:
		return

	if src.has_method("get_selected_file") and dst.has_method("set_input_file"):
		dst.set_input_file(src.get_selected_file())
	elif src.has_method("get_output_file") and dst.has_method("set_pending_input"):
		var existing: String = src.get_output_file()
		if existing.is_empty():
			dst.set_pending_input()
		else:
			dst.set_input_file(existing)


func _on_disconnection_request(from_node: StringName, from_port: int,
		to_node: StringName, to_port: int) -> void:
	_graph.disconnect_node(from_node, from_port, to_node, to_port)


func _on_delete_nodes_request(nodes: Array[StringName]) -> void:
	for node_name in nodes:
		for conn in _graph.get_connection_list():
			if conn.from_node == node_name or conn.to_node == node_name:
				_graph.disconnect_node(conn.from_node, conn.from_port, conn.to_node, conn.to_port)
		
		var node = _graph.get_node_or_null(NodePath(node_name))
		if node:
			node.queue_free()
	_log_line("[color=gray]› Deleted %d node(s)[/color]" % nodes.size())


func _propagate_to_exports(translate_name: String, output_path: String) -> void:
	for conn in _graph.get_connection_list():
		if conn.from_node != translate_name:
			continue
		var dst := _graph.get_node_or_null(NodePath(conn.to_node))
		if dst and dst.has_method("set_input_file"):
			dst.set_input_file(output_path)


# ── Run pipeline ──────────────────────────────────────────────────────────────

func _run_pipeline() -> void:
	_log.clear()
	_preview.text = ""
	_preview_label.text = "  Live translation will appear here…"
	_log_line("[color=cyan]▶  Run started[/color]")
	_run_btn.disabled = true
	_pause_btn.disabled = false
	_stop_btn.disabled = false

	var chains := _build_chains()
	if chains.is_empty():
		_log_line("[color=yellow]No complete chain found.[/color]")
		_log_line("[color=gray]Connect:  File Source → Translate → Export[/color]")
		_run_btn.disabled = false
		_pause_btn.disabled = true
		_stop_btn.disabled = true
		return

	var limit := int(_parallel_spin.value)
	_log_line("Found %d chain(s)  (parallel limit: %d)" % [chains.size(), limit])
	_chains_queue = chains.duplicate()
	_active_chains = 0
	_run_active = true
	_node_progress.clear()
	_eta_start_ms = Time.get_ticks_msec()
	_eta_baseline_done = 0
	_eta_lbl.text = "  ETA: warming up…"
	_eta_timer.start()
	_pump_chains()


func _pump_chains() -> void:
	var limit := int(_parallel_spin.value)
	while _active_chains < limit and not _chains_queue.is_empty():
		# Pick the first queued chain whose Translate node is currently idle —
		# the same translate node can't run two chains at once.
		var idx := -1
		for i in _chains_queue.size():
			var tr = _chains_queue[i][1]
			if not (tr.has_method("is_running") and tr.is_running()):
				idx = i
				break
		if idx < 0:
			break  # all remaining chains share busy translate nodes — wait
		var chain: Array = _chains_queue[idx]
		_chains_queue.remove_at(idx)
		_active_chains += 1
		_start_chain(chain)

	if _active_chains == 0 and _chains_queue.is_empty() and _run_active:
		_run_active = false
		_eta_timer.stop()
		_eta_lbl.text = "  ETA: done"
		_log_line("[color=green]✓ All chains complete[/color]")
		_update_toolbar_buttons()
		_run_btn.disabled = false


func _start_chain(chain: Array) -> void:
	var tr  = chain[1]
	var file: String = String(chain[2]) if chain.size() > 2 else ""
	var exports: Array = []
	for i in range(3, chain.size()):
		exports.append(chain[i])

	if file.is_empty():
		_log_line("[color=red]Error: source has no file to translate[/color]")
		_active_chains -= 1
		_pump_chains()
		return

	_log_line("Chain  →  [b]%s[/b]" % file.get_file())
	tr.set_input_file(file)

	var err: String = tr.run()
	if not err.is_empty():
		_log_line("[color=red]Translate error: %s[/color]" % err)
		_active_chains -= 1
		_pump_chains()
		return

	tr.translation_done.connect(
		func(out: String) -> void:
			for ex in exports:
				ex.set_input_file(out)
				var ex_err: String = ex.run()
				if not ex_err.is_empty():
					_log_line("[color=red]Export error: %s[/color]" % ex_err)
			_active_chains -= 1
			_pump_chains(),
		CONNECT_ONE_SHOT
	)


func _build_chains() -> Array:
	var chains := []
	for child in _graph.get_children():
		if not child.has_method("get_selected_file"):
			continue
		# Collect the file list this source contributes. A Directory Source emits
		# one file per chain; a single-file source emits exactly one.
		var files: Array[String] = []
		if child.has_method("get_files"):
			files = child.get_files()
		if files.is_empty():
			var single: String = child.get_selected_file()
			if not single.is_empty():
				files = [single]
		if files.is_empty():
			continue

		for c1 in _graph.get_connection_list():
			if c1.from_node != child.name:
				continue
			var tr := _graph.get_node_or_null(NodePath(c1.to_node))
			if tr == null or not tr.has_method("run"):
				continue
			var exports: Array = []
			for c2 in _graph.get_connection_list():
				if c2.from_node != tr.name:
					continue
				var ex := _graph.get_node_or_null(NodePath(c2.to_node))
				if ex and ex.has_method("run") and ex.has_method("set_pending_input"):
					exports.append(ex)

			for f in files:
				var chain: Array = [child, tr, f]
				for ex_node in exports:
					chain.append(ex_node)
				chains.append(chain)
	return chains


# ── Progress + Preview ────────────────────────────────────────────────────────

func _on_progress(current: int, total: int, source: String, translated: String, node_name: String = "") -> void:
	# Record per-node progress for the ETA aggregator.
	if not node_name.is_empty():
		_node_progress[node_name] = {"current": current, "total": total}
		_refresh_eta()

	# Skip empty entries
	if source.is_empty():
		return

	var pct: String = (" %d%%" % int(100.0 * current / total)) if total > 0 else ""

	if not translated.is_empty():
		# Translation completed — log both source and translated, update preview
		_log_line("  · %d/%d%s" % [current, total, pct])
		_log_line("[color=#aab4cc]    📝 %s[/color]" % source)
		_log_line("[color=#5af094]    ✅ %s[/color]" % translated)
		_preview.text += "%s  →  %s\n" % [source, translated]
		_preview_label.text = "  Live translation (%d/%d)" % [current, total]


# ── ETA ──────────────────────────────────────────────────────────────────────

func _aggregate_progress() -> Dictionary:
	var done := 0
	var total := 0
	for k in _node_progress:
		var d: Dictionary = _node_progress[k]
		done += int(d.get("current", 0))
		total += int(d.get("total", 0))
	return {"done": done, "total": total}


func _refresh_eta() -> void:
	if not _run_active:
		return
	var agg := _aggregate_progress()
	var done: int = agg["done"]
	var total: int = agg["total"]
	if total <= 0 or done <= 0:
		_eta_lbl.text = "  ETA: warming up…"
		return

	var elapsed_ms := Time.get_ticks_msec() - _eta_start_ms
	var delta_done := done - _eta_baseline_done
	if delta_done <= 0 or elapsed_ms <= 0:
		_eta_lbl.text = "  ETA: warming up…"
		return

	var rate := float(delta_done) / (float(elapsed_ms) / 1000.0)  # strings / s
	if rate <= 0.0:
		_eta_lbl.text = "  ETA: —"
		return

	var remaining := total - done
	if remaining <= 0:
		_eta_lbl.text = "  ETA: finishing…"
		return

	var eta_sec := int(float(remaining) / rate)
	var finish := Time.get_unix_time_from_system() + eta_sec
	var finish_str := Time.get_time_string_from_unix_time(int(finish)).substr(0, 5)  # HH:MM
	_eta_lbl.text = "  ETA: %s left  •  ~%s  •  %d/%d" % [
		_format_duration(eta_sec), finish_str, done, total
	]


func _format_duration(sec: int) -> String:
	if sec < 60:
		return "%ds" % sec
	if sec < 3600:
		return "%dm %02ds" % [sec / 60, sec % 60]
	return "%dh %02dm" % [sec / 3600, (sec % 3600) / 60]


# ── Workflow save / load ──────────────────────────────────────────────────────

func _node_kind(node: Object) -> String:
	var script_path := (node.get_script() as Resource).resource_path
	if script_path.ends_with("file_source_node.gd"):
		return NODE_KIND_FILE
	if script_path.ends_with("directory_source_node.gd"):
		return NODE_KIND_DIRECTORY
	if script_path.ends_with("translate_node.gd"):
		return NODE_KIND_TRANSLATE
	if script_path.ends_with("export_node.gd"):
		return NODE_KIND_EXPORT
	if script_path.ends_with("prompt_node.gd"):
		return NODE_KIND_PROMPT
	return ""


func _save_workflow() -> void:
	# Quick save if we already have a path
	if not _current_workflow_path.is_empty():
		_do_save_workflow(_current_workflow_path)
		return
	_save_workflow_as()


func _save_workflow_as() -> void:
	if _save_dialog == null:
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(WORKFLOW_DIR))
		_save_dialog = EditorFileDialog.new()
		_save_dialog.file_mode = EditorFileDialog.FILE_MODE_SAVE_FILE
		_save_dialog.access = EditorFileDialog.ACCESS_RESOURCES
		_save_dialog.add_filter("*.json", "Workflow JSON")
		_save_dialog.current_path = WORKFLOW_DIR + "/workflow.json"
		_save_dialog.file_selected.connect(_do_save_workflow)
		add_child(_save_dialog)
	_save_dialog.popup_centered(Vector2i(900, 600))


func _do_save_workflow(path: String) -> void:
	var nodes_data := []
	for child in _graph.get_children():
		if not child.has_method("save_state"):
			continue
		var kind: String = _node_kind(child)
		if kind.is_empty():
			continue
		nodes_data.append({
			"name":   String(child.name),
			"kind":   kind,
			"pos":    [child.position_offset.x, child.position_offset.y],
			"state":  child.save_state(),
		})

	var connections := []
	for conn in _graph.get_connection_list():
		connections.append({
			"from":      String(conn.from_node),
			"from_port": int(conn.from_port),
			"to":        String(conn.to_node),
			"to_port":   int(conn.to_port),
		})

	var data := {
		"version":     1,
		"nodes":       nodes_data,
		"connections": connections,
	}

	var json_text := JSON.stringify(data, "\t")
	var abs := ProjectSettings.globalize_path(path)
	var file := FileAccess.open(abs, FileAccess.WRITE)
	if file == null:
		_log_line("[color=red]Save failed: cannot write %s[/color]" % abs)
		return
	file.store_string(json_text)
	file.close()
	_current_workflow_path = path
	_update_workflow_label()
	_log_line("[color=green]✓ Workflow saved → %s[/color]" % path)


func _load_workflow() -> void:
	if _load_dialog == null:
		_load_dialog = EditorFileDialog.new()
		_load_dialog.file_mode = EditorFileDialog.FILE_MODE_OPEN_FILE
		_load_dialog.access = EditorFileDialog.ACCESS_RESOURCES
		_load_dialog.add_filter("*.json", "Workflow JSON")
		_load_dialog.current_dir = WORKFLOW_DIR
		_load_dialog.file_selected.connect(_do_load_workflow)
		add_child(_load_dialog)
	_load_dialog.popup_centered(Vector2i(900, 600))


func _do_load_workflow(path: String) -> void:
	var abs := ProjectSettings.globalize_path(path)
	var file := FileAccess.open(abs, FileAccess.READ)
	if file == null:
		_log_line("[color=red]Load failed: cannot open %s[/color]" % abs)
		return
	var content := file.get_as_text()
	file.close()

	var p := JSON.new()
	if p.parse(content) != OK:
		_log_line("[color=red]Load failed: invalid JSON[/color]")
		return
	var data: Dictionary = p.get_data()

	_clear_graph()

	# Map saved node names → newly spawned node names
	var name_map: Dictionary = {}

	for entry in data.get("nodes", []):
		var d: Dictionary = entry
		var kind := str(d.get("kind", ""))
		var pos_arr: Array = d.get("pos", [80, 80])
		var pos := Vector2(float(pos_arr[0]), float(pos_arr[1]))
		var node: GraphNode = null
		match kind:
			NODE_KIND_FILE:      node = _spawn_typed(FileSourceScript,      pos)
			NODE_KIND_DIRECTORY: node = _spawn_typed(DirectorySourceScript, pos)
			NODE_KIND_TRANSLATE: node = _spawn_typed(TranslateScript,       pos)
			NODE_KIND_EXPORT:    node = _spawn_typed(ExportScript,          pos)
			NODE_KIND_PROMPT:    node = _spawn_typed(PromptScript,          pos)
		if node and node.has_method("load_state"):
			node.load_state(d.get("state", {}))
			name_map[str(d.get("name", ""))] = String(node.name)

	# Restore connections (mapped to new names) — propagate file paths too
	for conn in data.get("connections", []):
		var d: Dictionary = conn
		var new_from: String = name_map.get(str(d.get("from", "")), "")
		var new_to:   String = name_map.get(str(d.get("to", "")), "")
		if new_from.is_empty() or new_to.is_empty():
			continue
		_graph.connect_node(new_from, int(d.get("from_port", 0)),
				new_to, int(d.get("to_port", 0)))

		# Re-run connection-time propagation so Translate gets its file path
		var src_node := _graph.get_node_or_null(NodePath(new_from))
		var dst_node := _graph.get_node_or_null(NodePath(new_to))
		if src_node and dst_node:
			if src_node.has_method("get_selected_file") and dst_node.has_method("set_input_file"):
				dst_node.set_input_file(src_node.get_selected_file())
			elif src_node.has_method("get_output_file") and dst_node.has_method("set_pending_input"):
				dst_node.set_pending_input()

	_current_workflow_path = path
	_update_workflow_label()
	_log_line("[color=green]✓ Workflow loaded ← %s[/color]" % path)


func _spawn_typed(script: GDScript, pos: Vector2) -> GraphNode:
	var node: GraphNode = script.new() as GraphNode
	_graph.add_child(node)
	node.position_offset = pos
	_connect_node_signals(node)
	return node


func _clear_graph() -> void:
	_graph.clear_connections()
	for child in _graph.get_children():
		if child is GraphNode:
			child.queue_free()
	_current_workflow_path = ""
	_update_workflow_label()


# ── Preview ───────────────────────────────────────────────────────────────────

func _show_preview(path: String) -> void:
	var abs := ProjectSettings.globalize_path(path)
	var file := FileAccess.open(abs, FileAccess.READ)
	if file == null:
		_preview.text = "(cannot open file: %s)" % abs
		return
	var content := file.get_as_text()
	file.close()

	_preview.text = content
	_preview_label.text = "  %s  (%d lines, %d bytes)" % [
		path.get_file(),
		content.count("\n"),
		content.length(),
	]
	# Switch to Preview tab
	_output_tabs.current_tab = 1


# ── Log ───────────────────────────────────────────────────────────────────────

func _log_line(msg: String) -> void:
	if _log:
		_log.append_text(msg + "\n")


func _on_copy_log() -> void:
	if not _log:
		return
	# Prefer current selection; fall back to the full plain-text log.
	var text := _log.get_selected_text() if _log.get_selected_text() != "" else _log.get_parsed_text()
	if text.is_empty():
		return
	DisplayServer.clipboard_set(text)
	_log_line("[color=gray]› Copied %d chars to clipboard[/color]" % text.length())


func _log_info(msg: String) -> void:
	_log_line("  " + msg)


func _update_workflow_label() -> void:
	if _hint_lbl == null:
		return
	if _current_workflow_path.is_empty():
		_hint_lbl.text = ""
		_hint_lbl.visible = false
	else:
		_hint_lbl.text = "  📁 %s" % _current_workflow_path.get_file()
		_hint_lbl.visible = true


# ── Settings popup + GitHub update check ─────────────────────────────────────

const PLUGIN_CFG_PATH := "res://addons/localization_ai/plugin.cfg"
const GITHUB_REPO := "ismailivanov/LocalizationAI"
const GITHUB_RELEASES_URL := "https://github.com/" + GITHUB_REPO + "/releases"
const GITHUB_API_LATEST := "https://api.github.com/repos/" + GITHUB_REPO + "/releases/latest"
const DONATE_URL := "https://buymeacoffee.com/carbon06"
const LOGO_CREDIT_URL := "https://www.behance.net/warcedesign"

var _settings_window: AcceptDialog
var _about_status_lbl: Label
var _about_check_btn: Button
var _about_open_btn: Button
var _about_http: HTTPRequest
var _about_latest_url: String = ""


func _build_settings_button() -> void:
	if _run_btn == null:
		return
	var toolbar: Node = _run_btn.get_parent()
	if toolbar == null:
		return

	# HintLbl shows the loaded workflow filename; hide it when nothing is loaded
	# so the toolbar doesn't show a stray "(unsaved…)" snippet next to Settings.
	if _hint_lbl != null:
		_hint_lbl.size_flags_horizontal = Control.SIZE_FILL
		_hint_lbl.clip_text = true
		_hint_lbl.visible = false

	# Spacer absorbs leftover space → version + Settings sit at the right edge.
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	toolbar.add_child(spacer)

	var ver_lbl := Label.new()
	ver_lbl.text = "v%s" % _current_version()
	ver_lbl.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
	ver_lbl.tooltip_text = "LocalizationAI version"
	toolbar.add_child(ver_lbl)

	var btn := Button.new()
	btn.text = "⚙  Settings"
	btn.tooltip_text = "About & update check"
	btn.pressed.connect(_open_settings_window)
	toolbar.add_child(btn)

	_about_http = HTTPRequest.new()
	_about_http.request_completed.connect(_on_update_check_done)
	add_child(_about_http)


func _open_settings_window() -> void:
	if _settings_window == null:
		_settings_window = _build_settings_window()
		add_child(_settings_window)
	_settings_window.popup_centered(Vector2i(560, 360))


func _build_settings_window() -> AcceptDialog:
	var dlg := AcceptDialog.new()
	dlg.title = "Settings — LocalizationAI"

	var pad := MarginContainer.new()
	pad.add_theme_constant_override("margin_left", 18)
	pad.add_theme_constant_override("margin_right", 18)
	pad.add_theme_constant_override("margin_top", 12)
	pad.add_theme_constant_override("margin_bottom", 12)
	dlg.add_child(pad)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 10)
	pad.add_child(vb)

	var info := _read_plugin_info()

	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 14)
	vb.add_child(header)

	var icon_tex: Texture2D = load("res://addons/localization_ai/icon.svg") as Texture2D
	if icon_tex != null:
		var icon_rect := TextureRect.new()
		icon_rect.texture = icon_tex
		icon_rect.custom_minimum_size = Vector2(128, 128)
		icon_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		icon_rect.expand_mode = TextureRect.EXPAND_FIT_WIDTH_PROPORTIONAL
		header.add_child(icon_rect)

	var title_vb := VBoxContainer.new()
	title_vb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title_vb)

	var title_lbl := Label.new()
	title_lbl.text = str(info.get("name", "LocalizationAI"))
	title_lbl.add_theme_font_size_override("font_size", 20)
	title_vb.add_child(title_lbl)

	var ver_lbl := Label.new()
	ver_lbl.text = "Version  %s" % str(info.get("version", "?"))
	title_vb.add_child(ver_lbl)

	var author_lbl := Label.new()
	author_lbl.text = "Author   %s" % str(info.get("author", "?"))
	title_vb.add_child(author_lbl)

	var desc_lbl := Label.new()
	desc_lbl.text = str(info.get("description", ""))
	desc_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	desc_lbl.custom_minimum_size = Vector2(500, 0)
	desc_lbl.add_theme_color_override("font_color", Color(0.75, 0.75, 0.75))
	vb.add_child(desc_lbl)

	vb.add_child(HSeparator.new())

	var repo_lbl := Label.new()
	repo_lbl.text = "GitHub: " + GITHUB_REPO
	vb.add_child(repo_lbl)

	var btn_row := HBoxContainer.new()
	btn_row.add_theme_constant_override("separation", 10)
	vb.add_child(btn_row)

	_about_check_btn = Button.new()
	_about_check_btn.text = "🔄  Check for updates"
	_about_check_btn.pressed.connect(_check_for_updates)
	btn_row.add_child(_about_check_btn)

	var repo_btn := Button.new()
	repo_btn.text = "🌐  Open GitHub"
	repo_btn.pressed.connect(_open_github_repo)
	btn_row.add_child(repo_btn)

	_about_open_btn = Button.new()
	_about_open_btn.text = "⬇  Open latest release"
	_about_open_btn.visible = false
	_about_open_btn.pressed.connect(_open_latest_release)
	btn_row.add_child(_about_open_btn)

	_about_status_lbl = Label.new()
	_about_status_lbl.text = ""
	_about_status_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_about_status_lbl.custom_minimum_size = Vector2(500, 0)
	vb.add_child(_about_status_lbl)

	vb.add_child(HSeparator.new())

	var credits_row := HBoxContainer.new()
	credits_row.add_theme_constant_override("separation", 10)
	vb.add_child(credits_row)

	var donate_btn := Button.new()
	donate_btn.text = "☕  Buy me a coffee"
	donate_btn.tooltip_text = DONATE_URL
	donate_btn.pressed.connect(func() -> void: OS.shell_open(DONATE_URL))
	credits_row.add_child(donate_btn)

	var logo_btn := Button.new()
	logo_btn.text = "🎨  Logo by warcedesign"
	logo_btn.tooltip_text = LOGO_CREDIT_URL
	logo_btn.pressed.connect(func() -> void: OS.shell_open(LOGO_CREDIT_URL))
	credits_row.add_child(logo_btn)

	return dlg


func _read_plugin_info() -> Dictionary:
	var cfg := ConfigFile.new()
	var out := {
		"name": "LocalizationAI",
		"version": "0.0.0",
		"author": "",
		"description": "",
	}
	if cfg.load(PLUGIN_CFG_PATH) != OK:
		return out
	for key in out.keys():
		var v = cfg.get_value("plugin", key, out[key])
		out[key] = v
	return out


func _current_version() -> String:
	return str(_read_plugin_info().get("version", "0.0.0"))


func _open_github_repo() -> void:
	OS.shell_open("https://github.com/" + GITHUB_REPO)


func _open_latest_release() -> void:
	if not _about_latest_url.is_empty():
		OS.shell_open(_about_latest_url)


func _check_for_updates() -> void:
	if _about_http == null:
		return
	_about_status_lbl.add_theme_color_override("font_color", Color(0.75, 0.75, 0.75))
	_about_status_lbl.text = "Checking GitHub…"
	_about_open_btn.visible = false
	_about_check_btn.disabled = true
	var headers := ["Accept: application/vnd.github+json", "User-Agent: LocalizationAI"]
	var err := _about_http.request(GITHUB_API_LATEST, headers)
	if err != OK:
		_about_check_btn.disabled = false
		_about_status_lbl.add_theme_color_override("font_color", Color(1, 0.5, 0.5))
		_about_status_lbl.text = "Request failed to start (error %d)." % err


func _on_update_check_done(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	_about_check_btn.disabled = false
	if result != HTTPRequest.RESULT_SUCCESS:
		_about_status_lbl.add_theme_color_override("font_color", Color(1, 0.5, 0.5))
		_about_status_lbl.text = "Network error (result %d). Check your connection." % result
		return
	if code == 404:
		_about_status_lbl.add_theme_color_override("font_color", Color(1, 0.8, 0.4))
		_about_status_lbl.text = "No releases published yet on GitHub."
		return
	if code != 200:
		_about_status_lbl.add_theme_color_override("font_color", Color(1, 0.5, 0.5))
		_about_status_lbl.text = "GitHub returned HTTP %d." % code
		return

	var parser := JSON.new()
	if parser.parse(body.get_string_from_utf8()) != OK:
		_about_status_lbl.add_theme_color_override("font_color", Color(1, 0.5, 0.5))
		_about_status_lbl.text = "Could not parse GitHub response."
		return
	var data: Dictionary = parser.get_data()
	var tag := str(data.get("tag_name", "")).strip_edges()
	_about_latest_url = str(data.get("html_url", GITHUB_RELEASES_URL))
	if tag.is_empty():
		_about_status_lbl.add_theme_color_override("font_color", Color(1, 0.8, 0.4))
		_about_status_lbl.text = "Latest release has no tag."
		return

	var current := _current_version()
	var cmp := _compare_versions(tag, current)
	if cmp > 0:
		_about_status_lbl.add_theme_color_override("font_color", Color(0.4, 0.95, 0.55))
		_about_status_lbl.text = "Update available: %s  (you have %s)" % [tag, current]
		_about_open_btn.visible = true
	elif cmp == 0:
		_about_status_lbl.add_theme_color_override("font_color", Color(0.55, 0.75, 1.0))
		_about_status_lbl.text = "You are on the latest version (%s)." % current
	else:
		_about_status_lbl.add_theme_color_override("font_color", Color(0.75, 0.75, 0.75))
		_about_status_lbl.text = "Your version (%s) is ahead of the latest release (%s)." % [current, tag]


# Returns 1 if a > b, -1 if a < b, 0 if equal. Strips a leading 'v', compares
# dot-separated integer parts; non-numeric parts fall back to string compare.
static func _compare_versions(a: String, b: String) -> int:
	var ap := _parse_version(a)
	var bp := _parse_version(b)
	var n := max(ap.size(), bp.size())
	for i in n:
		var av: int = ap[i] if i < ap.size() else 0
		var bv: int = bp[i] if i < bp.size() else 0
		if av > bv: return 1
		if av < bv: return -1
	return 0


static func _parse_version(s: String) -> Array:
	var t := s.strip_edges().to_lower()
	if t.begins_with("v"):
		t = t.substr(1)
	# Strip pre-release/build suffix (e.g. 1.2.3-beta+ci).
	var dash := t.find("-")
	if dash >= 0: t = t.substr(0, dash)
	var plus := t.find("+")
	if plus >= 0: t = t.substr(0, plus)
	var parts := t.split(".")
	var out: Array = []
	for p in parts:
		out.append(int(p))
	return out
