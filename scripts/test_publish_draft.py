import hashlib
import importlib.util
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('publish_draft', Path(__file__).with_name('publish-draft.py'))
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)
SHA = 'a' * 40


class FakeGitHub:
    def __init__(self, *, draft=True, sha=SHA, existing=True, tag_sha=SHA,
                 publish_during_listing=False, fail_upload=False):
        self.repository = 'hikariatama/libhm'
        self.sha = sha
        self.tags = {'v0.0.1': tag_sha} if tag_sha else {}
        self.releases = [{'id': 1, 'tag_name': 'v0.0.1', 'draft': draft}] if existing else []
        self.assets = {1: [{'id': 2, 'name': 'previous.zip'}]} if existing else {}
        self.publish_during_listing = publish_during_listing
        self.fail_upload = fail_upload
        self.mutations = []

    def pages(self, path):
        if path == '/releases':
            snapshot = [dict(r) for r in self.releases]
            if self.publish_during_listing:
                self.releases[0]['draft'] = False
            return iter(snapshot)
        return iter(list(self.assets[int(path.split('/')[2])]))

    def request(self, method, path, data=None, *, upload=None):
        if method == 'GET':
            return {'object': {'sha': self.sha}}
        self.mutations.append((method, path, data))
        if method != 'POST':
            raise AssertionError('Existing releases, assets and tags must never be mutated')
        if path == '/git/refs':
            tag = data['ref'].removeprefix('refs/tags/')
            if tag in self.tags:
                raise AssertionError('Build tags must be unique')
            self.tags[tag] = data['sha']
            return {}
        if path == '/releases':
            current = dict(data, id=len(self.releases) + 1)
            current['upload_url'] = f"https://uploads.github.com/{current['id']}{{?name}}"
            self.releases.append(current)
            self.assets[current['id']] = []
            return dict(current)
        if upload is not None:
            if self.fail_upload:
                raise RuntimeError('Simulated upload interruption')
            asset = {'id': 3, 'name': upload.name, 'size': upload.stat().st_size,
                     'digest': 'sha256:' + hashlib.sha256(upload.read_bytes()).hexdigest()}
            self.assets[int(path.split('/')[-1].split('?')[0])].append(asset)
            return asset
        raise AssertionError(path)


class DraftReleaseTests(unittest.TestCase):
    def artifacts(self, root):
        package = Path(root) / 'app.zip'
        package.write_bytes(b'synthetic build')
        return release.collect_artifacts(Path(root), ['app.zip'])

    def test_missing_package_fails_before_publishing(self):
        with tempfile.TemporaryDirectory() as root:
            with self.assertRaises(ValueError):
                release.collect_artifacts(Path(root), ['missing.zip'])

    def test_repeated_collection_regenerates_checksums(self):
        with tempfile.TemporaryDirectory() as root:
            self.artifacts(root)
            sums = Path(root) / 'SHA256SUMS.txt'
            sums.write_text('incomplete previous attempt')
            package = Path(root) / 'app.zip'
            package.write_bytes(b'new synthetic build')
            files = release.collect_artifacts(Path(root), ['app.zip'])
            expected = hashlib.sha256(package.read_bytes()).hexdigest() + '  app.zip\n'
            self.assertEqual(sums.read_text(), expected)
            self.assertEqual(set(files), {'app.zip', 'SHA256SUMS.txt'})
            release.collect_artifacts(Path(root), ['app.zip'])
            self.assertEqual(sums.read_text(), expected)

    def test_generated_checksum_symlink_is_rejected_without_writing_target(self):
        with tempfile.TemporaryDirectory() as root, tempfile.TemporaryDirectory() as outside:
            self.artifacts(root)
            sums = Path(root) / 'SHA256SUMS.txt'
            sums.unlink()
            target = Path(outside) / 'target'
            target.write_text('untouched')
            sums.symlink_to(target)
            with self.assertRaises(ValueError):
                release.collect_artifacts(Path(root), ['app.zip'])
            self.assertEqual(target.read_text(), 'untouched')

    def test_unexpected_nested_checksum_is_rejected(self):
        with tempfile.TemporaryDirectory() as root:
            self.artifacts(root)
            nested = Path(root) / 'nested'
            nested.mkdir()
            (nested / 'SHA256SUMS.txt').write_text('not generated here')
            with self.assertRaises(ValueError):
                release.collect_artifacts(Path(root), ['app.zip'])

    def test_rebuild_leaves_previous_draft_tag_and_assets_untouched(self):
        github = FakeGitHub(tag_sha='b' * 40)
        with tempfile.TemporaryDirectory() as root:
            files = self.artifacts(root)
            notes = Path(__file__).with_name('release-notes.md').read_text().strip()
            draft, _ = release.publish(github, '0.0.1', SHA, files, notes=notes)
        self.assertTrue(draft['draft'])
        self.assertEqual(draft['name'], 'libhm v0.0.1 (' + SHA[:12] + ')')
        self.assertEqual(draft['body'], notes)
        self.assertEqual(github.tags['v0.0.1'], 'b' * 40)
        self.assertEqual(github.assets[1], [{'id': 2, 'name': 'previous.zip'}])
        self.assertEqual({a['name'] for a in github.assets[draft['id']]}, {'app.zip', 'SHA256SUMS.txt'})

    def test_manual_publication_during_build_is_not_reverted(self):
        github = FakeGitHub(publish_during_listing=True)
        with tempfile.TemporaryDirectory() as root:
            release.publish(github, '0.0.1', SHA, self.artifacts(root))
        self.assertFalse(github.releases[0]['draft'])
        self.assertEqual(github.tags['v0.0.1'], SHA)
        self.assertEqual(github.assets[1], [{'id': 2, 'name': 'previous.zip'}])

    def test_retry_after_upload_failure_uses_separate_draft(self):
        github = FakeGitHub(fail_upload=True)
        with tempfile.TemporaryDirectory() as root:
            files = self.artifacts(root)
            with self.assertRaisesRegex(RuntimeError, 'interruption'):
                release.publish(github, '0.0.1', SHA, files)
            github.fail_upload = False
            current, _ = release.publish(github, '0.0.1', SHA, release.collect_artifacts(Path(root), ['app.zip']))
        self.assertEqual(len(github.releases), 3)
        self.assertEqual(len(github.tags), 3)
        self.assertEqual(github.assets[2], [])
        self.assertEqual(len(github.assets[current['id']]), 2)

    def test_first_release_starts_as_draft(self):
        github = FakeGitHub(existing=False, tag_sha=None)
        with tempfile.TemporaryDirectory() as root:
            current, _ = release.publish(github, '0.0.1', SHA, self.artifacts(root))
        self.assertTrue(current['draft'])
        self.assertTrue(current['tag_name'].startswith('v0.0.1-build-' + SHA + '-'))
        self.assertEqual(github.tags[current['tag_name']], SHA)

    def test_published_release_is_untouched(self):
        github = FakeGitHub(draft=False)
        with self.assertRaisesRegex(RuntimeError, 'already published'):
            release.publish(github, '0.0.1', SHA, {})
        self.assertEqual(github.mutations, [])

    def test_published_build_blocks_same_version(self):
        github = FakeGitHub(draft=False)
        github.releases[0]['tag_name'] = 'v0.0.1-build-' + SHA + '-unique'
        with self.assertRaisesRegex(RuntimeError, 'already published'):
            release.publish(github, '0.0.1', SHA, {})
        self.assertEqual(github.mutations, [])

    def test_tag_trigger_cannot_publish_even_matching_main(self):
        github = FakeGitHub()
        with self.assertRaises(ValueError):
            release.publish(github, '0.0.1', SHA, {}, ref='refs/tags/v0.0.1')
        self.assertEqual(github.mutations, [])

    def test_unowned_version_tag_is_untouched(self):
        github = FakeGitHub(existing=False, tag_sha='b' * 40)
        with tempfile.TemporaryDirectory() as root:
            release.publish(github, '0.0.1', SHA, self.artifacts(root))
        self.assertEqual(github.tags['v0.0.1'], 'b' * 40)

    def test_stale_build_cannot_create_draft(self):
        github = FakeGitHub(sha='b' * 40)
        with self.assertRaises(RuntimeError):
            release.publish(github, '0.0.1', SHA, {})
        self.assertEqual(github.mutations, [])


if __name__ == '__main__':
    unittest.main()
