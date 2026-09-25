extends Control

const SCENE_PATHS: Array[String] = [
    "res://runner_entry.tscn",
    "res://main.tscn",
    "res://scenes/main.tscn",
    "res://game.tscn",
]

var elapsed: float = 0.0
var refresh: float = 0.0
var info: Label
var status: Label
var pack_list: VBoxContainer
var pack_loaded: bool = false
var documents_dir: String = ""
var file_picker: Object = null

func _ready() -> void:
    var title := Label.new()
    title.text = "Godot iOS Runner"
    title.position = Vector2(24, 88)
    title.add_theme_font_size_override("font_size", 30)
    add_child(title)

    info = Label.new()
    info.position = Vector2(24, 146)
    info.add_theme_font_size_override("font_size", 17)
    add_child(info)
    _update_info()

    var pick_button := Button.new()
    pick_button.text = "Files에서 게임 ZIP / PCK 선택"
    pick_button.position = Vector2(24, 390)
    pick_button.size = Vector2(342, 52)
    pick_button.pressed.connect(_pick_game_file)
    add_child(pick_button)

    var scroll := ScrollContainer.new()
    scroll.position = Vector2(24, 452)
    scroll.size = Vector2(342, 215)
    add_child(scroll)
    pack_list = VBoxContainer.new()
    pack_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    scroll.add_child(pack_list)

    status = Label.new()
    status.position = Vector2(24, 675)
    status.size = Vector2(342, 125)
    status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    status.add_theme_font_size_override("font_size", 16)
    add_child(status)

    if OS.has_feature("ios"):
        documents_dir = OS.get_system_dir(OS.SYSTEM_DIR_DOCUMENTS)
        if Engine.has_singleton("IOSFilePicker"):
            file_picker = Engine.get_singleton("IOSFilePicker")
    else:
        documents_dir = OS.get_user_data_dir()

    if documents_dir.is_empty():
        status.text = "Documents 폴더를 찾을 수 없습니다."
    else:
        _refresh_packs(false)
        if OS.has_feature("ios") and file_picker == null:
            status.text = "iOS 파일 선택기 플러그인을 불러오지 못했습니다.\nDocuments 폴더에 직접 ZIP/PCK를 넣는 방식만 사용할 수 있습니다."
        elif OS.has_feature("ios"):
            status.text = "버튼을 누르면 Files 앱에서 ZIP/PCK를 직접 선택할 수 있습니다."
    print("RUNNER_READY: ", Engine.get_version_info()["string"], " / ", OS.get_name())

func _pick_game_file() -> void:
    if pack_loaded:
        status.text = "다른 팩을 실행하려면 앱을 완전히 종료한 후 다시 열어주세요."
        return
    if OS.has_feature("ios") and file_picker != null:
        status.text = "Files 앱을 여는 중..."
        var result := int(file_picker.call("open_picker"))
        if result != OK:
            status.text = "파일 선택기를 열 수 없습니다. 오류 코드: %d" % result
        return

    _refresh_packs(true)

func _poll_native_picker() -> void:
    if file_picker == null or pack_loaded:
        return
    var event_value: Variant = file_picker.call("poll_result")
    if not (event_value is Dictionary):
        return
    var event: Dictionary = event_value
    if event.is_empty():
        return
    var event_status := str(event.get("status", ""))
    match event_status:
        "selected":
            var path := str(event.get("path", ""))
            if path.is_empty():
                status.text = "선택된 파일 경로를 받지 못했습니다."
                return
            _refresh_packs(false)
            _open_pack(path)
        "cancelled":
            status.text = "파일 선택을 취소했습니다."
        "error":
            status.text = "파일 선택 오류: " + str(event.get("error", "알 수 없는 오류"))

func _refresh_packs(show_hint: bool = true) -> void:
    for child in pack_list.get_children():
        child.queue_free()
    if documents_dir.is_empty():
        status.text = "Documents 폴더를 찾을 수 없습니다."
        return

    var search_dirs: Array[String] = [documents_dir, documents_dir.path_join("ImportedGames")]
    var found: Array[Dictionary] = []
    for base_dir in search_dirs:
        var dir := DirAccess.open(base_dir)
        if dir == null:
            continue
        for filename in dir.get_files():
            var lower := filename.to_lower()
            if lower.ends_with(".pck") or lower.ends_with(".zip"):
                found.append({"name": filename, "path": base_dir.path_join(filename)})

    found.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return str(a["name"]) < str(b["name"]))
    if found.is_empty():
        if show_hint:
            status.text = "Files에서 ZIP/PCK를 선택하거나, 파일 앱 → 나의 iPhone → Godot iOS Runner 폴더에 직접 복사하세요."
        return

    for item in found:
        var file_button := Button.new()
        file_button.text = str(item["name"])
        file_button.custom_minimum_size = Vector2(330, 48)
        file_button.disabled = pack_loaded
        pack_list.add_child(file_button)
        file_button.pressed.connect(_open_pack.bind(str(item["path"])))
    if show_hint:
        status.text = "%d개 파일. 실행할 파일을 눌러주세요." % found.size()

func _open_pack(path: String) -> void:
    if pack_loaded:
        status.text = "다른 팩을 실행하려면 앱을 완전히 종료한 후 다시 열어주세요."
        return
    if not FileAccess.file_exists(path):
        status.text = "파일이 없습니다. 목록을 새로고침해 주세요."
        return
    var lower := path.to_lower()
    if not lower.ends_with(".zip") and not lower.ends_with(".pck"):
        status.text = "ZIP/PCK 파일만 실행할 수 있습니다."
        return
    status.text = "불러오는 중: " + path.get_file()
    if not ProjectSettings.load_resource_pack(path, false):
        status.text = "Godot 리소스 팩이 아닙니다. Godot에서 Export PCK/ZIP으로 만든 파일을 사용하세요."
        return
    pack_loaded = true
    var scene: PackedScene = null
    for scene_path in SCENE_PATHS:
        if ResourceLoader.exists(scene_path, "PackedScene"):
            scene = ResourceLoader.load(scene_path, "PackedScene", ResourceLoader.CACHE_MODE_IGNORE) as PackedScene
            if scene != null:
                break
    if scene == null:
        pack_loaded = false
        status.text = "팩을 읽었지만 시작 씬을 찾지 못했습니다.\nrunner_entry.tscn 또는 main.tscn을 팩 루트에 넣어주세요."
        return
    var game := scene.instantiate()
    if game == null:
        pack_loaded = false
        status.text = "시작 씬을 실행할 수 없습니다."
        return
    get_tree().root.add_child(game)
    get_tree().current_scene = game
    print("RUNNER_GAME_STARTED: ", path.get_file())
    queue_free()

func _process(delta: float) -> void:
    elapsed += delta
    refresh += delta
    _poll_native_picker()
    if refresh >= 0.25:
        refresh = 0.0
        _update_info()
    queue_redraw()

func _update_info() -> void:
    var pixels: Vector2i = DisplayServer.window_get_size()
    info.text = "Godot: %s\nFPS: %d\nRenderer: %s\nDriver: %s\nResolution: %d x %d\nPlatform: %s\niOS: %s" % [
        Engine.get_version_info()["string"],
        Engine.get_frames_per_second(),
        RenderingServer.get_current_rendering_method(),
        RenderingServer.get_current_rendering_driver_name(),
        pixels.x, pixels.y, OS.get_name(), str(OS.has_feature("ios"))]

func _draw() -> void:
    var center := Vector2(size.x * 0.85, size.y * 0.40)
    var radius: float = 18.0
    draw_arc(center, radius, 0.0, TAU, 48, Color(0.18, 0.27, 0.40), 2.0, true)
    var dot := center + Vector2(cos(elapsed * 1.8), sin(elapsed * 1.8)) * radius
    draw_circle(dot, 8.0, Color(0.24, 0.88, 0.75), true, -1.0, true)
