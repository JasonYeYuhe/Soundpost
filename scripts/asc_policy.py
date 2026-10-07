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

# Submissions the script may cancel to free the app's single active-submission slot:
# a draft that was never sent, and one stuck on export compliance. Nothing else.
CANCELABLE = ('READY_FOR_REVIEW', 'WAITING_FOR_EXPORT_COMPLIANCE')

# A screenshot set holds at most this many images (App Store Connect's limit).
SCREENSHOT_SET_CAPACITY = 10

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


def screenshot_swap(existing_ids, new_count, capacity=SCREENSHOT_SET_CAPACITY):
    """Which old screenshots to delete before uploading the new set, and which after.

    Upload first, delete after: a failure part-way through then leaves the locale
    with its old images rather than with none. The set's capacity is the only reason
    to delete anything first, and only as many as the new set needs room for.
    Returns `(delete_before, delete_after)`, both lists of ids, oldest first.
    """
    if new_count <= 0:
        raise Refusal('No new screenshots to upload; refusing to touch the set.')
    if new_count > capacity:
        raise Refusal(f'{new_count} screenshots will not fit: a set holds {capacity}.')
    existing = list(existing_ids)
    overflow = max(0, len(existing) + new_count - capacity)
    if existing and overflow >= len(existing):
        raise Refusal(f'Uploading {new_count} screenshots would empty the set first '
                      f'(it holds {capacity}). Upload fewer.')
    return existing[:overflow], existing[overflow:]
