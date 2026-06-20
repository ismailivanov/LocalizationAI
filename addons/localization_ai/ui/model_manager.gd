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

const OLLAMA_DOWNLOAD_PAGE := "https://ollama.com/download"
const OLLAMA_DEFAULT_URL := "http://localhost:11434"

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

# ── Ollama install / setup ───────────────────────────────────────────────────
var _setup_status: Label
var _setup_btn: Button
var _setup_page_btn: Button
var _ollama_http: HTTPRequest
var _dl_poll: Timer
var _download_target: String = ""


func _ready() -> void:
	add_theme_constant_override("margin_left", 12)
	add_theme_constant_override("margin_top", 12)
	add_theme_constant_override("margin_right", 12)
	add_theme_constant_override("margin_bottom", 12)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 6)
	add_child(vbox)

	_build_ollama_setup(vbox)

	# ── URL row ───────────────────────────────────────────────────────────────
	var url_row := HBoxContainer.new()
	var url_lbl := Label.new()
	url_lbl.text = "Ollama URL:"
	url_row.add_child(url_lbl)

	_url_input = LineEdit.new()
	_url_input.text = OLLAMA_DEFAULT_URL
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
	_refresh_setup_status()


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

	# Progress file (Godot polls; Python writes atomically). Lives under the
	# plugin's shared user-data subdir to keep Godot's user:// folder tidy.
	var runs_dir := ProjectSettings.globalize_path("user://localization_ai/runs")
	DirAccess.make_dir_recursive_absolute(runs_dir)
	_progress_file = runs_dir.path_join("pull_%d.json" % Time.get_ticks_msec())
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


# ── Ollama install / setup ────────────────────────────────────────────────────

# A one-click row that downloads Ollama for the current OS (or starts it if it
# is already present) and points the URL field at the local server. The plugin
# talks to Ollama purely over its HTTP API, so all this needs to achieve is "a
# reachable server at localhost:11434".
func _build_ollama_setup(vbox: VBoxContainer) -> void:
	var panel := PanelContainer.new()
	vbox.add_child(panel)

	var inner := VBoxContainer.new()
	inner.add_theme_constant_override("separation", 4)
	panel.add_child(inner)

	var title := Label.new()
	title.text = "🦙  Ollama"
	title.add_theme_font_size_override("font_size", 14)
	inner.add_child(title)

	_setup_status = Label.new()
	_setup_status.text = "Checking for Ollama…"
	_setup_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_setup_status.add_theme_font_size_override("font_size", 11)
	inner.add_child(_setup_status)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	inner.add_child(row)

	_setup_btn = Button.new()
	_setup_btn.text = "⬇  Install & Start Ollama"
	_setup_btn.tooltip_text = "Download Ollama for this operating system, start the local server, and point the URL above at it."
	_setup_btn.pressed.connect(_on_setup_pressed)
	row.add_child(_setup_btn)

	_setup_page_btn = Button.new()
	_setup_page_btn.text = "🌐  Download page"
	_setup_page_btn.tooltip_text = OLLAMA_DOWNLOAD_PAGE
	_setup_page_btn.pressed.connect(func() -> void: OS.shell_open(OLLAMA_DOWNLOAD_PAGE))
	row.add_child(_setup_page_btn)

	_ollama_http = HTTPRequest.new()
	_ollama_http.max_redirects = 10
	_ollama_http.use_threads = true
	_ollama_http.request_completed.connect(_on_ollama_downloaded)
	add_child(_ollama_http)

	_dl_poll = Timer.new()
	_dl_poll.wait_time = 0.3
	_dl_poll.timeout.connect(_poll_ollama_download)
	add_child(_dl_poll)

	vbox.add_child(HSeparator.new())


func _refresh_setup_status() -> void:
	if _setup_status == null:
		return
	if _ollama_installed():
		_setup_status.add_theme_color_override("font_color", Color(0.4, 0.9, 0.55))
		_setup_status.text = "Ollama is installed. Use the button to (re)start the local server if needed."
		_setup_btn.text = "▶  Start Ollama server"
	else:
		_setup_status.add_theme_color_override("font_color", Color(1.0, 0.8, 0.4))
		_setup_status.text = "Ollama not detected. Click below to download and set it up for %s." % OS.get_name()
		_setup_btn.text = "⬇  Install & Start Ollama"


func _on_setup_pressed() -> void:
	# Already installed → no download needed, just make sure the server runs and
	# the URL field points at it.
	if _ollama_installed():
		_ensure_serve_and_configure()
		return

	var os_name := OS.get_name()
	if _ollama_download_url(os_name).is_empty():
		_setup_status.text = "Automatic install isn't supported on %s — opening the download page." % os_name
		OS.shell_open(OLLAMA_DOWNLOAD_PAGE)
		return

	var dlg := ConfirmationDialog.new()
	dlg.title = "Install Ollama"
	dlg.dialog_text = ("Download Ollama for %s and set it up?\n\n" \
			+ "• Saved to %s\n" \
			+ "• On Linux/macOS the local server is started automatically.\n" \
			+ "• On Windows the official installer is launched — follow its steps.") \
			% [os_name, _ollama_install_dir()]
	dlg.confirmed.connect(_begin_ollama_install)
	add_child(dlg)
	dlg.popup_centered()


func _begin_ollama_install() -> void:
	var os_name := OS.get_name()
	var url := _ollama_download_url(os_name)
	if url.is_empty():
		OS.shell_open(OLLAMA_DOWNLOAD_PAGE)
		return

	var dir := _ollama_install_dir()
	DirAccess.make_dir_recursive_absolute(dir)
	_download_target = dir.path_join(_ollama_download_filename(os_name))
	if FileAccess.file_exists(_download_target):
		DirAccess.remove_absolute(_download_target)

	_setup_btn.disabled = true
	_setup_page_btn.disabled = true
	_progress_bar.value = 0
	_setup_status.add_theme_color_override("font_color", Color(0.75, 0.75, 0.75))
	_setup_status.text = "Downloading Ollama for %s…" % os_name

	_ollama_http.download_file = _download_target
	var err := _ollama_http.request(url, ["User-Agent: LocalizationAI"])
	if err != OK:
		_setup_install_failed("Download failed to start (error %d)." % err)
		return
	_dl_poll.start()


func _poll_ollama_download() -> void:
	var total := _ollama_http.get_body_size()
	var got := _ollama_http.get_downloaded_bytes()
	if total > 0:
		_progress_bar.value = 100.0 * got / total
		_setup_status.text = "Downloading Ollama… %.1f / %.1f MB" % [
			got / 1048576.0, total / 1048576.0
		]
	elif got > 0:
		_setup_status.text = "Downloading Ollama… %.1f MB" % (got / 1048576.0)


func _on_ollama_downloaded(result: int, code: int, _headers: PackedStringArray,
		_body: PackedByteArray) -> void:
	_dl_poll.stop()
	_setup_btn.disabled = false
	_setup_page_btn.disabled = false
	if result != HTTPRequest.RESULT_SUCCESS:
		_setup_install_failed("Network error (result %d). Try the download page." % result)
		return
	if code >= 400:
		_setup_install_failed("Server returned HTTP %d. Try the download page." % code)
		return
	if not FileAccess.file_exists(_download_target):
		_setup_install_failed("Downloaded file is missing.")
		return

	_progress_bar.value = 100
	match OS.get_name():
		"Linux":
			# .tar.zst needs zstd; GNU tar shells out to it via --zstd.
			if not _has_command("zstd"):
				_setup_install_failed("Extraction needs the 'zstd' tool. Install it and retry "
						+ "(Debian/Ubuntu: sudo apt install zstd · Fedora: sudo dnf install zstd "
						+ "· Arch: sudo pacman -S zstd).")
				return
			_install_ollama_archive(["tar", "--zstd", "-xf", _download_target, "-C", _ollama_install_dir()])
		"macOS":
			_install_ollama_archive(["unzip", "-o", _download_target, "-d", _ollama_install_dir()])
		"Windows":
			# Launch the official installer GUI; it registers Ollama and starts
			# the background server itself once the user finishes.
			_setup_status.text = "Launching the Ollama installer — follow its steps, then click Refresh."
			_url_input.text = OLLAMA_DEFAULT_URL
			if OS.create_process(_download_target, PackedStringArray()) <= 0:
				OS.shell_open(_download_target)
		_:
			OS.shell_open(OLLAMA_DOWNLOAD_PAGE)


# Extract the downloaded archive (Linux .tgz via tar, macOS .zip via unzip) and
# then bring the server up. Falls back to the download page if extraction tools
# are unavailable.
func _install_ollama_archive(extract_cmd: Array) -> void:
	_setup_status.text = "Extracting Ollama…"
	var tool := String(extract_cmd[0])
	var tool_args := PackedStringArray()
	for i in range(1, extract_cmd.size()):
		tool_args.append(String(extract_cmd[i]))
	var out: Array = []
	var ec := OS.execute(tool, tool_args, out)
	if ec != 0:
		_setup_install_failed("Could not extract the archive (%s exit %d)." % [tool, ec])
		return

	# macOS ships the CLI inside Ollama.app — open it so it can register itself.
	if OS.get_name() == "macOS":
		var app := _ollama_install_dir().path_join("Ollama.app")
		if DirAccess.dir_exists_absolute(app):
			OS.create_process("open", PackedStringArray([app]))
	_ensure_serve_and_configure()


# Start `ollama serve` (no-op if it's already running / managed as a service),
# point the URL field at the local server, then refresh the model list.
func _ensure_serve_and_configure() -> void:
	_url_input.text = OLLAMA_DEFAULT_URL
	var cli := _ollama_cli()
	if not cli.is_empty():
		OS.create_process(cli, PackedStringArray(["serve"]))
	_setup_status.add_theme_color_override("font_color", Color(0.75, 0.75, 0.75))
	_setup_status.text = "Starting the Ollama server…"
	# Give the server a moment to bind the port before we query it.
	await get_tree().create_timer(2.5).timeout
	_refresh_models()
	_refresh_setup_status()


func _setup_install_failed(msg: String) -> void:
	_dl_poll.stop()
	_setup_btn.disabled = false
	_setup_page_btn.disabled = false
	_setup_status.add_theme_color_override("font_color", Color(1.0, 0.5, 0.5))
	_setup_status.text = msg


# Absolute path where a self-contained Ollama is downloaded/extracted.
func _ollama_install_dir() -> String:
	return ProjectSettings.globalize_path("user://localization_ai/ollama")


func _ollama_download_url(os_name: String) -> String:
	var arch := "arm64" if OS.has_feature("arm64") else "amd64"
	match os_name:
		# Current Linux releases ship as zstd-compressed tarballs (the old .tgz
		# redirect now 404s). Matches what ollama.com/install.sh fetches.
		"Linux":   return "https://ollama.com/download/ollama-linux-%s.tar.zst" % arch
		"Windows": return "https://ollama.com/download/OllamaSetup.exe"
		"macOS":   return "https://ollama.com/download/Ollama-darwin.zip"
	return ""


func _ollama_download_filename(os_name: String) -> String:
	match os_name:
		"Windows": return "OllamaSetup.exe"
		"macOS":   return "Ollama-darwin.zip"
		_:         return "ollama.tar.zst"


# Path to a usable ollama binary: the one we extracted under user:// if present,
# otherwise whatever is on PATH.
func _ollama_cli() -> String:
	var dir := _ollama_install_dir()
	if OS.get_name() == "Windows":
		var exe := dir.path_join("ollama.exe")
		return exe if FileAccess.file_exists(exe) else "ollama"
	var bin := dir.path_join("bin/ollama")
	return bin if FileAccess.file_exists(bin) else "ollama"


func _ollama_installed() -> bool:
	var out: Array = []
	var ec := OS.execute(_ollama_cli(), PackedStringArray(["--version"]), out)
	return ec == 0


func _has_command(name: String) -> bool:
	var out: Array = []
	return OS.execute(name, PackedStringArray(["--version"]), out) == 0


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
