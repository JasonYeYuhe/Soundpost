"""The decisions `scripts/asc.py` makes before it writes to App Store Connect (M20 §4B).

Standard library only, on purpose. `asc.py` imports `jwt` and `requests` at load, so
CI's stock Python cannot import it, and a decision that lives only inside `asc.py`
cannot be tested anywhere that runs on every push. Each rule here either returns what
to act on or raises `Refusal` with the sentence to print; `asc.py` exits on it.

`scripts/test_asc_policy.py` tests these functions and also reads `asc.py`'s source to
check they are actually called from it — a rule nobody calls is not a guard.
"""

SOUNDPOST_BUNDLE_ID = 'com.soundpost.Soundpost'

# Apple is holding this version for a person to press Release.
PENDING_RELEASE = 'PENDING_DEVELOPER_RELEASE'

# A submission in these states is in Apple's hands. The script never cancels one —
# that is a decision for the App Store Connect web UI, made on purpose.
IN_APPLES_HANDS = ('WAITING_FOR_REVIEW', 'IN_REVIEW')

# A rejected submission. It carries the App Review thread: cancelling it to open a
# fresh submission makes that thread read-only, which is what happened to build 19's
# explanation (M19 §8-iii). Never cancelled without `--force-cancel`.
REJECTED = 'UNRESOLVED_ISSUES'

# A review submission that has been created but not (or no longer) submitted.
DRAFT = 'READY_FOR_REVIEW'

# Submissions the script may cancel to free the app's single active-submission slot:
# one stuck on export compliance. Nothing else.
#
# A draft is NOT here (M22 §4B.8). A draft that was never submitted cannot be cancelled —
# Apple answers 409 "Resource is not in cancellable state" (M21 §13 S6, where `submit`
# had created one, failed at the age-rating question, and could then never get past
# it). `submit` finishes such a draft instead (`reusable_draft`). A draft that WAS
# submitted before is a rejection reopened with "Update Review": it carries the review
# thread, and is never touched from here (`reusable_draft` refuses it).
CANCELABLE = ('WAITING_FOR_EXPORT_COMPLIANCE',)

THREAD_KEEPING_PATH = (
    'A rejected submission (UNRESOLVED_ISSUES) holds the App Review thread.\n'
    'Cancelling it opens a fresh submission and makes that thread read-only (M19 §8-iii).\n'
    'Keep the thread instead:\n'
    '  1. asc.py attach <build>\n'
    '  2. App Store Connect → App Review → reply in the rejection thread\n'
    '  3. the version page → Update Review\n'
    '  4. Resubmit to App Review (web UI)\n'
    'Only if you mean to abandon the thread: asc.py submit --force-cancel'
)


class Refusal(Exception):
    """A decision not to act. `asc.py` prints the message and exits non-zero."""


def _state(version):
    return version['attributes']['appStoreState']


def _version_string(version):
    return version['attributes']['versionString']


def describe_versions(versions):
    """`v1.9.0=READY_FOR_SALE, v1.10.0=PREPARE_FOR_SUBMISSION` — for refusals."""
    return ', '.join(f'v{_version_string(v)}={_state(v)}' for v in versions) or '(no versions)'


def assert_app_identity(app_id, bundle_id, expected=SOUNDPOST_BUNDLE_ID):
    """Refuse unless the app every write is aimed at really is Soundpost.

    `~/.zshrc` exports `ASC_APP_ID` for a different app (CLI Pulse Bar); until
    2026-10-07 every command run from Jason's own terminal — `release` included —
    acted on that app.
    """
    if bundle_id != expected:
        raise Refusal(f'Refusing to write: app {app_id} is {bundle_id!r}, not {expected}.\n'
                      f'  Check SOUNDPOST_ASC_APP_ID in your environment.')


def pick_version(versions, version_string):
    """The one version record with this version string, or None.

    Two records with one version string cannot be told apart by anything this script
    reads, so it refuses rather than pick one.
    """
    matches = [v for v in versions if _version_string(v) == version_string]
    if len(matches) > 1:
        raise Refusal(f'{len(matches)} App Store versions are called {version_string}: '
                      f'{describe_versions(matches)}. Refusing to choose between them.')
    return matches[0] if matches else None


def releasable(versions, marketing_version):
    """The version `release` may put on sale: exactly the project's version, approved.

    It used to take the first PENDING_DEVELOPER_RELEASE version by state alone, so an
    approved build of any version — an old one, another app's — would have gone live
    on a command meant for this one.
    """
    pending = [v for v in versions if _state(v) == PENDING_RELEASE]
    matches = [v for v in pending if _version_string(v) == marketing_version]
    if len(matches) == 1:
        return matches[0]
    if len(matches) > 1:
        raise Refusal(f'{len(matches)} approved versions are called {marketing_version}. '
                      f'Refusing to choose between them.')
    raise Refusal(
        f'Nothing to release: v{marketing_version} (the project\'s MARKETING_VERSION) is not '
        f'approved and waiting.\n'
        f'  Current: {describe_versions(versions)}\n'
        f'  A version is releasable only in {PENDING_RELEASE}, and only the project\'s own.')


def may_cancel(state, force=False):
    """Whether the script may cancel a review submission in `state`."""
    if state in CANCELABLE:
        return True
    if state == REJECTED:
        return force
    return False


def submit_plan(submission_states, force_cancel=False):
    """What `submit` may do, given the states of the app's review submissions.

    Returns `'in_review'` when one is already with Apple (nothing to do) and
    `'proceed'` when it may cancel what `may_cancel` allows and open a fresh one.
    Raises `Refusal` with the thread-keeping path when a rejected submission exists
    and `force_cancel` was not given: `resubmit` after a rejection used to cancel it
    unconditionally, and that is what made build 19's review thread read-only.
    """
    if any(s in IN_APPLES_HANDS for s in submission_states):
        return 'in_review'
    if REJECTED in submission_states and not force_cancel:
        raise Refusal(THREAD_KEEPING_PATH)
    return 'proceed'


def build_number_is_new(local_build, uploaded_builds):
    """Refuse unless `local_build` is greater than every build already uploaded.

    App Store Connect rejects a reused number only after a full archive and upload;
    this says so before the archive starts.
    """
    try:
        local = int(str(local_build).strip())
    except ValueError:
        raise Refusal(f'CURRENT_PROJECT_VERSION {local_build!r} is not a whole number.')
    numbers = []
    for b in uploaded_builds:
        try:
            numbers.append(int(str(b).strip()))
        except ValueError:
            raise Refusal(f'App Store Connect holds a build numbered {b!r}; '
                          f'cannot tell whether {local} is newer.')
    newest = max(numbers) if numbers else None
    if newest is not None and local <= newest:
        raise Refusal(f'Build {local} is not new: App Store Connect already has build {newest}.\n'
                      f'  Raise CURRENT_PROJECT_VERSION above {newest}.')
    return newest


def reusable_draft(submissions):
    """The id of the one never-submitted draft `submit` should finish, or None to create one.

    A draft with a `submittedDate` was submitted before: it is a rejection reopened for
    another round, and it holds the App Review thread. Finishing or cancelling it from
    here would be the build-19 mistake again (M19 §8-iii), so it is refused with the
    path that keeps the thread. Two never-submitted drafts cannot be told apart, so
    that is refused too.
    """
    drafts = [x for x in submissions if x['attributes'].get('state') == DRAFT]
    reopened = [d for d in drafts if d['attributes'].get('submittedDate')]
    if reopened:
        raise Refusal(f'Submission {reopened[0]["id"]} was submitted before and reopened; it '
                      f'holds the review thread.\n' + THREAD_KEEPING_PATH)
    if len(drafts) > 1:
        raise Refusal(f'{len(drafts)} unsubmitted drafts: ' + ', '.join(d['id'] for d in drafts)
                      + '. Remove the extra ones in App Store Connect first.')
    return drafts[0]['id'] if drafts else None


def draft_items_plan(item_version_ids, version_id):
    """What to do with a draft holding `item_version_ids`, to submit `version_id`.

    `'add'` for an empty draft, `'submit'` when it already holds this version. Refuses
    when it holds any other version — or an item whose version could not be read, which
    is treated as another version rather than assumed to be this one.
    """
    others = [v for v in item_version_ids if v != version_id]
    if others:
        shown = ', '.join(v or '(unreadable item)' for v in others)
        raise Refusal(f'The open draft holds something other than this version ({shown}); '
                      f'remove it in App Store Connect first.')
    return 'submit' if version_id in item_version_ids else 'add'


# ── M23 §4B.1: a version goes live only when a person presses Release ──────────

MANUAL = 'MANUAL'


def require_manual_release(version):
    """Refuse unless `version` will wait for a person to release it (`releaseType` MANUAL).

    Every release since 1.9.0 was MANUAL only because someone read it back by hand; nothing
    in asc.py looked. `AFTER_APPROVAL` would put a build in front of users the moment App
    Review approved it, and `SCHEDULED` on a date. Called before `attach` or `submit` writes
    anything.
    """
    release_type = (version.get('attributes') or {}).get('releaseType')
    if release_type != MANUAL:
        raise Refusal(
            f"Refusing: v{_version_string(version)} has releaseType {release_type or '(none)'}, "
            f"not {MANUAL}.\n"
            f"  It would go live without anyone pressing Release. `asc.py create-version "
            f"{_version_string(version)}` sets MANUAL while the version is PREPARE_FOR_SUBMISSION;\n"
            f"  otherwise set \"Manually release this version\" in App Store Connect first.")
    return version


def release_type_plan(version):
    """What `create-version` does with a version that already exists.

    `'ok'` when it is MANUAL; `'patch'` when it is PREPARE_FOR_SUBMISSION with another
    release type (the one state where changing it touches nothing in review); `'report'`
    otherwise — print it and write nothing.
    """
    a = version.get('attributes') or {}
    if a.get('releaseType') == MANUAL:
        return 'ok'
    if a.get('appStoreState') == 'PREPARE_FOR_SUBMISSION':
        return 'patch'
    return 'report'


# ── M23 §4B.4, §4B.7: screenshots ─────────────────────────────────────────────
#
# Settled read-only in M23 S1 (docs/M23-DEVPLAN.md §13, with links):
#   - `appScreenshotSets` / `appScreenshots` are deprecated (API 4.5) in favour of App
#     Asset Library placements; they still answer, with no announced sunset.
#   - A new version's screenshots are its own placements over the SAME library images
#     (read on 1.12.0: the inherited 6.5-inch set is four `IPHONE_FACE_ID_LARGE_PROFILE`
#     placements; its appScreenshot ids differ from 1.11.0's, its image assets do not).
#   - `DELETE /v1/appScreenshots/{id}` is documented only as "use the image delete
#     instead", and an image backs the LIVE version's placements too. Its effect is not
#     documented, so asc.py never sends it. A placement delete is documented to leave the
#     image in the library, so a stale set leaves a new version that way, or by hand.
#   - 1320x2868 is accepted for "iPhone with Dynamic Island (large display)"; the
#     display-type enum's largest iPhone value is APP_IPHONE_67 (there is no _69).

SCREENSHOT_DISPLAY_TYPE = 'APP_IPHONE_67'
SCREENSHOT_SIZE = (1320, 2868)
# The placement group App Store Connect files an APP_IPHONE_67 upload under, and the one
# the old 6.5-inch set sits in (read on 1.12.0). The new group is by analogy until S7 reads
# it on 1.13.0, so `stale_placements` refuses unless the kept group really holds the upload.
SCREENSHOT_PLACEMENT_GROUP = 'IPHONE_DYNAMIC_ISLAND_LARGE_PROFILE'
# What `scripts/screenshots.sh` captures, in store order. The file for screen i is
# `NN-<screen>.png`, NN = i + 1, two digits.
SCREENSHOT_SCREENS = ('gallery', 'detail', 'search', 'capture')


def screenshot_dir():
    """Where screenshots.sh writes and `asc.py screenshots` reads: outside iCloud.

    Not `build/screenshots/` — that is the set the store shows today, iCloud-synced, and
    screenshots.sh empties a locale folder before capturing into it.
    """
    import os
    return os.environ.get('SOUNDPOST_SCREENSHOT_DIR') or os.path.expanduser(
        '~/Library/Caches/Soundpost-build/screenshots-69')


def screenshot_file_names(screens=SCREENSHOT_SCREENS):
    return [f'{i + 1:02d}-{s}.png' for i, s in enumerate(screens)]


def screenshot_files(names, screens=SCREENSHOT_SCREENS):
    """The files to upload from one locale folder, in store order — exactly the names
    screenshots.sh produces, or a refusal naming what is extra or missing.

    `cmd_screenshots` used to upload every `.png` it found: an iCloud `01-gallery 2.png`
    sorts before `01-gallery.png` and would have gone to the store as the first image.
    """
    expected = screenshot_file_names(screens)
    pngs = sorted(n for n in names if n.lower().endswith('.png'))
    extra = [n for n in pngs if n not in expected]
    missing = [n for n in expected if n not in pngs]
    if extra or missing:
        parts = []
        if extra:
            parts.append('not a screen screenshots.sh captures: ' + ', '.join(extra))
        if missing:
            parts.append('missing: ' + ', '.join(missing))
        raise Refusal('Refusing to upload this locale\'s screenshots — ' + '; '.join(parts) + '.')
    return expected


def screenshot_target_set_plan(existing_ids):
    """Upload into a set only while it is empty.

    asc.py no longer deletes screenshots (`DELETE /v1/appScreenshots` has undocumented
    effects on the live version's images), so a set that already holds images is left for
    a placement delete or the web UI rather than replaced.
    """
    existing = list(existing_ids)
    if existing:
        raise Refusal(
            f'The {SCREENSHOT_DISPLAY_TYPE} set already holds {len(existing)} image(s). asc.py does not '
            f'delete screenshots (§4B.7);\n'
            f'  remove them in App Store Connect, or with `asc.py screenshots-prune` once it lists them, then rerun.')
    return 'upload'


def stale_placements(placements, keep_group=SCREENSHOT_PLACEMENT_GROUP, expected_count=len(SCREENSHOT_SCREENS)):
    """The editable version's screenshot placements to remove: every group except the one
    just uploaded — and only once that group holds exactly `expected_count` images.

    `placements`: [{'id', 'group'}] listed from the EDITABLE localization only (a new
    version's placements are its own records, so the live version's are never in it).
    Refuses rather than leave a locale with no screenshots.
    """
    kept = [p for p in placements if p['group'] == keep_group]
    if len(kept) != expected_count:
        raise Refusal(
            f'Refusing to remove anything: the {keep_group} group holds {len(kept)} placement(s), '
            f'not the {expected_count} this release uploads.\n'
            f'  Groups present: {sorted({p["group"] for p in placements}) or "(none)"}.')
    return [p['id'] for p in placements if p['group'] != keep_group]


# ── M23 §4B.5: check-submittable ──────────────────────────────────────────────

LIVE_APP_INFO_STATE = 'READY_FOR_DISTRIBUTION'   # read on 2026-11-12 (§13 S1)

# Age-rating attributes that may be null in a complete declaration (learned from the live
# one, 2026-11-12): optional fields, and follow-ups to a question answered "no".
AGE_RATING_OPTIONAL = ('developerAgeRatingInfoUrl', 'gracRatingClassificationNumber', 'kidsAgeBand')
AGE_RATING_FOLLOW_UPS = {'socialMediaAgeRestricted': ('socialMedia', False)}

REQUIRED_WHATS_NEW_LOCALES = ('en-US', 'ja', 'zh-Hans')


def editable_app_info(app_infos):
    """The one app info that is not live. Two exist while a version is in flight, each
    with its own age-rating declaration; the live one answers nothing about the next
    release. Refuses unless exactly one qualifies."""
    candidates = [i for i in app_infos if (i.get('attributes') or {}).get('state') != LIVE_APP_INFO_STATE]
    if len(candidates) != 1:
        states = ', '.join(f"{i['id'][:8]}={(i.get('attributes') or {}).get('state')}" for i in app_infos)
        raise Refusal(f'Expected exactly one app info that is not {LIVE_APP_INFO_STATE}; '
                      f'found {len(candidates)} ({states or "none"}).')
    return candidates[0]


def age_rating_gaps(attributes):
    """Every unanswered age-rating question: a null attribute, except the optional ones
    and a follow-up whose question was answered so that it does not apply."""
    gaps = []
    for name, value in sorted((attributes or {}).items()):
        if value is not None or name in AGE_RATING_OPTIONAL:
            continue
        follow = AGE_RATING_FOLLOW_UPS.get(name)
        if follow and attributes.get(follow[0]) == follow[1]:
            continue
        gaps.append(name)
    return gaps


def submittable_problems(version, build, whats_new, display_types, age_gaps,
                         expected_type=SCREENSHOT_DISPLAY_TYPE):
    """Every reason `version` cannot be submitted — read-only, all of them at once.

    `build`: the attached build's attributes or None. `whats_new`: {locale: text}.
    `display_types`: {locale: {display type: image count}}. `age_gaps`: from
    `age_rating_gaps` on the EDITABLE app info's declaration.
    """
    problems = []
    if (version.get('attributes') or {}).get('releaseType') != MANUAL:
        problems.append(f"releaseType is {(version.get('attributes') or {}).get('releaseType')}, not MANUAL")
    if not build:
        problems.append('no build is attached')
    else:
        if build.get('processingState') != 'VALID':
            problems.append(f"the attached build is {build.get('processingState')}, not VALID")
        if build.get('usesNonExemptEncryption') is None:
            problems.append('the attached build has no export-compliance answer (usesNonExemptEncryption)')
    for locale in REQUIRED_WHATS_NEW_LOCALES:
        if not (whats_new.get(locale) or '').strip():
            problems.append(f"What's New is empty in {locale}")
    for locale in REQUIRED_WHATS_NEW_LOCALES:
        types = display_types.get(locale, {})
        if not types.get(expected_type):
            problems.append(f'{locale} has no {expected_type} screenshots')
        for t, count in sorted(types.items()):
            if t != expected_type and t.startswith('APP_IPHONE'):
                problems.append(f'{locale} still has a stale {t} set ({count} image(s))')
    for name in age_gaps:
        problems.append(f'age rating: {name} is unanswered on the editable app info')
    return problems


# ── M23 §4B.8: measurement ────────────────────────────────────────────────────

def analytics_request_plan(existing_requests):
    """One ONGOING analytics report request per app: refuse if one already exists."""
    ongoing = [r for r in existing_requests
               if (r.get('attributes') or {}).get('accessType') == 'ONGOING']
    if ongoing:
        raise Refusal(f'An ONGOING analytics report request already exists ({ongoing[0]["id"]}); '
                      f'nothing to send.')
    return {'accessType': 'ONGOING'}
