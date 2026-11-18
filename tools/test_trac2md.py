#!/usr/bin/env python3
"""Tests for trac2md.py.

Run from the repository root:

    python3 -m unittest discover -s tools -p 'test_*.py' -v
"""

import unittest

from trac2md import Converter, convert


def md(text, **options):
    markdown, _ = convert(text, **options)
    return markdown


class HeadingTests(unittest.TestCase):
    def test_atx_levels(self):
        self.assertEqual(md("= Title ="), "# Title\n")
        self.assertEqual(md("=== Deep ===\n"), "### Deep\n")

    def test_trailing_equals_is_optional(self):
        self.assertEqual(md("== Downloads\n"), "## Downloads\n")

    def test_drops_the_wiki_escape(self):
        self.assertEqual(
            md("= !MapGuide 4.0.1-Test Release Notes = "),
            "# MapGuide 4.0.1-Test Release Notes\n",
        )

    def test_a_run_of_equals_is_not_a_heading(self):
        self.assertEqual(md("============================\n"), "============================\n")


class TableTests(unittest.TestCase):
    def test_first_row_becomes_header_and_cells_are_inline_formatted(self):
        source = "||Item||Download||\n||'''Bold'''||[https://example.com/x file]||\n||TBD||TBD||\n"
        self.assertEqual(
            md(source),
            "| Item | Download |\n"
            "| --- | --- |\n"
            "| **Bold** | [file](https://example.com/x) |\n"
            "| TBD | TBD |\n",
        )

    def test_short_row_is_padded(self):
        self.assertEqual(
            md("||a||b||\n||c||\n"),
            "| a | b |\n| --- | --- |\n| c |  |\n",
        )

    def test_unbalanced_bold_in_a_cell(self):
        self.assertEqual(
            md("||'''Fusion build tools''||TBD||TBD||\n"),
            "| **Fusion build tools** | TBD | TBD |\n| --- | --- | --- |\n",
        )

    def test_literal_pipe_is_escaped(self):
        self.assertEqual(md("||a|b||\n"), "| a\\|b |\n| --- |\n")

    def test_cell_alignment_prefix(self):
        self.assertEqual(
            md("||<:>Centre||\n||x||\n"),
            "| Centre |\n| :---: |\n| x |\n",
        )

    def test_header_can_be_disabled(self):
        self.assertEqual(
            md("||a||b||\n||c||d||\n", table_header="none"),
            "|  |  |\n| --- | --- |\n| a | b |\n| c | d |\n",
        )


class ListTests(unittest.TestCase):
    def test_nesting_follows_indent(self):
        self.assertEqual(
            md(" * a\n    * b\n        * c\n * d\n"),
            "* a\n  * b\n    * c\n* d\n",
        )

    def test_three_and_four_space_indents_are_siblings(self):
        self.assertEqual(
            md(" * a\n   * b\n * c\n    * d\n"),
            "* a\n  * b\n* c\n  * d\n",
        )

    def test_ordered_items_are_renumbered(self):
        self.assertEqual(md(" 1. one\n 1. two\n"), "1. one\n2. two\n")

    def test_ordered_child_indents_past_its_parent_marker(self):
        self.assertEqual(md(" * a\n     1. b\n"), "* a\n  1. b\n")


class LinkTests(unittest.TestCase):
    def test_labelled_and_bare_external_links(self):
        self.assertEqual(md("[https://example.com/x a label]"), "[a label](https://example.com/x)\n")
        self.assertEqual(md("[https://example.com/x]"), "<https://example.com/x>\n")

    def test_interwiki_wiki_link(self):
        self.assertEqual(
            md("Please [wiki:SubmitTicket report any issues you find]."),
            "Please [report any issues you find]"
            "(https://trac.osgeo.org/mapguide/wiki/SubmitTicket).\n",
        )

    def test_wiki_base_empty_keeps_the_label(self):
        self.assertEqual(md("[wiki:SubmitTicket report]", wiki_base=""), "report\n")


class TicketLinkTests(unittest.TestCase):
    def test_bare_reference_uses_the_mapguide_trac_by_default(self):
        self.assertEqual(
            md("Fixes #2584 on the MapGuide side"),
            "Fixes [#2584](https://trac.osgeo.org/mapguide/ticket/2584) on the MapGuide side\n",
        )

    def test_base_can_be_overridden(self):
        self.assertEqual(
            md("See #1015.", ticket_base="https://trac.osgeo.org/fdo/ticket/"),
            "See [#1015](https://trac.osgeo.org/fdo/ticket/1015).\n",
        )

    def test_base_can_be_disabled(self):
        self.assertEqual(md("See #1015.", ticket_base=""), "See #1015.\n")

    def test_existing_link_label_is_not_linkified_again(self):
        self.assertEqual(
            md("[https://trac.osgeo.org/fdo/ticket/1015 #1015]: New support"),
            "[#1015](https://trac.osgeo.org/fdo/ticket/1015): New support\n",
        )

    def test_code_span_is_not_linkified(self):
        self.assertEqual(md("the `#2897` marker"), "the `#2897` marker\n")


class InlineTests(unittest.TestCase):
    def test_italic_but_not_underscore_emphasis(self):
        self.assertEqual(md("''italic'' and FDO_SQS_PERF=1"), "*italic* and FDO_SQS_PERF=1\n")

    def test_code_spans_and_inline_verbatim(self):
        self.assertEqual(md("your `Dictionaries` folder"), "your `Dictionaries` folder\n")
        self.assertEqual(md("the {{{mono}}} word"), "the `mono` word\n")

    def test_wiki_escape_only_strips_before_camel_case(self):
        self.assertEqual(md("the !MapGuide project"), "the MapGuide project\n")
        self.assertEqual(md("hello! world"), "hello! world\n")

    def test_line_starts_that_markdown_would_reinterpret_are_escaped(self):
        self.assertEqual(md("+ Reported as compatible by users"), "\\+ Reported as compatible by users\n")
        self.assertEqual(md("# not a heading"), "\\# not a heading\n")
        self.assertEqual(md("1) not a list"), "1\\) not a list\n")
        self.assertEqual(md("- not a bullet"), "\\- not a bullet\n")

    def test_trac_numbered_list_is_converted_rather_than_escaped(self):
        self.assertEqual(md("1. first\n1. second\n"), "1. first\n2. second\n")


class VerbatimTests(unittest.TestCase):
    def test_fenced_block(self):
        self.assertEqual(md("{{{\nprint(1)\n}}}\n"), "```\nprint(1)\n```\n")

    def test_fenced_block_with_language(self):
        self.assertEqual(md("{{{#!python\nprint(1)\n}}}\n"), "```python\nprint(1)\n```\n")


class MacroTests(unittest.TestCase):
    def test_toc_is_dropped_without_leaving_a_gap(self):
        self.assertEqual(md("Intro.\n\n[[TOC]]\n\n== Downloads ==\n"), "Intro.\n\n## Downloads\n")

    def test_br_becomes_a_line_break(self):
        self.assertEqual(md("a[[BR]]b"), "a<br>b\n")

    def test_unknown_macro_is_reported_not_lost(self):
        converter = Converter()
        result = converter.convert("[[TicketQuery(x)]]\n")
        self.assertEqual(result, "<!-- unsupported Trac macro: [[TicketQuery(x)]] -->\n")
        self.assertEqual(len(converter.warnings), 1)


class ParagraphTests(unittest.TestCase):
    def test_blank_lines_collapse_and_lines_are_kept(self):
        self.assertEqual(md("one\n\ntwo\n\n\nthree   \n"), "one\n\ntwo\n\nthree\n")


class DocumentTests(unittest.TestCase):
    def test_no_trac_markup_survives_a_representative_document(self):
        source = (
            "= !MapGuide Release Notes =\n\n[[TOC]]\n\n== Downloads ==\n\n"
            "||Item||Download||\n||'''Installer'''||[https://example.com/x x.exe]||\n\n"
            "* #2897: first\n    * nested\n\n"
            "'''Note.'''\n\n"
            "{{{\ncode\n}}}\n\n"
            "+ footnote-ish\n"
            "Please [wiki:SubmitTicket report bugs].\n"
        )
        result = md(source)
        for leftover in ("'''", "[[", "[http", "wiki:", "\n||"):
            self.assertNotIn(leftover, result)
        self.assertIn("| **Installer** | [x.exe](https://example.com/x) |", result)
        self.assertIn("* [#2897](https://trac.osgeo.org/mapguide/ticket/2897): first", result)
        self.assertIn("```\ncode\n```", result)


if __name__ == "__main__":
    unittest.main()
