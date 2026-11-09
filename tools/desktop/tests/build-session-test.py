#!/usr/bin/env python3
"""Exercise source and output safety checks of the session build helper."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

repo = Path(__file__).resolve().parents[3]
helper = repo / 'tools/desktop/build-session.sh'
source = repo / 'contrib/gershwin-components/gershwin-session/gershwin-session.m'
if not source.is_file():
    raise SystemExit('missing pinned source: initialize contrib/gershwin-components')

with tempfile.TemporaryDirectory() as directory:
    work = Path(directory)
    bindir = work / 'bin'
    bindir.mkdir()
    config = bindir / 'gnustep-config'
    config.write_text('#!/bin/sh\nexit 0\n')
    config.chmod(0o755)
    compiler = bindir / 'fake-cc'
    compiler.write_text('''#!/bin/sh
while [ "$#" -gt 0 ]; do
    if [ "$1" = -o ]; then shift; printf binary > "$1"; exit 0; fi
    shift
done
exit 1
''')
    compiler.chmod(0o755)
    env = dict(os.environ, PATH=str(bindir) + os.pathsep + os.environ['PATH'],
               CC='fake-cc', CFLAGS='', LDFLAGS='')
    output = work / 'session'
    def run(input_path, output_path):
        return subprocess.run([str(helper), str(input_path), str(output_path)],
                              env=env, capture_output=True, text=True)
    result = run(source, output)
    assert result.returncode == 0, result.stderr
    assert output.read_bytes() == b'binary'
    assert output.stat().st_mode & 0o111
    assert sorted(p.name for p in work.iterdir()) == ['bin', 'session']
    assert run(source, output).returncode != 0
    assert output.read_bytes() == b'binary'
    bad_source = work / 'modified.m'
    shutil.copyfile(source, bad_source)
    with bad_source.open('a') as f:
        f.write('\n')
    assert run(bad_source, work / 'bad-output').returncode != 0
    assert not (work / 'bad-output').exists()
    print('build-session safety checks: ok')
