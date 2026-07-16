#!/usr/bin/env python3
"""Demo 1 Bootstrap: Set up Boundary resources for 3 FRR routers.

Creates: org, project, host catalog, 3 hosts, 3 per-router host sets,
credential store, username/password credential, 3 TCP targets with brokered credentials.

Usage: python3 bootstrap-boundary.py
Requires: BOUNDARY_ADDR and BOUNDARY_TOKEN env vars, or boundary CLI on PATH.
"""
import subprocess, os, json, sys, time

BOUNDARY_ADDR = os.environ.get('BOUNDARY_ADDR', 'http://127.0.0.1:9200')
BOUNDARY_TOKEN = os.environ.get('BOUNDARY_TOKEN', '')
KEYRING = 'none'

def authenticate():
    """Get a token by authenticating as the dev admin user."""
    env = os.environ.copy()
    env['ADMIN_PW'] = 'adminadmin'
    env['BOUNDARY_ADDR'] = BOUNDARY_ADDR
    env['BOUNDARY_KEYRING_TYPE'] = KEYRING
    r = subprocess.run(
        ['boundary', 'authenticate', 'password',
         '-auth-method-id', 'ampw_1234567890',
         '-login-name', 'admin',
         '-password', 'env://ADMIN_PW',
         '-keyring-type', 'none'],
        capture_output=True, text=True, env=env
    )
    import re
    m = re.search(r'at_[A-Za-z0-9_]+', r.stdout + r.stderr)
    if m:
        return m.group(0)
    return None

def bcmd(args, format_json=True):
    """Run a boundary CLI command with the token."""
    env = os.environ.copy()
    env['BOUNDARY_ADDR'] = BOUNDARY_ADDR
    env['BOUNDARY_KEYRING_TYPE'] = KEYRING
    env['BOUNDARY_TOKEN'] = BOUNDARY_TOKEN
    cmd = ['boundary'] + args
    if format_json:
        cmd += ['-token', 'env://BOUNDARY_TOKEN', '-format', 'json']
    else:
        cmd += ['-token', 'env://BOUNDARY_TOKEN']
    r = subprocess.run(cmd, capture_output=True, text=True, env=env)
    if r.returncode != 0:
        return None, r.stderr
    if format_json:
        try:
            return json.loads(r.stdout), None
        except:
            return r.stdout, None
    return r.stdout, None

def get_or_create(create_args, list_args, name, id_field='id'):
    """Try to create a resource; if it exists, find it by name in the list."""
    r, err = bcmd(create_args)
    if r and isinstance(r, dict) and 'item' in r:
        return r['item']['id']
    # Find existing
    r2, _ = bcmd(list_args)
    if r2 and isinstance(r2, dict):
        for item in r2.get('items', []):
            if item.get('name') == name:
                return item['id']
    return None

def wait_for_boundary():
    """Wait for the Boundary controller to be ready."""
    for i in range(30):
        try:
            r = subprocess.run(['curl', '-s', '-o', '/dev/null', '-w', '%{http_code}',
                              f'{BOUNDARY_ADDR}/v1/scopes/global'],
                             capture_output=True, text=True, timeout=5)
            if r.stdout.strip() in ['200', '401']:
                return True
        except:
            pass
        time.sleep(2)
    return False

def main():
    global BOUNDARY_TOKEN

    print("=== Demo 1: BGP Router Ring Bootstrap ===")
    print(f"Boundary: {BOUNDARY_ADDR}")

    # Wait for Boundary
    print("Waiting for Boundary controller...", end=' ', flush=True)
    if not wait_for_boundary():
        print("FAILED")
        sys.exit(1)
    print("OK")

    # Authenticate if needed
    if not BOUNDARY_TOKEN:
        print("Authenticating...", end=' ', flush=True)
        BOUNDARY_TOKEN = authenticate()
        if BOUNDARY_TOKEN:
            print(f"OK (token: {BOUNDARY_TOKEN[:15]}...)")
        else:
            print("FAILED")
            sys.exit(1)
    else:
        print(f"Using existing token: {BOUNDARY_TOKEN[:15]}...")

    # Create org
    print("\n=== Creating org and project ===")
    ORG_ID = get_or_create(
        ['scopes', 'create', '-name', 'network-org', '-description', 'Network automation org', '-scope-id', 'global'],
        ['scopes', 'list', '-scope-id', 'global'],
        'network-org')
    print(f"Org: {ORG_ID}")

    PROJ_ID = get_or_create(
        ['scopes', 'create', '-name', 'network-project', '-description', 'Network automation project', '-scope-id', ORG_ID],
        ['scopes', 'list', '-scope-id', ORG_ID],
        'network-project')
    print(f"Project: {PROJ_ID}")

    # Create host catalog
    print("\n=== Creating host catalog ===")
    HC_ID = get_or_create(
        ['host-catalogs', 'create', 'static', '-name', 'routers', '-description', 'FRR router catalog', '-scope-id', PROJ_ID],
        ['host-catalogs', 'list', '-scope-id', PROJ_ID],
        'routers')
    print(f"Host Catalog: {HC_ID}")

    # Create 3 hosts and 3 per-router host sets
    print("\n=== Creating hosts and host sets ===")
    host_ids = {}
    hs_ids = {}
    for i in range(1, 4):
        name = f"router-{i}"
        addr = f"10.100.{i}.1"

        host_id = get_or_create(
            ['hosts', 'create', 'static', '-name', name, '-address', addr, '-host-catalog-id', HC_ID],
            ['hosts', 'list', '-host-catalog-id', HC_ID],
            name)
        host_ids[name] = host_id
        print(f"  Host {name} ({addr}): {host_id}")

        hs_name = f"router-{i}-set"
        hs_id = get_or_create(
            ['host-sets', 'create', 'static', '-name', hs_name, '-host-catalog-id', HC_ID],
            ['host-sets', 'list', '-host-catalog-id', HC_ID],
            hs_name)
        hs_ids[hs_name] = hs_id
        print(f"  Host Set {hs_name}: {hs_id}")

        # Add host to its set
        if host_id and hs_id:
            r = subprocess.run(['boundary', 'host-sets', 'add-hosts', '-id', hs_id,
                               '-host', host_id, '-token', 'env://BOUNDARY_TOKEN'],
                              capture_output=True, text=True,
                              env={**os.environ, 'BOUNDARY_ADDR': BOUNDARY_ADDR,
                                   'BOUNDARY_TOKEN': BOUNDARY_TOKEN, 'BOUNDARY_KEYRING_TYPE': KEYRING})
            print(f"    Added {name} to {hs_name}: {'OK' if r.returncode == 0 else 'already added'}")

    # Create credential store
    print("\n=== Creating credential store ===")
    CS_ID = get_or_create(
        ['credential-stores', 'create', 'static', '-name', 'router-creds', '-scope-id', PROJ_ID],
        ['credential-stores', 'list', '-scope-id', PROJ_ID],
        'router-creds')
    print(f"Credential Store: {CS_ID}")

    # Create username/password credential
    print("\n=== Creating credentials ===")
    env_pw = os.environ.copy()
    env_pw['BOUNDARY_ADDR'] = BOUNDARY_ADDR
    env_pw['BOUNDARY_KEYRING_TYPE'] = KEYRING
    env_pw['BOUNDARY_TOKEN'] = BOUNDARY_TOKEN
    env_pw['ROUTER_PW'] = 'fr12pass!'

    r = subprocess.run(['boundary', 'credentials', 'create', 'username-password',
        '-name', 'router-cli-cred', '-credential-store-id', CS_ID,
        '-username', 'frruser', '-password', 'env://ROUTER_PW',
        '-token', 'env://BOUNDARY_TOKEN', '-format', 'json'],
        capture_output=True, text=True, env=env_pw)

    CRED_ID = None
    if r.returncode == 0:
        CRED_ID = json.loads(r.stdout)['item']['id']
    else:
        r2, _ = bcmd(['credentials', 'list', '-credential-store-id', CS_ID])
        if r2:
            for c in r2.get('items', []):
                if c.get('name') == 'router-cli-cred':
                    CRED_ID = c['id']
    print(f"Credential: {CRED_ID}")

    # Create 3 TCP targets
    print("\n=== Creating TCP targets ===")
    for i in range(1, 4):
        target_name = f"router-{i}-cli"
        hs_name = f"router-{i}-set"
        hs_id = hs_ids.get(hs_name)

        # Create target without host sources (added separately)
        r = subprocess.run(['boundary', 'targets', 'create', 'tcp',
            '-name', target_name, '-scope-id', PROJ_ID,
            '-default-port', '2024',
            '-token', 'env://BOUNDARY_TOKEN', '-format', 'json'],
            capture_output=True, text=True, env=env_pw)

        target_id = None
        if r.returncode == 0:
            target_id = json.loads(r.stdout)['item']['id']
        else:
            r2, _ = bcmd(['targets', 'list', '-scope-id', PROJ_ID])
            if r2:
                for t in r2.get('items', []):
                    if t.get('name') == target_name:
                        target_id = t['id']

        print(f"  {target_name}: {target_id}")

        # Add host source
        if hs_id and target_id:
            subprocess.run(['boundary', 'targets', 'add-host-sources',
                '-id', target_id, '-host-source', hs_id,
                '-token', 'env://BOUNDARY_TOKEN'],
                capture_output=True, text=True, env=env_pw)

        # Add brokered credential source
        if CRED_ID and target_id:
            subprocess.run(['boundary', 'targets', 'add-credential-sources',
                '-id', target_id, '-brokered-credential-source', CRED_ID,
                '-token', 'env://BOUNDARY_TOKEN'],
                capture_output=True, text=True, env=env_pw)
            print(f"    host source + brokered credential added")

    # Summary
    print("\n=== Bootstrap complete ===")
    print(f"Org: {ORG_ID}  Project: {PROJ_ID}")
    print(f"Host Catalog: {HC_ID}")
    print(f"Credential Store: {CS_ID}  Credential: {CRED_ID}")
    print(f"3 TCP targets on port 2024 with brokered credentials")
    print(f"3 per-router host sets (router-1-set, router-2-set, router-3-set)")
    print(f"\nToken for .mcp.json: {BOUNDARY_TOKEN}")

if __name__ == '__main__':
    main()