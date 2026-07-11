use "pony_test"
use client = "client"
use server = "server"
use wire = "wire"

actor \nodoc\ Main is TestList
  new create(env: Env) => PonyTest(env, this)
  new make() => None

  fun tag tests(test: PonyTest) =>
    wire.Main.make().tests(test)
    server.Main.make().tests(test)
    client.Main.make().tests(test)
    test(_WorkQueuePushThenPop)
    test(_WorkQueuePopThenPush)
    test(_WorkQueueWithdraw)
    test(_LoopbackHandshake)
    test(_LoopbackRawHandshake)
    test(_LoopbackLargeQuery)
    test(_LoopbackGarbageStartup)
