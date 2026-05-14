@tool
extends MarginContainer

# Curated Ollama models with rough Q4 VRAM / disk-size estimates.
# Sizes are approximate — actual usage depends on quant & context length.
const POPULAR := [
	# ── OpenAI open-weight ────────────────────────────────────────────────
	{"name": "gpt-oss:20b",     "params": "20B",   "size_gb": 12.1, "vram_gb": 14.0, "desc": "OpenAI open-weight (gpt-oss), strong general model"},
	{"name": "gpt-oss:120b",    "params": "120B",  "size_gb": 65.0, "vram_gb": 80.0, "desc": "OpenAI open-weight flagship — needs serious GPU"},
	# ── Llama family ──────────────────────────────────────────────────────
	{"name": "llama3.2:1b",     "params": "1B",    "size_gb": 1.3,  "vram_gb": 1.5,  "desc": "Fastest, very low VRAM"},
	{"name": "llama3.2",        "params": "3B",    "size_gb": 2.0,  "vram_gb": 2.5,  "desc": "Small & fast, decent quality"},
	{"name": "llama3.1",        "params": "8B",    "size_gb": 4.7,  "vram_gb": 6.0,  "desc": "Solid all-rounder"},
	{"name": "llama3.1:8b",     "params": "8B",    "size_gb": 4.7,  "vram_gb": 6.0,  "desc": "Same as llama3.1"},
	{"name": "llama3.1:70b",    "params": "70B",   "size_gb": 40.0, "vram_gb": 48.0, "desc": "Top-tier quality, heavy"},
	{"name": "llama3.3",        "params": "70B",   "size_gb": 43.0, "vram_gb": 48.0, "desc": "Llama 3.3 70B — best Llama open model"},
	# ── Qwen (best for multilingual translation) ──────────────────────────
	{"name": "qwen2.5:3b",      "params": "3B",    "size_gb": 1.9,  "vram_gb": 2.5,  "desc": "Excellent multilingual, small"},
	{"name": "qwen2.5",         "params": "7B",    "size_gb": 4.7,  "vram_gb": 6.0,  "desc": "Top multilingual translator"},
	{"name": "qwen2.5:7b",      "params": "7B",    "size_gb": 4.7,  "vram_gb": 6.0,  "desc": "Same as qwen2.5"},
	{"name": "qwen2.5:14b",     "params": "14B",   "size_gb": 9.0,  "vram_gb": 11.0, "desc": "Higher-quality multilingual"},
	{"name": "qwen2.5:32b",     "params": "32B",   "size_gb": 20.0, "vram_gb": 24.0, "desc": "Very strong, needs 24GB+ VRAM"},
	{"name": "qwen3:8b",        "params": "8B",    "size_gb": 5.2,  "vram_gb": 6.5,  "desc": "Qwen 3 — newest generation"},
	# ── Mistral ───────────────────────────────────────────────────────────
	{"name": "mistral",         "params": "7B",    "size_gb": 4.1,  "vram_gb": 5.5,  "desc": "Strong general model"},
	{"name": "mistral-nemo",    "params": "12B",   "size_gb": 7.1,  "vram_gb": 8.5,  "desc": "Higher quality, more VRAM"},
	{"name": "mistral-small",   "params": "22B",   "size_gb": 13.0, "vram_gb": 15.0, "desc": "Mistral Small 22B"},
	# ── Gemma ─────────────────────────────────────────────────────────────
	{"name": "gemma2:2b",       "params": "2B",    "size_gb": 1.6,  "vram_gb": 2.0,  "desc": "Tiny & fast"},
	{"name": "gemma2",          "params": "9B",    "size_gb": 5.4,  "vram_gb": 7.0,  "desc": "Google Gemma 2"},
	{"name": "gemma3:4b",       "params": "4B",    "size_gb": 3.3,  "vram_gb": 4.0,  "desc": "Google Gemma 3 — multimodal"},
	{"name": "gemma3:12b",      "params": "12B",   "size_gb": 8.1,  "vram_gb": 10.0, "desc": "Google Gemma 3"},
	# ── Phi ───────────────────────────────────────────────────────────────
	{"name": "phi3.5",          "params": "3.8B",  "size_gb": 2.2,  "vram_gb": 3.0,  "desc": "Small, multilingual"},
	{"name": "phi3",            "params": "3.8B",  "size_gb": 2.3,  "vram_gb": 3.0,  "desc": "Compact Microsoft model"},
	{"name": "phi4",            "params": "14B",   "size_gb": 9.1,  "vram_gb": 11.0, "desc": "Microsoft Phi-4"},
	# ── DeepSeek ──────────────────────────────────────────────────────────
	{"name": "deepseek-r1:7b",  "params": "7B",    "size_gb": 4.7,  "vram_gb": 6.0,  "desc": "Reasoning model"},
	{"name": "deepseek-r1",     "params": "7B",    "size_gb": 4.7,  "vram_gb": 6.0,  "desc": "Reasoning model"},
	{"name": "deepseek-r1:14b", "params": "14B",   "size_gb": 9.0,  "vram_gb": 11.0, "desc": "Reasoning model, larger"},
	{"name": "deepseek-r1:32b", "params": "32B",   "size_gb": 20.0, "vram_gb": 24.0, "desc": "Reasoning model, heavy"},
	# ── Code ──────────────────────────────────────────────────────────────
	{"name": "codellama",       "params": "7B",    "size_gb": 3.8,  "vram_gb": 5.0,  "desc": "Code-tuned"},
	{"name": "qwen2.5-coder",   "params": "7B",    "size_gb": 4.7,  "vram_gb": 6.0,  "desc": "Code-tuned Qwen 2.5"},
]

var _url_input: LineEdit
var _installed_list: ItemList
var _model_select: OptionButton
var _model_info: Label
var _custom_input: LineEdit
var _progress_bar: ProgressBar
var _status_label: Label
var _download_btn: Button
var _thread: Thread
var _progress_file: String = ""
var _progress_timer: Timer
var _current_download: String = ""


func _ready() -> void:
	add_theme_constant_override("margin_left", 12)
	add_theme_constant_override("margin_top", 12)
	add_theme_constant_override("margin_right", 12)
	add_theme_constant_override("margin_bottom", 12)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 6)
	add_child(vbox)

	# ── URL row ───────────────────────────────────────────────────────────────
	var url_row := HBoxContainer.new()
	var url_lbl := Label.new()
	url_lbl.text = "Ollama URL:"
	url_row.add_child(url_lbl)

	_url_input = LineEdit.new()
	_url_input.text = "http://localhost:11434"
	_url_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	url_row.add_child(_url_input)

	var refresh_btn := Button.new()
	refresh_btn.text = "Refresh"
	refresh_btn.pressed.connect(_refresh_models)
	url_row.add_child(refresh_btn)
	vbox.add_child(url_row)

	vbox.add_child(HSeparator.new())

	# ── Installed list ────────────────────────────────────────────────────────
	var installed_lbl := Label.new()
	installed_lbl.text = "Installed Models"
	vbox.add_child(installed_lbl)

	_installed_list = ItemList.new()
	_installed_list.custom_minimum_size = Vector2(0, 160)
	_installed_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(_installed_list)

	var del_btn := Button.new()
	del_btn.text = "Delete Selected"
	del_btn.pressed.connect(_delete_selected)
	vbox.add_child(del_btn)

	vbox.add_child(HSeparator.new())

	# ── Download section ──────────────────────────────────────────────────────
	var dl_lbl := Label.new()
	dl_lbl.text = "Download Model"
	vbox.add_child(dl_lbl)

	var dl_row := HBoxContainer.new()
	_model_select = OptionButton.new()
	for m in POPULAR:
		_model_select.add_item("%s  (%s, ~%.1f GB)" % [m["name"], m["params"], m["size_gb"]])
	_model_select.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_model_select.item_selected.connect(_on_model_selected)
	dl_row.add_child(_model_select)

	_download_btn = Button.new()
	_download_btn.text = "Download"
	_download_btn.pressed.connect(_download_model)
	dl_row.add_child(_download_btn)
	vbox.add_child(dl_row)

	_model_info = Label.new()
	_model_info.add_theme_color_override("font_color", Color(0.7, 0.8, 1.0))
	_model_info.add_theme_font_size_override("font_size", 11)
	_model_info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(_model_info)

	_custom_input = LineEdit.new()
	_custom_input.placeholder_text = "Or enter custom model name (e.g. llama3.2:latest)…"
	vbox.add_child(_custom_input)

	_progress_bar = ProgressBar.new()
	_progress_bar.min_value = 0
	_progress_bar.max_value = 100
	_progress_bar.value = 0
	vbox.add_child(_progress_bar)

	_status_label = Label.new()
	_status_label.text = "Ready"
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(_status_label)

	_progress_timer = Timer.new()
	_progress_timer.wait_time = 0.4
	_progress_timer.timeout.connect(_poll_progress)
	add_child(_progress_timer)

	if _model_select.item_count > 0:
		_on_model_selected(0)
	_refresh_models()


# ── Refresh ───────────────────────────────────────────────────────────────────

func _refresh_models() -> void:
	_status_label.text = "Fetching installed models…"
	var out: Array = []
	OS.execute(_python(), _args(["--action", "list"]), out)

	_installed_list.clear()
	var data := _last_json(out)
	if data.get("type", "") == "models":
		var models: Array = data.get("models", [])
		for m in models:
			if typeof(m) == TYPE_DICTIONARY:
				var sz := float(m.get("size", 0)) / (1024.0 * 1024.0 * 1024.0)
				_installed_list.add_item("%s  (%.1f GB)" % [str(m.get("name", "")), sz])
			else:
				_installed_list.add_item(str(m))
		_status_label.text = "%d model(s) installed" % _installed_list.item_count
	elif data.get("type", "") == "error":
		_status_label.text = "Error: " + str(data.get("message", "")) \
			+ "\nIs Ollama installed and running? See https://ollama.com"
	else:
		_status_label.text = "Could not reach Ollama at %s.\nIs `ollama serve` running?" % _url_input.text


# ── Selected model info ───────────────────────────────────────────────────────

func _on_model_selected(idx: int) -> void:
	if idx < 0 or idx >= POPULAR.size():
		_model_info.text = ""
		return
	var m: Dictionary = POPULAR[idx]
	_model_info.text = "● %s — %s\n   Download ~%.1f GB · est. VRAM ~%.1f GB" % [
		m["params"], str(m["desc"]), m["size_gb"], m["vram_gb"]
	]


# ── Delete ────────────────────────────────────────────────────────────────────

func _delete_selected() -> void:
	var sel := _installed_list.get_selected_items()
	if sel.is_empty():
		_status_label.text = "Select a model first"
		return
	var label := _installed_list.get_item_text(sel[0])
	var model_name := label.split("  ")[0]
	_status_label.text = "Deleting %s…" % model_name
	var out: Array = []
	OS.execute(_python(), _args(["--action", "delete", "--model", model_name]), out)
	_refresh_models()


# ── Download ──────────────────────────────────────────────────────────────────

func _download_model() -> void:
	var model := _custom_input.text.strip_edges()
	if model.is_empty():
		var idx := _model_select.selected
		if idx >= 0 and idx < POPULAR.size():
			model = String(POPULAR[idx]["name"])
	if model.is_empty():
		_status_label.text = "No model selected"
		return

	_download_btn.disabled = true
	_progress_bar.value = 0
	_status_label.text = "Starting download of %s…" % model
	_current_download = model

	# Progress file (Godot polls; Python writes atomically)
	var user_dir := ProjectSettings.globalize_path("user://")
	DirAccess.make_dir_recursive_absolute(user_dir)
	_progress_file = user_dir.path_join("localization_ai_pull_%d.json" % Time.get_ticks_msec())
	# Make sure stale file doesn't trip polling
	if FileAccess.file_exists(_progress_file):
		DirAccess.remove_absolute(_progress_file)

	_progress_timer.start()
	_thread = Thread.new()
	_thread.start(func() -> void: _run_download(model))


func _run_download(model: String) -> void:
	var out: Array = []
	var exit_code := OS.execute(_python(), _args([
		"--action", "pull",
		"--model", model,
		"--progress-file", _progress_file,
	]), out)
	call_deferred("_on_download_done", exit_code, out, model)


func _poll_progress() -> void:
	if _progress_file.is_empty() or not FileAccess.file_exists(_progress_file):
		return
	var f := FileAccess.open(_progress_file, FileAccess.READ)
	if f == null:
		return
	var content := f.get_as_text()
	f.close()
	var p := JSON.new()
	if p.parse(content) != OK:
		return
	var d: Dictionary = p.get_data()
	var t := str(d.get("type", ""))
	if t == "progress":
		var pct := int(d.get("percent", 0))
		_progress_bar.value = pct
		var status := str(d.get("status", ""))
		var done_b := float(d.get("completed", 0))
		var total_b := float(d.get("total", 0))
		if total_b > 0:
			_status_label.text = "%s — %s · %.2f / %.2f GB (%d%%)" % [
				_current_download, status,
				done_b / 1.073e9, total_b / 1.073e9, pct
			]
		else:
			_status_label.text = "%s — %s" % [_current_download, status]
	elif t == "done":
		_progress_bar.value = 100
		_status_label.text = "%s downloaded ✓" % _current_download
	elif t == "error":
		_status_label.text = "Error: " + str(d.get("message", ""))


func _on_download_done(exit_code: int, raw: Array, model: String) -> void:
	_thread.wait_to_finish()
	_progress_timer.stop()
	# Final poll for the latest state.
	_poll_progress()
	if not _progress_file.is_empty() and FileAccess.file_exists(_progress_file):
		DirAccess.remove_absolute(_progress_file)
	_progress_file = ""
	_download_btn.disabled = false

	if exit_code == 0:
		_progress_bar.value = 100
		_status_label.text = "%s downloaded successfully" % model
		_custom_input.text = ""
		_refresh_models()
	else:
		var last := _last_json(raw)
		var msg := str(last.get("message", "exit %d" % exit_code))
		_status_label.text = "Download failed: " + msg


# ── Helpers ───────────────────────────────────────────────────────────────────

func _args(extra: Array) -> PackedStringArray:
	var base := PackedStringArray([
		ProjectSettings.globalize_path("res://addons/localization_ai/scripts/manage_models.py"),
		"--api-url", _url_input.text,
	])
	for a in extra:
		base.append(String(a))
	return base


func _last_json(raw: Array) -> Dictionary:
	var joined := "\n".join(PackedStringArray(raw))
	var lines := joined.split("\n")
	for i in range(lines.size() - 1, -1, -1):
		var l := lines[i].strip_edges()
		if l.begins_with("{"):
			var p := JSON.new()
			if p.parse(l) == OK:
				return p.get_data()
	return {}


static func _python() -> String:
	return "python" if OS.get_name() == "Windows" else "python3"
