use "collections"
use "promises"
use "connection"

// A promise-matched work queue. Servers with a pending client push themselves as
// work; free backends pop for work (holding a promise fulfilled when work
// arrives). Matching is order-preserving and never a synchronized handshake: a
// push either hands the server straight to a waiting backend or parks it.
//
// A server that disconnects while still parked withdraws itself (O(n), but
// `_items` is empty whenever a backend is free — it only holds servers under
// over-subscription).
actor BarnyardWorkQueue
  embed _items: List[BarnyardConnection tag] = _items.create()
  embed _waiters: List[Promise[BarnyardConnection tag]] = _waiters.create()

  be push(server: BarnyardConnection tag) =>
    try
      _waiters.shift()?(server)
    else
      _items.push(server)
    end

  be pop(p: Promise[BarnyardConnection tag]) =>
    try
      p(_items.shift()?)
    else
      _waiters.push(p)
    end

  be withdraw(server: BarnyardConnection tag) =>
    for node in _items.nodes() do
      try
        if node()? is server then
          node.remove()
          return
        end
      end
    end
