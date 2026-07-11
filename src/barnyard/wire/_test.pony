use "pony_test"

actor \nodoc\ Main is TestList
  new create(env: Env) => PonyTest(env, this)
  new make() => None

  fun tag tests(test: PonyTest) =>
    test(_WireFrameRoundtrip)
    test(_WireKnownMessageLiterals)
    test(_WireClientStartupLayout)
    test(_WireFrameHeaderBoundaries)
