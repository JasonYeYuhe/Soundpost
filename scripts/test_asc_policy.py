"""Tests for the release decisions in asc_policy.py, and for asc.py actually using them.

Run (CI does exactly this, and fails unless it reports `Ran N tests` with N >= 1):
    python3 -m unittest discover -s scripts -p 'test_*.py' -v

Not a bare `python3 -m unittest`: `scripts/` is not a package, so that finds no tests
here — and on Python < 3.12 it still exits 0 (M20 §4B).

CI cannot import asc.py (it imports `jwt` and `requests` at load), so the second half
of this file reads asc.py's *source* with `ast` and checks that each guard is called
from the command it protects. A guard that exists only in this module protects nothing.
"""
import ast
import os
import re
import unittest

import asc_policy
from asc_policy import Refusal

HERE = os.path.dirname(os.path.abspath(__file__))


def version(string, state, vid=None):
    return {'id': vid or f'id-{string}-{state}',
            'attributes': {'versionString': string, 'appStoreState': state}}


class AppIdentityTests(unittest.TestCase):
    def test_soundpost_is_allowed(self):
        asc_policy.assert_app_identity('6778389097', 'com.soundpost.Soundpost')

    def test_another_app_is_refused(self):
        # ~/.zshrc exports ASC_APP_ID for CLI Pulse Bar; that is the app this stops.
        with self.assertRaises(Refusal) as caught:
            asc_policy.assert_app_identity('123', 'com.clipulse.bar')
        self.assertIn('com.clipulse.bar', str(caught.exception))
        self.assertIn('SOUNDPOST_ASC_APP_ID', str(caught.exception))

    def test_a_missing_bundle_id_is_refused(self):
        with self.assertRaises(Refusal):
            asc_policy.assert_app_identity('123', None)


class PickVersionTests(unittest.TestCase):
    def test_finds_the_named_version_wherever_it_is(self):
        # Eleven records: the old `limit: 10` page could not have held this one.
        versions = [version(f'1.{n}.0', 'READY_FOR_SALE') for n in range(10)]
        versions.append(version('1.10.0', 'PREPARE_FOR_SUBMISSION', 'draft'))
        self.assertEqual(asc_policy.pick_version(versions, '1.10.0')['id'], 'draft')

    def test_absent_is_none(self):
        self.assertIsNone(asc_policy.pick_version([version('1.9.0', 'READY_FOR_SALE')], '1.10.0'))

    def test_two_records_with_one_name_are_refused(self):
        with self.assertRaises(Refusal):
            asc_policy.pick_version([version('1.10.0', 'REJECTED', 'a'),
                                     version('1.10.0', 'PREPARE_FOR_SUBMISSION', 'b')], '1.10.0')


class ReleasableTests(unittest.TestCase):
    def test_releases_the_projects_version_when_approved(self):
        versions = [version('1.9.0', 'READY_FOR_SALE'),
                    version('1.10.0', 'PENDING_DEVELOPER_RELEASE', 'mine')]
        self.assertEqual(asc_policy.releasable(versions, '1.10.0')['id'], 'mine')

    def test_never_releases_a_different_approved_version(self):
        # The old rule took `pending[0]` by state alone.
        versions = [version('1.8.0', 'PENDING_DEVELOPER_RELEASE', 'other'),
                    version('1.10.0', 'WAITING_FOR_REVIEW')]
        with self.assertRaises(Refusal) as caught:
            asc_policy.releasable(versions, '1.10.0')
        message = str(caught.exception)
        self.assertIn('v1.8.0=PENDING_DEVELOPER_RELEASE', message)
        self.assertIn('v1.10.0=WAITING_FOR_REVIEW', message)

    def test_picks_the_projects_version_even_when_it_is_not_first(self):
        versions = [version('1.8.0', 'PENDING_DEVELOPER_RELEASE', 'other'),
                    version('1.10.0', 'PENDING_DEVELOPER_RELEASE', 'mine')]
        self.assertEqual(asc_policy.releasable(versions, '1.10.0')['id'], 'mine')

    def test_nothing_approved_is_refused(self):
        with self.assertRaises(Refusal):
            asc_policy.releasable([version('1.10.0', 'IN_REVIEW')], '1.10.0')

    def test_no_versions_is_refused(self):
        with self.assertRaises(Refusal):
            asc_policy.releasable([], '1.10.0')


class CancelTests(unittest.TestCase):
    def test_a_rejected_submission_is_kept_without_force(self):
        self.assertFalse(asc_policy.may_cancel('UNRESOLVED_ISSUES'))
        self.assertFalse(asc_policy.may_cancel('UNRESOLVED_ISSUES', force=False))
        self.assertTrue(asc_policy.may_cancel('UNRESOLVED_ISSUES', force=True))

    def test_the_rejected_state_is_not_in_the_cancel_set(self):
        self.assertNotIn('UNRESOLVED_ISSUES', asc_policy.CANCELABLE)

    def test_export_compliance_may_be_cancelled_but_a_draft_may_not(self):
        # M21 §13 S6: Apple refuses to cancel a draft that was never submitted (409), and
        # a draft that was submitted before holds the review thread. Neither is cancelled.
        self.assertTrue(asc_policy.may_cancel('WAITING_FOR_EXPORT_COMPLIANCE'))
        self.assertFalse(asc_policy.may_cancel('READY_FOR_REVIEW'))
        self.assertFalse(asc_policy.may_cancel('READY_FOR_REVIEW', force=True))

    def test_apples_queue_is_never_cancelled_from_here(self):
        for state in ('WAITING_FOR_REVIEW', 'IN_REVIEW'):
            self.assertFalse(asc_policy.may_cancel(state, force=True), state)

    def test_finished_submissions_are_left_alone(self):
        for state in ('COMPLETE', 'CANCELING', None):
            self.assertFalse(asc_policy.may_cancel(state, force=True), state)


class SubmitPlanTests(unittest.TestCase):
    def test_a_rejection_prints_the_path_that_keeps_the_thread(self):
        with self.assertRaises(Refusal) as caught:
            asc_policy.submit_plan(['COMPLETE', 'UNRESOLVED_ISSUES'])
        message = str(caught.exception)
        for step in ('attach', 'Update Review', 'Resubmit to App Review', '--force-cancel'):
            self.assertIn(step, message)

    def test_force_proceeds_past_a_rejection(self):
        self.assertEqual(asc_policy.submit_plan(['UNRESOLVED_ISSUES'], force_cancel=True), 'proceed')

    def test_a_submission_with_apple_is_left_alone(self):
        self.assertEqual(asc_policy.submit_plan(['COMPLETE', 'WAITING_FOR_REVIEW']), 'in_review')

    def test_a_clean_slate_proceeds(self):
        self.assertEqual(asc_policy.submit_plan([]), 'proceed')
        self.assertEqual(asc_policy.submit_plan(['COMPLETE', 'READY_FOR_REVIEW']), 'proceed')


def _sub(sid, state, submitted=None):
    return {'id': sid, 'attributes': {'state': state, 'submittedDate': submitted}}


class DraftReuseTests(unittest.TestCase):
    def test_an_unsubmitted_draft_is_finished_not_replaced(self):
        # M21 §13 S6: `submit` created d56ef962, the add-item step 409'd on the age-rating
        # question, and the next `submit` tried to cancel the draft and could not.
        subs = [_sub('old', 'COMPLETE', '2026-10-06T00:00:00Z'), _sub('d56', 'READY_FOR_REVIEW')]
        self.assertEqual(asc_policy.reusable_draft(subs), 'd56')

    def test_no_draft_means_a_new_submission(self):
        self.assertIsNone(asc_policy.reusable_draft([_sub('old', 'COMPLETE', '2026-10-06T00:00:00Z')]))
        self.assertIsNone(asc_policy.reusable_draft([]))

    def test_a_reopened_rejection_is_never_reused(self):
        # A draft that was submitted before is a rejection reopened with "Update Review":
        # it carries the App Review thread (M19 §8-iii). Never finished or cancelled here.
        with self.assertRaises(Refusal) as caught:
            asc_policy.reusable_draft([_sub('r', 'READY_FOR_REVIEW', '2026-10-01T00:00:00Z')])
        self.assertIn('Update Review', str(caught.exception))

    def test_a_reopened_rejection_wins_over_a_fresh_draft(self):
        with self.assertRaises(Refusal):
            asc_policy.reusable_draft([_sub('fresh', 'READY_FOR_REVIEW'),
                                       _sub('r', 'READY_FOR_REVIEW', '2026-10-01T00:00:00Z')])

    def test_two_unsubmitted_drafts_are_refused(self):
        with self.assertRaises(Refusal):
            asc_policy.reusable_draft([_sub('a', 'READY_FOR_REVIEW'), _sub('b', 'READY_FOR_REVIEW')])

    def test_a_draft_is_filled_with_this_version_only(self):
        self.assertEqual(asc_policy.draft_items_plan([], 'v-1.12.0'), 'add')
        self.assertEqual(asc_policy.draft_items_plan(['v-1.12.0'], 'v-1.12.0'), 'submit')
        with self.assertRaises(Refusal):
            asc_policy.draft_items_plan(['v-1.11.0'], 'v-1.12.0')

    def test_an_item_whose_version_cannot_be_read_is_not_assumed_to_be_this_one(self):
        with self.assertRaises(Refusal):
            asc_policy.draft_items_plan([None], 'v-1.12.0')
        with self.assertRaises(Refusal):
            asc_policy.draft_items_plan(['v-1.12.0', None], 'v-1.12.0')


class BuildNumberTests(unittest.TestCase):
    def test_a_higher_number_is_new(self):
        self.assertEqual(asc_policy.build_number_is_new('21', ['20', '19', '3']), 20)

    def test_numbers_compare_as_numbers(self):
        # '9' > '21' as strings; build 9 must not pass as newer than 21.
        with self.assertRaises(Refusal):
            asc_policy.build_number_is_new('9', ['21'])

    def test_a_reused_or_older_number_is_refused(self):
        for local in ('20', '19'):
            with self.assertRaises(Refusal, msg=local):
                asc_policy.build_number_is_new(local, ['20', '18'])

    def test_first_upload_is_new(self):
        self.assertIsNone(asc_policy.build_number_is_new('1', []))

    def test_unreadable_numbers_are_refused(self):
        with self.assertRaises(Refusal):
            asc_policy.build_number_is_new('21a', ['20'])
        with self.assertRaises(Refusal):
            asc_policy.build_number_is_new('21', ['20', '1.0.3'])


def manual(string='1.13.0', state='PREPARE_FOR_SUBMISSION', release='MANUAL'):
    v = version(string, state)
    if release is not None:
        v['attributes']['releaseType'] = release
    return v


class ManualReleaseTests(unittest.TestCase):
    """M23 §4B.1: nothing goes live unless a person presses Release."""

    def test_manual_passes(self):
        v = manual()
        self.assertIs(asc_policy.require_manual_release(v), v)

    def test_after_approval_is_refused(self):
        with self.assertRaises(Refusal) as caught:
            asc_policy.require_manual_release(manual(release='AFTER_APPROVAL'))
        self.assertIn('AFTER_APPROVAL', str(caught.exception))

    def test_scheduled_is_refused(self):
        with self.assertRaises(Refusal) as caught:
            asc_policy.require_manual_release(manual(release='SCHEDULED'))
        self.assertIn('SCHEDULED', str(caught.exception))

    def test_a_missing_release_type_is_refused(self):
        with self.assertRaises(Refusal) as caught:
            asc_policy.require_manual_release(manual(release=None))
        self.assertIn('(none)', str(caught.exception))

    def test_create_version_patches_only_a_draft(self):
        self.assertEqual(asc_policy.release_type_plan(manual()), 'ok')
        self.assertEqual(asc_policy.release_type_plan(manual(release='AFTER_APPROVAL')), 'patch')
        # In review or live, a PATCH would touch a version Apple is looking at: print only.
        self.assertEqual(asc_policy.release_type_plan(
            manual(state='WAITING_FOR_REVIEW', release='AFTER_APPROVAL')), 'report')


class ScreenshotFileTests(unittest.TestCase):
    """M23 §4B.4: upload exactly what screenshots.sh produces, by name."""

    def test_the_captured_names_pass_in_store_order(self):
        names = ['04-capture.png', '01-gallery.png', '03-search.png', '02-detail.png', '.DS_Store']
        self.assertEqual(asc_policy.screenshot_files(names),
                         ['01-gallery.png', '02-detail.png', '03-search.png', '04-capture.png'])

    def test_an_icloud_copy_is_refused_by_name(self):
        # `01-gallery 2.png` sorts before `01-gallery.png`: the old loop uploaded it first.
        names = asc_policy.screenshot_file_names() + ['01-gallery 2.png']
        with self.assertRaises(Refusal) as caught:
            asc_policy.screenshot_files(names)
        self.assertIn('01-gallery 2.png', str(caught.exception))

    def test_a_missing_screen_is_refused(self):
        with self.assertRaises(Refusal) as caught:
            asc_policy.screenshot_files(['01-gallery.png', '02-detail.png', '03-search.png'])
        self.assertIn('missing: 04-capture.png', str(caught.exception))

    def test_screenshots_sh_captures_the_same_screens(self):
        # One list: screenshots.sh reads it from asc_policy rather than keeping its own.
        with open(os.path.join(HERE, 'screenshots.sh'), encoding='utf-8') as f:
            text = f.read()
        self.assertTrue('asc_policy' in text, 'screenshots.sh does not read asc_policy')
        self.assertIsNone(re.search(r'(?m)^SCREENS=\(', text), 'screenshots.sh keeps its own SCREENS list')

    def test_the_display_type_is_one_constant_with_its_size(self):
        self.assertEqual(asc_policy.SCREENSHOT_DISPLAY_TYPE, 'APP_IPHONE_67')
        self.assertEqual(asc_policy.SCREENSHOT_SIZE, (1320, 2868))
        with open(os.path.join(HERE, 'screenshots.sh'), encoding='utf-8') as f:
            text = f.read()
        self.assertFalse(re.search(r'\b1242\b|\b2688\b|APP_IPHONE_6[0-9]', text.split('set -euo pipefail', 1)[1]),
                         'screenshots.sh keeps its own size or type instead of reading asc_policy')

    def test_the_folder_is_outside_icloud(self):
        self.assertNotIn('/Documents/', asc_policy.screenshot_dir())
        self.assertIn('Library/Caches/Soundpost-build/', asc_policy.screenshot_dir())

    def test_a_set_with_images_is_not_replaced(self):
        self.assertEqual(asc_policy.screenshot_target_set_plan([]), 'upload')
        with self.assertRaises(Refusal):
            asc_policy.screenshot_target_set_plan(['old'])



class StalePlacementTests(unittest.TestCase):
    NEW, OLD = asc_policy.SCREENSHOT_PLACEMENT_GROUP, 'IPHONE_FACE_ID_LARGE_PROFILE'

    def rows(self, new, old):
        return ([{'id': f'n{i}', 'group': self.NEW} for i in range(new)]
                + [{'id': f'o{i}', 'group': self.OLD} for i in range(old)])

    def test_the_old_group_goes_once_the_new_one_is_complete(self):
        self.assertEqual(asc_policy.stale_placements(self.rows(4, 4)), ['o0', 'o1', 'o2', 'o3'])

    def test_nothing_goes_while_the_new_group_is_incomplete(self):
        # Removing the old set first could leave a locale with no screenshots at all.
        with self.assertRaises(Refusal) as caught:
            asc_policy.stale_placements(self.rows(3, 4))
        self.assertIn(self.OLD, str(caught.exception))

    def test_an_upload_filed_under_another_group_removes_nothing(self):
        with self.assertRaises(Refusal):
            asc_policy.stale_placements([{'id': 'x', 'group': 'SOMETHING_ELSE'}] * 4)


def app_info(iid, state):
    return {'id': iid, 'attributes': {'state': state}}


class CheckSubmittableTests(unittest.TestCase):
    """M23 §4B.5: every reason a version cannot be submitted, read before submit."""

    LIVE = {k: 'NONE' for k in ('violenceRealistic', 'gamblingSimulated')}
    LIVE.update(socialMedia=False, socialMediaAgeRestricted=None, kidsAgeBand=None,
                developerAgeRatingInfoUrl=None, gracRatingClassificationNumber=None)

    def good(self, **over):
        args = dict(version=manual(), build={'processingState': 'VALID', 'usesNonExemptEncryption': False},
                    whats_new={'en-US': 'x', 'ja': 'x', 'zh-Hans': 'x'},
                    display_types={l: {'APP_IPHONE_67': 4} for l in ('en-US', 'ja', 'zh-Hans')},
                    age_gaps=[])
        args.update(over)
        return asc_policy.submittable_problems(**args)

    def test_a_ready_version_has_no_problems(self):
        self.assertEqual(self.good(), [])

    def test_the_editable_app_info_is_read_even_when_the_live_one_is_listed_first(self):
        infos = [app_info('live', 'READY_FOR_DISTRIBUTION'), app_info('next', 'PREPARE_FOR_SUBMISSION')]
        self.assertEqual(asc_policy.editable_app_info(infos)['id'], 'next')
        declarations = {'live': dict(self.LIVE), 'next': dict(self.LIVE, violenceRealistic=None)}
        gaps = asc_policy.age_rating_gaps(declarations[asc_policy.editable_app_info(infos)['id']])
        self.assertEqual(gaps, ['violenceRealistic'])
        self.assertIn('age rating: violenceRealistic is unanswered on the editable app info',
                      self.good(age_gaps=gaps))

    def test_app_infos_that_cannot_be_told_apart_are_refused(self):
        with self.assertRaises(Refusal):
            asc_policy.editable_app_info([app_info('a', 'PREPARE_FOR_SUBMISSION'), app_info('b', 'WAITING_FOR_REVIEW')])
        with self.assertRaises(Refusal):
            asc_policy.editable_app_info([app_info('live', 'READY_FOR_DISTRIBUTION')])

    def test_a_complete_declaration_has_no_gaps(self):
        self.assertEqual(asc_policy.age_rating_gaps(self.LIVE), [])

    def test_a_follow_up_counts_once_its_question_says_it_applies(self):
        self.assertEqual(asc_policy.age_rating_gaps(dict(self.LIVE, socialMedia=True)), ['socialMediaAgeRestricted'])

    def test_a_stale_display_type_is_reported(self):
        problems = self.good(display_types={'en-US': {'APP_IPHONE_67': 4, 'APP_IPHONE_65': 4},
                                            'ja': {'APP_IPHONE_67': 4}, 'zh-Hans': {'APP_IPHONE_67': 4}})
        self.assertEqual(problems, ['en-US still has a stale APP_IPHONE_65 set (4 image(s))'])

    def test_a_locale_without_the_new_type_is_reported(self):
        problems = self.good(display_types={'en-US': {'APP_IPHONE_65': 4},
                                            'ja': {'APP_IPHONE_67': 4}, 'zh-Hans': {'APP_IPHONE_67': 4}})
        self.assertIn('en-US has no APP_IPHONE_67 screenshots', problems)

    def test_every_other_problem_is_named(self):
        problems = self.good(version=manual(release='AFTER_APPROVAL'), build=None,
                             whats_new={'en-US': 'x', 'ja': '  ', 'zh-Hans': 'x'})
        self.assertIn('releaseType is AFTER_APPROVAL, not MANUAL', problems)
        self.assertIn('no build is attached', problems)
        self.assertIn("What's New is empty in ja", problems)
        problems = self.good(build={'processingState': 'PROCESSING', 'usesNonExemptEncryption': None})
        self.assertEqual(len(problems), 2)


class AnalyticsRequestTests(unittest.TestCase):
    def test_one_ongoing_request_is_planned(self):
        self.assertEqual(asc_policy.analytics_request_plan([]), {'accessType': 'ONGOING'})
        snapshot = {'id': 's', 'attributes': {'accessType': 'ONE_TIME_SNAPSHOT'}}
        self.assertEqual(asc_policy.analytics_request_plan([snapshot]), {'accessType': 'ONGOING'})

    def test_an_existing_ongoing_request_is_not_repeated(self):
        with self.assertRaises(Refusal):
            asc_policy.analytics_request_plan([{'id': 'r', 'attributes': {'accessType': 'ONGOING'}}])



class PromoTests(unittest.TestCase):
    """M23 §4H (D6): promotional text goes to the live listing, so it may carry nothing else."""

    def test_the_patch_body_is_promotional_text_only(self):
        self.assertEqual(asc_policy.promo_attributes('Hello'), {'promotionalText': 'Hello'})

    def test_the_live_version_and_the_one_in_flight(self):
        live = version('1.11.0', 'READY_FOR_SALE')
        for state in ('WAITING_FOR_REVIEW', 'PENDING_DEVELOPER_RELEASE', 'PREPARE_FOR_SUBMISSION'):
            with self.subTest(state):
                flight = version('1.12.0', state)
                self.assertEqual(asc_policy.promo_targets([flight, live], '1.12.0'), [live, flight])

    def test_old_and_other_versions_are_left_alone(self):
        live = version('1.11.0', 'READY_FOR_SALE')
        versions = [live, version('1.10.0', 'REPLACED_WITH_NEW_VERSION'),
                    version('1.13.0', 'PREPARE_FOR_SUBMISSION')]
        self.assertEqual(asc_policy.promo_targets(versions, '1.12.0'), [live])

    def test_a_released_project_version_is_written_once(self):
        live = version('1.12.0', 'READY_FOR_SALE')
        self.assertEqual(asc_policy.promo_targets([live], '1.12.0'), [live])

    def test_nothing_to_write_to_refuses(self):
        with self.assertRaises(Refusal):
            asc_policy.promo_targets([version('1.12.0', 'REPLACED_WITH_NEW_VERSION')], '1.12.0')

    def test_the_live_version_is_the_newest_released_one(self):
        # App Store Connect reports every version that ever shipped as READY_FOR_SALE.
        released = [version(v, 'READY_FOR_SALE') for v in ('1.9.0', '1.11.0', '1.10.0', '1.2.0')]
        flight = version('1.12.0', 'WAITING_FOR_REVIEW')
        self.assertEqual(asc_policy.promo_targets(released + [flight], '1.12.0'), [released[1], flight])

    def test_an_unorderable_version_refuses(self):
        with self.assertRaises(Refusal):
            asc_policy.promo_targets([version('1.11.0', 'READY_FOR_SALE'), version('next', 'READY_FOR_SALE')],
                                     '1.12.0')

# ── asc.py actually calls the guards ─────────────────────────────────────────

def _asc_tree():
    with open(os.path.join(HERE, 'asc.py'), encoding='utf-8') as f:
        return ast.parse(f.read())


def _function(tree, name):
    for node in tree.body:
        if isinstance(node, ast.FunctionDef) and node.name == name:
            return node
    raise AssertionError(f'asc.py has no function {name}()')


def _calls(node):
    """Every name called inside `node`: `f()` gives 'f', `mod.f()` gives 'mod.f' and 'f'."""
    names = set()
    for child in ast.walk(node):
        if isinstance(child, ast.Call):
            func = child.func
            if isinstance(func, ast.Name):
                names.add(func.id)
            elif isinstance(func, ast.Attribute):
                names.add(func.attr)
                if isinstance(func.value, ast.Name):
                    names.add(f'{func.value.id}.{func.attr}')
    return names


def _string_constants(node):
    return {c.value for c in ast.walk(node)
            if isinstance(c, ast.Constant) and isinstance(c.value, str)}


class AscUsesThePolicyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tree = _asc_tree()

    def test_every_write_checks_the_app_first(self):
        req = _function(self.tree, 'req')
        self.assertIn('assert_soundpost_app', _calls(req))
        self.assertIn('asc_policy.assert_app_identity',
                      _calls(_function(self.tree, 'assert_soundpost_app')))

    def test_release_asks_releasable(self):
        release = _function(self.tree, 'cmd_release')
        self.assertIn('asc_policy.releasable', _calls(release))
        self.assertIn('project_marketing_version', _calls(release))
        # No second, local decision by state beside the policy's.
        self.assertNotIn('PENDING_DEVELOPER_RELEASE', _string_constants(release))

    def test_cancel_asks_may_cancel(self):
        self.assertIn('asc_policy.may_cancel', _calls(_function(self.tree, 'cmd_cancel')))

    def test_submit_asks_submit_plan_before_cancelling(self):
        submit = _function(self.tree, 'cmd_submit')
        self.assertIn('asc_policy.submit_plan', _calls(submit))

    def test_submit_finishes_a_draft_and_creates_only_when_there_is_none(self):
        submit = _function(self.tree, 'cmd_submit')
        calls = _calls(submit)
        self.assertIn('asc_policy.reusable_draft', calls)
        self.assertIn('asc_policy.draft_items_plan', calls)
        # The POST that creates a submission, and the cancel before it, sit only in the
        # branch taken when there is no draft to finish.
        creating = [n for n in ast.walk(submit)
                    if isinstance(n, ast.Call) and isinstance(n.func, ast.Name) and n.func.id == 'post'
                    and n.args and isinstance(n.args[0], ast.Constant)
                    and n.args[0].value == '/v1/reviewSubmissions']
        self.assertEqual(len(creating), 1, 'cmd_submit should create a submission in one place')
        branches = [n for n in ast.walk(submit) if isinstance(n, ast.If)
                    and isinstance(n.test, ast.Name) and n.test.id == 'sub_id']
        self.assertEqual(len(branches), 1, 'no `if sub_id:` branch deciding reuse vs create')
        orelse = ast.Module(body=branches[0].orelse, type_ignores=[])
        self.assertIn(creating[0], list(ast.walk(orelse)), 'the create POST runs even with a draft')
        cancels = [n for n in ast.walk(submit)
                   if isinstance(n, ast.Call) and isinstance(n.func, ast.Name) and n.func.id == 'cmd_cancel']
        self.assertEqual(len(cancels), 1, 'cmd_submit should cancel in one place only')
        self.assertIn(cancels[0], list(ast.walk(orelse)),
                      'cmd_submit cancels even when it has a draft to finish')

    def test_the_draft_items_are_read_with_their_versions(self):
        submit = _function(self.tree, 'cmd_submit')
        self.assertIn('appStoreVersion', _string_constants(submit))
        self.assertIn('include', _string_constants(submit))

    def test_no_cancel_set_in_asc_py_holds_the_rejected_state(self):
        for node in self.tree.body:
            if isinstance(node, ast.Assign):
                for target in node.targets:
                    if isinstance(target, ast.Name) and 'CANCEL' in target.id.upper():
                        self.assertNotIn('UNRESOLVED_ISSUES', _string_constants(node.value),
                                         f'{target.id} would cancel a rejected submission')

    def test_versions_are_picked_by_name(self):
        for name in ('editable_version', 'cmd_create_version'):
            self.assertIn('asc_policy.pick_version', _calls(_function(self.tree, name)), name)
        listing = _function(self.tree, 'ios_versions')
        self.assertIn('filter[versionString]', _string_constants(listing))
        limits = [kw for kw in ast.walk(listing)
                  if isinstance(kw, ast.Dict)
                  for k, v in zip(kw.keys, kw.values)
                  if isinstance(k, ast.Constant) and k.value == 'limit']
        self.assertTrue(limits, 'ios_versions sets no limit')
        for d in limits:
            for k, v in zip(d.keys, d.values):
                if isinstance(k, ast.Constant) and k.value == 'limit':
                    self.assertIsInstance(v, ast.Constant)
                    self.assertGreaterEqual(v.value, 200)

    def test_screenshots_never_delete_and_upload_only_what_was_captured(self):
        """M23 §4B.4, §4B.7: no `DELETE /v1/appScreenshots` (its effect on the live
        version's images is undocumented), files by name, from the folder outside iCloud,
        and only into an empty set."""
        shots = _function(self.tree, 'cmd_screenshots')
        self.assertNotIn('DELETE', _string_constants(shots))
        calls = _calls(shots)
        for guard in ('asc_policy.screenshot_files', 'asc_policy.screenshot_target_set_plan',
                      'asc_policy.screenshot_dir'):
            self.assertIn(guard, calls)
        self.assertNotIn('screenshots', _string_constants(shots) & {'screenshots'},
                         "cmd_screenshots builds its own folder path again")
        # The upload loop iterates exactly what the policy accepted.
        accepted = [a for a in ast.walk(shots) if isinstance(a, ast.Call)
                    and isinstance(a.func, ast.Attribute) and a.func.attr == 'screenshot_files']
        self.assertEqual(len(accepted), 1)
        self.assertFalse(any(isinstance(n, ast.Call) and isinstance(n.func, ast.Name)
                             and n.func.id == 'sorted' and 'png' in ast.dump(n) for n in ast.walk(shots)),
                         'cmd_screenshots lists .png files itself instead of asking screenshot_files')

    def test_nothing_in_asc_py_deletes_a_screenshot_or_an_image(self):
        for node in ast.walk(self.tree):
            if isinstance(node, ast.Call) and isinstance(node.func, ast.Name) and node.func.id == 'req' \
                    and node.args and isinstance(node.args[0], ast.Constant) and node.args[0].value == 'DELETE':
                path = ast.unparse(node.args[1])
                self.assertIn('/v1/appAssetLibraryPlacements/', path,
                              f'asc.py deletes something other than a placement: {path}')

    def test_prune_removes_placements_only_with_apply_and_by_the_policy(self):
        prune = _function(self.tree, 'cmd_screenshots_prune')
        self.assertIn('asc_policy.stale_placements', _calls(prune))
        dry = [n for n in prune.body if isinstance(n, ast.If) and ast.unparse(n.test) == 'not apply'
               and any(isinstance(b, ast.Return) for b in n.body)]
        self.assertEqual(len(dry), 1, 'no `if not apply: … return` before the deletes')
        deletes = [n for n in ast.walk(prune) if isinstance(n, ast.Call) and isinstance(n.func, ast.Name)
                   and n.func.id == 'req']
        self.assertTrue(deletes)
        self.assertTrue(all(d.lineno > dry[0].lineno for d in deletes))

    def test_build_number_check_is_wired(self):
        check = _function(self.tree, 'cmd_check_build_number')
        self.assertIn('asc_policy.build_number_is_new', _calls(check))
        # A read, but compared against another app's builds "new" means nothing.
        self.assertIn('assert_soundpost_app', _calls(check))

    # ── M23 §4B.1: MANUAL before any write ───────────────────────────────────
    WRITES = ('post', 'patch', 'cmd_cancel', 'cmd_attach')

    def _writes(self, fn):
        """Every write a function sends, by line: post/patch, req() with a non-GET method,
        and the commands that write (`cmd_cancel` PATCHes `canceled`, `cmd_attach` PATCHes)."""
        out = []
        for n in ast.walk(fn):
            if isinstance(n, ast.Call) and isinstance(n.func, ast.Name):
                if n.func.id in self.WRITES:
                    out.append(n)
                elif n.func.id == 'req' and not (n.args and isinstance(n.args[0], ast.Constant)
                                                  and n.args[0].value == 'GET'):
                    out.append(n)
        return out

    def _manual_guard(self, fn):
        guards = [i for i, stmt in enumerate(fn.body)
                  if isinstance(stmt, ast.Expr) and isinstance(stmt.value, ast.Call)
                  and 'asc_policy.require_manual_release' in _calls(stmt.value)]
        self.assertEqual(len(guards), 1, f'{fn.name}: no top-level require_manual_release(v) statement')
        return guards[0]

    def test_attach_and_submit_refuse_a_non_manual_version_before_any_write(self):
        for name in ('cmd_attach', 'cmd_submit'):
            with self.subTest(name):
                fn = _function(self.tree, name)
                index = self._manual_guard(fn)
                previous = fn.body[index - 1]
                self.assertTrue(isinstance(previous, ast.If) and ast.unparse(previous.test) == 'not v',
                                f'{name}: the guard does not follow the `if not v:` exit')
                guard_line = fn.body[index].lineno
                for write in self._writes(fn):
                    self.assertGreater(write.lineno, guard_line,
                                       f'{name}: {ast.unparse(write.func)}() at line {write.lineno} comes before the MANUAL guard')

    def test_submit_checks_submittability_before_cancelling_or_creating(self):
        submit = _function(self.tree, 'cmd_submit')
        checks = [n for n in ast.walk(submit) if isinstance(n, ast.Call) and isinstance(n.func, ast.Name)
                  and n.func.id == 'submittable_problems']
        self.assertEqual(len(checks), 1)
        first_write = min(w.lineno for w in self._writes(submit))
        self.assertLess(checks[0].lineno, first_write)
        self.assertGreater(checks[0].lineno, submit.body[self._manual_guard(submit)].lineno)

    def test_create_version_posts_manual(self):
        create = _function(self.tree, 'cmd_create_version')
        posts = [n for n in ast.walk(create) if isinstance(n, ast.Call) and isinstance(n.func, ast.Name)
                 and n.func.id == 'post']
        self.assertEqual(len(posts), 1)
        attributes = [v for d in ast.walk(posts[0]) if isinstance(d, ast.Dict)
                      for k, v in zip(d.keys, d.values)
                      if isinstance(k, ast.Constant) and k.value == 'attributes']
        self.assertEqual(len(attributes), 1)
        held = {k.value: v.value for k, v in zip(attributes[0].keys, attributes[0].values)
                if isinstance(k, ast.Constant) and isinstance(v, ast.Constant)}
        self.assertEqual(held.get('releaseType'), 'MANUAL', 'create-version does not send MANUAL')
        self.assertIn('asc_policy.release_type_plan', _calls(create))

    def test_status_shows_the_release_type(self):
        self.assertIn('releaseType', _string_constants(_function(self.tree, 'cmd_status')))

    def test_check_submittable_reads_only_and_checks_the_app_first(self):
        for name in ('cmd_check_submittable', 'submittable_problems'):
            with self.subTest(name):
                fn = _function(self.tree, name)
                self.assertEqual(self._writes(fn), [], f'{name} writes')
                first = fn.body[0] if not isinstance(fn.body[0], ast.Expr) or not isinstance(
                    fn.body[0].value, ast.Constant) else fn.body[1]
                self.assertIn('assert_soundpost_app', _calls(first), f'{name} does not check the app first')
        problems = _function(self.tree, 'submittable_problems')
        for rule in ('asc_policy.editable_app_info', 'asc_policy.age_rating_gaps', 'asc_policy.submittable_problems'):
            self.assertIn(rule, _calls(problems))
        self.assertIn('ageRatingDeclaration', ast.unparse(problems))

    def test_the_analytics_request_is_one_post_and_refuses_a_second(self):
        fn = _function(self.tree, 'cmd_analytics_request')
        self.assertEqual(len(self._writes(fn)), 1)
        plan = [n for n in ast.walk(fn) if isinstance(n, ast.Call) and 'analytics_request_plan' in _calls(n)]
        self.assertTrue(plan)
        self.assertLess(min(p.lineno for p in plan), self._writes(fn)[0].lineno)

    def test_analytics_only_reads(self):
        for name in ('cmd_analytics', 'analytics_requests'):
            self.assertEqual(self._writes(_function(self.tree, name)), [], name)
        self.assertIn('Library/Caches/Soundpost-build/analytics',
                      ast.unparse(next(n for n in self.tree.body if isinstance(n, ast.Assign)
                                       and ast.unparse(n.targets[0]) == 'ANALYTICS_DIR')))

    def test_promo_sends_only_promotional_text_and_reads_it_back(self):
        promo = _function(self.tree, 'cmd_promo')
        self.assertIn('asc_policy.promo_targets', _calls(promo))
        writes = self._writes(promo)
        self.assertEqual([ast.unparse(w.func) for w in writes], ['patch'],
                         'cmd_promo must send exactly one PATCH and never create a localization')
        attributes = [v for d in ast.walk(writes[0]) if isinstance(d, ast.Dict)
                      for k, v in zip(d.keys, d.values)
                      if isinstance(k, ast.Constant) and k.value == 'attributes']
        self.assertEqual(len(attributes), 1)
        self.assertEqual(ast.unparse(attributes[0]), 'asc_policy.promo_attributes(texts[locale])',
                         'the PATCH body is not exactly the policy\'s one-key promo_attributes')
        reads = [n for n in ast.walk(promo) if isinstance(n, ast.Call) and isinstance(n.func, ast.Name)
                 and n.func.id == 'get' and n.lineno > writes[0].lineno]
        self.assertTrue(reads, 'cmd_promo does not read the value back')
        self.assertIn('promotionalText', _string_constants(promo))

    def test_a_refusal_exits_non_zero(self):
        main = _function(self.tree, 'main')
        handlers = [h for h in ast.walk(main) if isinstance(h, ast.ExceptHandler)
                    and isinstance(h.type, ast.Name) and h.type.id == 'Refusal']
        self.assertEqual(len(handlers), 1, 'main() does not catch Refusal')
        handler = handlers[0]
        exits = [c for stmt in handler.body for c in ast.walk(stmt)
                 if isinstance(c, ast.Call) and isinstance(c.func, ast.Attribute)
                 and c.func.attr == 'exit' and isinstance(c.func.value, ast.Name)
                 and c.func.value.id == 'sys']
        self.assertEqual(len(exits), 1, 'the Refusal handler does not call sys.exit')
        # `sys.exit(message)` exits 1 and prints the refusal; `sys.exit()`, `sys.exit(0)`
        # or `sys.exit(None)` would report every refusal as success — and
        # release-preflight.sh reads check-build-number's answer from the exit code.
        args = exits[0].args
        self.assertEqual(len(args), 1, 'sys.exit() without the message exits 0')
        self.assertFalse(isinstance(args[0], ast.Constant) and args[0].value in (0, None, False))
        names_the_refusal = (
            (isinstance(args[0], ast.Name) and args[0].id == handler.name) or
            (isinstance(args[0], ast.Call) and isinstance(args[0].func, ast.Name)
             and args[0].func.id == 'str' and len(args[0].args) == 1
             and isinstance(args[0].args[0], ast.Name) and args[0].args[0].id == handler.name))
        self.assertTrue(names_the_refusal, 'the exit must carry the refusal message')


if __name__ == '__main__':
    unittest.main()
