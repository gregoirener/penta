extends Node
## Client for pentad's JSON-lines protocol over TCP loopback.
##
## Autoloaded as `Ipc`. Reconnects on its own, so the menu can start before the
## daemon and survive a daemon restart without the user seeing anything.
##
## Replies carry the `id` of their request; events have `id: null` and an
## `event` key, and can arrive *between* a request and its reply — so this
## demultiplexes rather than assuming the next line is the answer.

signal connected_changed(is_connected: bool)
signal event_received(event_name: String, args: Dictionary)

const HOST := "127.0.0.1"
const PORT := 8787
const RECONNECT_INTERVAL := 1.5

var _peer := StreamPeerTCP.new()
var _buffer := ""
var _next_id := 1
var _pending: Dictionary = {}          # id -> Callable
var _connected := false
var _reconnect_timer := 0.0

func _ready() -> void:
	set_process(true)
	_try_connect()

func _try_connect() -> void:
	_peer = StreamPeerTCP.new()
	_buffer = ""
	var err := _peer.connect_to_host(HOST, PORT)
	if err != OK:
		push_warning("Ipc: connect_to_host failed (%d)" % err)

func _process(delta: float) -> void:
	_peer.poll()
	var status := _peer.get_status()

	if status == StreamPeerTCP.STATUS_CONNECTED:
		if not _connected:
			_connected = true
			connected_changed.emit(true)
		_drain()
	else:
		if _connected:
			_connected = false
			_fail_pending("connection lost")
			connected_changed.emit(false)
		if status == StreamPeerTCP.STATUS_ERROR or status == StreamPeerTCP.STATUS_NONE:
			_reconnect_timer -= delta
			if _reconnect_timer <= 0.0:
				_reconnect_timer = RECONNECT_INTERVAL
				_try_connect()

func is_connected_to_daemon() -> bool:
	return _connected

## Send a command. `on_reply` receives (ok: bool, payload: Variant) where
## payload is the result dictionary on success or an error string on failure.
func request(cmd: String, args: Dictionary = {}, on_reply: Callable = Callable()) -> int:
	var id := _next_id
	_next_id += 1
	if on_reply.is_valid():
		_pending[id] = on_reply
	if not _connected:
		_settle(id, false, "not connected")
		return id
	var line := JSON.stringify({"id": id, "cmd": cmd, "args": args}) + "\n"
	_peer.put_data(line.to_utf8_buffer())
	return id

func _drain() -> void:
	var available := _peer.get_available_bytes()
	if available > 0:
		var chunk := _peer.get_data(available)
		if chunk[0] == OK:
			_buffer += (chunk[1] as PackedByteArray).get_string_from_utf8()

	while true:
		var nl := _buffer.find("\n")
		if nl == -1:
			break
		var line := _buffer.substr(0, nl)
		_buffer = _buffer.substr(nl + 1)
		if line.strip_edges().is_empty():
			continue
		_handle_line(line)

func _handle_line(line: String) -> void:
	var parsed: Variant = JSON.parse_string(line)
	if typeof(parsed) != TYPE_DICTIONARY:
		push_warning("Ipc: unparseable line: %s" % line.substr(0, 120))
		return
	var msg: Dictionary = parsed

	# Event: no id, has an `event` key. Events can arrive at any time.
	if msg.get("id") == null and msg.has("event"):
		event_received.emit(str(msg["event"]), msg.get("args", {}) as Dictionary)
		return

	# Reply: match to the pending request by id.
	if msg.has("id"):
		var id := int(msg["id"])
		var ok := bool(msg.get("ok", false))
		_settle(id, ok, msg.get("result", {}) if ok else str(msg.get("error", "unknown error")))

func _settle(id: int, ok: bool, payload: Variant) -> void:
	if not _pending.has(id):
		return
	var cb: Callable = _pending[id]
	_pending.erase(id)
	if cb.is_valid():
		cb.call(ok, payload)

func _fail_pending(reason: String) -> void:
	for id in _pending.keys().duplicate():
		_settle(id, false, reason)
