use "harness"
use "connection"
use "promises"
use "pony_test"

class \nodoc\ iso _WorkQueuePushThenPop is UnitTest
  fun name(): String => "work_queue/push_then_pop"

  fun apply(h: TestHelper) =>
    h.long_test(2_000_000_000)
    h.expect_action("popped")
    let wq = BarnyardWorkQueue
    let server = ProbePeer(h)
    wq.push(server)
    let p = Promise[BarnyardConnection tag]
    p.next[None]({(s: BarnyardConnection tag)(h, server) =>
      h.assert_true(s is server, "popped the pushed server")
      h.complete_action("popped")
    })
    wq.pop(p)

class \nodoc\ iso _WorkQueuePopThenPush is UnitTest
  fun name(): String => "work_queue/pop_then_push"

  fun apply(h: TestHelper) =>
    h.long_test(2_000_000_000)
    h.expect_action("fulfilled")
    let wq = BarnyardWorkQueue
    let server = ProbePeer(h)
    let p = Promise[BarnyardConnection tag]
    p.next[None]({(s: BarnyardConnection tag)(h, server) =>
      h.assert_true(s is server, "waiting backend got the pushed server")
      h.complete_action("fulfilled")
    })
    wq.pop(p)
    wq.push(server)

class \nodoc\ iso _WorkQueueWithdraw is UnitTest
  fun name(): String => "work_queue/withdraw_skips_dead_server"

  fun apply(h: TestHelper) =>
    h.long_test(2_000_000_000)
    h.expect_action("skipped")
    let wq = BarnyardWorkQueue
    let dead = ProbePeer(h)
    let live = ProbePeer(h)
    wq.push(dead)
    wq.push(live)
    wq.withdraw(dead)
    let p = Promise[BarnyardConnection tag]
    p.next[None]({(s: BarnyardConnection tag)(h, dead, live) =>
      h.assert_false(s is dead, "withdrawn server not delivered")
      h.assert_true(s is live, "next live server delivered instead")
      h.complete_action("skipped")
    })
    wq.pop(p)
