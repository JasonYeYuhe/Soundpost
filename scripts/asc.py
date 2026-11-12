#!/usr/bin/env python3
"""App Store Connect helper for Soundpost: inspect state, attach a build to the
1.1.0 version, and (re)submit for review via the ASC API.

Usage (run with the venv that has pyjwt+requests):
  $ASC_PYTHON scripts/asc.py status
  $ASC_PYTHON scripts/asc.py create-version 1.4.0     # new version record
  $ASC_PYTHON scripts/asc.py notes                    # metadata/*/release_notes.txt -> whatsNew
  $ASC_PYTHON scripts/asc.py attach <build-version>   # e.g. 5
  $ASC_PYTHON scripts/asc.py submit [--force-cancel]
  $ASC_PYTHON scripts/asc.py release             # APPROVED -> live (manual release)
  $ASC_PYTHON scripts/asc.py resubmit <build-version> # attach + submit
  $ASC_PYTHON scripts/asc.py check-build-number <n>  # read-only: is <n> new?
  $ASC_PYTHON scripts/asc.py check-submittable    # read-only: every reason submit would fail
  $ASC_PYTHON scripts/asc.py screenshots-prune [--apply]  # stale screenshot placements off the new version
  $ASC_PYTHON scripts/asc.py analytics-request    # ONE POST, on Jason's word only (M23 D5)
  $ASC_PYTHON scripts/asc.py analytics            # read-only: weekly store reports, to ~/Library/Caches
  $ASC_PYTHON scripts/asc.py promo                # promotional_text.txt -> the LIVE version and the one in flight

ASC_PYTHON is ~/Library/Caches/Soundpost-build/asc-venv/bin/python3 (M23 §4B.6; /tmp is
emptied by macOS). `attach` and `submit` refuse a version whose releaseType is not MANUAL,
before any write; `create-version` sends MANUAL; `submit` runs `check-submittable` first.

After a REJECTION, do not `resubmit`: a rejected (UNRESOLVED_ISSUES) submission carries the
App Review thread, and cancelling it makes the thread read-only. `submit` refuses it unless
`--force-cancel` is given, and prints the path that keeps the thread (M19 §8-iii).

The decisions — which app, which version, what may be cancelled — live in asc_policy.py
(stdlib only) so CI can test them; scripts/test_asc_policy.py checks they are called here.

Rebuilding the venv:
  python3 -m venv ~/Library/Caches/Soundpost-build/asc-venv \
    && ~/Library/Caches/Soundpost-build/asc-venv/bin/python3 -m pip install "pyjwt[crypto]" requests \
    && touch ~/Library/Caches/Soundpost-build/asc-venv/.no-sweep
"""
import sys, time, json, os, re, hashlib
import jwt, requests

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import asc_policy
from asc_policy import Refusal

KEY_ID  = os.environ.get('ASC_API_KEY_ID', 'DMMFP6XTXX')
ISSUER  = os.environ.get('ASC_API_ISSUER', 'c5671c11-49ec-47d9-bd38-5e3c1a249416')
KEY_PATH = os.environ.get('ASC_API_KEY_PATH',
    os.path.expanduser('~/Library/Mobile Documents/com~apple~CloudDocs/Downloads/AuthKey_DMMFP6XTXX.p8'))
# Not `ASC_APP_ID`. ~/.zshrc exports that name for a different app (CLI Pulse Bar), so in
# Jason's interactive terminal every command here — `release` included, which is public and
# irreversible — used to act on the wrong app; only agent shells, which skip ~/.zshrc, got
# Soundpost. Found 2026-10-07. `SOUNDPOST_ASC_APP_ID` overrides it, and every write is
# checked against the bundle id below before it is sent.
APP_ID  = os.environ.get('SOUNDPOST_ASC_APP_ID', '6778389097')
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


_identity_checked = False


def assert_soundpost_app():
    """Refuse to write unless APP_ID really is Soundpost. Runs once, before the first write."""
    global _identity_checked
    if _identity_checked:
        return
    r = requests.get(f'{BASE}/v1/apps/{APP_ID}', headers=H(), timeout=90)
    r.raise_for_status()
    asc_policy.assert_app_identity(APP_ID, r.json()['data']['attributes'].get('bundleId'))
    _identity_checked = True


def req(method, path, payload=None, **params):
    if method != 'GET':
        assert_soundpost_app()
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


def ios_versions(version_string=None):
    """Every iOS version record, or only those called `version_string`.

    It used to ask for `limit: 10` with no order, and the app now has more than ten
    versions — so the one a command was looking for could simply not be in the page.
    200 is the API's maximum; a lookup by name asks the server to filter instead.
    """
    params = {'filter[platform]': 'IOS', 'limit': 200, 'include': 'build'}
    if version_string is not None:
        params['filter[versionString]'] = version_string
    return get(f'/v1/apps/{APP_ID}/appStoreVersions', **params).get('data', [])


def recent_builds(n=10):
    return get('/v1/builds',
               **{'filter[app]': APP_ID, 'sort': '-uploadedDate', 'limit': n}).get('data', [])


def review_submissions():
    # 200, not 20: the list is every submission the app has ever had, unordered, and
    # a rejected one beyond the first page would be invisible to the cancel guard.
    return get(f'/v1/apps/{APP_ID}/reviewSubmissions',
               **{'filter[platform]': 'IOS', 'limit': 200}).get('data', [])


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
    v = asc_policy.pick_version(ios_versions(expected), expected)
    if v and v['attributes']['appStoreState'] in EDITABLE_STATES:
        return v
    editable = [v for v in ios_versions()
                if v['attributes']['appStoreState'] in EDITABLE_STATES]
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
    for b in recent_builds(200):
        if b['attributes']['version'] == str(version_str):
            return b
    return None


def cmd_status():
    print('=== iOS App Store versions ===')
    for v in sorted(ios_versions(), key=lambda v: v['attributes'].get('createdDate') or '',
                    reverse=True):
        a = v['attributes']
        bid = (v.get('relationships', {}).get('build', {}).get('data') or {}).get('id')
        print(f"  v{a['versionString']:8} state={a['appStoreState']:24} release={a.get('releaseType') or '?':14} "
              f"build_rel={bid}  id={v['id']}")
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
IN_APPLES_HANDS = asc_policy.IN_APPLES_HANDS


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
    already approved and is holding for you — and only the project's own
    MARKETING_VERSION (`asc_policy.releasable`). It will not submit, attach, or
    otherwise nudge anything that is still in the queue.
    """
    v = asc_policy.releasable(ios_versions(), project_marketing_version())
    version = v['attributes']['versionString']
    post('/v1/appStoreVersionReleaseRequests',
         {'data': {'type': 'appStoreVersionReleaseRequests',
                   'relationships': {'appStoreVersion': {
                       'data': {'type': 'appStoreVersions', 'id': v['id']}}}}})
    print(f'RELEASED v{version} — it is going live on the App Store now.')
    return v


def cmd_create_version(version_string):
    """Create a new (PREPARE_FOR_SUBMISSION) App Store version record, released MANUALLY.

    Idempotent: an existing version is returned — after making sure it is MANUAL where
    that is safe to change (`asc_policy.release_type_plan`): PATCHed and read back in
    PREPARE_FOR_SUBMISSION, only printed in any other state. Creating a version cannot
    affect an already-live one, and a PREPARE_FOR_SUBMISSION version can be deleted in
    ASC, so this is reversible.
    """
    v = asc_policy.pick_version(ios_versions(version_string), version_string)
    if v:
        a = v['attributes']
        print(f"Version {version_string} already exists "
              f"(state={a['appStoreState']}, releaseType={a.get('releaseType')}, id={v['id']}).")
        plan = asc_policy.release_type_plan(v)
        if plan == 'patch':
            patch(f"/v1/appStoreVersions/{v['id']}",
                  {'data': {'type': 'appStoreVersions', 'id': v['id'],
                            'attributes': {'releaseType': 'MANUAL'}}})
            v = asc_policy.pick_version(ios_versions(version_string), version_string)
            print(f"  set releaseType=MANUAL; read back: {v['attributes'].get('releaseType')}")
            asc_policy.require_manual_release(v)
        elif plan == 'report':
            print(f"  ! not MANUAL and not PREPARE_FOR_SUBMISSION — left alone; `attach` and "
                  f"`submit` will refuse it.")
        return v
    v = post('/v1/appStoreVersions',
             {'data': {'type': 'appStoreVersions',
                       'attributes': {'platform': 'IOS', 'versionString': version_string,
                                      'releaseType': 'MANUAL'},
                       'relationships': {'app': {'data': {'type': 'apps', 'id': APP_ID}}}}})['data']
    print(f"Created version {version_string} "
          f"(state={v['attributes']['appStoreState']}, releaseType={v['attributes'].get('releaseType')}, "
          f"id={v['id']})")
    asc_policy.require_manual_release(v)
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
    asc_policy.require_manual_release(v)   # before any write (M23 §4B.1)
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


# States that occupy the single active-submission slot for the app and that a wait can
# outlast. A draft (READY_FOR_REVIEW) is not here: nothing here cancels one, so waiting
# for it to clear would only time out (M22 §4B.8) — `submit` finishes it instead.
BLOCKING = ('WAITING_FOR_REVIEW', 'WAITING_FOR_EXPORT_COMPLIANCE',
            'UNRESOLVED_ISSUES', 'IN_REVIEW', 'CANCELING')


def cmd_cancel(force_cancel=False):
    """Cancel what `asc_policy.may_cancel` allows; wait until the slot clears.

    A rejected submission is cancelled only with `--force-cancel`: it carries the App
    Review thread, and cancelling it is what made build 19's thread read-only.
    """
    submissions = review_submissions()
    if any(s['attributes'].get('state') == asc_policy.REJECTED for s in submissions) \
            and not force_cancel:
        raise Refusal(asc_policy.THREAD_KEEPING_PATH)
    for s in submissions:
        st = s['attributes'].get('state')
        if st in IN_APPLES_HANDS:
            print(f"  ! submission {s['id']} is {st} (genuinely in Apple's queue) — "
                  f"cancel it in ASC if you really mean to.")
        elif asc_policy.may_cancel(st, force_cancel):
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


def cmd_submit(force_cancel=False):
    v = editable_version()
    if not v:
        sys.exit('No editable App Store version found.')
    asc_policy.require_manual_release(v)   # before any write, cmd_cancel's included (M23 §4B.1)
    problems = submittable_problems(v)
    if problems:
        raise Refusal('Refusing to submit — ' + str(len(problems)) + ' problem(s):\n'
                      + '\n'.join(f'  - {p}' for p in problems))
    submissions = review_submissions()
    plan = asc_policy.submit_plan([s['attributes'].get('state') for s in submissions],
                                  force_cancel)
    if plan == 'in_review':
        s = next(s for s in submissions if s['attributes'].get('state') in IN_APPLES_HANDS)
        print(f"A submission is already {s['attributes']['state']} (id={s['id']}). Nothing to do.")
        return
    # A draft this script created on an earlier run that stopped half way (M21: the
    # age-rating 409) cannot be cancelled, so it is finished rather than replaced.
    sub_id = asc_policy.reusable_draft(submissions)
    if sub_id:
        print(f"Reusing the unsubmitted draft {sub_id}")
    else:
        cmd_cancel(force_cancel)
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
        sub_id = sub['id']
        print(f"Created reviewSubmission {sub_id}")
    # What the draft holds, with each item's version — asked for explicitly, since an
    # item listed without its relationship would read as holding nothing.
    items = get(f"/v1/reviewSubmissions/{sub_id}/items",
                **{'include': 'appStoreVersion', 'limit': 200}).get('data', [])
    held = [(it.get('relationships', {}).get('appStoreVersion', {}).get('data') or {}).get('id')
            for it in items]
    if asc_policy.draft_items_plan(held, v['id']) == 'add':
        post('/v1/reviewSubmissionItems',
             {'data': {'type': 'reviewSubmissionItems',
                       'relationships': {
                           'reviewSubmission': {'data': {'type': 'reviewSubmissions', 'id': sub_id}},
                           'appStoreVersion': {'data': {'type': 'appStoreVersions', 'id': v['id']}}}}})
        print(f"Added version {v['attributes']['versionString']} to submission")
    patch(f"/v1/reviewSubmissions/{sub_id}",
          {'data': {'type': 'reviewSubmissions', 'id': sub_id,
                    'attributes': {'submitted': True}}})
    print(f"SUBMITTED for review (submission {sub_id}).")


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

# What `scripts/screenshots.sh` produces and App Store Connect is sent: one constant in
# asc_policy (display type, pixel size, screens, folder), read by both — M23 §4B.7.
SCREENSHOT_DISPLAY_TYPE = asc_policy.SCREENSHOT_DISPLAY_TYPE


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
    """Upload each locale's screenshots (from `scripts/screenshots.sh`) as a new
    `SCREENSHOT_DISPLAY_TYPE` set on the editable version.

    **It never deletes a screenshot** (M23 §4B.7). `DELETE /v1/appScreenshots/{id}` is
    deprecated in favour of the App Asset Library's image delete, and an image backs the
    LIVE version's placements as well; what the old call now does to them is not
    documented. So a set that already holds images is refused here, and a stale set of
    another display type leaves the new version through `screenshots-prune` (a placement
    delete, documented to leave the image in the library) or the web UI.
    """
    v = editable_version()
    if not v:
        sys.exit('No editable App Store version found — run `create-version <x.y.z>` first.')
    state = v['attributes']['appStoreState']
    version = v['attributes']['versionString']
    if state not in SCREENSHOT_EDITABLE_STATES:
        sys.exit(
            f'Refusing to upload the screenshots of v{version}: it is {state}.\n'
            f'  Images are only editable in {", ".join(SCREENSHOT_EDITABLE_STATES)} —\n'
            f'  App Store Connect answers 409 STATE_ERROR otherwise, and it would do so\n'
            f'  part way through, leaving some locales uploaded and some not.'
        )

    root = asc_policy.screenshot_dir()
    if not os.path.isdir(root):
        sys.exit(f'No screenshots at {root} — run `scripts/screenshots.sh` first.')

    print(f"Uploading {SCREENSHOT_DISPLAY_TYPE} screenshots to v{version} ({state}) from {root}")
    localizations = {loc['attributes']['locale']: loc['id']
                     for loc in get(f"/v1/appStoreVersions/{v['id']}/appStoreVersionLocalizations")
                     .get('data', [])}

    # Every locale is checked before anything is sent, so a bad folder stops the run whole.
    plan = {}
    for locale in sorted(os.listdir(root)):
        folder = os.path.join(root, locale)
        if not os.path.isdir(folder):
            continue
        if locale not in localizations:
            sys.exit(f'  ! {locale} has screenshots but no localization on v{version}')
        plan[locale] = (folder, asc_policy.screenshot_files(os.listdir(folder)))
    if not plan:
        sys.exit(f'No locale folders under {root}.')

    for locale, (folder, files) in plan.items():
        sets = get(f"/v1/appStoreVersionLocalizations/{localizations[locale]}/appScreenshotSets") \
            .get('data', [])
        match = [s for s in sets
                 if s['attributes']['screenshotDisplayType'] == SCREENSHOT_DISPLAY_TYPE]
        if match:
            set_id = match[0]['id']
            asc_policy.screenshot_target_set_plan(
                [s['id'] for s in get(f'/v1/appScreenshotSets/{set_id}/appScreenshots',
                                      limit=200).get('data', [])])
        else:
            set_id = post('/v1/appScreenshotSets',
                          {'data': {'type': 'appScreenshotSets',
                                    'attributes': {'screenshotDisplayType': SCREENSHOT_DISPLAY_TYPE},
                                    'relationships': {'appStoreVersionLocalization': {
                                        'data': {'type': 'appStoreVersionLocalizations',
                                                 'id': localizations[locale]}}}}})['data']['id']

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

        held = [s['id'] for s in get(f'/v1/appScreenshotSets/{set_id}/appScreenshots',
                                     limit=200).get('data', [])]
        if sorted(held) != sorted(uploaded):
            sys.exit(f'  ! {locale}: the set holds {len(held)} image(s), not exactly the {len(uploaded)} '
                     f'just uploaded; left as it is — check it in App Store Connect.')
        # Order is the set's relationship linkage, not an attribute on the image. It goes
        # out only now that the set holds exactly this run's uploads.
        req('PATCH', f'/v1/appScreenshotSets/{set_id}/relationships/appScreenshots',
            {'data': [{'type': 'appScreenshots', 'id': i} for i in uploaded]})
        print(f'  {locale}: {len(uploaded)} screenshots, in order')

    print(f'Screenshots uploaded to v{version}. A stale set of another type: '
          f'`asc.py screenshots-prune` (dry run first), or the web UI.')
    return v


def editable_placements(v):
    """{locale: [{'id', 'group'}]} — the EDITABLE version's screenshot placements only."""
    out = {}
    for loc in get(f"/v1/appStoreVersions/{v['id']}/appStoreVersionLocalizations").get('data', []):
        rows = get(f"/v1/appStoreVersionLocalizations/{loc['id']}/placements",
                   **{'filter[placementType]': 'APP_SCREENSHOT', 'limit': 200}).get('data', [])
        out[loc['attributes']['locale']] = [{'id': p['id'], 'group': p['attributes'].get('placementGroup')}
                                            for p in rows]
    return out


def cmd_screenshots_prune(apply=False):
    """Remove the editable version's screenshot placements of every group except the one
    `screenshots` uploads — a placement delete, documented to leave the image in the
    library (the live version keeps its own placements). Dry run unless `--apply`; refuses
    a locale whose uploaded group does not yet hold exactly this release's screens.
    """
    v = editable_version()
    if not v:
        sys.exit('No editable App Store version found.')
    state = v['attributes']['appStoreState']
    if state not in SCREENSHOT_EDITABLE_STATES:
        sys.exit(f"Refusing: v{v['attributes']['versionString']} is {state}; its screenshots cannot change.")
    plan = {locale: asc_policy.stale_placements(rows)
            for locale, rows in editable_placements(v).items()}
    for locale, ids in sorted(plan.items()):
        print(f"  {locale}: {len(ids)} stale placement(s) to remove")
    if not apply:
        print('Dry run — nothing removed. Rerun with --apply.')
        return plan
    for locale, ids in sorted(plan.items()):
        for pid in ids:
            req('DELETE', f'/v1/appAssetLibraryPlacements/{pid}')
        print(f"  {locale}: removed {len(ids)}")
    return plan


def cmd_keywords():
    """Push metadata/<locale>/keywords.txt.

    Keywords live on `appStoreVersionLocalizations`, per version, like the description
    — so this inherits `push_localized_field`'s safety exactly. The **subtitle** does
    not: it lives on `appInfoLocalizations`, which is app-level and shared with the
    live listing, and editing it can put the app itself into review. There is
    deliberately no `subtitle` command here; adding one must not reuse this path.
    """
    push_localized_field('keywords.txt', 'keywords', 'keywords')


def cmd_promo():
    """Push metadata/<locale>/promotional_text.txt to the live version and the one in flight.

    Promotional text is the one listing field Apple lets an app change without review, so
    unlike every other push here it writes to the LIVE version — and for that reason it
    sends nothing else: the PATCH body is `asc_policy.promo_attributes`, one key. It only
    edits localizations that exist (a new locale on the live listing is not its call), and
    reads every value back. M23 §4H, D6: run on Jason's word for the exact texts.
    """
    assert_soundpost_app()
    targets = asc_policy.promo_targets(ios_versions(), project_marketing_version())
    texts = {}
    metadata_root = os.path.join(PROJECT_DIR, 'metadata')
    for locale in sorted(os.listdir(metadata_root)):
        path = os.path.join(metadata_root, locale, 'promotional_text.txt')
        if os.path.isfile(path):
            with open(path, encoding='utf-8') as f:
                texts[locale] = f.read().strip()
    mismatched = []
    for v in targets:
        print(f"Promotional text on v{v['attributes']['versionString']} ({v['attributes']['appStoreState']})")
        for loc in get(f"/v1/appStoreVersions/{v['id']}/appStoreVersionLocalizations").get('data', []):
            locale = loc['attributes']['locale']
            if locale not in texts:
                print(f'  {locale}: no promotional_text.txt in the repo, left as it is')
                continue
            patch(f"/v1/appStoreVersionLocalizations/{loc['id']}",
                  {'data': {'type': 'appStoreVersionLocalizations', 'id': loc['id'],
                            'attributes': asc_policy.promo_attributes(texts[locale])}})
            back = get(f"/v1/appStoreVersionLocalizations/{loc['id']}")['data']['attributes'].get('promotionalText')
            same = back == texts[locale]
            print(f"  {locale}: {'read back, identical' if same else 'READ BACK DIFFERS'} ({len(back or '')} chars)")
            if not same:
                mismatched.append(f"v{v['attributes']['versionString']} {locale}")
    if mismatched:
        sys.exit(f"Promotional text did not read back as sent: {', '.join(mismatched)}")


def submittable_problems(v):
    """Every reason `v` cannot be submitted (`asc_policy.submittable_problems`). GET only."""
    assert_soundpost_app()
    build = (get(f"/v1/appStoreVersions/{v['id']}/build").get('data') or {}).get('attributes')
    whats_new, display_types = {}, {}
    for loc in get(f"/v1/appStoreVersions/{v['id']}/appStoreVersionLocalizations").get('data', []):
        locale = loc['attributes']['locale']
        whats_new[locale] = loc['attributes'].get('whatsNew') or ''
        types = {}
        for st in get(f"/v1/appStoreVersionLocalizations/{loc['id']}/appScreenshotSets").get('data', []):
            count = len(get(f"/v1/appScreenshotSets/{st['id']}/appScreenshots", limit=200).get('data', []))
            types[st['attributes']['screenshotDisplayType']] = count
        display_types[locale] = types
    info = asc_policy.editable_app_info(get(f'/v1/apps/{APP_ID}/appInfos').get('data', []))
    declaration = get(f"/v1/appInfos/{info['id']}/ageRatingDeclaration").get('data') or {}
    gaps = asc_policy.age_rating_gaps(declaration.get('attributes') or {})
    return asc_policy.submittable_problems(v, build, whats_new, display_types, gaps)


def cmd_check_submittable():
    """Read-only: list every reason the editable version cannot be submitted; exit 1 if any."""
    assert_soundpost_app()
    v = editable_version()
    if not v:
        sys.exit('No editable App Store version found.')
    problems = submittable_problems(v)
    name = f"v{v['attributes']['versionString']} ({v['attributes']['appStoreState']})"
    if problems:
        raise Refusal(f'{name} cannot be submitted — {len(problems)} problem(s):\n'
                      + '\n'.join(f'  - {p}' for p in problems))
    print(f'{name} is submittable: MANUAL, a VALID build with an export-compliance answer, '
          f"What's New in every locale, {asc_policy.SCREENSHOT_DISPLAY_TYPE} screenshots only, "
          f'every age-rating question answered.')


# ── Measurement (M23 §4B.8) ──────────────────────────────────────────────────

ANALYTICS_DIR = os.path.expanduser('~/Library/Caches/Soundpost-build/analytics')
ANALYTICS_REPORTS = ('App Store Discovery and Engagement Standard', 'App Downloads Standard')


def analytics_requests():
    return get(f'/v1/apps/{APP_ID}/analyticsReportRequests', limit=200).get('data', [])


def cmd_analytics_request():
    """Ask App Store Connect to start producing analytics reports (one ONGOING request).

    The one write here, sent only on Jason's word (D5): an App Store Connect write
    outside the release path. Refuses if a request already exists.
    """
    attributes = asc_policy.analytics_request_plan(analytics_requests())
    r = post('/v1/analyticsReportRequests',
             {'data': {'type': 'analyticsReportRequests', 'attributes': attributes,
                       'relationships': {'app': {'data': {'type': 'apps', 'id': APP_ID}}}}})['data']
    print(f"Requested ONGOING analytics reports ({r['id']}). Apple produces the first ones in a day or two.")


def cmd_analytics():
    """GET only: download the weekly Discovery & Engagement and Downloads report instances
    to ~/Library/Caches/Soundpost-build/analytics/ (never ~/Documents) and print a table."""
    import csv, gzip, io
    requests_ = [r for r in analytics_requests() if r['attributes'].get('accessType') == 'ONGOING']
    if not requests_:
        sys.exit('No ONGOING analytics report request yet (`asc.py analytics-request`, on Jason\'s word).')
    os.makedirs(ANALYTICS_DIR, exist_ok=True)
    totals = {}
    for rq in requests_:
        for report in get(f"/v1/analyticsReportRequests/{rq['id']}/reports", limit=200).get('data', []):
            name = report['attributes'].get('name')
            if name not in ANALYTICS_REPORTS:
                continue
            for inst in get(f"/v1/analyticsReports/{report['id']}/instances",
                            **{'filter[granularity]': 'WEEKLY', 'limit': 200}).get('data', []):
                day = inst['attributes'].get('processingDate')
                for seg in get(f"/v1/analyticsReportInstances/{inst['id']}/segments", limit=200).get('data', []):
                    url = seg['attributes'].get('url')
                    if not url:
                        continue
                    # A presigned download: no Authorization header, so not through req().
                    blob = requests.get(url, timeout=120).content
                    dest = os.path.join(ANALYTICS_DIR, f"{name.replace(' ', '_')}-{day}-{seg['id'][:8]}.csv.gz")
                    with open(dest, 'wb') as f:
                        f.write(blob)
                    text = gzip.decompress(blob).decode('utf-8', 'replace')
                    for row in csv.DictReader(io.StringIO(text), delimiter='\t'):
                        kind = row.get('Event') or row.get('Download Type') or '?'
                        source = row.get('Source Type') or '?'
                        key = (row.get('Date', day)[:10], name.split(' ')[2] if name.startswith('App Store') else 'Downloads', kind, source)
                        try:
                            totals[key] = totals.get(key, 0) + int(float(row.get('Counts') or 0))
                        except ValueError:
                            pass
    if not totals:
        print(f'No report rows yet; files (if any) are in {ANALYTICS_DIR}.')
        return
    print(f"{'date':10}  {'report':10}  {'event / type':28}  {'source':24}  count")
    for (date, report, kind, source), n in sorted(totals.items()):
        print(f'{date:10}  {report:10}  {kind[:28]:28}  {source[:24]:24}  {n}')


def cmd_check_build_number(build_number):
    """Read-only: refuse unless `build_number` is newer than every uploaded build.

    `build-upload-asc.sh` calls this before it archives, so a reused number is caught
    in a second instead of after a twenty-minute archive and upload. A read, but it
    still checks the app first: compared against another app's builds, "new" means
    nothing.
    """
    assert_soundpost_app()
    newest = asc_policy.build_number_is_new(
        build_number, [b['attributes']['version'] for b in recent_builds(200)])
    print(f'Build {build_number} is new (newest on App Store Connect: {newest}).')


def main():
    args = [a for a in sys.argv[1:] if a != '--force-cancel']
    force_cancel = '--force-cancel' in sys.argv[1:]
    try:
        dispatch(args, force_cancel)
    except Refusal as refusal:
        sys.exit(str(refusal))


def dispatch(args, force_cancel):
    cmd = args[0] if args else 'status'
    if cmd == 'status':
        cmd_status()
    elif cmd == 'release':
        cmd_release()
    elif cmd == 'create-version':
        cmd_create_version(args[1])
    elif cmd == 'notes':
        cmd_notes()
    elif cmd == 'description':
        cmd_description()
    elif cmd == 'keywords':
        cmd_keywords()
    elif cmd == 'promo':
        cmd_promo()
    elif cmd == 'screenshots':
        cmd_screenshots()
    elif cmd == 'cancel':
        cmd_cancel(force_cancel)
    elif cmd == 'attach':
        cmd_attach(args[1])
    elif cmd == 'submit':
        cmd_submit(force_cancel)
    elif cmd == 'resubmit':
        cmd_attach(args[1])
        cmd_submit(force_cancel)
    elif cmd == 'check-build-number':
        cmd_check_build_number(args[1])
    elif cmd == 'check-submittable':
        cmd_check_submittable()
    elif cmd == 'screenshots-prune':
        cmd_screenshots_prune(apply='--apply' in args)
    elif cmd == 'analytics-request':
        cmd_analytics_request()
    elif cmd == 'analytics':
        cmd_analytics()
    else:
        sys.exit(f'Unknown command: {cmd}')


if __name__ == '__main__':
    main()
