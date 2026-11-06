# Serve measurements

Authenticated `GET /diagnostics/serve` returns process-local measurements. It <!-- local-path-ok -->
uses the normal Remote API bearer-token policy. It does not read agent state.
The endpoint shares the same 32 worker slots as other requests.

- `accepted_sockets`: cumulative accepted sockets, including the socket waiting
  for a worker slot, and connections rejected by the address limit.
- `active_worker_slots` and `worker_limit`: current occupied slots and the
  unchanged limit of 32. The diagnostic request occupies a slot.
- `rejected_connections`: cumulative address-limit rejections (HTTP 429 or an
  immediate close if the nonblocking response write cannot finish). These
  connections use no worker and do not add completed request samples.
- `connections_per_address` and `header_timeout_seconds`: effective connection
  limit and total header-read deadline. No client addresses enter diagnostics.
- `samples`: the latest 1,024 completed requests, oldest first. Labels group
  requests by HTTP method, fixed resource and fixed action words. Variable
  segments become `:id`; labels stop at eight segments. Unknown resources and
  methods use `other` and `OTHER`. No IDs, queries, headers, prompts, paths,
  tokens, or response bodies enter the sample store.
- `admission_ms`: time from accept to worker execution, including the slot wait.
  Time before accept in the kernel backlog is unavailable. Compare this with
  client elapsed time. Later connections can wait in the backlog while the
  listener waits for the first accepted socket.
- `store_lock_wait_ms`: cumulative wait for managed_agents.json.lock.
- `store_lock_hold_ms`: cumulative elapsed time from acquisition until unlock,
  including nested work and exception paths.
- `route_ms`: parsed-request processing through response encoding, before write.
- `response_bytes`: encoded response body size, excluding headers. This is the
  attempted size; it does not prove delivery after a disconnected client.
- `write_ms`: elapsed response write attempt, including headers and body.

Absent lock stages have zero values. Samples include bad requests and failed
writes. They reset on restart. They are a bounded observation window, not durable
metrics or an unbiased traffic histogram. Snapshot copies and sample updates
use a short mutex; no file I/O occurs under it.

`Server-Timing` adds `admission`, `store_lock_hold`, and `route` to the existing
stages. Write duration is available only after headers have been sent, so it
appears only in the endpoint. Byte counts and socket counts are also endpoint
fields. The existing `total` starts at worker execution and includes parsing;
the header total ends before writing. Admission, route, and lock hold are elapsed
observations and overlap other stages. Do not add them to exclusive stage times.

The worker limit, global slot wait, file-lock scope, and process model are unchanged.
Per-address admission now rejects extra connections before the global slot wait.
Headers have a separate 1-second default deadline; bodies retain 10 seconds.
Project metadata still uses the on-demand cache from Card 809.
