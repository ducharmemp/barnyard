use "../connection"
use "../wire"

primitive BarnyardClientIdle is BarnyardConnectionIdleState
  fun name(): String => "ClientIdle"

  fun enter(conn: BarnyardConnection ref) =>
    conn.established()

  fun wake(conn: BarnyardConnection ref, peer: BarnyardConnection tag)
    : BarnyardConnectionTransition box
  =>
    peer.peer_with(conn)
    BarnyardClientServing(peer, ScanBetween)

// Bound to a server: a command is in flight and its response is being relayed to
// the client and walked for the ReadyForQuery that ends the transaction. At an
// 'I' boundary the walk returns BarnyardClientIdle, re-offering this backend to
// the pool; at 'T'/'E' it stays bound.
class BarnyardClientServing is BarnyardConnectionPipingState
  let _peer: BarnyardConnection tag
  let _position: ScanPosition

  new create(peer: BarnyardConnection tag, position: ScanPosition) =>
    _peer = peer
    _position = position

  fun name(): String => "ClientServing"

  fun enter(conn: BarnyardConnection ref) =>
    ArmStream(conn)

  fun pipe(conn: BarnyardConnection ref, chunks: ForwardData): BarnyardConnectionTransition box =>
    conn.send(chunks)
    BarnyardClientServing(_peer, _position)

  fun read(conn: BarnyardConnection ref, data: ByteSeq val): BarnyardConnectionTransition box =>
    BarnyardBackendResponseWalk(conn, _peer, data, _position)
