import tempfile
import unittest
from pathlib import Path

from check_docs import anchors, check, gitbook_errors, landing_errors, markup_errors


class DocumentationChecks(unittest.TestCase):
    def test_gitbook_nesting(self):
        self.assertEqual([], markup_errors('{% tabs %}\n{% tab title="Core" %}\n{% hint style="info" %}Text{% endhint %}\n{% endtab %}\n{% endtabs %}'))
        self.assertTrue(markup_errors('{% tabs %}{% tab title="Core" %}{% endtabs %}'))

    def test_code_fences_and_example_markers(self):
        self.assertTrue(markup_errors('```crystal\nputs "hello"\n'))
        self.assertTrue(markup_errors('```crystal\nputs "hello"\n```'))
        self.assertEqual([], markup_errors('<!-- illustrative: inside an application -->\n```crystal\nputs "hello"\n```'))

    def test_screenshot_contract(self):
        self.assertEqual([], markup_errors('[Screenshot: A terminal displaying one completed job.]'))
        self.assertTrue(markup_errors('[Screenshot: A terminal'))

    def test_heading_anchors_ignore_code(self):
        self.assertEqual({'setup', 'setup-1', 'cli--tokens'}, anchors('# Setup\n## Setup\n## CLI & tokens\n```sh\n# Not a heading\n```'))

    def test_broken_links_navigation_and_examples(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            docs = root / 'docs'
            docs.mkdir()
            (root / '.gitbook.yaml').write_text('root: ./docs/\nstructure:\n  readme: README.md\n  summary: SUMMARY.md\n')
            (docs / 'SUMMARY.md').write_text('* [Introduction](README.md)\n')
            (docs / 'README.md').write_text('---\ndescription: Test.\n---\n# Intro\n[Bad](missing.md)\n[Escape](../../outside.md)\n[Anchor](README.md#missing)\n<!-- example: core/first_job.cr -->\n```crystal\nputs "changed"\n```\n')
            (docs / 'orphan.md').write_text('# Orphan\n')
            errors = '\n'.join(check(root))
            for expected in ('page missing from SUMMARY', 'missing target', 'link escapes repository', 'missing anchor', 'example differs'):
                self.assertIn(expected, errors)

    def test_gitbook_configuration(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'docs' / 'how-to').mkdir(parents=True)
            (root / 'docs' / 'how-to' / 'new.md').write_text('# New\n')
            (root / 'docs' / 'how-to' / 'live.md').write_text('# Live\n')
            space = 'root: ./docs/\nstructure:\n  readme: README.md\n  summary: SUMMARY.md\n'
            site = 'site:\n  structure:\n    - type: space\n      key: space-docs\n      content:\n        directory: ./docs\n'
            (root / '.gitbook.yaml').write_text(space + 'redirects:\n  old: how-to/new.md\n  # a comment\n  gone: how-to/missing.md\n'
                                                  '  how-to/live: how-to/new.md\n  old: how-to/live.md\n')
            (root / 'gitbook-docs.yaml').write_text(site.replace('./docs', './elsewhere'))
            errors = '\n'.join(gitbook_errors(root))
            for expected in ('redirect target missing: gone -> how-to/missing.md', 'redirect source is a live page: how-to/live',
                             'duplicate redirect source: old', 'gitbook-docs.yaml: directory does not exist: ./elsewhere',
                             'gitbook-docs.yaml: no space maps ./docs/'):
                self.assertIn(expected, errors)
            (root / '.gitbook.yaml').write_text(space + 'redirects:\n  old: how-to/new.md\n')
            (root / 'gitbook-docs.yaml').write_text(site)
            self.assertEqual([], gitbook_errors(root))
            (root / '.gitbook.yaml').write_text('redirects:\n  old: ../outside.md\n' + space)
            (root / 'gitbook-docs.yaml').write_text(site.replace('./docs', '"./docs"'))
            self.assertEqual(['.gitbook.yaml: redirect target missing: old -> ../outside.md'], gitbook_errors(root))
            (root / '.gitbook.yaml').write_text(space + 'redirects:\n  old: how-to/new.md\n')
            self.assertEqual([], gitbook_errors(root))  # a quoted directory is the same directory
            (root / 'gitbook-docs.yaml').unlink()
            self.assertEqual(['missing gitbook-docs.yaml'], gitbook_errors(root))

    def test_section_landing_lists_each_page_with_scope(self):
        with tempfile.TemporaryDirectory() as directory:
            section = Path(directory) / 'docs' / 'how-to'
            section.mkdir(parents=True)
            (section / 'a.md').write_text('# A\n')
            (section / 'b.md').write_text('# B\n')
            (section / 'README.md').write_text('# How-to\n## Core\n* [A](a.md) · Core\n* Later · Pro · coming soon\n'
                                               '* [Console](https://example.com/docs/x) · JoobQUI\n')
            errors = '\n'.join(landing_errors(section))
            self.assertIn('must list b.md exactly once', errors)
            (section / 'README.md').write_text('# How-to\n## Core\n* [A](a.md) · Core\n* [B](b.md) · Core · Preview\n')
            self.assertEqual([], landing_errors(section))
            (section / 'README.md').write_text('# How-to\n## Elsewhere\n* [A](a.md)\n* Later · Pro\n* [B](b.md) · Core\n')
            errors = '\n'.join(landing_errors(section))
            for expected in ('unknown area', 'malformed entry: * [A](a.md)', 'must be marked coming soon'):
                self.assertIn(expected, errors)


if __name__ == '__main__':
    unittest.main()
