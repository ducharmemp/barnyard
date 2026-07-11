use "logger"
use "../connection"
use "../wire"

// Relays a Postgres response chunk to the server and tracks where transactions
// end. The scan is shared with the server (which watches the same stream on its
// outbound side); this side acts on the boundary purely for pool membership.
primitive BarnyardBackendResponseWalk
  fun apply(conn: BarnyardConnection ref, peer: BarnyardConnection tag,
    chunks: ByteSeq val, resume: ScanPosition = ScanBetween)
    : BarnyardConnectionTransition box
  =>
    match ResponseScan(_Bytes(chunks), resume)
    | let r: ScanReady =>
      peer.forward(chunks)
      if r.status == 'I' then
        // Transaction complete: return this backend to the pool. Our server sees
        // the same ReadyForQuery on its outbound stream and releases us on its
        // own — there is no cross-actor handoff to race the byte stream.
        BarnyardClientIdle
      else
        // Still in a transaction ('T'/'E'): stay bound and keep serving.
        BarnyardClientServing(peer, ScanBetween)
      end
    | let c: ScanContinue =>
      peer.forward(chunks)
      BarnyardClientServing(peer, c.position)
    | ScanMalformed =>
      conn.log()(Error) and conn.log().log("backend: malformed response frame")
      BarnyardConnectionHardClose
    end

primitive _Bytes
  fun apply(chunks: ByteSeq val): Array[U8] val =>
    match chunks
    | let s: String => s.array()
    | let a: Array[U8] val => a
    end
