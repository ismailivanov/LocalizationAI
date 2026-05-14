@tool
extends EditorPlugin

const MAIN_SCENE = preload("res://addons/localization_ai/ui/main.tscn")

var _main_panel: Control


func _has_main_screen() -> bool:
	return true


func _get_plugin_name() -> String:
	return "LocalizationAI"


func _get_plugin_icon() -> Texture2D:
	return null

func _make_visible(visible: bool) -> void:
	if _main_panel:
		_main_panel.visible = visible


func _enter_tree() -> void:
	_main_panel = MAIN_SCENE.instantiate()
	EditorInterface.get_editor_main_screen().add_child(_main_panel)
	_make_visible(false)


func _exit_tree() -> void:
	if _main_panel:
		_main_panel.queue_free()
		_main_panel = null
