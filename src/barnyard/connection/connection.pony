use "logger"
use "lori"

type ForwardData is (ByteSeq | Array[ByteSeq] val)

interface BarnyardConnection
  fun ref log(): Logger[String]
  fun ref send(payload: (ByteSeq | ByteSeqIter))
  fun ref buffer_until(qty: (BufferSize | Streaming))
  fun ref mute()
  fun ref unmute()
  fun ref on_param(key: String val, value: String val)
  fun ref established()
  be peer_with(peer: BarnyardConnection tag)
  be forward(data: ForwardData)
  be release()
