use "barnyard"

actor Main
  new create(env: Env) =>
    Barnyard(env)

  fun @runtime_override_defaults(rto: RuntimeOptions) =>
    // An I/O-bound proxy wants few scheduler threads: with the runtime
    // default (one per core), mostly-idle threads suspend and wake per
    // message and actors migrate across cores, which measured ~4x worse
    // than 2 threads on a 14-thread machine. Pass --ponymaxthreads to
    // override.
    //
    // This can't honor an environment variable: it's a bare function that
    // runs before the runtime starts and may only call FFI and primitive
    // functions, which rules out building the name string for getenv.
    rto.ponymaxthreads = 2
