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

    def test_drafts_may_be_cancelled(self):
        self.assertTrue(asc_policy.may_cancel('READY_FOR_REVIEW'))
        self.assertTrue(asc_policy.may_cancel('WAITING_FOR_EXPORT_COMPLIANCE'))

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


class ScreenshotSwapTests(unittest.TestCase):
    def test_five_over_five_uploads_before_deleting_anything(self):
        before, after = asc_policy.screenshot_swap(['a', 'b', 'c', 'd', 'e'], 5)
        self.assertEqual(before, [])
        self.assertEqual(after, ['a', 'b', 'c', 'd', 'e'])

    def test_only_the_overflow_goes_first(self):
        before, after = asc_policy.screenshot_swap(['a', 'b', 'c', 'd', 'e', 'f'], 5)
        self.assertEqual(before, ['a'])
        self.assertEqual(after, ['b', 'c', 'd', 'e', 'f'])

    def test_an_empty_set_takes_a_full_upload(self):
        self.assertEqual(asc_policy.screenshot_swap([], 10), ([], []))

    def test_a_swap_that_would_empty_the_locale_is_refused(self):
        with self.assertRaises(Refusal):
            asc_policy.screenshot_swap(['a', 'b'], 10)

    def test_nothing_or_too_much_is_refused(self):
        with self.assertRaises(Refusal):
            asc_policy.screenshot_swap(['a'], 0)
        with self.assertRaises(Refusal):
            asc_policy.screenshot_swap([], 11)


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

    def test_screenshots_upload_before_deleting(self):
        """Not only that the policy is asked — that its answer is what asc.py obeys.

        Calling `screenshot_swap` and then deleting `old_ids` before the upload would
        bring back the old delete-first behaviour with this test still finding the call.
        So: the only deletions before the upload loop iterate `delete_before`, the only
        ones after it iterate `delete_after`, and `old_ids` is never deleted directly.
        """
        shots = _function(self.tree, 'cmd_screenshots')
        self.assertIn('asc_policy.screenshot_swap', _calls(shots))
        swap = [a for a in ast.walk(shots) if isinstance(a, ast.Assign)
                and isinstance(a.value, ast.Call) and 'screenshot_swap' in _calls(a.value)]
        self.assertEqual(len(swap), 1)
        self.assertEqual([e.id for e in swap[0].targets[0].elts], ['delete_before', 'delete_after'])

        leaf_loops = [f for f in ast.walk(shots) if isinstance(f, ast.For)
                      and not any(isinstance(n, ast.For) for n in ast.walk(f) if n is not f)]
        uploads = [f for f in leaf_loops if '/v1/appScreenshots' in _string_constants(f)
                   and 'post' in _calls(f)]
        deletes = [f for f in leaf_loops if 'DELETE' in _string_constants(f)]
        self.assertEqual(len(uploads), 1, 'expected one upload loop')
        upload_line = uploads[0].lineno
        before = [f.iter.id for f in deletes if f.lineno < upload_line]
        after = [f.iter.id for f in deletes if f.lineno > upload_line]
        self.assertEqual(before, ['delete_before'])
        self.assertEqual(after, ['delete_after'])

    def test_build_number_check_is_wired(self):
        check = _function(self.tree, 'cmd_check_build_number')
        self.assertIn('asc_policy.build_number_is_new', _calls(check))
        # A read, but compared against another app's builds "new" means nothing.
        self.assertIn('assert_soundpost_app', _calls(check))

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
