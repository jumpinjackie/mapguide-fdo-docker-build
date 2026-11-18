#!/usr/bin/env python3
"""Convert Trac wiki markup into GitHub-Flavored Markdown.

The Trac subset this understands is the one release notes actually use, plus its
immediate neighbours:

Block level
    = H =  ...  ====== H ======     ATX headings (# .. ######)
    ||a||b||                         GFM tables, first row promoted to header
    * / 1. / a. / i.                 nested lists, nesting derived from indentation
    {{{ ... }}}  {{{#!lang ... }}}   fenced code blocks
    ----                             horizontal rule
    [[TOC]]                          dropped: GitHub renders its own outline
    [[BR]] / [[Anchor(x)]]           <br> / <a id="x"></a>

Inline
    '''bold'''   ''italic''          **bold**   *italic*
    `code`  {{{code}}}               `code`
    [url label]  [url]               [label](url)  <url>
    [wiki:Page label]                [label](<wiki-base>Page)
    #123                             [#123](<ticket-base>123)
    !CamelCase                       CamelCase   (Trac's "do not linkify" escape)

Two deliberate stances:

* The converter only ever re-writes *markup*. It does not correct content, so a
  source typo survives the round trip.
* Anything this does not understand is reported on stderr instead of being
  silently dropped: an unknown macro becomes an HTML comment plus a warning, and
  a line-start character that is literal in Trac but significant in Markdown
  (`+`, `-`, `#`, `>` ...) is backslash-escaped rather than reinterpreted. Trac's own
  list markers (`*`, `1.`, `a.`, `i.`) are converted; `#` is not one of them, so a line
  starting with `#` stays text instead of becoming a Markdown heading or a numbered list.

Usage:
    trac2md.py [options] INPUT...

Run `trac2md.py --help` for the options.
"""

from __future__ import annotations

import argparse
import re
import sys
from collections import Counter
from pathlib import Path

DEFAULT_TICKET_BASE = "https://trac.osgeo.org/mapguide/ticket/"
DEFAULT_WIKI_BASE = "https://trac.osgeo.org/mapguide/wiki/"

# Placeholder marker used while markup is rewritten link-by-link; never present
# in real input.
GUARD = "\x00"

HEADING_RE = re.compile(r"^(={1,6})[ \t]*(.*?)[ \t]*={0,6}[ \t]*$")
RULE_RE = re.compile(r"^-{4,}[ \t]*$")
LIST_RE = re.compile(
    r"^(?P<indent>[ \t]*)(?P<marker>\*|\d+\.|[a-zA-Z]\.|[ivxIVX]+\.)"
    r"(?:[ \t]+(?P<body>.*))?$"
)
VERBATIM_RE = re.compile(r"^[ \t]*\{\{\{(?:#!(\S+))?[ \t]*(.*)$")
MACRO_RE = re.compile(r"\[\[([A-Za-z]\w*)(?:\((?P<args>[^)]*)\))?\]\]")
ANCHOR_MACRO_RE = re.compile(r"\[\[#([\w-]+)\]\]")

SCHEME_LINK_RE = re.compile(
    r"\[(?P<target>(?:https?|ftp|file|irc|mailto|news):[^\]\s]+"
    r"|(?:wiki|ticket|changeset|source|log|milestone|attachment|comment):[^\]\s]+)"
    r"(?:[ \t]+(?P<label>[^\]]+?))?[ \t]*\]"
)
CODE_SPAN_RE = re.compile(r"(?<!`)(`+)(?!`)(.+?)(?<!`)\1(?!`)")
TRAC_INLINE_VERBATIM_RE = re.compile(r"\{\{\{(.+?)\}\}\}")

TRAC_BOLD_RE = re.compile(r"'''(?=\S)(.+?)(?<=\S)'''(?!')")
TRAC_BOLD_UNBALANCED_RE = re.compile(r"'''(?=\S)(.+?)(?<=\S)''")
TRAC_ITALIC_RE = re.compile(r"(?<!\w)''(?=\S)(.+?)(?<=\S)''(?!\w)")

WIKI_ESCAPE_RE = re.compile(r"!(?=[A-Z][a-z0-9]+(?:[A-Z][a-z0-9]*)+)")

TICKET_RE = re.compile(r"(?<![\w&/#])#(\d+)\b")

# Trac cell alignment prefix, e.g. ||<)>right||, ||<:>centre||
CELL_PREFIX_RE = re.compile(r"^<([^>]*)>")
CELL_ALIGNMENTS = {"<": "left", "(": "left", ">": "right", ")": "right", "=": "center", ":": "center"}

LEADING_MARKER_RE = re.compile(r"^([ ]{0,3})(#{1,6}[ \t]|[-+*][ \t]|(?P<digits>\d+)(?P<delimiter>[.)])[ \t]|>)")


def strip_cell_prefix(cell: str) -> tuple[str, str | None]:
    """Split a leading Trac cell-decoration (`<)>`, `<:>`, ...) off a table cell."""
    cell = cell.lstrip()
    match = CELL_PREFIX_RE.match(cell)
    if not match:
        return cell, None
    alignment = None
    for char in match.group(1):
        if char in CELL_ALIGNMENTS:
            alignment = CELL_ALIGNMENTS[char]
    return cell[match.end() :], alignment


def escape_leading_marker(line: str) -> str:
    """Escape a character that starts a Markdown block but is literal text in Trac."""
    match = LEADING_MARKER_RE.match(line)
    if not match:
        return line
    prefix, rest = match.group(1), line[match.end(1) :]
    if match.group("digits"):
        digits = match.group("digits")
        return f"{prefix}{digits}\\{rest[len(digits):]}"
    return f"{prefix}\\{rest}"


class Converter:
    def __init__(
        self,
        ticket_base: str = DEFAULT_TICKET_BASE,
        wiki_base: str = DEFAULT_WIKI_BASE,
        table_header: str = "first",
        warn=None,
    ):
        self.ticket_base = ticket_base
        self.wiki_base = wiki_base
        self.table_header = table_header
        self._warn = warn or (lambda line, message: None)
        self.stats = Counter()
        self.warnings: list[tuple[int, str]] = []

    # -- public ---------------------------------------------------------

    def convert(self, text: str) -> str:
        lines = text.replace("\r\n", "\n").replace("\r", "\n").split("\n")
        out: list[str] = []
        index = 0
        while index < len(lines):
            index = self._consume_block(lines, index, out)
        while out and not out[-1]:
            out.pop()
        return "\n".join(out) + "\n"

    def report(self) -> str:
        parts = [
            f"{self.stats['heading']} heading(s)",
            f"{self.stats['table']} table(s)/{self.stats['table_row']} row(s)",
            f"{self.stats['list_item']} list item(s)",
            f"{self.stats['link']} link(s) ({self.stats['ticket']} ticket)",
            f"{self.stats['macro_dropped']} macro(s) dropped, "
            f"{self.stats['macro_expanded']} expanded, "
            f"{self.stats['macro_unsupported']} unsupported",
            f"{len(self.warnings)} warning(s)",
        ]
        return ", ".join(parts)

    # -- block level ----------------------------------------------------

    def _consume_block(self, lines: list[str], index: int, out: list[str]) -> int:
        line = lines[index]
        stripped = line.strip()

        if not stripped:
            self._emit(out, "")
            return index + 1

        verbatim = VERBATIM_RE.match(line)
        if verbatim and "}}}" not in verbatim.group(2):
            return self._consume_verbatim(lines, index, verbatim, out)

        if stripped.startswith("[[") and self._is_macro_only(stripped):
            rendered = self._render_macro_line(stripped, index)
            if rendered:
                self._emit(out, rendered)
            return index + 1

        if RULE_RE.match(stripped):
            self.stats["rule"] += 1
            self._emit(out, "---")
            return index + 1

        heading = self._parse_heading(line)
        if heading:
            self.stats["heading"] += 1
            level, title = heading
            self._emit(out, f"{'#' * level} {self.inline(title)}")
            return index + 1

        if stripped.startswith("||"):
            return self._consume_table(lines, index, out)

        if LIST_RE.match(line):
            return self._consume_list(lines, index, out)

        return self._consume_paragraph(lines, index, out)

    def _consume_verbatim(self, lines, index, opening, out) -> int:
        lang = opening.group(1) or ""
        body = [opening.group(2)] if opening.group(2).strip() else []
        index += 1
        while index < len(lines):
            line = lines[index]
            closing = line.find("}}}")
            if closing >= 0:
                if line[:closing].strip():
                    body.append(line[:closing])
                index += 1
                break
            body.append(line)
            index += 1
        content = "\n".join(body)
        fence = "`" * max(3, max((len(run) for run in re.findall(r"`+", content)), default=0) + 1)
        self.stats["verbatim"] += 1
        self._emit(out, f"{fence}{lang}")
        for line in content.split("\n"):
            out.append(line)
        out.append(fence)
        return index

    def _consume_table(self, lines, index, out) -> int:
        rows = []
        while index < len(lines) and lines[index].strip().startswith("||"):
            rows.append(lines[index].strip())
            index += 1
        rendered = self._render_table(rows)
        if rendered:
            self._emit(out, "")
            out.extend(rendered)
            self._emit(out, "")
        return index

    def _render_table(self, rows: list[str]) -> list[str]:
        self.stats["table"] += 1
        self.stats["table_row"] += len(rows)
        alignments: list[str | None] = []
        cells: list[list[str]] = []
        for row in rows:
            body = row
            if body.startswith("||"):
                body = body[2:]
            if body.endswith("||"):
                body = body[:-2]
            fields = body.split("||")
            rendered = []
            for column, field in enumerate(fields):
                text, alignment = strip_cell_prefix(field)
                while len(alignments) <= column:
                    alignments.append(None)
                if alignment and alignments[column] in (None, alignment):
                    alignments[column] = alignment
                elif alignment and alignments[column] != alignment:
                    alignments[column] = ""  # conflicting: fall back to default
                rendered.append(self._table_cell(text))
            cells.append(rendered)

        width = max(len(row) for row in cells)
        for row in cells:
            row.extend([""] * (width - len(row)))

        header = cells[0] if self.table_header == "first" else [""] * width
        body = cells[1:] if self.table_header == "first" else cells

        def format_row(row: list[str]) -> str:
            return "| " + " | ".join(row) + " |"

        delimiters = []
        for column in range(width):
            alignment = alignments[column] if column < len(alignments) else None
            if alignment == "left":
                delimiters.append(":---")
            elif alignment == "right":
                delimiters.append("---:")
            elif alignment == "center":
                delimiters.append(":---:")
            else:
                delimiters.append("---")

        rendered_lines = [format_row(header), "| " + " | ".join(delimiters) + " |"]
        rendered_lines.extend(format_row(row) for row in body)
        return rendered_lines

    def _table_cell(self, text: str) -> str:
        guarded, tokens = self._inline_core(text.strip())
        guarded = guarded.replace("|", "\\|")
        return self._restore(guarded, tokens)

    def _consume_list(self, lines, index, out) -> int:
        items = []
        while index < len(lines):
            line = lines[index]
            if not line.strip():
                probe = index + 1
                while probe < len(lines) and not lines[probe].strip():
                    probe += 1
                if probe < len(lines) and LIST_RE.match(lines[probe]):
                    index = probe
                    continue
                break
            match = LIST_RE.match(line)
            if match:
                items.append(
                    {
                        "indent": len(match.group("indent").expandtabs(4)),
                        "ordered": match.group("marker") != "*",
                        "body": match.group("body") or "",
                        "continuations": [],
                    }
                )
                index += 1
                continue
            if items and line.startswith((" ", "\t")):
                items[-1]["continuations"].append(line)
                index += 1
                continue
            break
        self._emit(out, "")
        out.extend(self._render_list(items))
        self._emit(out, "")
        return index

    def _render_list(self, items) -> list[str]:
        self.stats["list_item"] += len(items)
        rendered = []
        stack: list[dict] = []
        for item in items:
            indent = item["indent"]
            ordered = item["ordered"]
            while stack and indent < stack[-1]["indent"]:
                stack.pop()
            if not stack:
                stack.append({"indent": indent, "ordered": ordered, "count": 0})
            elif indent >= stack[-1]["indent"] + 2:
                stack.append({"indent": indent, "ordered": ordered, "count": 0})
            elif stack[-1]["ordered"] != ordered:
                stack[-1]["ordered"] = ordered
                stack[-1]["count"] = 0
            width = sum(3 if level["ordered"] else 2 for level in stack[:-1])
            if ordered:
                stack[-1]["count"] += 1
                marker = f"{stack[-1]['count']}."
            else:
                marker = "*"
            body = self.inline(item["body"].strip())
            rendered.append(f"{' ' * width}{marker} {body}".rstrip())
            for continuation in item["continuations"]:
                text = self.inline(continuation.strip())
                rendered.append(f"{' ' * (width + len(marker) + 1)}{text}")
        return rendered

    def _consume_paragraph(self, lines, index, out) -> int:
        text = []
        while index < len(lines):
            line = lines[index]
            if not line.strip() or self._starts_block(lines, index):
                break
            text.append(escape_leading_marker(self.inline(line.strip())))
            index += 1
        self._emit(out, "")
        out.extend(text)
        return index

    def _starts_block(self, lines, index) -> bool:
        line = lines[index]
        stripped = line.strip()
        if stripped.startswith("||"):
            return True
        if RULE_RE.match(stripped):
            return True
        if LIST_RE.match(line):
            return True
        verbatim = VERBATIM_RE.match(line)
        if verbatim and "}}}" not in verbatim.group(2):
            return True
        if stripped.startswith("[[") and self._is_macro_only(stripped):
            return True
        return self._parse_heading(line) is not None

    @staticmethod
    def _parse_heading(line: str) -> tuple[int, str] | None:
        match = HEADING_RE.match(line)
        if not match:
            return None
        title = match.group(2).strip()
        if not title.strip("=").strip():
            return None
        return len(match.group(1)), title

    def _emit(self, out: list[str], line: str) -> None:
        if not line:
            if out and out[-1] != "":
                out.append("")
            return
        out.append(line)

    # -- macros ---------------------------------------------------------

    def _is_macro_only(self, text: str) -> bool:
        remainder = MACRO_RE.sub("", ANCHOR_MACRO_RE.sub("", text))
        return not remainder.strip()

    def _render_macro_line(self, text: str, lineno: int) -> str:
        pieces = []
        for match in ANCHOR_MACRO_RE.finditer(text):
            self.stats["macro_expanded"] += 1
            pieces.append(f'<a id="{match.group(1)}"></a>')
        consumed = ANCHOR_MACRO_RE.sub("", text)
        last = 0
        for match in MACRO_RE.finditer(consumed):
            pieces.append(consumed[last : match.start()])
            last = match.end()
            pieces.append(self._render_macro(match.group(1), match.group("args") or "", lineno))
        pieces.append(consumed[last:])
        return "".join(pieces).strip()

    def _render_macro(self, name: str, args: str, lineno: int) -> str:
        lowered = name.lower()
        if lowered == "toc":
            self.stats["macro_dropped"] += 1
            return ""
        if lowered == "br":
            self.stats["macro_expanded"] += 1
            return "<br>"
        if lowered == "anchor":
            self.stats["macro_expanded"] += 1
            return f'<a id="{args.strip()}"></a>'
        self._warning(lineno, f"unsupported Trac macro [[{name}]] left as an HTML comment")
        self.stats["macro_unsupported"] += 1
        return f"<!-- unsupported Trac macro: [[{name}({args})]] -->"

    # -- inline level ---------------------------------------------------

    def inline(self, text: str, tickets: bool = True) -> str:
        guarded, tokens = self._inline_core(text, tickets)
        return self._restore(guarded, tokens)

    def _inline_core(self, text: str, tickets: bool = True) -> tuple[str, list[str]]:
        tokens: list[str] = []

        def stash(markup: str) -> str:
            tokens.append(markup)
            return f"{GUARD}{len(tokens) - 1}{GUARD}"

        def code_span(content: str) -> str:
            fence = "`"
            if "`" in content:
                fence = "``"
                while fence in content:
                    fence += "`"
                return stash(f"{fence} {content} {fence}")
            return stash(f"{fence}{content}{fence}")

        text = CODE_SPAN_RE.sub(lambda m: code_span(m.group(2)), text)
        text = TRAC_INLINE_VERBATIM_RE.sub(lambda m: code_span(m.group(1)), text)

        text = ANCHOR_MACRO_RE.sub(lambda m: stash(f'<a id="{m.group(1)}"></a>'), text)
        text = MACRO_RE.sub(
            lambda m: (
                stash("<br>") if m.group(1).lower() == "br" else self._inline_macro_comment(m)
            ),
            text,
        )

        text = SCHEME_LINK_RE.sub(lambda m: stash(self._render_link(m)), text)

        text = WIKI_ESCAPE_RE.sub("", text)
        text = TRAC_BOLD_RE.sub(r"**\1**", text)
        text = TRAC_BOLD_UNBALANCED_RE.sub(r"**\1**", text)
        text = TRAC_ITALIC_RE.sub(r"*\1*", text)

        if tickets and self.ticket_base:
            text = self._linkify_tickets(text)

        return text, tokens

    def _inline_macro_comment(self, match: re.Match) -> str:
        self.stats["macro_unsupported"] += 1
        name, args = match.group(1), match.group("args") or ""
        return f"<!-- unsupported Trac macro: [[{name}({args})]] -->"

    def _render_link(self, match: re.Match) -> str:
        target = match.group("target")
        label = match.group("label")
        self.stats["link"] += 1
        if ":" in target and not re.match(r"^[a-z]+://", target):
            scheme, rest = target.split(":", 1)
            resolved = self._interwiki_target(scheme, rest)
            if resolved is None:
                self._warning(0, f"unsupported Trac interwiki link [{target}] left as text")
                self.stats["link_unsupported"] += 1
                return label if label else target
            target = resolved
        if label is None:
            return f"<{target}>"
        return f"[{self.inline(label.strip(), tickets=False)}]({target})"

    def _interwiki_target(self, scheme: str, rest: str) -> str | None:
        if scheme == "wiki":
            return self.wiki_base + rest if self.wiki_base else None
        if scheme == "ticket":
            return self.ticket_base + rest if self.ticket_base else None
        return None

    def _linkify_tickets(self, text: str) -> str:
        def replace(match: re.Match) -> str:
            self.stats["ticket"] += 1
            number = match.group(1)
            return f"[#{number}]({self.ticket_base}{number})"

        return TICKET_RE.sub(replace, text)

    @staticmethod
    def _restore(text: str, tokens: list[str]) -> str:
        pattern = re.compile(f"{GUARD}(\\d+){GUARD}")

        def replace(match: re.Match) -> str:
            return tokens[int(match.group(1))]

        return pattern.sub(replace, text)

    def _warning(self, lineno: int, message: str) -> None:
        self.warnings.append((lineno, message))
        self._warn(lineno, message)


def convert(text: str, **options) -> tuple[str, Converter]:
    converter = Converter(**options)
    return converter.convert(text), converter


def parse_args(argv: list[str] | None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog="trac2md.py",
        description="Convert Trac wiki markup to GitHub-Flavored Markdown.",
    )
    parser.add_argument("inputs", nargs="+", metavar="INPUT", help="Trac wiki files to convert")
    parser.add_argument(
        "-o",
        "--output",
        help="output path; '-' writes to stdout (default: <input>.github.md beside the input)",
    )
    parser.add_argument(
        "--ticket-base",
        default=DEFAULT_TICKET_BASE,
        help=f"base URL for bare #123 ticket references (default: {DEFAULT_TICKET_BASE}; '' disables)",
    )
    parser.add_argument(
        "--wiki-base",
        default=DEFAULT_WIKI_BASE,
        help=f"base URL for [wiki:Page] links (default: {DEFAULT_WIKI_BASE}; '' keeps the label as text)",
    )
    parser.add_argument(
        "--table-header",
        choices=("first", "none"),
        default="first",
        help="treat the first ||row|| as the table header (default: first)",
    )
    parser.add_argument("--stats", action="store_true", help="print conversion counts to stderr")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    if args.output and args.output != "-" and len(args.inputs) > 1:
        print("trac2md.py: -o accepts a single input file", file=sys.stderr)
        return 2

    status = 0
    for name in args.inputs:
        source = Path(name)
        try:
            text = source.read_text(encoding="utf-8-sig")
        except OSError as error:
            print(f"trac2md.py: {name}: {error}", file=sys.stderr)
            status = 1
            continue

        converter = Converter(
            ticket_base=args.ticket_base,
            wiki_base=args.wiki_base,
            table_header=args.table_header,
            warn=lambda line, message, _name=name: print(
                f"trac2md.py: {_name}:{line}: warning: {message}", file=sys.stderr
            ),
        )
        markdown = converter.convert(text)

        if args.output == "-":
            sys.stdout.write(markdown)
        else:
            target = Path(args.output) if args.output else source.with_suffix(".github.md")
            with open(target, "w", encoding="utf-8", newline="\n") as handle:
                handle.write(markdown)
        if args.stats:
            destination = "(stdout)" if args.output == "-" else str(target)
            print(f"trac2md.py: {name} -> {destination}: {converter.report()}", file=sys.stderr)

    return status


if __name__ == "__main__":
    sys.exit(main())
