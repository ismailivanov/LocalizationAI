@tool
extends EditorPlugin

const MAIN_SCENE = preload("res://addons/localization_ai/ui/main.tscn")
const LOCALIZATION_ICON = preload("uid://cmv5e7ji2cr2o")
const Updater = preload("res://addons/localization_ai/ui/updater.gd")

const TOOL_MENU_LABEL := "LocalizationAI: Check for updates"

var _main_panel: Control


func _has_main_screen() -> bool:
	return true


func _get_plugin_name() -> String:
	return "LocalizationAI"


func _get_plugin_icon() -> Texture2D:
	return LOCALIZATION_ICON

func _make_visible(visible: bool) -> void:
	if _main_panel:
		_main_panel.visible = visible


func _enter_tree() -> void:
	# Register the Tool-menu entry FIRST so the user has a way to trigger an
	# update even when the main scene fails to instantiate (for example after
	# a broken upgrade). The menu lives in Project → Tools and survives a
	# broken main panel.
	add_tool_menu_item(TOOL_MENU_LABEL, _on_tool_menu_check_updates)

	_main_panel = MAIN_SCENE.instantiate()
	EditorInterface.get_editor_main_screen().add_child(_main_panel)
	_make_visible(false)


func _on_tool_menu_check_updates() -> void:
	var updater: Node = Updater.new()
	EditorInterface.get_base_control().add_child(updater)
	updater.run_update_flow(EditorInterface.get_base_control())


func _exit_tree() -> void:
	remove_tool_menu_item(TOOL_MENU_LABEL)

	if _main_panel:
		# Give the main panel a chance to flush any in-flight translation
		# (write the _progress partial, join the Python child) before we tear
		# the tree down. queue_free() alone runs _exit_tree on children too
		# late to reliably block on Thread.wait_to_finish().
		if _main_panel.has_method("shutdown_translations"):
			_main_panel.shutdown_translations()
		_main_panel.queue_free()
		_main_panel = null
