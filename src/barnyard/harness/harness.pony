use "collections"
use "logger"
use "lori"
use "pony_test"
use "../connection"

class \nodoc\ val Prime
  let qty: USize
  new val create(qty': USize) => qty = qty'

class \nodoc\ val Start
  let make: {(BarnyardConnection tag): BarnyardConnectionTransition box} val
  new val create(make': {(BarnyardConnection tag): BarnyardConnectionTransition box} val) =>
    make = make'

class \nodoc\ val Feed
  let data: Array[U8] val
  new val create(data': Array[U8] val) => data = data'

class \nodoc\ val PipeIn
  let data: Array[U8] val
  new val create(data': Array[U8] val) => data = data'

class \nodoc\ val Wake
  let peer: BarnyardConnection tag
  new val create(peer': BarnyardConnection tag) => peer = peer'

type Step is (Prime | Start | Feed | PipeIn | Wake)

actor \nodoc\ HarnessConnection is BarnyardConnection
  let _h: TestHelper
  let _log: Logger[String]
  embed _params: Map[String, String] = _params.create()
  embed _sent: Array[U8] = _sent.create()
  embed _events: Array[String] = _events.create()
  embed _trail: Array[String] = _trail.create()
  var _pending: Array[U8] val = recover val Array[U8] end
  var _state: (BarnyardConnectionInteractableState box | None) = None
  var _armed: USize = 0
  var _outcome: String = "open"

  new create(h: TestHelper) =>
    _h = h
    _log = StringLogger(Error, h.env.out)

  be scenario(steps: Array[Step] val, verify: {(HarnessConnection ref)} val) =>
    _advance(steps, 0, verify)

  be _next(steps: Array[Step] val, i: USize, verify: {(HarnessConnection ref)} val) =>
    _advance(steps, i, verify)

  fun ref _advance(steps: Array[Step] val, i: USize,
    verify: {(HarnessConnection ref)} val)
  =>
    if i >= steps.size() then
      verify(this)
      return
    end
    try
      match steps(i)?
      | let s: Prime =>
        _armed = s.qty
      | let s: Start =>
        _drive(s.make(this))
        _pump()
      | let s: Feed =>
        _pending = _CatBytes(_pending, s.data)
        _pump()
      | let s: PipeIn =>
        match _state
        | let p: BarnyardConnectionPipingState box => _drive(p.pipe(this, s.data))
        else
          _events.push("pipe_ignored")
        end
      | let s: Wake =>
        match _state
        | let is': BarnyardConnectionIdleState box =>
          _drive(is'.wake(this, s.peer))
          _pump()
        else
          _events.push("wake_ignored")
        end
      end
    end
    _next(steps, i + 1, verify)

  fun ref _pump() =>
    while true do
      match _state
      | let rs: BarnyardConnectionReaderState box =>
        let want = if _armed == 0 then _pending.size() else _armed end
        if (want == 0) or (_pending.size() < want) then return end
        let chunk = _pending.trim(0, want)
        _pending = _pending.trim(want)
        _drive(rs.read(this, chunk))
      else
        return
      end
    end

  fun ref _drive(t: BarnyardConnectionTransition box) =>
    var continue' = true
    var s = t
    while continue' do
      _trail.push(s.name())
      match \exhaustive\ s
      | let _: BarnyardConnectionClose box =>
        continue' = false
        _outcome = "close"
        _state = None
      | let _: BarnyardConnectionHardClose box =>
        continue' = false
        _outcome = "hard_close"
        _state = None
      | let ws: BarnyardConnectionWriterState box =>
        s = ws.write(this)
      | let is': BarnyardConnectionIdleState box =>
        continue' = false
        _state = is'
        is'.enter(this)
      | let p: BarnyardConnectionPipingState box =>
        continue' = false
        _state = p
        p.enter(this)
      | let rs: BarnyardConnectionReaderState box =>
        continue' = false
        _state = rs
        rs.enter(this)
      end
    end

  fun ref log(): Logger[String] => _log

  fun ref send(payload: (ByteSeq | ByteSeqIter)) =>
    _events.push("send")
    match payload
    | let str: String => _sent.append(str.array())
    | let arr: Array[U8] val => _sent.append(arr)
    | let iter: ByteSeqIter =>
      for b in iter.values() do
        match b
        | let str: String => _sent.append(str.array())
        | let arr: Array[U8] val => _sent.append(arr)
        end
      end
    end

  fun ref buffer_until(qty: (BufferSize | Streaming)) =>
    _armed = match qty
    | let b: BufferSize => b()
    | Streaming => 0
    end
    _events.push("arm:" + _armed.string())

  fun ref mute() => _events.push("mute")

  fun ref unmute() => _events.push("unmute")

  fun ref on_param(key: String val, value: String val) => _params(key) = value

  fun params(): this->Map[String, String] => _params

  fun ref established() => _events.push("established")

  be peer_with(peer: BarnyardConnection tag) => _events.push("peer_with")

  be forward(data: ForwardData) => _events.push("forward_ignored")

  be release() => _events.push("release")

  fun sent_bytes(): this->Array[U8] => _sent
  fun events(): this->Array[String] => _events
  fun trail(): this->Array[String] => _trail
  fun outcome(): String => _outcome
  fun armed(): USize => _armed

  fun state_name(): String =>
    match _state
    | let s: BarnyardConnectionInteractableState box => s.name()
    | None => _outcome
    end
