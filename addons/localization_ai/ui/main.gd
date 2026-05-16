@tool
extends PanelContainer

const FileSourceScript      = preload("res://addons/localization_ai/ui/elements/file_source_node.gd")
const DirectorySourceScript = preload("res://addons/localization_ai/ui/elements/directory_source_node.gd")
const TranslateScript       = preload("res://addons/localization_ai/ui/elements/translate_node.gd")
const ExportScript          = preload("res://addons/localization_ai/ui/elements/export_node.gd")
const PromptScript          = preload("res://addons/localization_ai/ui/elements/prompt_node.gd")

@onready var _graph: GraphEdit       = $Tabs/Graph/GraphEdit
@onready var _log: RichTextLabel     = $Tabs/Graph/OutputTabs/Log/LogOutput
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
var _welcome_panel: Control = null

# Parallel chain scheduler + ETA tracker
var _chains_queue: Array = []
var _active_chains: int = 0
var _run_active: bool = false
var _graph_locked: bool = false
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
	_install_body_splitter()
	_setup_status_border()

	_log_line("[color=gray]=== Localization AI ready ===[/color]")
	_log_line("[color=gray]Right-click the graph to add nodes.[/color]")
	_report_orphan_partials()
	# Show the workflow picker on first open (when the graph is empty). Loading
	# a workflow or pressing "Start blank" dismisses it.
	call_deferred("_maybe_show_welcome")


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
	# Pipeline is "active" as long as either a node is mid-translation or there
	# are still queued chains waiting to start. A naive per-node check flips the
	# UI back to "done" between files when a Directory Source has more queued.
	var pipeline_active := _run_active or any_running or not _chains_queue.is_empty()
	_pause_btn.disabled = not any_running
	_stop_btn.disabled = not pipeline_active
	_run_btn.disabled = pipeline_active
	if not any_running:
		_pause_btn.text = "⏸  Pause"
	_set_graph_locked(pipeline_active)
	_refresh_status_border()


# ── Status border (green = running, orange = paused) ─────────────────────────

var _default_panel_style: StyleBox = null

func _setup_status_border() -> void:
	_default_panel_style = get_theme_stylebox("panel", "PanelContainer")
	_refresh_status_border()


func _refresh_status_border() -> void:
	var any_running := false
	var any_paused := false
	for child in _graph.get_children():
		if not (child.has_method("is_running") and child.is_running()):
			continue
		any_running = true
		if child.has_method("is_paused") and child.is_paused():
			any_paused = true

	# Border stays on for the whole pipeline, not just per-node — otherwise it
	# flickers off between files when a Directory Source has more queued.
	var pipeline_active := _run_active or any_running or not _chains_queue.is_empty()
	if not pipeline_active:
		remove_theme_stylebox_override("panel")
		return

	var color := Color(1.0, 0.6, 0.2) if any_paused else Color(0.35, 0.85, 0.45)
	var style := StyleBoxFlat.new()
	if _default_panel_style is StyleBoxFlat:
		var src: StyleBoxFlat = _default_panel_style
		style.bg_color = src.bg_color
	else:
		style.bg_color = Color(0, 0, 0, 0)
		style.draw_center = false
	style.border_width_left = 3
	style.border_width_top = 3
	style.border_width_right = 3
	style.border_width_bottom = 3
	style.border_color = color
	style.corner_radius_top_left = 4
	style.corner_radius_top_right = 4
	style.corner_radius_bottom_left = 4
	style.corner_radius_bottom_right = 4
	add_theme_stylebox_override("panel", style)


# ── Resizable bottom panel (GraphEdit ↕ Log) ─────────────────────────────────

func _install_body_splitter() -> void:
	var graph_vb: Node = _graph.get_parent()
	var output_header: Node = _clear_btn.get_parent()
	if graph_vb == null or output_header == null:
		return

	var graph_idx := _graph.get_index()
	graph_vb.remove_child(_graph)
	graph_vb.remove_child(output_header)
	graph_vb.remove_child(_output_tabs)

	_body_split = VSplitContainer.new()
	_body_split.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_body_split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	graph_vb.add_child(_body_split)
	graph_vb.move_child(_body_split, graph_idx)

	_graph.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_body_split.add_child(_graph)

	_body_bottom = VBoxContainer.new()
	_body_bottom.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_body_bottom.size_flags_vertical = Control.SIZE_FILL
	_body_bottom.custom_minimum_size = Vector2(0, 120)
	_body_split.add_child(_body_bottom)
	_body_bottom.add_child(output_header)
	_body_bottom.add_child(_output_tabs)
	_output_tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL

	# Drag handle nudges the bottom panel up; negative offset pulls split up.
	_body_split.split_offset = -220
	_saved_split_offset = _body_split.split_offset

	# Collapse / expand toggle, mimicking Godot's bottom-dock show/hide button.
	_toggle_btn = Button.new()
	_toggle_btn.text = "▾"
	_toggle_btn.flat = true
	_toggle_btn.tooltip_text = "Hide log panel"
	_toggle_btn.pressed.connect(_toggle_bottom_panel)
	output_header.add_child(_toggle_btn)
	output_header.move_child(_toggle_btn, 0)


var _body_split: VSplitContainer
var _body_bottom: VBoxContainer
var _toggle_btn: Button
var _saved_split_offset: int = -220
var _bottom_collapsed: bool = false


func shutdown_translations() -> void:
	# Called by the plugin on editor exit / plugin disable. Sends stop to every
	# running Translate node and blocks until its Python child has flushed the
	# _progress partial, so closing the editor mid-run doesn't lose work.
	if _graph == null:
		return
	for child in _graph.get_children():
		if child.has_method("is_running") and child.is_running():
			if child.has_method("stop_translation"):
				child.stop_translation()
	for child in _graph.get_children():
		if child.has_method("wait_for_finish"):
			child.wait_for_finish()


func _report_orphan_partials() -> void:
	# Translate writes intermediates to user://localization_ai/out/. After a
	# normal Run + Export they are cleaned up. Anything left over means a
	# previous session was killed (editor crash, force-quit) — surface those
	# paths so the user can recover them by hand.
	var tmp_dir := OS.get_user_data_dir().path_join("localization_ai/out")
	# Also peek at the pre-refactor location in case the user is upgrading
	# from an older plugin version.
	var legacy := OS.get_user_data_dir().path_join("localization_ai_out")
	if not DirAccess.dir_exists_absolute(tmp_dir) and DirAccess.dir_exists_absolute(legacy):
		tmp_dir = legacy
	if not DirAccess.dir_exists_absolute(tmp_dir):
		return
	var d := DirAccess.open(tmp_dir)
	if d == null:
		return
	var found: Array[String] = []
	d.list_dir_begin()
	while true:
		var name := d.get_next()
		if name.is_empty():
			break
		if d.current_is_dir():
			continue
		if name.ends_with("_progress.csv") or name.ends_with("_progress.po") \
				or name.ends_with("_translated.csv") or name.ends_with("_translated.po"):
			found.append(tmp_dir.path_join(name))
	d.list_dir_end()
	if found.is_empty():
		return
	_log_line("[color=yellow]⚠ Recovered %d unfinished translation(s) from a previous session:[/color]" % found.size())
	for p in found:
		_log_line("[color=yellow]    %s[/color]" % p)
	_log_line("[color=gray]    (Drag them into a File Source to resume, or delete them.)[/color]")


func _toggle_bottom_panel() -> void:
	_bottom_collapsed = not _bottom_collapsed
	if _bottom_collapsed:
		_saved_split_offset = _body_split.split_offset
		_output_tabs.visible = false
		_body_bottom.custom_minimum_size = Vector2(0, 0)
		# Slam the split all the way down so only the header strip shows.
		_body_split.split_offset = -_output_tabs.get_combined_minimum_size().y - 4
		await get_tree().process_frame
		_body_split.split_offset = -28
		_toggle_btn.text = "▴"
		_toggle_btn.tooltip_text = "Show log panel"
	else:
		_output_tabs.visible = true
		_body_bottom.custom_minimum_size = Vector2(0, 120)
		_body_split.split_offset = _saved_split_offset if _saved_split_offset < -100 else -220
		_toggle_btn.text = "▾"
		_toggle_btn.tooltip_text = "Hide log panel"


# ── Right-click handler ───────────────────────────────────────────────────────

func _on_graph_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton \
			and event.button_index == MOUSE_BUTTON_RIGHT \
			and event.pressed:
		if _graph_locked:
			_log_line("[color=gray]› Graph is locked while a translation is running. Pause or Stop first.[/color]")
			return
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
			_update_toolbar_buttons()
		)
	if node.has_signal("progress_updated"):
		node.progress_updated.connect(_on_progress.bind(String(node.name)))
	if node.has_signal("translation_paused"):
		node.translation_paused.connect(func() -> void:
			_pause_btn.text = "▶  Resume"
			_refresh_status_border()
		)
	if node.has_signal("translation_resumed"):
		node.translation_resumed.connect(func() -> void:
			_pause_btn.text = "⏸  Pause"
			_refresh_status_border()
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
	if _graph_locked:
		return
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
	if _graph_locked:
		return
	_graph.disconnect_node(from_node, from_port, to_node, to_port)


func _on_delete_nodes_request(nodes: Array[StringName]) -> void:
	if _graph_locked:
		_log_line("[color=gray]› Cannot delete nodes while a translation is running.[/color]")
		return
	for node_name in nodes:
		for conn in _graph.get_connection_list():
			if conn.from_node == node_name or conn.to_node == node_name:
				_graph.disconnect_node(conn.from_node, conn.from_port, conn.to_node, conn.to_port)
		
		var node = _graph.get_node_or_null(NodePath(node_name))
		if node:
			node.queue_free()
	_log_line("[color=gray]› Deleted %d node(s)[/color]" % nodes.size())


# ── Welcome panel (first-open workflow picker) ───────────────────────────────

func _has_graph_nodes() -> bool:
	if _graph == null:
		return false
	for child in _graph.get_children():
		if child is GraphNode:
			return true
	return false


func _maybe_show_welcome() -> void:
	if _welcome_panel != null or _has_graph_nodes() or _body_split == null:
		return
	_welcome_panel = _build_welcome_panel()
	_welcome_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_welcome_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	# Put the welcome panel in Tabs/Graph (the outer VBox) just above the body
	# splitter, then hide the splitter so the picker takes the full canvas
	# without disturbing the splitter's GraphEdit/Log children.
	var graph_vb: Node = _body_split.get_parent()
	graph_vb.add_child(_welcome_panel)
	graph_vb.move_child(_welcome_panel, _body_split.get_index())
	_body_split.visible = false


func _dismiss_welcome() -> void:
	if _welcome_panel == null:
		return
	_welcome_panel.queue_free()
	_welcome_panel = null
	if _body_split != null:
		_body_split.visible = true


func _build_welcome_panel() -> Control:
	var root := PanelContainer.new()
	root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root.size_flags_vertical = Control.SIZE_EXPAND_FILL

	var center := CenterContainer.new()
	center.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	center.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(center)

	var col := VBoxContainer.new()
	col.custom_minimum_size = Vector2(420, 0)
	col.add_theme_constant_override("separation", 8)
	center.add_child(col)

	var title := Label.new()
	title.text = "👋  Welcome to LocalizationAI"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 22)
	col.add_child(title)

	var subtitle := Label.new()
	subtitle.text = "Pick a starter workflow or begin with an empty graph."
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	subtitle.add_theme_color_override("font_color", Color(0.7, 0.7, 0.75))
	col.add_child(subtitle)

	var spacer1 := Control.new()
	spacer1.custom_minimum_size = Vector2(0, 12)
	col.add_child(spacer1)

	# One button per workflow JSON shipped with the plugin (and any the user
	# has saved alongside them).
	var workflows := _list_workflows()
	if workflows.is_empty():
		var none := Label.new()
		none.text = "(no starter workflows found in %s)" % WORKFLOW_DIR
		none.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		none.add_theme_color_override("font_color", Color(0.7, 0.55, 0.55))
		col.add_child(none)
	else:
		for path in workflows:
			var btn := Button.new()
			btn.text = "📁  %s" % path.get_file().get_basename()
			btn.tooltip_text = path
			btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			btn.pressed.connect(_on_welcome_workflow_pressed.bind(path))
			col.add_child(btn)

	var spacer2 := Control.new()
	spacer2.custom_minimum_size = Vector2(0, 16)
	col.add_child(spacer2)

	var blank_btn := Button.new()
	blank_btn.text = "Start with an empty graph"
	blank_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	blank_btn.pressed.connect(_dismiss_welcome)
	col.add_child(blank_btn)

	var hint := Label.new()
	hint.text = "You can reopen this picker any time by clearing the graph."
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.add_theme_color_override("font_color", Color(0.55, 0.55, 0.6))
	hint.add_theme_font_size_override("font_size", 11)
	col.add_child(hint)

	return root


func _on_welcome_workflow_pressed(path: String) -> void:
	_dismiss_welcome()
	_do_load_workflow(path)


func _list_workflows() -> Array[String]:
	var out: Array[String] = []
	var abs := ProjectSettings.globalize_path(WORKFLOW_DIR)
	var dir := DirAccess.open(abs)
	if dir == null:
		return out
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if not dir.current_is_dir() and entry.to_lower().ends_with(".json"):
			out.append(WORKFLOW_DIR + "/" + entry)
		entry = dir.get_next()
	dir.list_dir_end()
	out.sort()
	return out


# ── Graph lock (no edits while a translation is running) ─────────────────────

# We disable interactive widgets inside each GraphNode rather than overlay a
# transparent shield, because (a) the toolbar's Pause/Stop must stay clickable
# (b) users still want to scroll / zoom the graph to watch progress. Original
# state is remembered per-control via metadata so we can restore on unlock.

const _LOCK_PROPS := {
	"OptionButton": "disabled",
	"Button": "disabled",
	"MenuButton": "disabled",
	"CheckBox": "disabled",
	"CheckButton": "disabled",
	"SpinBox": "editable",
	"LineEdit": "editable",
	"TextEdit": "editable",
}


func _set_graph_locked(locked: bool) -> void:
	if locked == _graph_locked:
		return
	_graph_locked = locked
	for child in _graph.get_children():
		if not (child is GraphNode):
			continue
		var gn: GraphNode = child
		# Keep nodes selectable so the user can still inspect / pan to them,
		# but freeze their position and disable inner controls.
		if locked:
			if not gn.has_meta("_lock_draggable"):
				gn.set_meta("_lock_draggable", gn.draggable)
			gn.draggable = false
		else:
			if gn.has_meta("_lock_draggable"):
				gn.draggable = bool(gn.get_meta("_lock_draggable"))
				gn.remove_meta("_lock_draggable")
		_set_controls_locked(gn, locked)


func _set_controls_locked(root: Node, locked: bool) -> void:
	for c in root.get_children():
		if c is Control:
			_lock_single_control(c, locked)
		if c.get_child_count() > 0:
			_set_controls_locked(c, locked)


func _lock_single_control(c: Control, locked: bool) -> void:
	# Per-node flow controls (Pause / Stop on translate_node) opt out via meta
	# so users can still pause/stop a running file from the node itself.
	if c.has_meta("lock_exempt") and bool(c.get_meta("lock_exempt")):
		return
	var cls := c.get_class()
	var prop: String = _LOCK_PROPS.get(cls, "")
	# Some Godot classes don't show up exactly in the map (e.g. EditorSpinSlider
	# subclasses); fall back to inherits-from checks.
	if prop.is_empty():
		if c is Button:
			prop = "disabled"
		elif c is LineEdit:
			prop = "editable"
		elif c is SpinBox:
			prop = "editable"
	if prop.is_empty():
		return
	var meta_key := "_lock_" + prop
	if locked:
		if not c.has_meta(meta_key):
			c.set_meta(meta_key, c.get(prop))
		# disabled → set to true; editable → set to false
		c.set(prop, true if prop == "disabled" else false)
	else:
		if c.has_meta(meta_key):
			c.set(prop, c.get_meta(meta_key))
			c.remove_meta(meta_key)


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

	# Pre-flight: validate every Export node's destination before we kick off
	# any translation work, so the user finds out about a missing folder up front.
	var seen_exports := {}
	for chain in chains:
		for i in range(3, chain.size()):
			var ex = chain[i]
			if seen_exports.has(ex):
				continue
			seen_exports[ex] = true
			if not ex.has_method("validate_destination"):
				continue
			var dest_err: String = ex.validate_destination()
			if not dest_err.is_empty():
				_log_line("[color=red]✗ %s[/color]" % dest_err)
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
	_update_toolbar_buttons()


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
	# Tell each downstream export which file this chain originated from so it
	# can fall back to that folder if the user-chosen destination vanishes.
	for ex in exports:
		if ex.has_method("set_source_file"):
			ex.set_source_file(file)

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


# ── Progress ─────────────────────────────────────────────────────────────────

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
		# Translation completed — log both source and translated lines.
		_log_line("  · %d/%d%s" % [current, total, pct])
		_log_line("[color=#aab4cc]    📝 %s[/color]" % source)
		_log_line("[color=#5af094]    ✅ %s[/color]" % translated)


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
	_dismiss_welcome()
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
	# Bring the picker back so the user can grab a starter workflow without
	# digging through Load Workflow.
	call_deferred("_maybe_show_welcome")


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
		_hint_lbl.text = "📁 %s   " % _current_workflow_path.get_file()
		_hint_lbl.tooltip_text = _current_workflow_path
		_hint_lbl.add_theme_color_override("font_color", Color(0.6, 0.85, 1.0))
		_hint_lbl.visible = true


# ── Settings popup + GitHub update check ─────────────────────────────────────

const PLUGIN_CFG_PATH := "res://addons/localization_ai/plugin.cfg"
const GITHUB_REPO := "ismailivanov/LocalizationAI"
const GITHUB_RELEASES_URL := "https://github.com/" + GITHUB_REPO + "/releases"
# /releases/latest excludes pre-releases. The list endpoint returns the full
# set newest-first; we pick the first non-draft entry and optionally skip
# pre-releases based on user preference.
const GITHUB_API_LATEST := "https://api.github.com/repos/" + GITHUB_REPO + "/releases?per_page=10"
const DONATE_URL := "https://buymeacoffee.com/carbon06"
const LOGO_CREDIT_URL := "https://www.behance.net/warcedesign"

var _settings_window: AcceptDialog
var _about_status_lbl: Label
var _about_check_btn: Button
var _about_open_btn: Button
var _about_install_btn: Button
var _about_stable_only_chk: CheckBox
var _about_http: HTTPRequest
var _about_update_http: HTTPRequest
var _about_latest_url: String = ""
var _about_latest_tag: String = ""
var _about_zipball_url: String = ""

# Persistent user prefs live alongside the keyring under user://localization_ai/.
const _PREFS_FILE := "user://localization_ai/prefs.cfg"
const _PREFS_SECTION := "updates"


func _pref_get(key: String, fallback: Variant) -> Variant:
	var cfg := ConfigFile.new()
	if cfg.load(_PREFS_FILE) != OK:
		return fallback
	return cfg.get_value(_PREFS_SECTION, key, fallback)


func _pref_set(key: String, value: Variant) -> void:
	DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path("user://localization_ai"))
	var cfg := ConfigFile.new()
	cfg.load(_PREFS_FILE)
	cfg.set_value(_PREFS_SECTION, key, value)
	cfg.save(_PREFS_FILE)


func _build_settings_button() -> void:
	if _run_btn == null:
		return
	var toolbar: Node = _run_btn.get_parent()
	if toolbar == null:
		return

	# HintLbl shows the loaded workflow filename. It sits between the toolbar
	# separator and the Save/Load buttons so it's the first thing you read in
	# that group. Hidden when nothing is loaded so the toolbar stays tidy.
	if _hint_lbl != null:
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

	_about_install_btn = Button.new()
	_about_install_btn.text = "⬇  Install update"
	_about_install_btn.tooltip_text = "Download the new release and replace the plugin files in this project."
	_about_install_btn.visible = false
	_about_install_btn.pressed.connect(_start_auto_update)
	btn_row.add_child(_about_install_btn)

	_about_open_btn = Button.new()
	_about_open_btn.text = "🌐  Open release page"
	_about_open_btn.visible = false
	_about_open_btn.pressed.connect(_open_latest_release)
	btn_row.add_child(_about_open_btn)

	_about_stable_only_chk = CheckBox.new()
	_about_stable_only_chk.text = "Only check stable releases (skip pre-releases)"
	_about_stable_only_chk.tooltip_text = "When off, the update check picks up alpha / beta / rc releases too. Turn this on once a v1.0 stable exists and you only want to be notified about non-prerelease versions."
	_about_stable_only_chk.button_pressed = bool(_pref_get("stable_only", false))
	_about_stable_only_chk.toggled.connect(func(p: bool) -> void:
		_pref_set("stable_only", p)
	)
	vb.add_child(_about_stable_only_chk)

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
	var disk_path := ProjectSettings.globalize_path(PLUGIN_CFG_PATH)
	if cfg.load(disk_path) != OK:
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


# ── Auto-update ──────────────────────────────────────────────────────────────

func _start_auto_update() -> void:
	if _settings_window:
		_settings_window.hide()
	var updater: Node = preload("res://addons/localization_ai/ui/updater.gd").new()
	EditorInterface.get_base_control().add_child(updater)
	updater.run_update_flow(EditorInterface.get_base_control())


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
	# /releases returns an array, newest-first. Pick the first non-draft entry,
	# optionally skipping pre-releases when the user turned on "stable only".
	var arr = parser.get_data()
	if typeof(arr) != TYPE_ARRAY or (arr as Array).is_empty():
		_about_status_lbl.add_theme_color_override("font_color", Color(1, 0.8, 0.4))
		_about_status_lbl.text = "No releases published yet on GitHub."
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
	var tag := str(data.get("tag_name", "")).strip_edges()
	_about_latest_url = str(data.get("html_url", GITHUB_RELEASES_URL))
	if tag.is_empty():
		_about_status_lbl.add_theme_color_override("font_color", Color(1, 0.8, 0.4))
		_about_status_lbl.text = "No stable releases yet on GitHub." if stable_only \
				else "No public releases yet on GitHub."
		return
	var is_prerelease := bool(data.get("prerelease", false))
	_about_latest_tag = tag
	_about_zipball_url = str(data.get("zipball_url", ""))
	if _about_zipball_url.is_empty():
		_about_zipball_url = "https://github.com/" + GITHUB_REPO + "/archive/refs/tags/" + tag + ".zip"

	var current := _current_version()
	var cmp := _compare_versions(tag, current)
	var prerelease_tag := "  (pre-release)" if is_prerelease else ""
	if cmp > 0:
		_about_status_lbl.add_theme_color_override("font_color", Color(0.4, 0.95, 0.55))
		_about_status_lbl.text = "Update available: %s%s  (you have %s)" % [tag, prerelease_tag, current]
		_about_install_btn.visible = true
		_about_open_btn.visible = true
	elif cmp == 0:
		_about_status_lbl.add_theme_color_override("font_color", Color(0.55, 0.75, 1.0))
		_about_status_lbl.text = "You are on the latest version (%s)%s." % [current, prerelease_tag]
		_about_install_btn.visible = false
		_about_open_btn.visible = false
	else:
		_about_status_lbl.add_theme_color_override("font_color", Color(0.75, 0.75, 0.75))
		_about_status_lbl.text = "Your version (%s) is ahead of the latest release (%s)%s." % [current, tag, prerelease_tag]
		_about_install_btn.visible = false
		_about_open_btn.visible = false


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
