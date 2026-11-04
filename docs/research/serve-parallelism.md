# Parallel request handling in `tycho serve`

Research for [Fizzy card #798](https://fizzy.startkit.tech/1/cards/798).
Source baseline: `d24d0f4fbcc5a7eb6e074b19fa10290b13e9c91a`, 4 November 2026.
No runtime code changes. Card #803 owns the dismiss/poll lock path; this report does not change it.

## Finding

The current server is already threaded. It uses Ruby `TCPServer`, with a custom HTTP parser and response writer. It does not use WEBrick, Rack, or Puma. Adding threads alone will not remove the remaining waits.

`RemoteServer#start` accepts sockets on one listener thread. `spawn_client_worker` starts one Ruby thread per client. The limit is 32 active client workers. At the limit, the listener waits for a slot. It has already accepted one socket; later connections wait in the operating system backlog. Each worker reads one request, routes it, writes the response, and closes the socket. There is no HTTP keep-alive request loop.

The read deadline is 10 seconds, with a 64 KiB header limit. This deadline covers request parsing, not the full handler or response write. A slow reader, large attachment, remote peer call, or blocked lifecycle operation can occupy a worker. Shutdown drains workers for five seconds, then closes remaining sockets. Closing a socket cannot cancel work blocked elsewhere.

There are also background threads: push/lifecycle polling (five-second poll interval), project Git metadata refresh (30-second interval), and resource catalog workers. These can compete with request threads for state and locks.

Source map (paths are relative to the repository root):

| Source | Relevant methods or state |
| --- | --- |
| `lib/hq/remote_server.rb` | `start`, `spawn_client_worker`, `wait_for_client_slot`, `handle_client`, `read_request`, `write_http`, `load_all_agents`, `find_attachment!` |
| `lib/hq/domain/agent_store.rb` | `load_with_poll_events`, `mutate`, `read_snapshot`, `with_exclusive_lock` |
| `lib/hq/domain/request_timing.rb` | Thread-local timing and exclusive stage durations |

## Measurements

Environment: macOS arm64, Ruby 4.0.9, localhost, empty agent store and project list. A separate `bundle exec bin/tycho serve` process used a fresh temporary Tycho home, explicit config and logs roots, a fixture token, and an unused localhost port. No real Tycho state or running daemon was used. The helper stopped only its child PID.

The helper held `managed_agents.json.lock` with an external `flock`, then sent two concurrent `GET /agents` requests and three independent reads. It released the lock after one second. This models a slow lifecycle/poll critical section. It does not claim that a real empty poll takes one second. All responses below were HTTP 200.

| Trial | `/agents` A | `/agents` B | `/ui` | `/activity` | `/servers/resources` |
| --- | ---: | ---: | ---: | ---: | ---: |
| 1 | 1010.70 ms | 1009.92 ms | 5.68 ms | 5.92 ms | 3.95 ms |
| 2 | 1010.68 ms | 1010.52 ms | 7.16 ms | 7.47 ms | 7.65 ms |
| 3 | 1001.58 ms | 1001.66 ms | 1.47 ms | 1.77 ms | 1.52 ms |

The six agent reads reported `store_lock_wait` of 999.0–1002.0 ms. They waited for the same lock; after release, their short lifecycle sections ran in sequence. The independent reads completed while the lock was held. The first page request before the experiment took 15.96 ms, including connection and startup effects.

A second experiment opened 32 sockets and sent incomplete HTTP headers. A new `/ui` request took **10011.10 ms**. Its `Server-Timing` total was **0.5 ms**. The read deadlines freed worker slots after about 10 seconds. Thus the client delay was mostly admission wait, outside the request timer. This is a saturation demonstration, not a normal traffic benchmark. Socket admission order is not guaranteed; repeat measurements can vary. The fixture did not measure CPU scaling, large file throughput, real peer latency, or production percentiles.

## Where requests still wait

1. **Lifecycle file lock.** `AgentStore#with_exclusive_lock` opens the shared lock file and uses `LOCK_EX`. `load_with_poll_events` performs reconciliation and queue/delegation work under that lock. `mutate` also holds it across load, caller work, and save. Different agents can therefore block each other. Background polling uses this store too. Keep #803 changes separate and repeat the measurement after they land.
2. **Worker admission.** All 32 worker slots are shared by page, API, upload, attachment, and peer traffic. There is no reserved capacity for cheap reads. Slow socket writes have no total write deadline in this implementation.
3. **Work on the worker.** Attachment reads use `File.binread`, then write a buffered body. Large files use memory and can hold a slot. Peer HTTP, Git/PR work, log parsing, and JSON encoding also consume worker time. `find_attachment!` already uses a read snapshot instead of lifecycle reconciliation; a slow attachment is not proof that all handlers share one request thread.
4. **CPU and GVL.** In CRuby, threads overlap blocking I/O but do not execute ordinary Ruby code on several cores at once in the same Ractor. Parsing and object construction can still delay other work. The GVL does not protect a multi-step application transaction. See the [Ruby thread implementation](https://docs.ruby-lang.org/capi/en/master/d3/de7/thread_8c_source.html) and [Ruby thread API](https://docs.ruby-lang.org/capi/en/master/d6/dfb/include_2ruby_2thread_8h.html).

## Shared state and lock audit

This is a source audit, not a proof that every route is thread-safe.

| State | Current protection | Work needed before more concurrency |
| --- | --- | --- |
| Active agent records, ownership, queues, lifecycle | Cross-process `managed_agents.json.lock`; atomic publication; `read_snapshot` avoids maintenance | Keep mutation transactions locked. Move external work out only with a durable claim and generation/run check on completion. Define one lock order with schedule, delegation, metrics, and notification stores. |
| Agent list cache | Shared mutex, file/recovery signature, age limit, copies for individual fetch | `readonly_agents` returns shared objects by convention. Audit callers for mutation and lazy memoization. Test stale fills racing with writes; consider generation checks at publication. |
| Activity snapshot, conversation blocks, Git metadata | Shared cache mutexes; metadata refresh in background | Check returned nested values, cache fill scope, stale completion, invalidation, and memory bounds. A mutex around a hash does not make its returned objects immutable. |
| Resource catalog | Main mutex, worker mutex, persistence mutex, revisions and worker state | Keep network work outside snapshot locks. Verify lock order, refresh coalescing, stale worker completion, and shutdown. |
| Archive cache | Class-level mutex and root-keyed snapshots | Verify invalidation across processes and immutable returned records. A process-local mutex cannot coordinate several servers. |
| Schedules | Per-path mutex plus file lock | Keep schedule/agent lock order consistent across CLI, daemon, and HTTP. |
| Delegation, usage metrics, push notification records | File locks in their stores | Preserve deduplication and ownership transactions. Test two processes, not only two threads. |
| Remote credentials | Process-wide mutex | Atomic writes alone do not prevent cross-process lost updates. Audit other credential writers before a process model. |
| Worker table and output | Server mutexes | Avoid handler work under worker-table or output locks. |
| Registry/config, service caches, subscription files, settings writes | Mixed per-request objects, memoized values, file publication | Audit each writer and cache lifetime. `RemoteService` is constructed per request; its PR fetch and archived-query mutexes do not automatically serialize separate service instances. |
| File transactions | `FileTransaction` snapshots and rollback; `FileStore` atomic rename | These are not general transaction locks. Concurrent rollback can restore old state over a newer write unless the caller holds the proper store lock. |
| Request timing | Thread-local object, cleared after request | Add admission and full response measurements; current totals do not cover backlog waits. |

Atomic rename gives a reader one complete file generation. It does not make a read-modify-write sequence safe, or publish several files as one transaction. Cross-process safety also requires all writers to use the same lock path and compatible locking rules. Do not unlink or replace lock files during normal operation.

## Options

| Option | Benefit | Required safety work and risk |
| --- | --- | --- |
| Keep bounded request threads | Already overlaps I/O; smallest change | Add handler/write budgets, body limits, admission metrics, and overload behavior. Increasing 32 without data can increase memory, file descriptors, and lock waiters. |
| Fixed worker pool | Bounds thread creation and makes queue policy explicit | Use a bounded queue with a deadline and rejection policy. A pool still stalls when all workers wait on one lock. Reserve or isolate cheap reads only with a clear starvation policy. |
| Move blocking work to background jobs | Releases HTTP workers; allows status reads from snapshots | Use durable job IDs, idempotency receipts, bounded queues, ownership/run stamps, retries, cancellation rules, and recovery after restart. Claim under lock, work outside it, validate and commit under lock. Never blindly repeat a process launch or callback. |
| Replace transport with a threaded HTTP server | Can supply maintained HTTP parsing, limits, and lifecycle controls | Needs a request adapter, streaming/auth tests, request-local service objects, and the same state audit. It cannot remove AgentStore contention. Measure migration cost before selecting a library. |
| Several server processes | Can use several CPU cores and isolate CPU-heavy work | File locks still serialize writers. Need one owner for lifecycle/queue/push scheduling, shared cache invalidation, process-safe credentials/settings writes, durable job ownership, and coordinated restart/control state. Several copies of the current daemon risk duplicate work and stale state. |

## Recommended stages

1. **Keep the transport for now.** Add measurements for accepted sockets, active slots, admission wait, route duration, file-lock wait and hold time, response bytes, and write time. Use route labels without tokens, prompts, or file bodies. Compare client latency with `Server-Timing`; measure p50/p95/p99 under mixed loads.
2. **Complete the state audit and tests.** Establish a lock-order table from actual call graphs. Test concurrent mutations of the same and different agents, schedule dispatch, exact receipt replay, callback deduplication, stale cache publication, archive/delete, failed rollback, and restart. Use separate file descriptors and separate processes for file-lock tests. Test slow readers and all-worker saturation too.
3. **Reduce lock scope through durable claims.** Use read snapshots for display-only routes where stale data is acceptable. Keep lifecycle writes serialized. Coordinate with #803. Move measured external work outside the store lock using prepare/work/commit with generation checks. Retest lost responses and process crashes between each phase.
4. **Protect capacity.** Add bounded work queues for costly jobs and response write deadlines. Consider a fixed request pool or reserved read capacity only after the mixed-load data shows a need. Proposed acceptance target: a one-second lifecycle hold must not make cached/page reads wait one second below the cap; overload must have bounded delay and memory.
5. **Consider processes only for measured CPU pressure.** First separate lifecycle ownership from read-serving processes. Add process-safe state and invalidation tests. Compare CPU, memory, throughput, and tail latency before deployment.

Do not change the worker limit or deploy a multi-process server from this report alone. The measured next step is lock and admission instrumentation, followed by narrower lifecycle work and bounded background work.

## Repeat the fixture

The complete measurement helper is in the Python code block below. It uses the Python standard library and the repository's Ruby bundle. Save it to `/tmp/serve798.py` and run `python3 /tmp/serve798.py` from the repository root. It prints the temporary evidence directory. That directory contains server output and `logs/hq.log`. The temporary files are retained for inspection. It starts no agents and has no projects or push subscriptions. It uses timed Event waits only to set the lock-hold duration, with no repeated sleep commands.

```python
import os, tempfile, subprocess, socket, time, http.client, concurrent.futures, fcntl, json, pathlib
root=tempfile.mkdtemp(prefix='tycho-798-'); p=pathlib.Path(root)
(p/'config').mkdir(); (p/'logs').mkdir()
(p/'config/hq.yml').write_text('projects: []\ngroups: {}\ncustom_harnesses: []\n')
(p/'config/system_prompts.yml').write_text('{}\n'); (p/'logs/managed_agents.json').write_text('[]')
env={k:v for k,v in os.environ.items() if not k.startswith(('TYCHO_','HQ_'))}
env.update(TYCHO_HOME=root,TYCHO_LOGS_ROOT=str(p/'logs'),TYCHO_CONFIG_PATH=str(p/'config/hq.yml'),TYCHO_SYSTEM_PROMPTS_PATH=str(p/'config/system_prompts.yml'),TYCHO_REMOTE_TOKEN='fixture-only')
s=socket.socket(); s.bind(('127.0.0.1',0)); port=s.getsockname()[1]; s.close()
log=open(p/'server.log','w'); proc=subprocess.Popen(['bundle','exec','bin/tycho','serve','--host','127.0.0.1','--port',str(port)],env=env,stdout=log,stderr=log)
def get(path):
 t=time.monotonic(); c=http.client.HTTPConnection('127.0.0.1',port,timeout=20); c.request('GET',path,headers={'Authorization':'Bearer fixture-only'}); r=c.getresponse(); r.read(); c.close(); return {'path':path,'status':r.status,'ms':round((time.monotonic()-t)*1000,2),'timing':r.getheader('Server-Timing')}
try:
 # Blocking socket retries use a deadline; no sleep loop.
 deadline=time.monotonic()+30
 while True:
  try: baseline=get('/ui'); break
  except OSError:
   if proc.poll() is not None or time.monotonic()>deadline: raise
 print('fixture',root,'pid',proc.pid,'baseline',json.dumps(baseline),flush=True)
 with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
  for i in range(3):
   with open(p/'logs/managed_agents.json.lock','a') as lock:
    fcntl.flock(lock,fcntl.LOCK_EX)
    pending=[pool.submit(get,'/agents') for _ in range(2)]
    # One deliberate timed hold, not a readiness or repeated sleep loop.
    start=time.monotonic(); cheap=[pool.submit(get,x) for x in ['/ui','/activity','/servers/resources']]
    results=[x.result() for x in cheap]
    threading_event=__import__('threading').Event(); threading_event.wait(max(0,1.0-(time.monotonic()-start)))
    fcntl.flock(lock,fcntl.LOCK_UN)
   print('lock',i,json.dumps(results+[x.result() for x in pending]),flush=True)
  stalled=[socket.create_connection(('127.0.0.1',port)) for _ in range(32)]
  for c in stalled: c.sendall(b'GET /ui HTTP/1.1\r\nHost: localhost\r\n')
  print('cap',json.dumps(get('/ui')),flush=True)
  for c in stalled: c.close()
finally:
 proc.terminate()
 try: proc.wait(timeout=20)
 except subprocess.TimeoutExpired: proc.kill(); proc.wait()
 log.close()

```
