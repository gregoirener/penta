extends Node
## Cover art: fetch once, cache forever, never block the UI.
##
## Autoloaded as `Art`. Steam serves cover art publicly, so there is no API key
## and no account involved — a title's appid is enough. Everything is cached to
## disk, so the second boot is instant and an offline console still looks right.
##
## Cards ask for art and get a placeholder immediately; the real image arrives
## later and fades in. Nothing ever waits on the network.

signal art_ready(uid: String, kind: String, texture: Texture2D)

const CACHE_DIR := "user://art"
const MAX_PARALLEL := 4
const TIMEOUT := 12.0

var _memory: Dictionary = {}          # "uid:kind" -> Texture2D
var _queue: Array = []                # pending {uid, kind, url}
var _active := 0
var _failed: Dictionary = {}          # keys we already know are 404s

func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(CACHE_DIR)

## Returns a texture immediately if we have one, else null and starts a fetch.
func get_art(uid: String, kind: String, url: String) -> Texture2D:
	var key := "%s:%s" % [uid, kind]
	if _memory.has(key):
		return _memory[key]
	if _failed.has(key) or url.is_empty():
		return null

	var path := _cache_path(uid, kind)
	if FileAccess.file_exists(path):
		var tex := _load_file(path)
		if tex:
			_memory[key] = tex
			return tex

	_enqueue(uid, kind, url)
	return null

func _cache_path(uid: String, kind: String) -> String:
	# uids contain ':' which is not filename-safe on every filesystem.
	return "%s/%s_%s.img" % [CACHE_DIR, uid.replace(":", "_"), kind]

func _load_file(path: String) -> Texture2D:
	var bytes := FileAccess.get_file_as_bytes(path)
	if bytes.is_empty():
		return null
	var img := Image.new()
	# Steam serves jpg for capsules and png for logos; sniff rather than trust
	# the extension, because a failed download can leave HTML in the file.
	var err := img.load_jpg_from_buffer(bytes)
	if err != OK:
		err = img.load_png_from_buffer(bytes)
	if err != OK:
		return null
	return ImageTexture.create_from_image(img)

# --- Fetching -----------------------------------------------------------------

func _enqueue(uid: String, kind: String, url: String) -> void:
	for q in _queue:
		if q.uid == uid and q.kind == kind:
			return
	_queue.append({"uid": uid, "kind": kind, "url": url})
	_pump()

func _pump() -> void:
	while _active < MAX_PARALLEL and not _queue.is_empty():
		var job: Dictionary = _queue.pop_front()
		_active += 1
		_fetch(job)

func _fetch(job: Dictionary) -> void:
	var req := HTTPRequest.new()
	req.timeout = TIMEOUT
	add_child(req)
	req.request_completed.connect(
		func(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
			_on_done(job, result, code, body, req))
	var err := req.request(job.url)
	if err != OK:
		_on_done(job, HTTPRequest.RESULT_CANT_CONNECT, 0, PackedByteArray(), req)

func _on_done(job: Dictionary, result: int, code: int,
			  body: PackedByteArray, req: HTTPRequest) -> void:
	req.queue_free()
	_active -= 1

	var key := "%s:%s" % [job.uid, job.kind]
	if result != HTTPRequest.RESULT_SUCCESS or code != 200 or body.is_empty():
		# Plenty of titles have no portrait capsule. Remember the miss so we
		# don't retry it every time the card scrolls back into view.
		_failed[key] = true
		_pump()
		return

	var path := _cache_path(job.uid, job.kind)
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f:
		f.store_buffer(body)
		f.close()

	var tex := _load_file(path)
	if tex:
		_memory[key] = tex
		art_ready.emit(job.uid, job.kind, tex)
	else:
		_failed[key] = true
		DirAccess.remove_absolute(path)
	_pump()

## True once we know an image will never arrive — lets callers stop waiting.
func has_failed(uid: String, kind: String) -> bool:
	return _failed.has("%s:%s" % [uid, kind])
