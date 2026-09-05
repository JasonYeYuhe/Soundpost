#!/usr/bin/env python3
"""App Store Connect helper for Soundpost: inspect state, attach a build to the
1.1.0 version, and (re)submit for review via the ASC API.

Usage (run with the venv that has pyjwt+requests):
  /tmp/asc-venv/bin/python3 scripts/asc.py status
  /tmp/asc-venv/bin/python3 scripts/asc.py create-version 1.4.0     # new version record
  /tmp/asc-venv/bin/python3 scripts/asc.py notes                    # metadata/*/release_notes.txt -> whatsNew
  /tmp/asc-venv/bin/python3 scripts/asc.py attach <build-version>   # e.g. 5
  /tmp/asc-venv/bin/python3 scripts/asc.py submit
  /tmp/asc-venv/bin/python3 scripts/asc.py release             # APPROVED -> live (manual release)
  /tmp/asc-venv/bin/python3 scripts/asc.py resubmit <build-version> # attach + submit

Rebuilding the venv:
  python3 -m venv /tmp/asc-venv && /tmp/asc-venv/bin/python3 -m pip install "pyjwt[crypto]" requests
"""
import sys, time, json, os, re, hashlib
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


def project_marketing_version():
    """MARKETING_VERSION from the Xcode project — the version the binary says it is."""
    pbxproj = os.path.join(PROJECT_DIR, 'Soundpost.xcodeproj', 'project.pbxproj')
    found = set()
    with open(pbxproj, encoding='utf-8') as f:
        for line in f:
            m = re.search(r'MARKETING_VERSION = ([0-9][^;]*);', line)
            if m:
                found.add(m.group(1).strip())
    if len(found) != 1:
        sys.exit(f'Could not read a single MARKETING_VERSION from the project (found: {sorted(found)}).')
    return found.pop()


def editable_version():
    """The version we (re)submit, or None when there isn't one.

    It must NEVER fall back to "whatever version is first". Once every version is
    live (READY_FOR_SALE) that fallback resolved to the *shipped* version, so
    `attach` and `submit` would have aimed at the public listing. Callers handle
    None by telling you to create a version first (`create-version`).

    It is also matched against the project's `MARKETING_VERSION` rather than taken
    as "the first editable one". `ios_versions()` is unordered and `EDITABLE_STATES`
    includes the rejection states, so with a rejected 1.5.0 sitting beside a
    1.6.0 draft the API could hand back 1.5.0 first — and `notes` would have
    rewritten the 1.5.0 listing with 1.6.0's copy while `attach` bound the new
    binary to the old version string. Nothing downstream would have noticed.
    """
    expected = project_marketing_version()
    editable = [v for v in ios_versions()
                if v['attributes']['appStoreState'] in EDITABLE_STATES]
    for v in editable:
        if v['attributes']['versionString'] == expected:
            return v
    if editable:
        others = ', '.join(f"{v['attributes']['versionString']} ({v['attributes']['appStoreState']})"
                           for v in editable)
        sys.exit(
            f"No editable v{expected} on App Store Connect, but these are editable: {others}.\n"
            f"  The project's MARKETING_VERSION is {expected}; refusing to act on a different\n"
            f"  version. Run `create-version {expected}`, or fix MARKETING_VERSION first."
        )
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


def cmd_release():
    """Release an APPROVED version to the public (`releaseType: MANUAL`).

    This is the one genuinely public, irreversible action in this script: it puts
    the build in front of users. So it only ever acts on a version Apple has
    already approved and is holding for you — it will not submit, attach, or
    otherwise nudge anything that is still in the queue.
    """
    pending = [v for v in ios_versions()
               if v['attributes']['appStoreState'] == 'PENDING_DEVELOPER_RELEASE']
    if not pending:
        states = ', '.join(f"v{v['attributes']['versionString']}={v['attributes']['appStoreState']}"
                           for v in ios_versions()) or '(no versions)'
        sys.exit('Nothing is approved and waiting for release.\n'
                 f'  Current: {states}\n'
                 '  A version is releasable only in PENDING_DEVELOPER_RELEASE.')
    v = pending[0]
    version = v['attributes']['versionString']
    post('/v1/appStoreVersionReleaseRequests',
         {'data': {'type': 'appStoreVersionReleaseRequests',
                   'relationships': {'appStoreVersion': {
                       'data': {'type': 'appStoreVersions', 'id': v['id']}}}}})
    print(f'RELEASED v{version} — it is going live on the App Store now.')
    return v


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


def push_localized_field(filename, attribute, what):
    """Push metadata/<locale>/<filename> into <attribute> on the editable version.

    Only ever writes to the editable version — never to a live one.
    """
    v = editable_version()
    if not v:
        sys.exit('No editable App Store version found — run `create-version <x.y.z>` first.')
    guard_not_in_review(v, f'rewrite the {what} of')
    print(f"Setting {what} on v{v['attributes']['versionString']} "
          f"({v['attributes']['appStoreState']})")

    existing = {loc['attributes']['locale']: loc
                for loc in get(f"/v1/appStoreVersions/{v['id']}/appStoreVersionLocalizations").get('data', [])}

    metadata_root = os.path.join(PROJECT_DIR, 'metadata')
    for locale in sorted(os.listdir(metadata_root)):
        path = os.path.join(metadata_root, locale, filename)
        if not os.path.isfile(path):
            continue
        with open(path, encoding='utf-8') as f:
            text = f.read().strip()
        if locale in existing:
            patch(f"/v1/appStoreVersionLocalizations/{existing[locale]['id']}",
                  {'data': {'type': 'appStoreVersionLocalizations',
                            'id': existing[locale]['id'],
                            'attributes': {attribute: text}}})
            print(f"  {locale}: set {attribute} ({len(text)} chars)")
        else:
            post('/v1/appStoreVersionLocalizations',
                 {'data': {'type': 'appStoreVersionLocalizations',
                           'attributes': {'locale': locale, attribute: text},
                           'relationships': {'appStoreVersion': {
                               'data': {'type': 'appStoreVersions', 'id': v['id']}}}}})
            print(f"  {locale}: created localization + {attribute} ({len(text)} chars)")
    return v


def cmd_notes():
    """Push metadata/<locale>/release_notes.txt into the editable version's whatsNew."""
    return push_localized_field('release_notes.txt', 'whatsNew', 'release notes')


def cmd_description():
    """Push metadata/<locale>/description.txt into the editable version's description.

    Added at M15: the store description had gone stale (it still claimed capsules
    were device-only long after iCloud backup shipped in 1.3.0) precisely because
    there was no push path for it — `notes` only ever touched whatsNew, so nothing
    in the release flow could notice the drift.
    """
    return push_localized_field('description.txt', 'description', 'description')


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


# ── Screenshots ──────────────────────────────────────────────────────────────
#
# M19 §4A. The store's five screenshots were captured by hand on 2026-06-10 and not
# touched through eight releases; `scripts/screenshots.sh` makes capturing them a
# command, and this makes uploading them one. Together they turn "an afternoon" into
# two lines of a release checklist, which is the only reason the 1.1.0 set went stale
# — there was no step that could fail.

# Screenshots are stricter than text metadata, and the difference matters.
#
# `EDITABLE_STATES` above includes WAITING_FOR_REVIEW and IN_REVIEW because *some*
# app information can be edited there. Images cannot: Apple's own status reference
# says images and previews stop being editable once a version reaches Ready for
# Review, and the API answers a POST /v1/appScreenshots with 409 STATE_ERROR
# ("Attribute cannot be edited at this time"). So this has its own, narrower list —
# reusing `EDITABLE_STATES` would have produced a 409 half way through a 15-file
# upload, with some locales replaced and some not.
SCREENSHOT_EDITABLE_STATES = ('PREPARE_FOR_SUBMISSION', 'REJECTED', 'DEVELOPER_REJECTED',
                              'METADATA_REJECTED', 'INVALID_BINARY')

# What `scripts/screenshots.sh` produces, and what App Store Connect currently holds:
# one set per locale, five images, 1242x2688. Read from ASC on 2026-09-05 rather than
# assumed — a wrong display type is a rejected submission, not a cosmetic problem.
SCREENSHOT_DISPLAY_TYPE = 'APP_IPHONE_65'


def upload_asset(operations, data):
    """PUT the parts of one reserved asset.

    Deliberately NOT through `req()`. Those URLs are unauthenticated, time-limited
    presigned blobstore URLs — Apple's docs are explicit that no JWT is needed — and
    `req()` would attach `Authorization` and force `Content-Type: application/json`
    onto a PNG. The only headers that belong on these calls are the ones the
    reservation handed back.
    """
    for op in operations:
        chunk = data[op['offset']:op['offset'] + op['length']]
        headers = {h['name']: h['value'] for h in op.get('requestHeaders', [])}
        r = requests.request(op['method'], op['url'], data=chunk, headers=headers, timeout=300)
        if r.status_code >= 400:
            sys.exit(f'  ! upload part failed {r.status_code}: {r.text[:200]}')


def await_asset(screenshot_id, name):
    """Block until Apple has processed the image, or say why it refused.

    **This poll is not optional.** Dimension and format validation happens here, not
    at the commit: a wrong-sized PNG returns 200 from the PATCH and only later turns
    up as FAILED with a reason. Skipping the poll would mean the script reports
    success and the listing quietly keeps the old images — the exact shape of failure
    this whole milestone is about.
    """
    for _ in range(150):                                     # ~5 minutes
        state = get(f'/v1/appScreenshots/{screenshot_id}',
                    **{'fields[appScreenshots]': 'assetDeliveryState'})
        delivery = state['data']['attributes'].get('assetDeliveryState') or {}
        if delivery.get('state') == 'COMPLETE':
            return
        if delivery.get('state') == 'FAILED':
            why = '; '.join(f"{e.get('code')}: {e.get('description')}"
                            for e in delivery.get('errors') or []) or 'no reason given'
            sys.exit(f'  ! {name} was rejected by App Store Connect — {why}')
        time.sleep(2)
    sys.exit(f'  ! {name} never finished processing')


def cmd_screenshots():
    """Replace every locale's screenshots with what `scripts/screenshots.sh` captured."""
    v = editable_version()
    if not v:
        sys.exit('No editable App Store version found — run `create-version <x.y.z>` first.')
    state = v['attributes']['appStoreState']
    version = v['attributes']['versionString']
    if state not in SCREENSHOT_EDITABLE_STATES:
        sys.exit(
            f'Refusing to replace the screenshots of v{version}: it is {state}.\n'
            f'  Images are only editable in {", ".join(SCREENSHOT_EDITABLE_STATES)} —\n'
            f'  App Store Connect answers 409 STATE_ERROR otherwise, and it would do so\n'
            f'  part way through, leaving some locales replaced and some not.'
        )

    root = os.path.join(PROJECT_DIR, 'build', 'screenshots')
    if not os.path.isdir(root):
        sys.exit(f'No screenshots at {root} — run `scripts/screenshots.sh` first.')

    print(f"Replacing screenshots on v{version} ({state})")
    localizations = {loc['attributes']['locale']: loc['id']
                     for loc in get(f"/v1/appStoreVersions/{v['id']}/appStoreVersionLocalizations")
                     .get('data', [])}

    for locale in sorted(os.listdir(root)):
        folder = os.path.join(root, locale)
        if not os.path.isdir(folder):
            continue
        files = sorted(f for f in os.listdir(folder) if f.endswith('.png'))
        if not files:
            continue
        if locale not in localizations:
            sys.exit(f'  ! {locale} has screenshots but no localization on v{version}')

        sets = get(f"/v1/appStoreVersionLocalizations/{localizations[locale]}/appScreenshotSets") \
            .get('data', [])
        match = [s for s in sets
                 if s['attributes']['screenshotDisplayType'] == SCREENSHOT_DISPLAY_TYPE]
        if match:
            set_id = match[0]['id']
        else:
            set_id = post('/v1/appScreenshotSets',
                          {'data': {'type': 'appScreenshotSets',
                                    'attributes': {'screenshotDisplayType': SCREENSHOT_DISPLAY_TYPE},
                                    'relationships': {'appStoreVersionLocalization': {
                                        'data': {'type': 'appStoreVersionLocalizations',
                                                 'id': localizations[locale]}}}}})['data']['id']

        # Delete before creating, not after. A set holds at most ten images; five old
        # plus five new is fine but five plus six is not, and the failure would land
        # mid-locale.
        for existing in get(f'/v1/appScreenshotSets/{set_id}/appScreenshots',
                            limit=200).get('data', []):
            req('DELETE', f"/v1/appScreenshots/{existing['id']}")

        uploaded = []
        for name in files:
            path = os.path.join(folder, name)
            with open(path, 'rb') as f:
                data = f.read()
            reserved = post('/v1/appScreenshots',
                            {'data': {'type': 'appScreenshots',
                                      'attributes': {'fileSize': len(data), 'fileName': name},
                                      'relationships': {'appScreenshotSet': {
                                          'data': {'type': 'appScreenshotSets',
                                                   'id': set_id}}}}})['data']
            upload_asset(reserved['attributes'].get('uploadOperations') or [], data)
            # MD5 of the whole file, lowercase hex — not per-part, not base64. The
            # commit is the only place `uploaded` and `sourceFileChecksum` are
            # writable, and after it the file can only be changed by deleting the
            # resource and reserving again.
            patch(f"/v1/appScreenshots/{reserved['id']}",
                  {'data': {'type': 'appScreenshots', 'id': reserved['id'],
                            'attributes': {'uploaded': True,
                                           'sourceFileChecksum': hashlib.md5(data).hexdigest()}}})
            await_asset(reserved['id'], f'{locale}/{name}')
            uploaded.append(reserved['id'])
            print(f'  {locale}: {name} ({len(data):,} bytes)')

        # Order is the set's relationship linkage, not an attribute on the image.
        # Creation order usually gives the right answer already; this is the only
        # thing that guarantees it, and it is idempotent.
        req('PATCH', f'/v1/appScreenshotSets/{set_id}/relationships/appScreenshots',
            {'data': [{'type': 'appScreenshots', 'id': i} for i in uploaded]})
        print(f'  {locale}: {len(uploaded)} screenshots, in order')

    print(f'Screenshots replaced on v{version}.')
    return v


def cmd_keywords():
    """Push metadata/<locale>/keywords.txt.

    Keywords live on `appStoreVersionLocalizations`, per version, like the description
    — so this inherits `push_localized_field`'s safety exactly. The **subtitle** does
    not: it lives on `appInfoLocalizations`, which is app-level and shared with the
    live listing, and editing it can put the app itself into review. There is
    deliberately no `subtitle` command here; adding one must not reuse this path.
    """
    push_localized_field('keywords.txt', 'keywords', 'keywords')


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else 'status'
    if cmd == 'status':
        cmd_status()
    elif cmd == 'release':
        cmd_release()
    elif cmd == 'create-version':
        cmd_create_version(sys.argv[2])
    elif cmd == 'notes':
        cmd_notes()
    elif cmd == 'description':
        cmd_description()
    elif cmd == 'keywords':
        cmd_keywords()
    elif cmd == 'screenshots':
        cmd_screenshots()
    elif cmd == 'cancel':
        cmd_cancel()
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
