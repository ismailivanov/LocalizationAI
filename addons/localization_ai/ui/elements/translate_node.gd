@tool
extends GraphNode

const PORT_TYPE := 0
const PORT_COLOR := Color(0.3, 0.9, 0.5)

const PORT_TYPE_PROMPT := 1
const PORT_COLOR_PROMPT := Color(0.9, 0.7, 0.3)

const LANGUAGES := [
	["af", "Afrikaans"],
	["sq", "Albanian"],
	["am", "Amharic"],
	["ar", "Arabic"],
	["hy", "Armenian"],
	["az", "Azerbaijani"],
	["eu", "Basque"],
	["be", "Belarusian"],
	["bn", "Bengali"],
	["bs", "Bosnian"],
	["bg", "Bulgarian"],
	["my", "Burmese"],
	["ca", "Catalan"],
	["zh-CN", "Chinese (Simplified)"],
	["zh-TW", "Chinese (Traditional)"],
	["hr", "Croatian"],
	["cs", "Czech"],
	["da", "Danish"],
	["nl", "Dutch"],
	["en", "English"],
	["et", "Estonian"],
	["fi", "Finnish"],
	["fr", "French"],
	["gl", "Galician"],
	["ka", "Georgian"],
	["de", "German"],
	["el", "Greek"],
	["gu", "Gujarati"],
	["he", "Hebrew"],
	["hi", "Hindi"],
	["hu", "Hungarian"],
	["is", "Icelandic"],
	["id", "Indonesian"],
	["ga", "Irish"],
	["it", "Italian"],
	["ja", "Japanese"],
	["kn", "Kannada"],
	["kk", "Kazakh"],
	["km", "Khmer"],
	["ko", "Korean"],
	["ku", "Kurdish"],
	["lo", "Lao"],
	["lv", "Latvian"],
	["lt", "Lithuanian"],
	["mk", "Macedonian"],
	["ms", "Malay"],
	["ml", "Malayalam"],
	["mt", "Maltese"],
	["mr", "Marathi"],
	["mn", "Mongolian"],
	["ne", "Nepali"],
	["no", "Norwegian"],
	["fa", "Persian"],
	["pl", "Polish"],
	["pt", "Portuguese"],
	["pt-BR", "Portuguese (Brazil)"],
	["pa", "Punjabi"],
	["ro", "Romanian"],
	["ru", "Russian"],
	["sr", "Serbian"],
	["si", "Sinhala"],
	["sk", "Slovak"],
	["sl", "Slovenian"],
	["es", "Spanish"],
	["es-419", "Spanish (Latin America)"],
	["sw", "Swahili"],
	["sv", "Swedish"],
	["tl", "Tagalog"],
	["ta", "Tamil"],
	["te", "Telugu"],
	["th", "Thai"],
	["tr", "Turkish"],
	["uk", "Ukrainian"],
	["ur", "Urdu"],
	["uz", "Uzbek"],
	["vi", "Vietnamese"],
	["cy", "Welsh"],
]

signal translation_done(output_path: String)
signal log_message(text: String)
signal progress_updated(current: int, total: int, source: String, translated: String)
signal translation_paused()
signal translation_resumed()
signal translation_stopped()

var _provider: OptionButton    # [0]  ← INPUT port
var _api_field: LineEdit       # [1]
var _model_row: HBoxContainer  # [2]
var _model_select: OptionButton
var _model_refresh_btn: Button
var _model_field: LineEdit
var _src_lang: OptionButton    # [3]
var _lang_btn: MenuButton      # [4]
var _selected_langs: Array[String] = []
var _status: Label             # [5]
var _btn_container: HBoxContainer  # [6]
var _pause_btn: Button
var _stop_btn: Button
var _source_header: Label      # [7]
var _source_label: Label       # [8]
var _translated_header: Label  # [9]
var _translated_label: Label   # [10]  → OUTPUT port

var _thread: Thread
var _input_file: String = ""
var _output_file: String = ""
var _progress_file: String = ""
var _control_file: String = ""
var _prompt_file: String = ""
var _progress_timer: Timer
var _last_progress_text: String = ""
var _last_progress_current: int = -1
var _is_running: bool = false
var _is_paused: bool = false

# Memory safety threshold (MB). If free RAM drops below this during
# translation, the backend aborts cleanly to keep the OS responsive.
var _min_free_mb: int = 800


func _init() -> void:
	title = "Translate"
	custom_minimum_size = Vector2(320, 0)


func _ready() -> void:
	_provider = OptionButton.new()
	_provider.add_item("Local AI (Ollama)")
	_provider.add_item("OpenRouter")
	_provider.item_selected.connect(_on_provider_changed)
	add_child(_provider)

	var prompt_hint = Label.new()
	prompt_hint.text = "✍️ Custom Prompts"
	prompt_hint.add_theme_font_size_override("font_size", 12)
	prompt_hint.add_theme_color_override("font_color", Color(0.9, 0.7, 0.3))
	add_child(prompt_hint)

	_api_field = LineEdit.new()
	_api_field.placeholder_text = "API URL (http://localhost:11434)"
	add_child(_api_field)

	# Model picker: dropdown of installed local models + refresh + custom name field.
	# Wrapped in a VBoxContainer so we keep a single top-level child (slot indices stay valid).
	_model_row = HBoxContainer.new()
	_model_row.custom_minimum_size = Vector2(320, 0)

	var model_box := VBoxContainer.new()
	model_box.add_theme_constant_override("separation", 2)

	_model_select = OptionButton.new()
	_model_select.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_model_select.add_item("(local: refresh to load)")
	_model_select.disabled = true
	_model_select.item_selected.connect(_on_local_model_selected)
	_model_row.add_child(_model_select)

	_model_refresh_btn = Button.new()
	_model_refresh_btn.text = "↻"
	_model_refresh_btn.tooltip_text = "Refresh installed Ollama models"
	_model_refresh_btn.pressed.connect(_refresh_local_models)
	_model_row.add_child(_model_refresh_btn)

	model_box.add_child(_model_row)

	_model_field = LineEdit.new()
	_model_field.placeholder_text = "Model (llama3.2) — or pick above"
	model_box.add_child(_model_field)

	add_child(model_box)

	_src_lang = OptionButton.new()
	_src_lang.add_item("(connect a file)")
	_src_lang.disabled = true
	add_child(_src_lang)

	_lang_btn = MenuButton.new()
	_lang_btn.text = "🌍 Select Languages"
	_lang_btn.custom_minimum_size = Vector2(320, 0)
	_lang_btn.flat = false
	var popup := _lang_btn.get_popup()
	for i in LANGUAGES.size():
		popup.add_check_item("%s — %s" % [LANGUAGES[i][0], LANGUAGES[i][1]], i)
	popup.id_pressed.connect(_on_lang_toggled)
	popup.hide_on_checkable_item_selection = false
	add_child(_lang_btn)

	_status = Label.new()
	_status.text = "Connect a File Source"
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.custom_minimum_size = Vector2(320, 0)
	add_child(_status)

	# ── Pause / Stop buttons ─────────────────────────────────────────────
	_btn_container = HBoxContainer.new()
	_btn_container.alignment = BoxContainer.ALIGNMENT_CENTER

	_pause_btn = Button.new()
	_pause_btn.text = "⏸  Pause"
	_pause_btn.disabled = true
	_pause_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_pause_btn.pressed.connect(_on_pause_pressed)
	_btn_container.add_child(_pause_btn)

	_stop_btn = Button.new()
	_stop_btn.text = "⏹  Stop"
	_stop_btn.disabled = true
	_stop_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_stop_btn.pressed.connect(_on_stop_pressed)
	_btn_container.add_child(_stop_btn)

	add_child(_btn_container)

	# ── Source text preview ──────────────────────────────────────────────
	_source_header = Label.new()
	_source_header.text = "📝 Source:"
	_source_header.add_theme_color_override("font_color", Color(0.6, 0.7, 0.85))
	_source_header.add_theme_font_size_override("font_size", 11)
	add_child(_source_header)

	_source_label = Label.new()
	_source_label.text = ""
	_source_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_source_label.custom_minimum_size = Vector2(320, 0)
	_source_label.add_theme_color_override("font_color", Color(0.85, 0.85, 0.85))
	add_child(_source_label)

	# ── Translated text preview ──────────────────────────────────────────
	_translated_header = Label.new()
	_translated_header.text = "✅ Translated:"
	_translated_header.add_theme_color_override("font_color", Color(0.35, 0.8, 0.5))
	_translated_header.add_theme_font_size_override("font_size", 11)
	add_child(_translated_header)

	_translated_label = Label.new()
	_translated_label.text = ""
	_translated_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_translated_label.custom_minimum_size = Vector2(320, 0)
	_translated_label.add_theme_color_override("font_color", Color(0.35, 0.95, 0.55))
	add_child(_translated_label)

	# Slot 0 = Provider OptionButton (Left: File Input, Right: nothing)
	set_slot(0, true,  PORT_TYPE, PORT_COLOR, false, PORT_TYPE, Color.WHITE)
	# Slot 1 = Prompt Hint Label (Left: Prompt Input, Right: nothing)
	set_slot(1, true, PORT_TYPE_PROMPT, PORT_COLOR_PROMPT, false, PORT_TYPE, Color.WHITE)
	# Slot 11 = Translated Label (Left: nothing, Right: File Output)
	set_slot(11, false, PORT_TYPE, Color.WHITE, true,  PORT_TYPE, PORT_COLOR)

	_progress_timer = Timer.new()
	_progress_timer.wait_time = 0.5
	_progress_timer.timeout.connect(_read_progress)
	add_child(_progress_timer)


# ── Public API ────────────────────────────────────────────────────────────────

func set_input_file(path: String) -> void:
	_input_file = path
	_populate_source_langs(path)
	_apply_pending_source_lang()


func get_output_file() -> String:
	return _output_file


func is_running() -> bool:
	return _is_running


func is_paused() -> bool:
	return _is_paused


# ── Pause / Stop ──────────────────────────────────────────────────────────────

func pause_translation() -> void:
	if not _is_running or _is_paused:
		return
	_is_paused = true
	_write_control("pause")
	_pause_btn.text = "▶  Resume"
	_stop_btn.disabled = false
	_status.text = "⏸ Paused"
	log_message.emit("Translate: ⏸ paused")
	translation_paused.emit()


func resume_translation() -> void:
	if not _is_running or not _is_paused:
		return
	_is_paused = false
	_write_control("run")
	_pause_btn.text = "⏸  Pause"
	_status.text = "Translating…"
	log_message.emit("Translate: ▶ resumed")
	translation_resumed.emit()


func stop_translation() -> void:
	if not _is_running:
		return
	_write_control("stop")
	_pause_btn.disabled = true
	_stop_btn.disabled = true
	_status.text = "⏹ Stopping…"
	log_message.emit("Translate: ⏹ stopping…")


func _on_pause_pressed() -> void:
	if _is_paused:
		resume_translation()
	else:
		pause_translation()


func _on_stop_pressed() -> void:
	stop_translation()


func _write_control(command: String) -> void:
	if _control_file.is_empty():
		return
	var file := FileAccess.open(_control_file, FileAccess.WRITE)
	if file == null:
		return
	file.store_string(JSON.stringify({"command": command}))
	file.close()


func _set_buttons_running(running: bool) -> void:
	_is_running = running
	_is_paused = false
	_pause_btn.disabled = not running
	_stop_btn.disabled = not running
	_pause_btn.text = "⏸  Pause"


# ── Workflow save / load ─────────────────────────────────────────────────────

func save_state() -> Dictionary:
	var src_lang := ""
	if _src_lang and not _src_lang.disabled and _src_lang.item_count > 0:
		src_lang = _src_lang.get_item_text(_src_lang.selected)
	return {
		"provider":    _provider.selected,
		"api":         _api_field.text,
		"model":       _model_field.text,
		"source_lang": src_lang,
		"target_langs": ",".join(PackedStringArray(_selected_langs)),
	}


func load_state(data: Dictionary) -> void:
	_provider.select(int(data.get("provider", 0)))
	_on_provider_changed(_provider.selected)
	_api_field.text   = str(data.get("api", ""))
	_model_field.text = str(data.get("model", ""))
	# Restore target languages (support both old "target_lang" and new "target_langs")
	var tl := str(data.get("target_langs", data.get("target_lang", "")))
	if not tl.is_empty():
		for code in tl.split(","):
			_select_lang_by_code(code.strip_edges())
	# Source lang only applies once a file is connected; remember for later
	set_meta("pending_source_lang", str(data.get("source_lang", "")))


func _apply_pending_source_lang() -> void:
	if not has_meta("pending_source_lang"):
		return
	var want := str(get_meta("pending_source_lang"))
	remove_meta("pending_source_lang")
	if want.is_empty():
		return
	for i in _src_lang.item_count:
		if _src_lang.get_item_text(i) == want:
			_src_lang.select(i)
			return


# Returns "" on success, or an error string.
func run() -> String:
	if _input_file.is_empty():
		return "no file connected"
	if _model_field.text.strip_edges().is_empty():
		return "model name is empty"
	if _selected_langs.is_empty():
		return "no target language selected"
	if _provider.selected == 1 and _api_field.text.strip_edges().is_empty():
		return "OpenRouter API key is empty"
	if _input_file.get_extension().to_lower() == "csv" \
			and (_src_lang.disabled or _src_lang.item_count == 0):
		return "CSV has no source language column"

	_status.text = "Translating…"
	_source_label.text = ""
	_translated_label.text = ""
	log_message.emit("Translate: starting  →  " + _input_file.get_file())

	_progress_file = OS.get_user_data_dir().path_join(
		"localization_ai_progress_%d.json" % Time.get_ticks_msec()
	)
	_control_file = OS.get_user_data_dir().path_join(
		"localization_ai_control_%d.json" % Time.get_ticks_msec()
	)
	_write_control("run")

	_prompt_file = ""
	var prompts := _collect_prompts()
	if not prompts.is_empty():
		var user_dir := ProjectSettings.globalize_path("user://")
		DirAccess.make_dir_recursive_absolute(user_dir)
		_prompt_file = user_dir.path_join(
			"localization_ai_prompts_%d.json" % Time.get_ticks_msec()
		)
		var pf := FileAccess.open(_prompt_file, FileAccess.WRITE)
		if pf != null:
			pf.store_string(JSON.stringify(prompts))
			pf.close()
			log_message.emit("[color=gray]› Sent %d prompt scopes to backend[/color]" % prompts.size())
		else:
			_prompt_file = ""
			log_message.emit("[color=red]Failed to write prompt file![/color]")
	else:
		log_message.emit("[color=gray]› No custom prompts found[/color]")

	_last_progress_current = -1
	_last_progress_text = ""
	_set_buttons_running(true)
	_progress_timer.start()

	_thread = Thread.new()
	_thread.start(_run_translation)
	return ""


# ── Source language detection ─────────────────────────────────────────────────

func _populate_source_langs(path: String) -> void:
	# Remember the previous selection so iterating a Directory Source over
	# multiple files with the same columns doesn't reset the picker each time.
	var prev_sel := ""
	if _src_lang and not _src_lang.disabled and _src_lang.item_count > 0:
		prev_sel = _src_lang.get_item_text(_src_lang.selected)

	_src_lang.clear()
	if path.is_empty():
		_src_lang.add_item("(connect a file)")
		_src_lang.disabled = true
		_status.text = "Connect a File Source"
		return

	var ext := path.get_extension().to_lower()
	if ext == "po":
		_src_lang.add_item("(from msgid)")
		_src_lang.disabled = true
		_status.text = "Ready  →  " + path.get_file()
		return

	if ext == "csv":
		var langs := _read_csv_languages(path)
		if langs.is_empty():
			_src_lang.add_item("No language columns")
			_src_lang.disabled = true
			_status.text = "Error: CSV has no language columns"
			return
		for l in langs:
			_src_lang.add_item(l)
		_src_lang.disabled = false
		_status.text = "Ready  →  " + path.get_file()
		if not prev_sel.is_empty():
			for i in _src_lang.item_count:
				if _src_lang.get_item_text(i) == prev_sel:
					_src_lang.select(i)
					break
		return

	_src_lang.add_item("Unsupported")
	_src_lang.disabled = true
	_status.text = "Unsupported file type"


func _read_csv_languages(path: String) -> PackedStringArray:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		file = FileAccess.open(ProjectSettings.globalize_path(path), FileAccess.READ)
	if file == null:
		return PackedStringArray()
	var header := file.get_csv_line()
	file.close()
	var langs := PackedStringArray()
	for col in header:
		var c := col.strip_edges()
		var lc := c.to_lower()
		if c.is_empty() or lc == "keys" or lc == "key" or lc == "id":
			continue
		langs.append(c)
	return langs


# ── Callbacks ─────────────────────────────────────────────────────────────────

func _on_provider_changed(idx: int) -> void:
	if idx == 0:
		_api_field.placeholder_text = "API URL (http://localhost:11434)"
		_api_field.secret = false
		_model_row.visible = true
		_model_field.placeholder_text = "Model (llama3.2) — or pick above"
		# Auto-populate dropdown the first time we switch to local.
		if _model_select.item_count <= 1:
			_refresh_local_models()
	else:
		_api_field.placeholder_text = "OpenRouter API Key"
		_api_field.secret = true
		_model_row.visible = false
		_model_field.placeholder_text = "Model (e.g. openai/gpt-4o-mini)"


func _on_local_model_selected(idx: int) -> void:
	if idx <= 0:
		return
	_model_field.text = _model_select.get_item_text(idx).split("  ")[0]


func _refresh_local_models() -> void:
	var url := _api_field.text.strip_edges()
	if url.is_empty():
		url = "http://localhost:11434"
	var script_path := ProjectSettings.globalize_path("res://addons/localization_ai/scripts/manage_models.py")
	var args := PackedStringArray([script_path, "--api-url", url, "--action", "list"])
	var out: Array = []
	OS.execute(_python(), args, out)
	var data := _last_json_dict(out)

	_model_select.clear()
	if data.get("type", "") != "models":
		_model_select.add_item("(Ollama not reachable)")
		_model_select.disabled = true
		return

	var models: Array = data.get("models", [])
	if models.is_empty():
		_model_select.add_item("(no local models — use Models tab)")
		_model_select.disabled = true
		return

	_model_select.add_item("— select installed model —")
	for m in models:
		if typeof(m) == TYPE_DICTIONARY:
			var sz := float(m.get("size", 0)) / (1024.0 * 1024.0 * 1024.0)
			_model_select.add_item("%s  (%.1f GB)" % [str(m.get("name", "")), sz])
		else:
			_model_select.add_item(str(m))
	_model_select.disabled = false

	# If current model field matches an installed one, pre-select it.
	var current := _model_field.text.strip_edges()
	if not current.is_empty():
		for i in range(1, _model_select.item_count):
			if _model_select.get_item_text(i).split("  ")[0] == current:
				_model_select.select(i)
				break


func _last_json_dict(raw: Array) -> Dictionary:
	var joined := "\n".join(PackedStringArray(raw))
	for line in joined.split("\n"):
		var l := line.strip_edges()
		if not l.begins_with("{"):
			continue
		var p := JSON.new()
		if p.parse(l) == OK:
			var d = p.get_data()
			if typeof(d) == TYPE_DICTIONARY and d.get("type", "") == "models":
				return d
	return {}


func _on_lang_toggled(id: int) -> void:
	var popup := _lang_btn.get_popup()
	var idx := popup.get_item_index(id)
	popup.toggle_item_checked(idx)
	_rebuild_selected_langs()


func _rebuild_selected_langs() -> void:
	_selected_langs.clear()
	var popup := _lang_btn.get_popup()
	for i in popup.item_count:
		if popup.is_item_checked(i):
			_selected_langs.append(LANGUAGES[i][0])
	if _selected_langs.is_empty():
		_lang_btn.text = "🌍 Select Languages"
	else:
		_lang_btn.text = "🌍 " + ", ".join(PackedStringArray(_selected_langs))


func _select_lang_by_code(code: String) -> void:
	var popup := _lang_btn.get_popup()
	for i in LANGUAGES.size():
		if LANGUAGES[i][0] == code:
			var idx := popup.get_item_index(i)
			if not popup.is_item_checked(idx):
				popup.toggle_item_checked(idx)
			_rebuild_selected_langs()
			return


# ── Background work ───────────────────────────────────────────────────────────

func _run_translation() -> void:
	var script := ProjectSettings.globalize_path("res://addons/localization_ai/scripts/translate.py")
	var input_g := ProjectSettings.globalize_path(_input_file)
	var ext := _input_file.get_extension()
	# Write the intermediate translated/partial file into user:// so it never
	# pollutes the source folder (and never triggers Godot's CSV-translation
	# auto-import, which leaves orphan .import / .translation sidecars behind).
	# The Export node picks this up via translation_done and copies it to the
	# user-chosen destination.
	var tmp_dir := OS.get_user_data_dir().path_join("localization_ai_out")
	DirAccess.make_dir_recursive_absolute(tmp_dir)
	var src_stem := _input_file.get_file().get_basename() \
			.trim_suffix("_progress").trim_suffix("_translated")
	var base := tmp_dir.path_join("%s_%d" % [src_stem, Time.get_ticks_msec()])
	var out_g := base + "_translated." + ext
	var stopped_g := base + "_progress." + ext

	var args: Array[String] = [
		script,
		"--input",       input_g,
		"--output",      out_g,
		"--stopped-output", stopped_g,
		"--provider",    "local" if _provider.selected == 0 else "openrouter",
		"--model",       _model_field.text.strip_edges(),
		"--target-lang", ",".join(PackedStringArray(_selected_langs)),
	]

	if _input_file.get_extension().to_lower() == "csv" and not _src_lang.disabled:
		args.append_array(["--source-lang",
				_src_lang.get_item_text(_src_lang.selected)])

	if _provider.selected == 0:
		var url := _api_field.text.strip_edges()
		args.append_array(["--api-url",
				url if not url.is_empty() else "http://localhost:11434"])
	else:
		args.append_array(["--api-key", _api_field.text.strip_edges()])

	if not _progress_file.is_empty():
		args.append_array(["--progress-file", _progress_file])

	if not _control_file.is_empty():
		args.append_array(["--control-file", _control_file])

	if not _prompt_file.is_empty():
		args.append_array(["--prompts-file", _prompt_file])

	# Low-memory safety: abort if free RAM drops below this threshold (MB).
	# Prevents the OS from freezing when a too-large local model spills into swap.
	args.append_array(["--min-free-mb", str(_min_free_mb)])

	var raw: Array = []
	var exit_code := OS.execute(_python(), args, raw)
	call_deferred("_on_done", exit_code, raw, out_g)


func _collect_prompts() -> Dictionary:
	var result := {}
	var parent := get_parent()
	if parent and parent.has_method("get_connection_list"):
		var conns = parent.get_connection_list()
		for conn in conns:
			if String(conn.to_node) == String(name) and int(conn.to_port) == 1:
				var prompt_node := parent.get_node_or_null(NodePath(String(conn.from_node)))
				if prompt_node and prompt_node.has_method("get_scope") and prompt_node.has_method("get_prompt_text"):
					var scope: String = prompt_node.get_scope()
					var txt: String = prompt_node.get_prompt_text()
					if not txt.is_empty():
						if not result.has(scope):
							result[scope] = []
						result[scope].append(txt)
	return result


func _read_progress() -> void:
	if _progress_file.is_empty() or not FileAccess.file_exists(_progress_file):
		return
	var file := FileAccess.open(_progress_file, FileAccess.READ)
	if file == null:
		return
	var content := file.get_as_text()
	file.close()
	var p := JSON.new()
	if p.parse(content) != OK:
		return
	var d: Dictionary = p.get_data()
	var current := int(d.get("current", 0))
	var total := int(d.get("total", 0))
	var source := str(d.get("source", ""))
	var translated := str(d.get("translated", ""))
	var last_source := str(d.get("last_source", ""))
	var last_translated := str(d.get("last_translated", ""))

	if total > 0 and not _is_paused:
		_status.text = "Translating %d/%d…" % [current, total]
	elif not _is_paused:
		_status.text = "Translating…"

	# Show current source being translated
	if not source.is_empty():
		_source_label.text = source

	# Show translated result: prefer current if available, else last completed
	if not translated.is_empty():
		_translated_label.text = translated
	elif not last_translated.is_empty():
		_translated_label.text = last_translated
	elif not source.is_empty():
		_translated_label.text = "…"

	# Emit when counter advances — use last completed data for the signal
	if current != _last_progress_current:
		_last_progress_current = current
		# Emit with the completed translation data
		if not last_source.is_empty() and not last_translated.is_empty():
			progress_updated.emit(current, total, last_source, last_translated)
		elif not translated.is_empty():
			progress_updated.emit(current, total, source, translated)
	elif source != _last_progress_text:
		_last_progress_text = source
		# New source started (in-progress, no translation yet)
		progress_updated.emit(current, total, source, "")


func _cleanup_progress() -> void:
	_progress_timer.stop()
	if not _progress_file.is_empty() and FileAccess.file_exists(_progress_file):
		DirAccess.remove_absolute(_progress_file)
	_progress_file = ""
	if not _control_file.is_empty() and FileAccess.file_exists(_control_file):
		DirAccess.remove_absolute(_control_file)
	_control_file = ""


func _on_done(exit_code: int, raw: Array, output_path: String) -> void:
	_thread.wait_to_finish()
	_cleanup_progress()
	_set_buttons_running(false)
	var joined := "\n".join(PackedStringArray(raw))

	for line in joined.split("\n"):
		line = line.strip_edges()
		if not line.begins_with("{"):
			continue
		var p := JSON.new()
		if p.parse(line) != OK:
			continue
		var d: Dictionary = p.get_data()
		match d.get("type", ""):
			"done":
				_output_file = ProjectSettings.localize_path(output_path)
				var msg := "Done (%d strings)" % d.get("count", 0)
				_status.text = msg
				log_message.emit("Translate: " + msg)
				translation_done.emit(_output_file)
				return
			"stopped":
				var partial_path := str(d.get("output", output_path))
				_output_file = ProjectSettings.localize_path(partial_path)
				var count_done := int(d.get("count", 0))
				var reason := str(d.get("reason", ""))
				var msg: String
				if reason == "low_memory":
					msg = "⚠ Stopped — low memory: %d MB free (< %d MB). Pick a smaller model. (%d strings done)" % [
						int(d.get("free_mb", 0)),
						int(d.get("threshold_mb", 0)),
						count_done,
					]
				else:
					msg = "⏹ Stopped (%d strings translated)" % count_done
				_status.text = msg
				log_message.emit("Translate: " + msg)
				log_message.emit("Translate: partial file → " + partial_path.get_file())
				translation_stopped.emit()
				# Route the partial _progress file through any connected Export node
				# so it lands in the export destination and can be resumed later.
				if FileAccess.file_exists(partial_path):
					translation_done.emit(_output_file)
				return
			"error":
				var msg := "Error: " + str(d.get("message", ""))
				_status.text = msg
				log_message.emit("Translate: " + msg)
				return

	if exit_code == 0:
		_output_file = ProjectSettings.localize_path(output_path)
		_status.text = "Done"
		log_message.emit("Translate: done")
		translation_done.emit(_output_file)
	else:
		_status.text = "Failed (exit %d)" % exit_code
		log_message.emit("Translate: failed\n" + joined.left(200))


static func _python() -> String:
	return "python" if OS.get_name() == "Windows" else "python3"
