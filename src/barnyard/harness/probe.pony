use "logger"
use "lori"
use "pony_test"
use "../connection"

actor \nodoc\ ProbePeer is BarnyardConnection
  let _h: TestHelper
  let _log: Logger[String]
  embed _forwarded: Array[U8] = _forwarded.create()
  embed _events: Array[String] = _events.create()
  var _peer: (BarnyardConnection tag | None) = None
  var _expected: (BarnyardConnection tag | None) = None
  var _action: String = ""
  var _any: Bool = false
  var _done: Bool = false
  var _fwd_expected: (Array[U8] val | None) = None
  var _fwd_action: String = ""
  var _invite: Bool = false

  new create(h: TestHelper) =>
    _h = h
    _log = StringLogger(Error, h.env.out)

  be inviting() =>
    // Act as a backend: when assigned a server, invite it back via peer_with,
    // mirroring how a real backend completes the binding.
    _invite = true

  fun ref log(): Logger[String] => _log
  fun ref send(payload: (ByteSeq | ByteSeqIter)) => _events.push("send")
  fun ref buffer_until(qty: (BufferSize | Streaming)) => None
  fun ref mute() => None
  fun ref unmute() => None
  fun ref on_param(key: String val, value: String val) => None
  fun ref established() => None

  be peer_with(peer: BarnyardConnection tag) =>
    _events.push("peer_with")
    _peer = peer
    if _invite then peer.peer_with(this) end
    _check()

  be forward(data: ForwardData) =>
    _events.push("forward")
    match data
    | let str: String => _forwarded.append(str.array())
    | let arr: Array[U8] val => _forwarded.append(arr)
    | let parts: Array[ByteSeq] val =>
      for p in parts.values() do
        match p
        | let s: String => _forwarded.append(s.array())
        | let b: Array[U8] val => _forwarded.append(b)
        end
      end
    end
    _check_forwarded()

  be release() => _events.push("release")

  be expect_forwarded(expected: Array[U8] val, action: String) =>
    _fwd_expected = expected
    _fwd_action = action
    _check_forwarded()

  fun ref _check_forwarded() =>
    match _fwd_expected
    | let e: Array[U8] val =>
      if _forwarded.size() >= e.size() then
        _fwd_expected = None
        if EqBytes(_h, e, _forwarded, _fwd_action) then
          _h.complete_action(_fwd_action)
        end
      end
    end

  be expect_peer(expected: BarnyardConnection tag, action: String) =>
    _expected = expected
    _action = action
    _check()

  be expect_any_peer(action: String) =>
    _any = true
    _action = action
    _check()

  fun ref _check() =>
    if _done or (_action.size() == 0) then return end
    match _peer
    | let p: BarnyardConnection tag =>
      if _any then
        _done = true
        _h.complete_action(_action)
        return
      end
      match _expected
      | let e: BarnyardConnection tag =>
        _done = true
        if p is e then
          _h.complete_action(_action)
        else
          _h.fail(_action + ": paired with the wrong peer")
        end
      end
    end

  be inspect(f: {(ProbePeer ref)} val) => f(this)

  fun forwarded_bytes(): this->Array[U8] => _forwarded
  fun events(): this->Array[String] => _events
