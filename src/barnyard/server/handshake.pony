use "buffered"
use "logger"
use "../connection"
use "../wire"

// States for the psql -> barnyard direction (we are impersonating a postgres
// backend to an incoming client).

primitive BarnyardServerAwaitLength is BarnyardConnectionReaderState
  fun name(): String => "ServerAwaitLength"

  fun read(conn: BarnyardConnection ref, data: ByteSeq val): BarnyardConnectionTransition box =>
    let r = Reader
    r.append(data)
    try
      let len = r.u32_be()?.usize()
      if len < 8 then
        conn.log()(Error) and conn.log().log("client: startup length too short: " + len.string())
        return BarnyardConnectionHardClose
      end
      conn.log()(Fine) and conn.log().log("client: startup header, " + len.string() + " byte payload")
      Arm(conn, 4)
      BarnyardServerAwaitDiscriminator(len)
    else
      conn.log()(Error) and conn.log().log("client: short startup header")
      BarnyardConnectionHardClose
    end

class BarnyardServerAwaitDiscriminator is BarnyardConnectionReaderState
  let _len: USize

  new create(len: USize) =>
    _len = len

  fun name(): String => "ServerAwaitDiscriminator"

  fun read(conn: BarnyardConnection ref, data: ByteSeq val): BarnyardConnectionTransition box =>
    let r = Reader
    r.append(data)
    try
      let disc = r.u32_be()?
      if (disc == Pg.ssl()) or (disc == Pg.gss()) then
        conn.log()(Fine) and conn.log().log("client: declining ssl/gss negotiation")
        conn.send("N")        // decline; 'S' if you support TLS
        Arm(conn, 4)
        BarnyardServerAwaitLength             // loop: real startup follows
      elseif disc == Pg.v3() then
        let rest = _len - 8                   // length + version already consumed
        if rest == 0 then
          conn.log()(Error) and conn.log().log("client: empty startup payload")
          return BarnyardConnectionHardClose
        end
        Arm(conn, rest)
        BarnyardServerAwaitStartupParams
      else
        conn.log()(Error) and conn.log().log("client: unknown startup discriminator " + disc.string())
        BarnyardConnectionHardClose
      end
    else
      conn.log()(Error) and conn.log().log("client: short startup discriminator")
      BarnyardConnectionHardClose
    end

primitive BarnyardServerAwaitStartupParams is BarnyardConnectionReaderState
  fun name(): String => "ServerAwaitStartupParams"

  fun read(conn: BarnyardConnection ref, data: ByteSeq val): BarnyardConnectionTransition box =>
    let r = Reader
    r.append(data)
    try
      while true do
        let key: String val = String.from_iso_array(r.read_until('\0')?)
        let value: String val = String.from_iso_array(r.read_until('\0')?)
        conn.log()(Fine) and conn.log().log("client: startup param " + key + " = " + value)
        conn.on_param(key, value)
      end
    end
    BarnyardServerAuthChallenge

primitive BarnyardServerAuthChallenge is BarnyardConnectionWriterState
  fun name(): String => "ServerAuthChallenge"

  fun write(conn: BarnyardConnection ref): BarnyardConnectionTransition box =>
    // Authentication OK, bullshit for now
    conn.send(PgWire.authentication_ok())
    BarnyardServerParameterStatus

primitive BarnyardServerParameterStatus is BarnyardConnectionWriterState
  fun name(): String => "ServerParameterStatus"

  fun write(conn: BarnyardConnection ref): BarnyardConnectionTransition box =>
    conn.send(PgWire.parameter_status("server_version", "15.0"))
    conn.send(PgWire.parameter_status("client_encoding", "UTF8"))
    conn.send(PgWire.parameter_status("standard_conforming_strings", "on"))
    conn.send(PgWire.parameter_status("DateStyle", "ISO, MDY"))
    BarnyardServerBackendKeyData

primitive BarnyardServerBackendKeyData is BarnyardConnectionWriterState
  fun name(): String => "ServerBackendKeyData"

  fun write(conn: BarnyardConnection ref): BarnyardConnectionTransition box =>
    conn.send(PgWire.backend_key_data(123, 456))
    BarnyardServerReadyIndicator

primitive BarnyardServerReadyIndicator is BarnyardConnectionWriterState
  fun name(): String => "ServerReadyIndicator"

  fun write(conn: BarnyardConnection ref): BarnyardConnectionTransition box =>
    conn.send(PgWire.ready_for_query('I'))
    conn.log()(Fine) and conn.log().log("client: handshake complete")
    BarnyardServerUnbound
