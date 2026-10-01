#!/usr/bin/env bats
# The README and docs/ link only to files and headings that exist.

load ../helpers

@test "every relative link in the README and docs/ resolves, headings included" {
    command -v python3 >/dev/null || skip "needs python3"
    cd "$REPO_ROOT"
    run python3 - README.md docs/*.md docker/modes/README.md <<'PYTHON'
import os, re, sys
def slug(heading):  # GitHub's anchor for a heading
    return re.sub(r'[^\w\- ]', '', heading.strip().lower()).replace(' ', '-')
def anchors(path):
    found, fence = set(), False
    for line in open(path):
        if line.startswith('```'):
            fence = not fence
        elif not fence and re.match(r'#{1,6} ', line):
            found.add(slug(re.sub(r'^#+ ', '', line)))
    return found
bad = []
for f in sys.argv[1:]:
    for target in re.findall(r'\]\(([^)\s]+)\)', open(f).read()):
        if re.match(r'[a-z]+:', target):
            continue
        path, _, anchor = target.partition('#')
        dest = os.path.normpath(os.path.join(os.path.dirname(f), path)) if path else f
        if not os.path.exists(dest):
            bad.append(f'{f}: {target} (no such file)')
        elif anchor and anchor not in anchors(dest):
            bad.append(f'{f}: {target} (no such heading)')
print('\n'.join(bad))
sys.exit(1 if bad else 0)
PYTHON
    assert_success
}
