# Serve wait measurement fixture

Work for [Card 806](https://fizzy.startkit.tech/1/cards/806), based on the attached report on [Card 798](https://fizzy.startkit.tech/1/cards/798). Baseline: e9271e2 (Card 809 on-demand Git metadata).

Environment: macOS arm64, Ruby 4.0.9, localhost, empty project and agent stores, one separate server process, temporary Tycho home and synthetic bearer token. Only the child PID was stopped. No real Tycho state or daemon was used.

Each mixed phase sends 200 requests with eight client threads: 50 each to four routes. Percentiles use nearest rank. These synthetic empty-store results do not predict production latency. The endpoint shares the normal worker slots and can itself wait during saturation.

## Client elapsed time

Values are p50 / p95 / p99 in milliseconds. Each request includes connect, headers and full response read. All 400 mixed-phase responses returned HTTP 200.

| Route | 32 incomplete-header sockets | 1 s external store lock, mixed load |
| --- | ---: | ---: |
| `/ui` | 1.920 / 35.790 / 10024.870 | 2.240 / 6.400 / 14.250 |
| `/agents` | 8.480 / 52.930 / 10057.850 | 16.460 / 1010.460 / 1011.380 |
| `/activity` | 1.480 / 26.180 / 10024.620 | 1.840 / 4.920 / 15.430 |
| `/servers/resources` | 1.620 / 15.790 / 10025.190 | 1.600 / 6.860 / 14.070 |

The saturation phase opens 32 sockets with incomplete headers. Their existing 10 s read deadlines free the slots. The listener has one accepted socket waiting for admission; other connections wait in the kernel backlog. The subsequent lock phase holds the lock for one second from a separate Python process. No worker or lock behavior changed.

## Server samples

Values are p50 / p95 / p99. Each phase has 200 completed routed samples. The 32 timed-out incomplete requests are excluded from this table but remain in the diagnostic window.

| Metric | Saturation phase | Lock phase |
| --- | ---: | ---: |
| `admission_ms` | 0.407 / 3.893 / 7.883 | 0.472 / 1.528 / 11.840 |
| `store_lock_wait_ms` | 0.000 / 3.306 / 5.052 | 0.000 / 10.508 / 980.403 |
| `store_lock_hold_ms` | 0.000 / 1.685 / 4.632 | 0.000 / 3.025 / 4.630 |
| `route_ms` | 0.355 / 11.768 / 27.299 | 0.365 / 24.012 / 1006.325 |
| `write_ms` | 0.257 / 2.043 / 9.785 | 0.032 / 1.808 / 2.777 |
| `response_bytes` | 138.000 / 14481.000 / 14481.000 | 138.000 / 14481.000 / 14481.000 |

The final snapshot had 449 accepted sockets and 448 completed samples. Its own request was not yet complete. The body-size metric excludes headers and reports attempted bytes. Write times measure the write calls, not confirmed client receipt.

Admission measures only accept-to-worker time. Kernel backlog time cannot be assigned to each request by this server. Client elapsed time remains necessary. This explains a high client tail even when many admission samples are small.

Before the mixed phases, three trials each held an external lock for one second and sent two agent reads plus three independent reads, as in the Card 798 fixture. The agent reads waited for the lock. The independent reads completed during the hold.

## Repeat

Save the following helper outside the repository and run `python3 /absolute/path/serve806.py` from the repository root. It prints its temporary evidence directory. It retains server output and a redacted diagnostic JSON snapshot. The token is synthetic. No agent is launched.

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
  cap=[pool.submit(get, x) for x in ['/ui','/agents','/activity','/servers/resources']*50]
  print('cap',json.dumps([x.result() for x in cap]),flush=True)
  lock=open(p/'logs/managed_agents.json.lock','a'); fcntl.flock(lock,fcntl.LOCK_EX)
  release=__import__('threading').Thread(target=lambda: (__import__('threading').Event().wait(1), fcntl.flock(lock,fcntl.LOCK_UN))); release.start()
  mixed=[pool.submit(get, x) for x in ['/ui','/agents','/activity','/servers/resources']*50]
  results=[x.result() for x in mixed]; release.join(); lock.close()
  print('mixed',json.dumps(results),flush=True)
  c=http.client.HTTPConnection('127.0.0.1',port,timeout=20); c.request('GET','/diagnostics/serve',headers={'Authorization':'Bearer fixture-only'}); r=c.getresponse(); (p/'diagnostics.json').write_bytes(r.read()); c.close()
  for c in stalled: c.close()
finally:
 proc.terminate()
 try: proc.wait(timeout=20)
 except subprocess.TimeoutExpired: proc.kill(); proc.wait()
 log.close()
```
