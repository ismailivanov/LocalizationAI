@tool
extends GraphNode

const PORT_TYPE_PROMPT := 1
const PORT_COLOR_PROMPT := Color(0.9, 0.7, 0.3)

const _TranslateNode = preload("res://addons/localization_ai/ui/elements/translate_node.gd")

signal log_message(text: String)

var _scope: OptionButton   # [0]
var _prompt_text: TextEdit  # [1] → OUTPUT port


func _init() -> void:
	title = "Prompt"
	custom_minimum_size = Vector2(280, 160)
	resizable = true


func _ready() -> void:
	_scope = OptionButton.new()
	_scope.add_item("🌍 Global")
	for lang in _TranslateNode.LANGUAGES:
		_scope.add_item("%s — %s" % [lang[0], lang[1]])
	add_child(_scope)

	_prompt_text = TextEdit.new()
	_prompt_text.placeholder_text = "Custom instructions for the AI translator..."
	_prompt_text.custom_minimum_size = Vector2(280, 80)
	_prompt_text.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_prompt_text.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(_prompt_text)

	# Output port on right side of text area row
	set_slot(1, false, 0, Color.WHITE, true, PORT_TYPE_PROMPT, PORT_COLOR_PROMPT)

	resize_request.connect(_on_resize_request)


func _on_resize_request(new_size: Vector2) -> void:
	size = new_size


func get_scope() -> String:
	if _scope.selected == 0:
		return "global"
	return _TranslateNode.LANGUAGES[_scope.selected - 1][0]


func get_prompt_text() -> String:
	return _prompt_text.text.strip_edges()


# ── Workflow save / load ─────────────────────────────────────────────────────

func save_state() -> Dictionary:
	return {
		"scope_idx": _scope.selected,
		"prompt": _prompt_text.text,
		"size": [size.x, size.y],
	}


func load_state(data: Dictionary) -> void:
	var idx := int(data.get("scope_idx", 0))
	if idx < _scope.item_count:
		_scope.select(idx)
	_prompt_text.text = str(data.get("prompt", ""))
	var sz: Array = data.get("size", [])
	if sz.size() == 2:
		size = Vector2(float(sz[0]), float(sz[1]))
