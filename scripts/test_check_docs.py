import tempfile
import unittest
from pathlib import Path

from check_docs import anchors, check, landing_errors, markup_errors


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
