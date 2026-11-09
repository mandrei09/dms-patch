#!/usr/bin/python3
"""Excerpt of a text file as Qt-RichText HTML in VS Code Dark Modern.

    usage: highlight.py PATH code|markdown

Called by ~/.local/bin/dms-file-details for the DMS launcher details pane.
Prints an HTML fragment for a QML Text item (Text.RichText), which supports
only a subset of HTML/CSS: inline styles, <pre>, <table>, <h1-6>, font sizes
by keyword. Run with python -I (no user site / cwd on sys.path), which is
why the shared style is loaded by path.

Memory: the pane only needs what fits on screen plus some scroll, and Qt lays
out rich text eagerly (a span per token), so the input is capped HARD before
anything is parsed -- MAX_BYTES read, MAX_LINES kept, each line cut at
MAX_COLS. A multi-GB log or a one-line minified bundle costs the same as a
small file.
"""

import html
import importlib.util
import os
import re
import sys

MAX_BYTES = 64 * 1024
MAX_LINES = 150
MAX_COLS = 400
MD_MAX_BYTES = 24 * 1024

STYLE_FILE = os.path.expanduser('~/.local/share/vscode-dark-modern/darkmodern.py')


def load_style():
    spec = importlib.util.spec_from_file_location('darkmodern', STYLE_FILE)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def read_head(path, limit):
    size = os.path.getsize(path)
    with open(path, 'rb') as fh:
        raw = fh.read(limit)
    cut_bytes = size > len(raw)
    if cut_bytes and b'\n' in raw:
        raw = raw[:raw.rindex(b'\n')]
    return raw.decode('utf-8', errors='replace'), cut_bytes, size


def note(text, dm):
    return ('<p style="color:%s; font-style:italic;">%s</p>'
            % (dm.GUTTER, html.escape(text)))


def code(path, dm):
    from pygments import highlight
    from pygments.formatters import HtmlFormatter
    from pygments.lexers import TextLexer, get_lexer_for_filename, guess_lexer
    from pygments.util import ClassNotFound

    text, cut_bytes, size = read_head(path, MAX_BYTES)
    lines = text.split('\n')
    cut_lines = len(lines) > MAX_LINES
    lines = lines[:MAX_LINES]
    long_cut = False
    for i, ln in enumerate(lines):
        if len(ln) > MAX_COLS:
            lines[i] = ln[:MAX_COLS] + ' …'
            long_cut = True
    text = '\n'.join(lines).rstrip('\n')

    try:
        lexer = get_lexer_for_filename(path, text)
    except ClassNotFound:
        try:
            # Content sniffing catches shebang scripts with no suffix; on a
            # short excerpt it is cheap.
            lexer = guess_lexer(text)
        except ClassNotFound:
            lexer = TextLexer()

    # Our own gutter instead of pygments' linenos: it stays one span per line
    # and survives the pre-wrap below.
    body = highlight(text, lexer, HtmlFormatter(
        style=dm.DarkModernStyle, noclasses=True, nowrap=True))
    out = []
    width = len(str(len(lines)))
    for n, ln in enumerate(body.rstrip('\n').split('\n'), 1):
        out.append('<span style="color:%s;">%s</span>  %s'
                   % (dm.GUTTER, str(n).rjust(width).replace(' ', '&nbsp;'), ln))
    # A multi-line token (docstring, block comment) stays one span across the
    # newlines; Qt renders that fine inside <pre>, gutter spans included.
    res = ('<pre style="white-space:pre-wrap; color:%s;">%s</pre>'
           % (dm.FG, '\n'.join(out)))
    if cut_bytes or cut_lines:
        res += note('First %d lines of %s. Open the full preview (Space) for more.'
                    % (len(lines), human(size)), dm)
    elif long_cut:
        res += note('Long lines shortened to %d characters.' % MAX_COLS, dm)
    return res


def markdown(path, dm):
    import markdown as md

    text, cut_bytes, size = read_head(path, MD_MAX_BYTES)
    body = md.markdown(text, extensions=['extra', 'sane_lists', 'codehilite'],
                       extension_configs={'codehilite': {
                           'noclasses': True, 'guess_lang': False,
                           'pygments_style': dm.DarkModernStyle}})

    # Qt's built-in heading sizes are huge in a narrow pane; tame them and use
    # VS Code's markdown-preview colours.
    sizes = {'1': 'large', '2': 'medium', '3': 'medium',
             '4': 'small', '5': 'small', '6': 'small'}
    body = re.sub(r'<h([1-6])([^>]*)>',
                  lambda m: '<h%s%s style="font-size:%s; color:#e7e7e7; font-weight:600;">'
                  % (m.group(1), m.group(2), sizes[m.group(1)]), body)
    # Inline code only: codehilite blocks open with <span></span><code>.
    body = re.sub(r'(?<!</span>)<code>', '<code style="color:#ce9178;">', body)
    body = re.sub(r'<a ', '<a style="color:#4daafc; text-decoration:none;" ', body)
    body = re.sub(r'<blockquote>',
                  '<blockquote style="color:#9d9d9d; margin-left:8px;">', body)
    body = re.sub(r'<table>',
                  '<table border="1" cellspacing="0" cellpadding="4" style="border-color:#3c3c3c;">', body)
    # codehilite's wrapper div carries the editor background already; make
    # its <pre> wrap so code blocks don't overflow the pane.
    body = body.replace('<pre style="', '<pre style="white-space:pre-wrap; ')
    res = '<div style="color:%s;">%s</div>' % (dm.FG, body)
    if cut_bytes:
        res += note('First %s of %s. Open the full preview (Space) for more.'
                    % (human(MD_MAX_BYTES), human(size)), dm)
    return res


def human(n):
    for unit in ('B', 'KB', 'MB', 'GB'):
        if n < 1024 or unit == 'GB':
            return ('%d %s' % (n, unit)) if unit == 'B' else ('%.1f %s' % (n, unit))
        n /= 1024.0
    return str(n)


def main():
    if len(sys.argv) < 3:
        return 2
    path, mode = sys.argv[1], sys.argv[2]
    dm = load_style()
    sys.stdout.write(markdown(path, dm) if mode == 'markdown' else code(path, dm))
    sys.stdout.write('\n')
    return 0


if __name__ == '__main__':
    sys.exit(main())
