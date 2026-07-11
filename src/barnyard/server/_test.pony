use "pony_test"

actor \nodoc\ Main is TestList
  new create(env: Env) => PonyTest(env, this)
  new make() => None

  fun tag tests(test: PonyTest) =>
    test(_ServerStartupEpilogue)
    test(_ServerSslGssDecline)
    test(_ServerMalformedStartup)
    test(_ServerRawRelay)
    test(_ServerReleasesAtReady)
    test(_ServerIdleTerminate)
    test(_ServerTerminateIntercepted)
