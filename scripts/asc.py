#!/usr/bin/env python3
"""App Store Connect helper for Soundpost: inspect state, attach a build to the
1.1.0 version, and (re)submit for review via the ASC API.

Usage (run with the venv that has pyjwt+requests):
  /tmp/asc-venv/bin/python3 scripts/asc.py status
  /tmp/asc-venv/bin/python3 scripts/asc.py create-version 1.4.0     # new version record
  /tmp/asc-venv/bin/python3 scripts/asc.py notes                    # metadata/*/release_notes.txt -> whatsNew
  /tmp/asc-venv/bin/python3 scripts/asc.py attach <build-version>   # e.g. 5
  /tmp/asc-venv/bin/python3 scripts/asc.py submit
  /tmp/asc-venv/bin/python3 scripts/asc.py resubmit <build-version> # attach + submit

Rebuilding the venv:
  python3 -m venv /tmp/asc-venv && /tmp/asc-venv/bin/python3 -m pip install "pyjwt[crypto]" requests
"""
import sys, time, json, os
import jwt, requests

KEY_ID  = os.environ.get('ASC_API_KEY_ID', 'DMMFP6XTXX')
ISSUER  = os.environ.get('ASC_API_ISSUER', 'c5671c11-49ec-47d9-bd38-5e3c1a249416')
KEY_PATH = os.environ.get('ASC_API_KEY_PATH',
    os.path.expanduser('~/Library/Mobile Documents/com~apple~CloudDocs/Downloads/AuthKey_DMMFP6XTXX.p8'))
APP_ID  = os.environ.get('ASC_APP_ID', '6778389097')
BASE    = 'https://api.appstoreconnect.apple.com'


def token():
    with open(KEY_PATH) as f:
        key = f.read()
    now = int(time.time())
    return jwt.encode(
        {'iss': ISSUER, 'iat': now, 'exp': now + 1200, 'aud': 'appstoreconnect-v1'},
        key, algorithm='ES256', headers={'kid': KEY_ID})


def H():
    return {'Authorization': f'Bearer {token()}', 'Content-Type': 'application/json'}


def req(method, path, payload=None, **params):
    url = BASE + path if path.startswith('/') else path
    r = requests.request(method, url, headers=H(),
                         data=json.dumps(payload) if payload is not None else None,
                         params=params or None, timeout=90)
    if r.status_code >= 400:
        print(f'  ! {method} {path} -> {r.status_code}\n  {r.text}', file=sys.stderr)
        r.raise_for_status()
    return r.json() if r.text else {}


def get(path, **p):    return req('GET', path, None, **p)
def patch(path, pl):   return req('PATCH', path, pl)
def post(path, pl):    return req('POST', path, pl)


def ios_versions():
    return get(f'/v1/apps/{APP_ID}/appStoreVersions',
               **{'filter[platform]': 'IOS', 'limit': 10,
                  'include': 'build'}).get('data', [])


def recent_builds(n=10):
    return get('/v1/builds',
               **{'filter[app]': APP_ID, 'sort': '-uploadedDate', 'limit': n}).get('data', [])


def review_submissions():
    return get(f'/v1/apps/{APP_ID}/reviewSubmissions',
               **{'filter[platform]': 'IOS', 'limit': 20}).get('data', [])


EDITABLE_STATES = ('PREPARE_FOR_SUBMISSION', 'REJECTED', 'DEVELOPER_REJECTED',
                   'METADATA_REJECTED', 'INVALID_BINARY', 'WAITING_FOR_REVIEW',
                   'IN_REVIEW')


def editable_version():
    """The version we (re)submit, or None when there isn't one.

    It must NEVER fall back to "whatever version is first". Once every version is
    live (READY_FOR_SALE) that fallback resolved to the *shipped* version, so
    `attach` and `submit` would have aimed at the public listing. Callers handle
    None by telling you to create a version first (`create-version`).
    """
    for v in ios_versions():
        if v['attributes']['appStoreState'] in EDITABLE_STATES:
            return v
    return None


def find_build(version_str):
    for b in recent_builds(20):
        if b['attributes']['version'] == str(version_str):
            return b
    return None


def cmd_status():
    print('=== iOS App Store versions ===')
    for v in ios_versions():
        a = v['attributes']
        bid = (v.get('relationships', {}).get('build', {}).get('data') or {}).get('id')
        print(f"  v{a['versionString']:8} state={a['appStoreState']:24} build_rel={bid}  id={v['id']}")
    print('=== Recent builds ===')
    for b in recent_builds(8):
        a = b['attributes']
        print(f"  build {a['version']:4} {a['processingState']:12} "
              f"enc={a.get('usesNonExemptEncryption')} expired={a.get('expired')}  id={b['id']}")
    print('=== Review submissions ===')
    for s in review_submissions():
        a = s['attributes']
        print(f"  state={a.get('state'):22} submitted={a.get('submittedDate')}  id={s['id']}")


PROJECT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# Apple is actively looking at these. `editable_version()` still returns them (you
# may legitimately want to cancel and re-attach), but silently mutating one from a
# script would disturb a live submission — so the mutating commands stop first.
IN_APPLES_HANDS = ('WAITING_FOR_REVIEW', 'IN_REVIEW')


def guard_not_in_review(version, action):
    state = version['attributes']['appStoreState']
    if state in IN_APPLES_HANDS:
        sys.exit(
            f"Refusing to {action} v{version['attributes']['versionString']}: it is {state}.\n"
            f"  That version is in Apple's review queue — changing it now would disturb the\n"
            f"  live submission. Wait for it to clear, or cancel it deliberately in ASC first."
        )


def cmd_create_version(version_string):
    """Create a new (PREPARE_FOR_SUBMISSION) App Store version record.

    Idempotent: if the version already exists it is returned untouched. Creating a
    version cannot affect an already-live one, and a PREPARE_FOR_SUBMISSION version
    can be deleted in ASC, so this is reversible.
    """
    for v in ios_versions():
        if v['attributes']['versionString'] == version_string:
            print(f"Version {version_string} already exists "
                  f"(state={v['attributes']['appStoreState']}, id={v['id']}) — leaving it alone.")
            return v
    v = post('/v1/appStoreVersions',
             {'data': {'type': 'appStoreVersions',
                       'attributes': {'platform': 'IOS', 'versionString': version_string},
                       'relationships': {'app': {'data': {'type': 'apps', 'id': APP_ID}}}}})['data']
    print(f"Created version {version_string} "
          f"(state={v['attributes']['appStoreState']}, id={v['id']})")
    return v


def cmd_notes():
    """Push metadata/<locale>/release_notes.txt into the editable version's whatsNew.

    Only ever writes to the editable version — never to a live one.
    """
    v = editable_version()
    if not v:
        sys.exit('No editable App Store version found — run `create-version <x.y.z>` first.')
    guard_not_in_review(v, 'rewrite the release notes of')
    print(f"Setting release notes on v{v['attributes']['versionString']} "
          f"({v['attributes']['appStoreState']})")

    existing = {loc['attributes']['locale']: loc
                for loc in get(f"/v1/appStoreVersions/{v['id']}/appStoreVersionLocalizations").get('data', [])}

    metadata_root = os.path.join(PROJECT_DIR, 'metadata')
    for locale in sorted(os.listdir(metadata_root)):
        path = os.path.join(metadata_root, locale, 'release_notes.txt')
        if not os.path.isfile(path):
            continue
        with open(path, encoding='utf-8') as f:
            text = f.read().strip()
        if locale in existing:
            patch(f"/v1/appStoreVersionLocalizations/{existing[locale]['id']}",
                  {'data': {'type': 'appStoreVersionLocalizations',
                            'id': existing[locale]['id'],
                            'attributes': {'whatsNew': text}}})
            print(f"  {locale}: set whatsNew ({len(text)} chars)")
        else:
            post('/v1/appStoreVersionLocalizations',
                 {'data': {'type': 'appStoreVersionLocalizations',
                           'attributes': {'locale': locale, 'whatsNew': text},
                           'relationships': {'appStoreVersion': {
                               'data': {'type': 'appStoreVersions', 'id': v['id']}}}}})
            print(f"  {locale}: created localization + whatsNew ({len(text)} chars)")
    return v


def cmd_attach(build_version):
    v = editable_version()
    if not v:
        sys.exit('No editable App Store version found — run `create-version <x.y.z>` first.')
    guard_not_in_review(v, 'attach a build to')
    b = find_build(build_version)
    if not b:
        sys.exit(f'Build {build_version} not found among recent builds (still processing?).')
    if b['attributes']['processingState'] != 'VALID':
        sys.exit(f"Build {build_version} processingState={b['attributes']['processingState']} (need VALID).")
    # Declare export-compliance on the build if ASC left it null.
    if b['attributes'].get('usesNonExemptEncryption') is None:
        patch(f"/v1/builds/{b['id']}",
              {'data': {'type': 'builds', 'id': b['id'],
                        'attributes': {'usesNonExemptEncryption': False}}})
        print('  set usesNonExemptEncryption=false on build')
    patch(f"/v1/appStoreVersions/{v['id']}/relationships/build",
          {'data': {'type': 'builds', 'id': b['id']}})
    print(f"Attached build {build_version} ({b['id']}) to version "
          f"{v['attributes']['versionString']} ({v['id']}).")
    return v, b


# States that occupy the single active-submission slot for the app.
BLOCKING = ('READY_FOR_REVIEW', 'WAITING_FOR_REVIEW', 'WAITING_FOR_EXPORT_COMPLIANCE',
            'UNRESOLVED_ISSUES', 'IN_REVIEW', 'CANCELING')
# States we may cancel to free the slot before creating a fresh submission.
CANCELABLE = ('READY_FOR_REVIEW', 'WAITING_FOR_REVIEW', 'WAITING_FOR_EXPORT_COMPLIANCE',
              'UNRESOLVED_ISSUES')


def cmd_cancel():
    """Cancel any submission holding the active slot; wait until it clears."""
    for s in review_submissions():
        st = s['attributes'].get('state')
        if st in ('WAITING_FOR_REVIEW', 'IN_REVIEW'):
            print(f"  ! submission {s['id']} is {st} (genuinely in Apple's queue) — "
                  f"cancel it in ASC if you really mean to.")
        elif st in CANCELABLE:
            patch(f"/v1/reviewSubmissions/{s['id']}",
                  {'data': {'type': 'reviewSubmissions', 'id': s['id'],
                            'attributes': {'canceled': True}}})
            print(f"  canceled submission {s['id']} (was {st})")
    for _ in range(36):
        blocking = [s for s in review_submissions()
                    if s['attributes'].get('state') in BLOCKING]
        if not blocking:
            print('  active submission slot is clear')
            return
        time.sleep(5)
    print('  ! timed out waiting for submission slot to clear; check `status`')


def cmd_submit():
    v = editable_version()
    if not v:
        sys.exit('No editable App Store version found.')
    for s in review_submissions():
        if s['attributes'].get('state') in ('WAITING_FOR_REVIEW', 'IN_REVIEW'):
            print(f"A submission is already {s['attributes']['state']} (id={s['id']}). Nothing to do.")
            return
    cmd_cancel()
    # Creating a new submission can briefly 409 (CONCURRENT_REVIEW_SUBMISSION_
    # TRY_AGAIN) while a just-canceled submission settles on Apple's backend.
    sub = None
    for attempt in range(10):
        try:
            sub = post('/v1/reviewSubmissions',
                       {'data': {'type': 'reviewSubmissions',
                                 'attributes': {'platform': 'IOS'},
                                 'relationships': {'app': {'data': {'type': 'apps', 'id': APP_ID}}}}})['data']
            break
        except requests.HTTPError as e:
            if e.response is not None and e.response.status_code == 409 and attempt < 9:
                print(f'  create 409 (settling), retry {attempt + 1}/9 in 15s…')
                time.sleep(15)
                continue
            raise
    print(f"Created reviewSubmission {sub['id']}")
    # Add the version as an item if not already present.
    items = get(f"/v1/reviewSubmissions/{sub['id']}/items").get('data', [])
    have = any((it.get('relationships', {}).get('appStoreVersion', {}).get('data') or {}).get('id') == v['id']
               for it in items)
    if not have:
        post('/v1/reviewSubmissionItems',
             {'data': {'type': 'reviewSubmissionItems',
                       'relationships': {
                           'reviewSubmission': {'data': {'type': 'reviewSubmissions', 'id': sub['id']}},
                           'appStoreVersion': {'data': {'type': 'appStoreVersions', 'id': v['id']}}}}})
        print(f"Added version {v['attributes']['versionString']} to submission")
    patch(f"/v1/reviewSubmissions/{sub['id']}",
          {'data': {'type': 'reviewSubmissions', 'id': sub['id'],
                    'attributes': {'submitted': True}}})
    print(f"SUBMITTED for review (submission {sub['id']}).")


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else 'status'
    if cmd == 'status':
        cmd_status()
    elif cmd == 'create-version':
        cmd_create_version(sys.argv[2])
    elif cmd == 'notes':
        cmd_notes()
    elif cmd == 'attach':
        cmd_attach(sys.argv[2])
    elif cmd == 'submit':
        cmd_submit()
    elif cmd == 'resubmit':
        cmd_attach(sys.argv[2])
        cmd_submit()
    else:
        sys.exit(f'Unknown command: {cmd}')


if __name__ == '__main__':
    main()
