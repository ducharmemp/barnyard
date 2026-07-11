use "../connection"
use "../wire"
use "../harness"
use "collections"
use "pony_test"
use "random"

primitive \nodoc\ _TestBackendInfo
  fun apply(): BarnyardBackendInfo val =>
    recover val BarnyardBackendInfo("127.0.0.1", "5432", "alice", "sekret", "db1") end

primitive \nodoc\ _AuthOk
  fun apply(): Array[U8] val => Frame('R', recover val [as U8: 0; 0; 0; 0] end)

primitive \nodoc\ _RfqIdle
  fun apply(): Array[U8] val => Frame('Z', recover val [as U8: 'I'] end)

primitive \nodoc\ _ClientAwait
  fun steps(extra: Array[Step] val): Array[Step] val =>
    recover val
      let out = Array[Step](1 + extra.size())
      out.push(Start(
        {(peer: BarnyardConnection tag): BarnyardConnectionTransition box =>
          BarnyardClientAwaitAuth(_TestBackendInfo())}))
      for s in extra.values() do out.push(s) end
      out
    end

class \nodoc\ iso _ClientStartupPacket is UnitTest
  fun name(): String => "client/startup_packet_and_arm"

  fun apply(h: TestHelper) =>
    h.long_test(2_000_000_000)
    let steps = recover val
      [as Step:
        Start(
          {(peer: BarnyardConnection tag): BarnyardConnectionTransition box =>
            BarnyardClientStartup(_TestBackendInfo())})
      ]
    end
    HarnessConnection(h).scenario(steps,
      {(hc: HarnessConnection ref) =>
        EqBytes(h, StartupLiteral(), hc.sent_bytes(), "startup packet")
        h.assert_eq[String]("ClientAwaitAuth", hc.state_name())
        h.assert_eq[USize](5, hc.armed())
        h.complete(true)
      })

class \nodoc\ iso _ClientAuthOkEpilogue is UnitTest
  fun name(): String => "client/auth_ok_epilogue_offers"

  fun apply(h: TestHelper) =>
    h.long_test(2_000_000_000)
    h.expect_action("c2-partial")
    h.expect_action("c2-full")
    h.expect_action("c2-kshort")
    let params = Cat(
      Frame('S', "a\x001\x00".array()),
      Frame('S', "b\x002\x00".array()))
    let keydata = Frame('K', recover val [as U8: 0; 0; 0; 9; 0; 0; 0; 9] end)
    let partial = Cat(Cat(_AuthOk(), params), keydata)
    HarnessConnection(h).scenario(
      _ClientAwait.steps(recover val [as Step: Feed(partial)] end),
      {(hc: HarnessConnection ref) =>
        h.assert_eq[USize](0, Count(hc.events(), "established"), "before rfq")
        h.assert_eq[String]("open", hc.outcome())
        h.complete_action("c2-partial")
      })
    HarnessConnection(h).scenario(
      _ClientAwait.steps(recover val
        [as Step: Feed(Cat(partial, _RfqIdle()))]
      end),
      {(hc: HarnessConnection ref) =>
        h.assert_eq[USize](1, Count(hc.events(), "established"), "after rfq")
        h.assert_eq[String]("ClientIdle", hc.state_name())
        h.assert_eq[USize](2, hc.params().size())
        h.assert_eq[String]("1", hc.params().get_or_else("a", "?"))
        h.assert_eq[String]("2", hc.params().get_or_else("b", "?"))
        h.assert_eq[USize](0, hc.sent_bytes().size(), "nothing sent")
        h.complete_action("c2-full")
      })
    HarnessConnection(h).scenario(
      _ClientAwait.steps(recover val
        [as Step:
          Feed(Cat(Cat(_AuthOk(),
            Frame('K', recover val [as U8: 1; 2; 3] end)), _RfqIdle()))
        ]
      end),
      {(hc: HarnessConnection ref) =>
        h.assert_eq[USize](1, Count(hc.events(), "established"), "short K tolerated")
        h.assert_eq[String]("ClientIdle", hc.state_name())
        h.complete_action("c2-kshort")
      })

class \nodoc\ iso _ClientCleartextAuth is UnitTest
  fun name(): String => "client/cleartext_auth_roundtrip"

  fun apply(h: TestHelper) =>
    h.long_test(2_000_000_000)
    let challenge = Frame('R', recover val [as U8: 0; 0; 0; 3] end)
    let steps = _ClientAwait.steps(recover val
      [as Step:
        Feed(challenge)
        Feed(Cat(_AuthOk(), _RfqIdle()))
      ]
    end)
    HarnessConnection(h).scenario(steps,
      {(hc: HarnessConnection ref) =>
        EqBytes(h,
          Cat(recover val [as U8: 'p'; 0; 0; 0; 11] end, "sekret\x00".array()),
          hc.sent_bytes(), "password message")
        h.assert_eq[String]("ClientIdle", hc.state_name())
        h.assert_eq[USize](1, Count(hc.events(), "established"))
        h.complete(true)
      })

class \nodoc\ iso _ClientMd5Auth is UnitTest
  fun name(): String => "client/md5_auth_known_vector"

  fun apply(h: TestHelper) =>
    h.long_test(2_000_000_000)
    let binfo = recover val
      BarnyardBackendInfo("127.0.0.1", "5432", "u", "pw", "db1")
    end
    let challenge = Frame('R',
      Cat(recover val [as U8: 0; 0; 0; 5] end, "abcd".array()))
    let steps = recover val
      [as Step:
        Start(
          {(peer: BarnyardConnection tag): BarnyardConnectionTransition box =>
            BarnyardClientAwaitAuth(binfo)})
        Feed(challenge)
      ]
    end
    HarnessConnection(h).scenario(steps,
      {(hc: HarnessConnection ref) =>
        EqBytes(h,
          Cat(recover val [as U8: 'p'; 0; 0; 0; 40] end,
            "md5f53705f070ba672cf558be39f3c59b15\x00".array()),
          hc.sent_bytes(), "md5 password message")
        h.assert_eq[String]("ClientAwaitAuth", hc.state_name())
        h.complete(true)
      })

class \nodoc\ iso _ClientRejectBranches is UnitTest
  fun name(): String => "client/reject_branches_hard_close"

  fun apply(h: TestHelper) =>
    h.long_test(2_000_000_000)
    let cases: Array[(String, Array[U8] val)] val = recover val
      [as (String, Array[U8] val):
        ("error-first", Frame('E', recover val [as U8: 1; 2; 3; 4] end).trim(0, 5))
        ("scram", Frame('R', recover val [as U8: 0; 0; 0; 10] end))
        ("short-auth", recover val [as U8: 'R'; 0; 0; 0; 6; 9; 9] end)
        ("epilogue-error",
          Cat(Frame('R', recover val [as U8: 0; 0; 0; 0] end),
            Frame('E', recover val [as U8: 1; 2; 3; 4] end)))
        ("epilogue-unknown",
          Cat(Frame('R', recover val [as U8: 0; 0; 0; 0] end),
            Frame('Q', recover val [as U8: 1; 2; 3; 4] end)))
      ]
    end
    for c in cases.values() do
      (let action: String, let bytes: Array[U8] val) = c
      h.expect_action(action)
      HarnessConnection(h).scenario(
        _ClientAwait.steps(recover val [as Step: Feed(bytes)] end),
        {(hc: HarnessConnection ref) =>
          h.assert_eq[String]("hard_close", hc.outcome(), action)
          h.assert_eq[USize](0, Count(hc.events(), "established"), action)
          h.assert_eq[USize](0, hc.sent_bytes().size(), action + " no leak")
          h.complete_action(action)
        })
    end

class \nodoc\ iso _ClientParamStorm is UnitTest
  fun name(): String => "client/parameter_storm"

  fun apply(h: TestHelper) =>
    h.long_test(4_000_000_000)
    let seed: U64 = 20260711
    for iter in Range[USize](0, 12) do
      let action: String = "c6-" + iter.string()
      h.expect_action(action)
      let pairs: Array[(String, String)] val = recover val
        let r = Rand(seed + iter.u64())
        let out = Array[(String, String)]
        for i in Range[USize](0, (r.next() % 9).usize()) do
          let value = recover iso String end
          for _ in Range[USize](0, (r.next() % 11).usize()) do
            value.push('a' + (r.next() % 26).u8())
          end
          out.push(("key" + i.string(), consume value))
        end
        out
      end
      let stream = recover val
        let r = Rand(seed + 1000 + iter.u64())
        let out = Array[U8]
        out.append(_AuthOk())
        let kd_at = (r.next() % (pairs.size().u64() + 1)).usize()
        var i: USize = 0
        for p in pairs.values() do
          if i == kd_at then
            out.append(Frame('K', recover val [as U8: 0; 0; 0; 1; 0; 0; 0; 2] end))
          end
          (let key: String, let value: String) = p
          out.append(Frame('S', Cat((key + "\x00").array(), (value + "\x00").array())))
          i = i + 1
        end
        if kd_at == pairs.size() then
          out.append(Frame('K', recover val [as U8: 0; 0; 0; 1; 0; 0; 0; 2] end))
        end
        out.append(_RfqIdle())
        out
      end
      HarnessConnection(h).scenario(
        _ClientAwait.steps(recover val [as Step: Feed(stream)] end),
        {(hc: HarnessConnection ref) =>
          h.assert_eq[String]("ClientIdle", hc.state_name(), action)
          h.assert_eq[USize](1, Count(hc.events(), "established"), action)
          h.assert_eq[USize](pairs.size(), hc.params().size(), action)
          for p in pairs.values() do
            (let key: String, let value: String) = p
            h.assert_eq[String](value, hc.params().get_or_else(key, "?"),
              action + " " + key)
          end
          h.complete_action(action)
        })
    end

class \nodoc\ iso _ClientMalformedParamTolerated is UnitTest
  fun name(): String => "client/malformed_param_tolerated"

  fun apply(h: TestHelper) =>
    h.long_test(2_000_000_000)
    let stream = Cat(Cat(_AuthOk(), Frame('S', "novalue".array())), _RfqIdle())
    HarnessConnection(h).scenario(
      _ClientAwait.steps(recover val [as Step: Feed(stream)] end),
      {(hc: HarnessConnection ref) =>
        h.assert_eq[String]("ClientIdle", hc.state_name())
        h.assert_eq[USize](1, Count(hc.events(), "established"))
        h.assert_eq[USize](0, hc.params().size())
        h.complete(true)
      })

class \nodoc\ iso _ClientBoundRelay is UnitTest
  fun name(): String => "client/bound_duplex_relay"

  fun apply(h: TestHelper) =>
    h.long_test(2_000_000_000)
    h.expect_action("relay")
    let probe = ProbePeer(h)
    let from_pg_1 = recover val [as U8: 10; 11; 12] end
    let from_pg_2 = recover val [as U8: 13] end
    let from_client_1 = recover val [as U8: 20; 21] end
    let from_client_2 = recover val [as U8: 22; 23; 24] end
    let steps = recover val
      [as Step:
        Start(
          {(peer: BarnyardConnection tag): BarnyardConnectionTransition box =>
            BarnyardClientServing(probe, ScanBetween)})
        Feed(from_pg_1)
        Feed(from_pg_2)
        PipeIn(from_client_1)
        PipeIn(from_client_2)
      ]
    end
    HarnessConnection(h).scenario(steps,
      {(hc: HarnessConnection ref)(h, probe, from_pg_1, from_pg_2,
        from_client_1, from_client_2)
      =>
        EqBytes(h, Cat(from_client_1, from_client_2), hc.sent_bytes(),
          "client bytes sent to pg")
        h.assert_eq[String]("ClientServing", hc.state_name())
        h.assert_eq[USize](0, hc.armed(), "streaming arm")
        probe.inspect(
          {(p: ProbePeer ref)(h, from_pg_1, from_pg_2) =>
            EqBytes(h, Cat(from_pg_1, from_pg_2),
              p.forwarded_bytes(), "pg bytes forwarded to server")
            h.complete_action("relay")
          })
      })

primitive \nodoc\ _WalkFixture
  fun apply(status: U8): Array[U8] val =>
    Cat(Cat(Cat(
      Frame('T', recover val [as U8: 1; 2; 3] end),
      Frame('D', recover val [as U8: 'Z'; 0; 0; 0; 5; 'I'; 7; 7; 7; 7] end)),
      Frame('C', "SELECT 1\x00".array())),
      Frame('Z', recover val [status] end))

class \nodoc\ iso _ClientResponseWalk is UnitTest
  fun name(): String => "client/response_walk_chunking"

  fun apply(h: TestHelper) =>
    h.long_test(10_000_000_000)
    for status in [as U8: 'I'; 'T'; 'E'].values() do
      let fixture = _WalkFixture(status)
      var at: USize = 1
      while at < fixture.size() do
        _run(h, status, fixture,
          recover val [as Array[U8] val: fixture.trim(0, at); fixture.trim(at)] end,
          "walk-" + String.from_array(recover val [status] end) + "-" + at.string())
        at = at + 1
      end
      _run(h, status, fixture, recover val [as Array[U8] val: fixture] end,
        "walk-" + String.from_array(recover val [status] end) + "-whole")
      let drip = recover val
        let out = Array[Array[U8] val](fixture.size())
        var i: USize = 0
        while i < fixture.size() do out.push(fixture.trim(i, i + 1)); i = i + 1 end
        out
      end
      _run(h, status, fixture, drip,
        "walk-" + String.from_array(recover val [status] end) + "-drip")
    end

  fun _run(h: TestHelper, status: U8, fixture: Array[U8] val,
    chunks: Array[Array[U8] val] val, action: String)
  =>
    h.expect_action(action)
    let probe = ProbePeer(h)
    // 'I' ends the transaction: the backend re-offers itself to the pool
    // (ClientIdle). 'T'/'E' stays serving. Either way it never signals the
    // server — the server releases it via its own outbound scan.
    let expected = if status == 'I' then "ClientIdle" else "ClientServing" end
    let steps = recover val
      let out = Array[Step](1 + chunks.size())
      out.push(Start(
        {(peer: BarnyardConnection tag): BarnyardConnectionTransition box =>
          BarnyardClientServing(probe, ScanBetween)}))
      for c in chunks.values() do out.push(Feed(c)) end
      out
    end
    HarnessConnection(h).scenario(steps,
      {(hc: HarnessConnection ref)(h, probe, fixture, action, expected) =>
        h.assert_eq[String](expected, hc.state_name(), action)
        probe.inspect(
          {(p: ProbePeer ref)(h, fixture, action) =>
            EqBytes(h, fixture, p.forwarded_bytes(), action + " relayed")
            // no cross-actor boundary signal: the backend never releases its peer
            h.assert_eq[USize](0, Count(p.events(), "release"), action + " no release")
            h.complete_action(action)
          })
      })
