import os, pty, select, time, re, signal, shlex
from pathlib import Path

module = Path(__file__).resolve().parents[1] / "Sources/ScrollFix/Resources/scrollfix-selection.zsh"
pid, fd = pty.fork()
if pid == 0:
    env = dict(os.environ, TERM='xterm-256color', LC_ALL='en_US.UTF-8', ZDOTDIR='/private/tmp')
    os.execve('/bin/zsh', ['zsh', '-dfi'], env)

def receive(pattern, timeout=5):
    end = time.monotonic() + timeout
    data = b''
    while time.monotonic() < end:
        ready, _, _ = select.select([fd], [], [], max(0, end-time.monotonic()))
        if not ready: break
        data += os.read(fd, 8192)
        found = re.search(pattern, data)
        if found: return found
    raise AssertionError('Isolated zsh did not produce expected QA state: '+repr(data[-1500:]))

try:
    setup = "PROMPT='SFQA> '; RPROMPT=''; unset HISTFILE; bindkey -e; source "+shlex.quote(str(module))+"; _scrollfix_snapshot() { print -r -- \"SF_STATE:${CURSOR}:${MARK}:${REGION_ACTIVE}:${#BUFFER}\"; BUFFER=''; CURSOR=0; MARK=0; REGION_ACTIVE=0; zle .redisplay; }; zle -N scrollfix-snapshot _scrollfix_snapshot; bindkey -M emacs $'\\e[99~' scrollfix-snapshot; print SF_READY\n"
    os.write(fd, setup.encode())
    receive(rb'\r?\nSF_READY\r?\n')
    cases = [
        ('Shift+Home', 'alpha beta', b'\x1b[1;2H', (0,10,1,10)),
        ('Shift+End', 'alpha beta', b'\x1b[D'*3+b'\x1b[1;2F', (10,7,1,10)),
        ('Repeated selection keeps anchor', 'alpha beta', b'\x1b[D'*3+b'\x1b[1;2H\x1b[1;2H\x1b[1;2F', (10,7,1,10)),
        ('Unicode character offsets', 'äö ü', b'\x1b[1;2H', (0,4,1,4)),
    ]
    for title, fixture, sequence, expected in cases:
        os.write(fd, fixture.encode()+sequence+b'\x1b[99~')
        result = receive(rb'SF_STATE:(\d+):(\d+):(\d+):(\d+)')
        actual = tuple(int(v) for v in result.groups())
        assert actual == expected, (title, actual, expected)
        print(title+': PASS')
finally:
    os.kill(pid, signal.SIGKILL)
    os.waitpid(pid, 0)
    os.close(fd)
