"""VS Code "Dark Modern" as a Pygments style.

Shared by every preview on this machine so they all look like the editor:
  - ~/.local/share/dms-launcher-patch/highlight.py  (DMS launcher details pane)
  - ~/.local/share/sushi-preview/share/sushi/md2html.py  (spacebar Markdown)
The GtkSourceView twin used by the spacebar text viewer is
~/.local/share/gtksourceview-4/styles/vscode-dark-modern.xml -- keep the two
palettes in step.

Load it by path (importlib), not by name: callers run python with -I.
Token colours are VS Code's Dark+ set, which Dark Modern inherits; the
editor chrome (background, gutter) is Dark Modern's own.
"""

from pygments.style import Style
from pygments.token import (Comment, Error, Escape, Generic, Keyword, Name,
                            Number, Operator, Punctuation, String, Text,
                            Token, Whitespace)

BG = '#1f1f1f'          # editor.background
FG = '#cccccc'          # editor.foreground
GUTTER = '#6e7681'      # editorLineNumber.foreground
BORDER = '#2b2b2b'      # editorGroup / panel borders
SELECTION = '#264f78'   # editor.selectionBackground

# Dark+ token colours
COMMENT = '#6a9955'
KEYWORD = '#569cd6'     # storage / declaration keywords, tags
CONTROL = '#c586c0'     # control flow, imports
STRING = '#ce9178'
REGEX = '#d16969'
ESCAPE = '#d7ba7d'
NUMBER = '#b5cea8'
FUNCTION = '#dcdcaa'
TYPE = '#4ec9b0'
VARIABLE = '#9cdcfe'
CONSTANT = '#4fc1ff'
PUNCT = '#d4d4d4'
INVALID = '#f44747'


class DarkModernStyle(Style):
    name = 'vscode-dark-modern'
    background_color = BG
    highlight_color = SELECTION
    line_number_color = GUTTER
    line_number_background_color = BG
    line_number_special_color = FG
    line_number_special_background_color = BG

    styles = {
        # Plain text has NO style on purpose: it inherits the container's
        # foreground (FG), and pygments then emits no span for it -- one
        # span per whitespace run tripled the HTML the launcher pane lays out.
        Token: '',
        Text: '',
        Whitespace: '',
        Error: INVALID,
        Escape: ESCAPE,

        Comment: COMMENT,
        Comment.Preproc: CONTROL,
        Comment.PreprocFile: STRING,
        Comment.Hashbang: COMMENT,

        Keyword: KEYWORD,
        Keyword.Namespace: CONTROL,
        Keyword.Reserved: CONTROL,
        Keyword.Type: KEYWORD,
        Keyword.Constant: KEYWORD,
        Keyword.Pseudo: KEYWORD,

        Operator: PUNCT,
        Operator.Word: KEYWORD,
        Punctuation: PUNCT,

        Name: VARIABLE,
        Name.Builtin: TYPE,
        Name.Builtin.Pseudo: KEYWORD,
        Name.Function: FUNCTION,
        Name.Function.Magic: FUNCTION,
        Name.Class: TYPE,
        Name.Namespace: TYPE,
        Name.Exception: TYPE,
        Name.Decorator: FUNCTION,
        Name.Constant: CONSTANT,
        Name.Variable: VARIABLE,
        Name.Variable.Magic: VARIABLE,
        Name.Attribute: VARIABLE,
        Name.Property: VARIABLE,
        Name.Label: '',
        Name.Tag: KEYWORD,
        Name.Entity: KEYWORD,
        Name.Other: VARIABLE,

        String: STRING,
        String.Escape: ESCAPE,
        String.Regex: REGEX,
        String.Interpol: KEYWORD,
        String.Affix: KEYWORD,
        String.Doc: STRING,
        String.Symbol: STRING,

        Number: NUMBER,

        Generic.Heading: 'bold ' + KEYWORD,
        Generic.Subheading: 'bold ' + KEYWORD,
        Generic.Deleted: STRING,
        Generic.Inserted: NUMBER,
        Generic.Error: INVALID,
        Generic.Emph: 'italic',
        Generic.Strong: 'bold ' + KEYWORD,
        Generic.Prompt: GUTTER,
        Generic.Output: '',
        Generic.Traceback: INVALID,
    }
