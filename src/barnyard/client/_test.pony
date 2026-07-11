use "pony_test"

actor \nodoc\ Main is TestList
  new create(env: Env) => PonyTest(env, this)
  new make() => None

  fun tag tests(test: PonyTest) =>
    test(_ClientStartupPacket)
    test(_ClientAuthOkEpilogue)
    test(_ClientCleartextAuth)
    test(_ClientMd5Auth)
    test(_ClientRejectBranches)
    test(_ClientParamStorm)
    test(_ClientMalformedParamTolerated)
    test(_ClientBoundRelay)
    test(_ClientResponseWalk)
