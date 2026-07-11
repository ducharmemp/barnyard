class BarnyardBackendInfo
  let host: String
  let port: String
  let username: String
  let password: String
  let database: String

  new create(host': String, port': String, username': String, password': String, database': String) =>
    host = host'
    port = port'
    username = username'
    password = password'
    database = database'

class BarnyardServerInfo
  let host: String
  let port: String

  new create(host': String, port': String) =>
    host = host'
    port = port'
