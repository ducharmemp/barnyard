use "../connection"
use "../wire"
use "../harness"
use "collections"
use "pony_test"

primitive \nodoc\ _ServerBoot
  fun plus(extra: Array[Step] val): Array[Step] val =>
    recover val
      let out = Array[Step](3 + extra.size())
      out.push(Prime(4))
      out.push(Start(
        {(peer: BarnyardConnection tag): BarnyardConnectionTransition box =>
          BarnyardServerAwaitLength}))
      out.push(Feed(StartupLiteral()))
      for s in extra.values() do out.push(s) end
      out
    end

primitive \nodoc\ _CheckEpilogue
  fun apply(h: TestHelper, frames: Array[(U8, Array[U8] val)] box,
    offset: USize, label: String)
  =>
    try
      (let t0: U8, let b0: Array[U8] val) = frames(offset)?
      h.assert_eq[U8]('R', t0, label + " frame 0 type")
      EqBytes(h, recover val [as U8: 0; 0; 0; 0] end, b0, label + " auth code")
      let expected_params: Array[(String, String)] val = recover val
        [as (String, String):
          ("server_version", "15.0")
          ("client_encoding", "UTF8")
          ("standard_conforming_strings", "on")
          ("DateStyle", "ISO, MDY")
        ]
      end
      for i in Range[USize](0, 4) do
        (let ts: U8, let bs: Array[U8] val) = frames(offset + 1 + i)?
        (let key: String, let value: String) = expected_params(i)?
        h.assert_eq[U8]('S', ts, label + " param frame type")
        EqBytes(h, Cat((key + "\x00").array(), (value + "\x00").array()),
          bs, label + " param " + key)
      end
      (let tk: U8, let bk: Array[U8] val) = frames(offset + 5)?
      h.assert_eq[U8]('K', tk, label + " key data type")
      (let tz: U8, let bz: Array[U8] val) = frames(offset + 6)?
      h.assert_eq[U8]('Z', tz, label + " rfq type")
      EqBytes(h, recover val [as U8: 'I'] end, bz, label + " rfq status")
    else
      h.fail(label + ": epilogue frames missing")
    end

class \nodoc\ iso _ServerStartupEpilogue is UnitTest
  fun name(): String => "server/startup_canonical_epilogue"

  fun apply(h: TestHelper) =>
    h.long_test(2_000_000_000)
    HarnessConnection(h).scenario(_ServerBoot.plus(recover val Array[Step] end),
      {(hc: HarnessConnection ref) =>
        h.assert_eq[String]("ServerUnbound", hc.state_name())
        h.assert_eq[USize](2, hc.params().size())
        h.assert_eq[String]("alice", hc.params().get_or_else("user", "?"))
        h.assert_eq[String]("db1", hc.params().get_or_else("database", "?"))
        let frames = SplitFrames(ToVal(hc.sent_bytes()))
        h.assert_eq[USize](7, frames.size())
        _CheckEpilogue(h, frames, 0, "epilogue")
        h.complete(true)
      })

class \nodoc\ iso _ServerSslGssDecline is UnitTest
  fun name(): String => "server/ssl_gss_declined_then_startup"

  fun apply(h: TestHelper) =>
    h.long_test(2_000_000_000)
    h.expect_action("ssl")
    h.expect_action("gss")
    for probe in [as (String, Array[U8] val): ("ssl", SslRequest()); ("gss", GssRequest())].values() do
      (let action: String, let request: Array[U8] val) = probe
      let steps = recover val
        [as Step:
          Prime(4)
          Start(
            {(peer: BarnyardConnection tag): BarnyardConnectionTransition box =>
              BarnyardServerAwaitLength})
          Feed(request)
          Feed(StartupLiteral())
        ]
      end
      HarnessConnection(h).scenario(steps,
        {(hc: HarnessConnection ref) =>
          try
            h.assert_eq[U8]('N', hc.sent_bytes()(0)?, action + " decline byte")
          else
            h.fail(action + ": nothing sent")
          end
          h.assert_eq[String]("ServerUnbound", hc.state_name())
          h.complete_action(action)
        })
    end

class \nodoc\ iso _ServerMalformedStartup is UnitTest
  fun name(): String => "server/malformed_startup_hard_closes"

  fun apply(h: TestHelper) =>
    h.long_test(2_000_000_000)
    let cases: Array[(String, Array[U8] val)] val = recover val
      [as (String, Array[U8] val):
        ("len7", recover val [as U8: 0; 0; 0; 7] end)
        ("empty-v3", recover val [as U8: 0; 0; 0; 8; 0; 3; 0; 0] end)
        ("bad-disc", recover val [as U8: 0; 0; 0; 16; 9; 9; 9; 9] end)
      ]
    end
    for c in cases.values() do
      (let action: String, let bytes: Array[U8] val) = c
      h.expect_action(action)
      let steps = recover val
        [as Step:
          Prime(4)
          Start(
            {(peer: BarnyardConnection tag): BarnyardConnectionTransition box =>
              BarnyardServerAwaitLength})
          Feed(bytes)
        ]
      end
      HarnessConnection(h).scenario(steps,
        {(hc: HarnessConnection ref) =>
          h.assert_eq[String]("hard_close", hc.outcome(), action)
          h.complete_action(action)
        })
    end

class \nodoc\ iso _ServerRawRelay is UnitTest
  fun name(): String => "server/raw_relay_both_ways"

  fun apply(h: TestHelper) =>
    h.long_test(2_000_000_000)
    h.expect_action("relay")
    let probe = ProbePeer(h)
    let q1 = Frame('Q', "select 1\x00".array())
    let q2 = Frame('Q', "select 2\x00".array())
    let resp = recover val [as U8: 9; 8; 7; 6] end
    let steps = _ServerBoot.plus(recover val
      [as Step:
        Feed(q1)
        Wake(probe)
        Feed(q2)
        PipeIn(resp)
      ]
    end)
    HarnessConnection(h).scenario(steps,
      {(hc: HarnessConnection ref)(h, probe, q1, q2, resp) =>
        h.assert_eq[String]("ServerBound", hc.state_name())
        h.assert_true(Count(hc.events(), "established") >= 1, "acquired a backend")
        let sent = ToVal(hc.sent_bytes())
        EqBytes(h, resp, sent.trim(sent.size() - resp.size()),
          "response relayed to client")
        probe.inspect(
          {(p: ProbePeer ref)(h, q1, q2) =>
            EqBytes(h, Cat(q1, q2), p.forwarded_bytes(), "client frames relayed to backend")
            h.complete_action("relay")
          })
      })

class \nodoc\ iso _ServerIdleTerminate is UnitTest
  fun name(): String => "server/idle_terminate_does_not_acquire"

  fun apply(h: TestHelper) =>
    h.long_test(2_000_000_000)
    h.expect_action("idle-term")
    // A done client sends a bare Terminate while idle (Unbound). It must close
    // without pulling a backend from the pool — otherwise that backend binds to a
    // dead client and leaks.
    let term = Frame('X', recover val Array[U8] end)
    let steps = _ServerBoot.plus(recover val [as Step: Feed(term)] end)
    HarnessConnection(h).scenario(steps,
      {(hc: HarnessConnection ref) =>
        h.assert_eq[String]("close", hc.outcome(), "closed on idle Terminate")
        h.assert_eq[USize](0, Count(hc.events(), "established"),
          "no backend acquired for a Terminate")
        h.complete_action("idle-term")
      })

class \nodoc\ iso _ServerReleasesAtReady is UnitTest
  fun name(): String => "server/releases_backend_at_ready_boundary"

  fun apply(h: TestHelper) =>
    h.long_test(2_000_000_000)
    // The server watches its own outbound (PG->client) stream: a ReadyForQuery
    // with status 'I' ends the transaction and unbinds it (re-acquire next
    // query); 'T'/'E' means still in a transaction, so it stays bound. Either
    // way the response reaches the client.
    let cases: Array[(U8, String, String)] val = recover val
      [as (U8, String, String):
        ('I', "idle", "ServerUnbound")
        ('T', "intx", "ServerBound")
      ]
    end
    for c in cases.values() do
      (let status: U8, let action: String, let expected: String) = c
      h.expect_action(action)
      let probe = ProbePeer(h)
      let q = Frame('Q', "select 1\x00".array())
      let resp = Cat(
        Frame('C', "SELECT 1\x00".array()),
        Frame('Z', recover val [status] end))
      let steps = _ServerBoot.plus(recover val
        [as Step:
          Feed(q)
          Wake(probe)
          PipeIn(resp)
        ]
      end)
      HarnessConnection(h).scenario(steps,
        {(hc: HarnessConnection ref)(h, action, expected, resp) =>
          h.assert_eq[String](expected, hc.state_name(), action)
          let sent = ToVal(hc.sent_bytes())
          EqBytes(h, resp, sent.trim(sent.size() - resp.size()),
            action + " response reached client")
          h.complete_action(action)
        })
    end

class \nodoc\ iso _ServerTerminateIntercepted is UnitTest
  fun name(): String => "server/terminate_not_forwarded"

  fun apply(h: TestHelper) =>
    h.long_test(2_000_000_000)
    h.expect_action("terminated")
    let probe = ProbePeer(h)
    let q = Frame('Q', "select 1\x00".array())
    let term = Frame('X', recover val Array[U8] end)
    let steps = _ServerBoot.plus(recover val
      [as Step:
        Feed(q)
        Wake(probe)
        Feed(term)
      ]
    end)
    HarnessConnection(h).scenario(steps,
      {(hc: HarnessConnection ref)(h, probe, q) =>
        // the client side closes, but Terminate must never reach the backend
        h.assert_eq[String]("close", hc.outcome(), "client closed on Terminate")
        probe.inspect(
          {(p: ProbePeer ref)(h, q) =>
            EqBytes(h, q, p.forwarded_bytes(), "only the query was forwarded, not Terminate")
            h.complete_action("terminated")
          })
      })
