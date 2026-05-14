@tool
extends Button

@export var icon_texture: Texture2D:
	set(tex):
		icon_texture = tex
		_apply_texture()

func _ready() -> void:
	for state in [&"normal", &"hover", &"pressed", &"hover_pressed"]:
		var style := get_theme_stylebox(state) as StyleBoxTexture
		if style:
			add_theme_stylebox_override(state, style.duplicate())
	_apply_texture()

func _apply_texture() -> void:
	for state in [&"normal", &"hover", &"pressed", &"hover_pressed"]:
		var style := get_theme_stylebox(state) as StyleBoxTexture
		if style:
			style.texture = icon_texture
