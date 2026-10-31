#!/usr/bin/env python3
"""Check GitBook navigation, relative links, markup, and executable examples."""
import argparse
from collections import Counter
from pathlib import Path
import re
import sys
from urllib.parse import unquote, urlsplit

ROOT = Path(__file__).resolve().parents[1]
FENCE = re.compile(r"^```([^\n]*)\n(.*?)^```[ \t]*$", re.M | re.S)
LINK = re.compile(r"(?<!!)\[[^\]\n]+\]\(([^)\s]+)(?:\s+\"[^\"]*\")?\)|href=\"([^\"]+)\"")
EXAMPLE = re.compile(r"<!-- example: ([a-z_/]+\.cr) -->\s*```crystal\n(.*?)^```", re.M | re.S)
ILLUSTRATIVE = re.compile(r"<!-- illustrative: [^\n]+ -->\s*$")
PAIRS = {"hint": "endhint", "tabs": "endtabs", "tab": "endtab", "code": "endcode"}


def anchors(text):
    counts = Counter()
    result = set()
    for heading in re.findall(r"^#{1,6}\s+(.+)$", FENCE.sub("", text), re.M):
        explicit = re.search(r"\{#([^}]+)\}", heading)
        slug = explicit[1] if explicit else re.sub(r"[^\w -]", "", heading.lower()).replace(" ", "-")
        count = counts[slug]
        counts[slug] += 1
        result.add(f"{slug}-{count}" if count else slug)
    return result


def markup_errors(text):
    errors = []
    if len(re.findall(r"^```", text, re.M)) != 2 * len(FENCE.findall(text)):
        errors.append("unclosed or unsupported code fence")
    stack = []
    for tag in re.findall(r"\{%\s*(\w+).*?%\}", FENCE.sub("", text)):
        if tag in PAIRS:
            stack.append(PAIRS[tag])
        elif tag in PAIRS.values():
            if not stack or stack.pop() != tag:
                errors.append(f"unbalanced GitBook tag: {tag}")
    if stack:
        errors.append("unclosed GitBook block")
    for line in text.splitlines():
        if "[Screenshot:" in line and not re.fullmatch(r"\[Screenshot: [^\[\]\n]+\]", line):
            errors.append("invalid screenshot placeholder")
    for fence in FENCE.finditer(text):
        if fence[1] == "crystal":
            prefix = text[:fence.start()]
            if not re.search(r"<!-- example: [a-z_/]+\.cr -->\s*$", prefix) and not ILLUSTRATIVE.search(prefix):
                errors.append("Crystal block needs an executable example or illustrative marker")
    return errors


def check(root):
    docs = root / "docs"
    errors = []
    config = root / ".gitbook.yaml"
    if not config.exists() or not re.search(r"^root: \./docs/$", config.read_text(), re.M):
        errors.append(".gitbook.yaml must use ./docs/")
    elif not all(re.search(rf"^  {key}: {value}$", config.read_text(), re.M)
                 for key, value in (("readme", "README.md"), ("summary", "SUMMARY.md"))):
        errors.append("GitBook readme/summary configuration is missing")
    summary = docs / "SUMMARY.md"
    if not summary.exists():
        return errors + ["missing docs/SUMMARY.md"]
    pages = {path.resolve() for path in docs.rglob("*.md") if path.name != "SUMMARY.md" and "api" not in path.relative_to(docs).parts}
    navigation = [(docs / (a or b)).resolve() for a, b in LINK.findall(summary.read_text())]
    for page in sorted(pages - set(navigation)):
        errors.append(f"page missing from SUMMARY: {page.relative_to(root)}")
    if len(navigation) != len(set(navigation)):
        errors.append("duplicate SUMMARY destination")
    seen_examples = set()
    for page in sorted(pages | {summary.resolve()}):
        text = page.read_text()
        relative = page.relative_to(root)
        for error in markup_errors(text):
            errors.append(f"{relative}: {error}")
        if page.name not in ("SUMMARY.md", "releasing.md"):
            if not re.match(r"---\ndescription: [^\n]+\n---\n", text):
                errors.append(f"{relative}: missing page description")
            if len(re.findall(r"^# ", FENCE.sub("", text), re.M)) != 1:
                errors.append(f"{relative}: expected one H1")
        for a, b in LINK.findall(FENCE.sub("", text)):
            url = urlsplit(a or b)
            if url.scheme or url.netloc:
                continue
            target = (page.parent / unquote(url.path)).resolve() if url.path else page
            if not target.is_relative_to(root.resolve()):
                errors.append(f"{relative}: link escapes repository: {a or b}")
            elif not target.is_file():
                errors.append(f"{relative}: missing target: {a or b}")
            elif url.fragment and target.suffix == ".md" and unquote(url.fragment) not in anchors(target.read_text()):
                errors.append(f"{relative}: missing anchor: {a or b}")
        for match in EXAMPLE.finditer(text):
            name, code = match.groups()
            source = root / "examples" / "docs" / name
            seen_examples.add(name)
            if not source.is_file() or source.read_text() != code:
                errors.append(f"{relative}: example differs from examples/docs/{name}")
    for required in ("core/first_job.cr", "core/scheduled_jobs.cr", "pro/first_workflow.cr", "pro/workflow_dsl.cr", "core/thin_job.cr",
                     "pro/approval_workflow.cr", "pro/compensation_workflow.cr", "pro/production_worker.cr", "pro/worker_probe.cr"):
        if required not in seen_examples:
            errors.append(f"missing executable quick-start example: {required}")
    for section in ("introduction", "quick-start", "core", "pro", "configuration", "best-practices",
                    "guides", "design-patterns", "production-deployment", "joobq-cloud"):
        if not (docs / section).is_dir():
            errors.append(f"missing required section: {section}")
    return errors


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=ROOT)
    args = parser.parse_args()
    errors = check(args.root.resolve())
    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    print("PASS GitBook navigation, links, markup, and executable examples")
    return 0


if __name__ == "__main__":
    sys.exit(main())
