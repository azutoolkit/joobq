#!/usr/bin/env python3
"""Check GitBook navigation, relative links, markup, and executable examples."""
import argparse
import os
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
SPEC_REFERENCE = re.compile(r'`(spec/[\w/.]+\.cr)` "([^"\n]+)"')
PAIRS = {"hint": "endhint", "tabs": "endtabs", "tab": "endtab", "code": "endcode", "stepper": "endstepper", "step": "endstep"}
SECTIONS = ("tutorials", "how-to", "reference", "explanation")
AREAS = ("Getting Started", "Core", "Advanced", "Production Ops")
# "* [Label](page.md) · Core · Pro" or "* Label · Pro · coming soon"; labels are scopes, then Preview or coming soon.
ENTRY = re.compile(r"\* (?:\[[^\]]+\]\((?P<target>[^)\s]+)\)|[^\[\]·]+?)"
                   r"(?P<labels>(?: · (?:Core|Pro|JoobQUI))+(?: · (?:Preview|coming soon))?)")


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


def gitbook_errors(root):
    """The two Git Sync files: .gitbook.yaml (docs root, readme/summary, redirects) and gitbook-docs.yaml (site mapping)."""
    errors = []
    config = root / ".gitbook.yaml"
    text = config.read_text() if config.exists() else ""
    if not re.search(r"^root: \./docs/$", text, re.M):
        errors.append(".gitbook.yaml must use ./docs/")
    elif not all(re.search(rf"^  {key}: {value}$", text, re.M) for key, value in (("readme", "README.md"), ("summary", "SUMMARY.md"))):
        errors.append("GitBook readme/summary configuration is missing")
    docs = root / "docs"
    block = re.search(r"^redirects:[ \t]*$", text, re.M)
    redirects = text[block.end():] if block else ""
    sources = set()
    for line in redirects.splitlines():
        if line and not line[0].isspace() and not line.startswith("#"):
            break  # the next top-level key
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        entry = re.fullmatch(r"  ([\w/.-]+): ([\w/.-]+\.md)", line)
        if not entry:
            errors.append(f".gitbook.yaml: malformed redirect: {line.strip()}")
            continue
        source, target = entry.groups()
        if source in sources:
            errors.append(f".gitbook.yaml: duplicate redirect source: {source}")
        sources.add(source)
        if not (docs / target).resolve().is_relative_to(docs.resolve()) or not (docs / target).is_file():
            errors.append(f".gitbook.yaml: redirect target missing: {source} -> {target}")
        if (docs / f"{source}.md").is_file() or (docs / source / "README.md").is_file():
            errors.append(f".gitbook.yaml: redirect source is a live page: {source}")
    site = root / "gitbook-docs.yaml"
    if not site.exists():
        return errors + ["missing gitbook-docs.yaml"]
    directories = [name.strip("\"'") for name in re.findall(r"^\s+directory: (\S+)\s*$", site.read_text(), re.M)]
    for directory in directories:
        if not (root / directory).is_dir():
            errors.append(f"gitbook-docs.yaml: directory does not exist: {directory}")
    if not any((root / directory).resolve() == docs.resolve() for directory in directories):
        errors.append("gitbook-docs.yaml: no space maps ./docs/")
    return errors


def nodoc_errors(root):
    """`:nodoc:` hides a member from `crystal docs` only as the first line of its comment block."""
    errors = []
    source = root / "src"
    for path in sorted(source.rglob("*.cr")) if source.is_dir() else []:
        previous_comment = False
        for number, line in enumerate(path.read_text().splitlines(), 1):
            comment = line.lstrip().startswith("#")
            if comment and line.lstrip().startswith("# :nodoc:") and previous_comment:
                errors.append(f"{path.relative_to(root)}:{number}: `:nodoc:` must be the first line of its comment")
            previous_comment = comment
    return errors


SPEC_TITLE = re.compile(r'^[ \t]*(?:describe|context|it|pending)[ \t]*\(?[ \t]*"((?:[^"\\\n]|\\.)*)"', re.M)
GUARANTEES = Path("docs") / "reference" / "delivery-guarantees.md"


def spec_reference_errors(root):
    """A cited spec, `spec/x_spec.cr` "name", exists and has a describe/context/it title containing the name (a comment does not count).
    docs/reference/delivery-guarantees.md must cite at least one."""
    errors = []
    docs = root / "docs"
    for page in sorted(docs.rglob("*.md")) if docs.is_dir() else []:
        citations = SPEC_REFERENCE.findall(FENCE.sub("", page.read_text()))
        if page.relative_to(root) == GUARANTEES and not citations:
            errors.append(f"{GUARANTEES}: cites no spec")
        for path, name in citations:
            source = root / path
            if not source.is_file():
                errors.append(f"{page.relative_to(root)}: spec file missing: {path}")
            elif not any(name in title for title in SPEC_TITLE.findall(source.read_text())):
                errors.append(f"{page.relative_to(root)}: {path} has no describe/it title containing \"{name}\"")
    return errors


def row_errors(page_text, label, manifest, source, required):
    """The version in the `label` row of the versions table is the one in `manifest` (a shard.yml)."""
    declared = re.search(r"^version:\s*(\S+)\s*$", manifest.read_text(), re.M)
    row = re.search(rf"^\| {re.escape(label)} \| ([^|]+)\|", page_text, re.M)
    if not declared:
        return [f"{manifest}: no version"]
    if not row:
        return [f"docs/reference/compatibility.md: no `{label}` row in the versions table"] if required else []
    documented = re.match(r"\s*(\d+\.\d+\.\d+)(?:,\s*tag `v(\d+\.\d+\.\d+)`)?", row[1])
    if not documented or {documented[1], documented[2] or documented[1]} != {declared[1]}:
        return [f"docs/reference/compatibility.md documents {label} {row[1].strip()}, {source} declares {declared[1]}"]
    return []


PRO_NOT_CHECKED = "Pro row not checked (no joobq-pro checkout)"


def pro_manifest(root, pro_checkout=None):
    """shard.yml of a joobq-pro checkout (the given one, JOOBQ_PRO_CHECKOUT, or a sibling of the repository), or None."""
    manifest = Path(pro_checkout or os.environ.get("JOOBQ_PRO_CHECKOUT") or root.parent / "joobq-pro") / "shard.yml"
    return manifest if manifest.is_file() else None


def compatibility_errors(root, pro_checkout=None):
    """docs/reference/compatibility.md names the shard.yml version of JoobQ (Core), and of JoobQ Pro when its checkout is at hand."""
    manifest = root / "shard.yml"
    page = root / "docs" / "reference" / "compatibility.md"
    if not manifest.is_file() or not page.is_file():
        return []
    text = page.read_text()
    errors = row_errors(text, "JoobQ (Core)", manifest, "shard.yml", True)
    pro = pro_manifest(root, pro_checkout)
    if pro:
        errors += row_errors(text, "JoobQ Pro", pro, "joobq-pro/shard.yml", False)
    return errors


def check(root):
    docs = root / "docs"
    errors = []
    errors += gitbook_errors(root)
    errors += compatibility_errors(root)
    errors += nodoc_errors(root)
    errors += spec_reference_errors(root)
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
    for section in SECTIONS:
        if not (docs / section / "README.md").is_file():
            errors.append(f"missing required section: {section}")
            continue
        errors += landing_errors(docs / section)
    return errors


def landing_errors(section):
    """A section README lists each of its pages once, grouped by area, with scope labels (the website reads it)."""
    errors = []
    relative = section.relative_to(section.parents[1])
    listed = []
    area = None
    for line in (section / "README.md").read_text().splitlines():
        if line.startswith("## "):
            area = line[3:]
            if area not in AREAS:
                errors.append(f"{relative}/README.md: unknown area: {area}")
        elif line.startswith("* "):
            match = ENTRY.fullmatch(line)
            if area is None or not match:
                errors.append(f"{relative}/README.md: malformed entry: {line}")
                continue
            target = match["target"]
            if target and not urlsplit(target).scheme:
                listed.append(target)
            elif not target and "coming soon" not in match["labels"]:
                errors.append(f"{relative}/README.md: an entry without a link must be marked coming soon: {line}")
    pages = sorted(path.name for path in section.glob("*.md") if path.name != "README.md")
    for page in pages:
        if listed.count(page) != 1:
            errors.append(f"{relative}/README.md: must list {page} exactly once")
    for target in sorted(set(listed) - set(pages)):
        errors.append(f"{relative}/README.md: lists a page outside the section: {target}")
    return errors


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=ROOT)
    args = parser.parse_args()
    errors = check(args.root.resolve())
    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    if not pro_manifest(args.root.resolve()):
        print(f"NOTE {PRO_NOT_CHECKED}: joobq-pro is private, so CI cannot check the version of the JoobQ Pro row of docs/reference/compatibility.md")
    print("PASS GitBook navigation, links, markup, and executable examples")
    return 0


if __name__ == "__main__":
    sys.exit(main())
