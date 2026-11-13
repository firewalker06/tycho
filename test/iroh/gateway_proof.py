#!/usr/bin/env python3
"""Real loopback Iroh + HTTPS + Tycho acceptance test. No relay or provider calls."""
import argparse, contextlib, hashlib, http.client, json, os, pathlib, shutil, signal, socket, ssl, subprocess, tempfile, time

ROOT = pathlib.Path(__file__).resolve().parents[2]
TOKEN = 'card850-fixture-bearer-only'


def port(kind=socket.SOCK_STREAM):
    with socket.socket(socket.AF_INET, kind) as sock:
        sock.bind(('127.0.0.1', 0))
        return sock.getsockname()[1]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--binary', required=True)
    parser.add_argument('--output', required=True)
    args = parser.parse_args()
    binary = str(pathlib.Path(args.binary).resolve())
    output = pathlib.Path(args.output).resolve()
    output.mkdir(parents=True, exist_ok=True)
    checks = {}
    processes = []
    handles = []
    with tempfile.TemporaryDirectory(prefix='tycho-iroh-proof-') as scratch:
        tmp = pathlib.Path(scratch)
        home = tmp/'home'
        home.mkdir()
        env = {k: v for k, v in os.environ.items() if k in ('PATH', 'LANG', 'LC_ALL', 'TMPDIR')}
        env.update(HOME=str(home), TYCHO_HOME=str(tmp/'tycho'), TYCHO_LOGS_ROOT=str(tmp/'logs'),
                   TYCHO_SKILLS_HOME=str(home), TYCHO_CONFIG_PATH=str(tmp/'hq.yml'),
                   TYCHO_SYSTEM_PROMPTS_PATH=str(tmp/'prompts.yml'))
        (tmp/'hq.yml').write_text('---\nprojects: []\n')
        (tmp/'prompts.yml').write_text('---\ncustom: Synthetic only\n')
        fake = tmp/'fake-tool'
        fake.write_text('#!/bin/sh\nexit 1\n')
        fake.chmod(0o700)
        for name in ('CODEX', 'CLAUDE', 'OPENCODE', 'PI', 'AGY', 'GH'):
            env['TYCHO_'+name+'_BIN'] = str(fake)

        def private(name, value):
            target = tmp/name
            target.write_text(value if isinstance(value, str) else json.dumps(value))
            target.chmod(0o600)
            return str(target)

        def start(command, name, ready=None):
            log = open(tmp/(name+'.log'), 'w')
            handles.append(log)
            process = subprocess.Popen(command, cwd=ROOT, env=env, stdout=log, stderr=log)
            processes.append(process)
            if ready:
                for _ in range(200):
                    if process.poll() is not None:
                        raise RuntimeError(name+' stopped before readiness (no secret diagnostics retained)')
                    if ready in (tmp/(name+'.log')).read_text():
                        break
                    time.sleep(.05)
                else:
                    raise RuntimeError(name+' readiness timeout')
            return process

        def stop(process):
            if process.poll() is None:
                process.send_signal(signal.SIGINT)
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()

        upstream = port()
        udp_host = port(socket.SOCK_DGRAM)
        udp_gateway = port(socket.SOCK_DGRAM)
        https_port = port()
        origin = 'https://127.0.0.1:'+str(https_port)
        ruby = '''require_relative "test/support/push_safety"; require_relative "lib/hq/remote_server"; require_relative "lib/hq/registry"; r = HQ::Registry.new(path: ENV.fetch("TYCHO_CONFIG_PATH"), system_prompts_path: ENV.fetch("TYCHO_SYSTEM_PROMPTS_PATH")); HQ::RemoteServer.new(host: "127.0.0.1", port: Integer(ARGV[0]), registry: r, token: "card850-fixture-bearer-only").start'''
        try:
            server = start([shutil.which('ruby'), '-e', ruby, str(upstream)], 'tycho')
            for _ in range(100):
                try:
                    c = http.client.HTTPConnection('127.0.0.1', upstream, timeout=.2)
                    c.request('GET', '/agents'); r = c.getresponse(); r.read(); c.close()
                    break
                except OSError:
                    time.sleep(.05)
            else:
                raise RuntimeError('Tycho readiness timeout')
            identities = {}
            for name in ('host', 'gateway', 'rogue'):
                identities[name] = subprocess.check_output([binary, 'init-key', str(tmp/(name+'.key'))], env=env, text=True).strip()
            private('token', TOKEN)
            subprocess.run(['openssl', 'req', '-x509', '-newkey', 'ec', '-pkeyopt', 'ec_paramgen_curve:P-256',
                            '-nodes', '-days', '1', '-subj', '/CN=localhost',
                            '-addext', 'subjectAltName=DNS:localhost,IP:127.0.0.1',
                            '-keyout', str(tmp/'tls.key'), '-out', str(tmp/'tls.pem')],
                           check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, env=env)
            (tmp/'tls.key').chmod(0o600)
            (tmp/'tls.pem').chmod(0o600)
            context = ssl.create_default_context(cafile=str(tmp/'tls.pem'))
            common = {'enabled': True, 'token_file': str(tmp/'token')}
            host_config = dict(common, key_file=str(tmp/'host.key'), udp_bind='127.0.0.1:'+str(udp_host),
                               peer_id=identities['gateway'], target='127.0.0.1:'+str(upstream))
            gateway_config = dict(common, key_file=str(tmp/'gateway.key'), udp_bind='127.0.0.1:'+str(udp_gateway),
                                  peer_id=identities['host'], peer_addr='127.0.0.1:'+str(udp_host),
                                  https_bind='127.0.0.1:'+str(https_port), public_origin=origin,
                                  tls_cert_file=str(tmp/'tls.pem'), tls_key_file=str(tmp/'tls.key'))
            host = start([binary, 'host', private('host.json', host_config)], 'host', 'ready host')
            gateway = start([binary, 'gateway', private('gateway.json', gateway_config)], 'gateway', 'ready gateway')

            def request(path, bearer=None, method='GET', headers=None, data=None, target_port=https_port):
                h = dict(headers or {})
                if bearer is not None:
                    h['Authorization'] = 'Bearer '+bearer
                c = http.client.HTTPSConnection('127.0.0.1', target_port, timeout=10, context=context)
                try:
                    c.request(method, path, data, h)
                    r = c.getresponse()
                    return r.status, r.read(), dict(r.getheaders())
                finally:
                    c.close()

            checks['missing_bearer_401'] = request('/agents')[0] == 401
            checks['wrong_bearer_401'] = request('/agents', 'wrong')[0] == 401
            result = request('/agents', TOKEN)
            checks['real_iroh_authorized_200'] = result[0] == 200 and json.loads(result[1])['agents'] == []
            checks['public_ui_loads_without_token'] = request('/ui')[0] == 200
            checks['unauthorized_mutation_401'] = request('/agents', method='POST', data='{}')[0] == 401
            checks['oversize_request_413'] = request('/agents', TOKEN, method='POST', headers={'Content-Length':str(16*1024*1024+1)})[0] == 413
            checks['cross_origin_403'] = request('/agents', TOKEN, headers={'Origin':'https://untrusted.invalid'})[0] == 403
            checks['wrong_host_403'] = request('/agents', TOKEN, headers={'Host':'untrusted.invalid'})[0] == 403
            checks['connect_method_rejected'] = request('/agents', TOKEN, method='CONNECT')[0] in (400, 403)
            image = request('/pwa-icon-192.png')
            c = http.client.HTTPConnection('127.0.0.1', upstream, timeout=5)
            c.request('GET', '/pwa-icon-192.png'); direct = c.getresponse(); direct_bytes = direct.read(); c.close()
            checks['binary_bytes_preserved'] = image[0] == 200 and image[1] == direct_bytes and len(direct_bytes) > 0
            checks['responses_not_cached'] = result[2].get('cache-control') == 'no-store'
            # Body has Unicode, NUL, and CR/LF bytes. The API rejects the synthetic unknown project,
            # but must return the same status/payload as a direct request.
            body = json.dumps({'project_key':'card850-missing', 'prompt':'synthetic \u0000 日本語\r\n'}).encode()
            forwarded = request('/agents', TOKEN, method='POST', headers={'Content-Type':'application/json'}, data=body)
            c = http.client.HTTPConnection('127.0.0.1', upstream, timeout=5)
            c.request('POST', '/agents', body, {'Authorization':'Bearer '+TOKEN, 'Content-Type':'application/json'})
            direct = c.getresponse(); direct_status = direct.status; direct_body = direct.read(); c.close()
            checks['json_body_and_error_preserved'] = forwarded[:2] == (direct_status, direct_body) and direct_status >= 400
            # A peer with a valid but unenrolled identity must not reach the host API.
            rogue_port = port()
            rogue_config = dict(gateway_config, key_file=str(tmp/'rogue.key'), udp_bind='127.0.0.1:0',
                                https_bind='127.0.0.1:'+str(rogue_port), public_origin='https://127.0.0.1:'+str(rogue_port))
            rogue = start([binary, 'gateway', private('rogue.json', rogue_config)], 'rogue', 'ready gateway')
            checks['unenrolled_peer_502'] = request('/agents', TOKEN, target_port=rogue_port)[0] == 502
            stop(rogue)
            # Host bearer validation must remain effective when gateway credentials differ.
            private('other-token', 'card850-other-fixture-token')
            alternate_port = port()
            alternate = dict(gateway_config, token_file=str(tmp/'other-token'), udp_bind='127.0.0.1:0',
                             https_bind='127.0.0.1:'+str(alternate_port), public_origin='https://127.0.0.1:'+str(alternate_port))
            stop(gateway)
            alternate_process = start([binary, 'gateway', private('alternate.json', alternate)], 'alternate', 'ready gateway')
            checks['host_rejects_different_bearer_401'] = request('/agents', 'card850-other-fixture-token', target_port=alternate_port)[0] == 401
            stop(alternate_process)
            gateway = start([binary, 'gateway', str(tmp/'gateway.json')], 'gateway-restart', 'ready gateway')
            if os.environ.get('TYCHO_PLAYWRIGHT_PATH'):
                browser_data = {'origin': origin, 'token': TOKEN, 'output': str(output)}
                browser = subprocess.run(['node', str(ROOT/'test/browser/iroh_gateway_smoke.js')],
                                         input=json.dumps(browser_data), text=True, env={**env, 'TYCHO_PLAYWRIGHT_PATH':os.environ['TYCHO_PLAYWRIGHT_PATH']},
                                         capture_output=True, timeout=60)
                checks['browser_smoke'] = browser.returncode == 0
                (output/'browser.log').write_text(browser.stdout+browser.stderr)
            stop(server)
            checks['broken_upstream_502'] = request('/agents', TOKEN)[0] == 502
            stop(host)
            checks['broken_iroh_502'] = request('/agents', TOKEN)[0] == 502
            checks['broken_iroh_still_rejects_unauthorized'] = request('/agents')[0] == 401
            # Startup must fail without binding for disabled, permissive, or symlinked config.
            for name, changed in [('disabled', {'enabled':False}), ('public-bind', {'udp_bind':'0.0.0.0:0'})]:
                config = dict(host_config, **changed)
                run = subprocess.run([binary, 'host', private(name+'.json', config)], env=env, capture_output=True, timeout=5)
                checks[name+'_startup_rejected'] = run.returncode != 0
            permissive = tmp/'permissive.json'
            permissive.write_text(json.dumps(host_config)); permissive.chmod(0o644)
            run = subprocess.run([binary, 'host', str(permissive)], env=env, capture_output=True, timeout=5)
            checks['permissive_config_rejected'] = run.returncode != 0
            (tmp/'symlink.json').symlink_to(tmp/'host.json')
            run = subprocess.run([binary, 'host', str(tmp/'symlink.json')], env=env, capture_output=True, timeout=5)
            checks['symlink_config_rejected'] = run.returncode != 0
            for handle in handles: handle.flush()
            logs = '\n'.join(p.read_text() for p in tmp.glob('*.log'))
            checks['no_bearer_in_logs'] = TOKEN not in logs and 'card850-other-fixture-token' not in logs
            print(json.dumps(checks, indent=2))
            record = {'checks':checks, 'all_passed':all(checks.values()), 'transport':'Iroh 1.4.1 real QUIC/TLS over loopback UDP',
                      'https':'Verified with a fixture-only CA; no system trust changes',
                      'network':'Explicit loopback bindings; no relay, discovery, multicast, or portmapper',
                      'asset_sha256':hashlib.sha256(image[1]).hexdigest(),
                      'limits':['No public gateway deployment','No relay or NAT test','No physical phone or Safari test','No production TLS certificate test']}
            (output/'result.json').write_text(json.dumps(record,indent=2)+'\n')
            if not all(checks.values()): raise RuntimeError('proof assertion failed')
        finally:
            for process in reversed(processes): stop(process)
            for handle in handles: handle.close()
    print('All temporary keys, tokens, config, logs, and processes removed.')


if __name__ == '__main__': main()
