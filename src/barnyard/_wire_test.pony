use "pony_test"

class iso _WireParameterStatusSmoke is UnitTest
  fun name(): String => "wire/parameter_status_produces_non_empty_message"

  fun apply(h: TestHelper) =>
    let bytes = _PgWire.parameter_status("server_version", "15.0")
    h.assert_true(bytes.size() > 0)
