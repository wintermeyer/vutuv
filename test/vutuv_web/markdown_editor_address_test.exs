defmodule VutuvWeb.MarkdownEditorAddressTest do
  @moduledoc """
  The composer must store a `user@host` address **bare**, because that is the
  only spelling vutuv renders: `VutuvWeb.Markdown` turns a bare `@user@host`
  into the account link itself, and `Vutuv.Mentions` reads the same raw source.

  GFM's autolink-literal extension parses `user@host.tld` into a link node with
  a `mailto:` url, and remark then serializes that node two ways depending on
  which path the body took — measured against the pinned remark, not assumed:

      re-parse (draft restore, post edit)  "Account @<php@tags.vutuv.de> folgen."
      first write (a plain text node)      "Account @php\\\\@tags.vutuv.de folgen."

  The first shipped: vutuv escapes `<` at render time (typed HTML must show as
  text), so a post read `@<php@tags.vutuv.de>` on the page. The second is worse
  — the backslash splits one fediverse handle into the two LOCAL handles
  `@php` and `@tags`, so the mention-existence check refuses to save the body,
  the same shape as the `@ulrich\\_wolf` bug.

  There is no JS test runner in this project, so this is a static source check
  in the spirit of `markdown_editor_link_test.exs`, plus the Elixir half that
  proves the bare form really is what the renderer wants.
  """
  use ExUnit.Case, async: true

  alias Vutuv.Mentions

  @editor_js Path.expand("../../assets/js/markdown_editor.js", __DIR__)

  defp editor_js, do: File.read!(@editor_js)

  test "the editor canonicalizes an address on the way out" do
    assert editor_js() =~ "canonicalizeAddresses(",
           "markdown_editor.js must canonicalize `user@host` addresses — without " <>
             "it every fediverse handle a member writes is stored corrupt"
  end

  test "canonicalizeAddresses runs inside normalizeMarkdown's chain" do
    js = editor_js()

    assert js =~ ~r/normalizeMarkdown\(md\)\s*\{[\s\S]{0,400}?canonicalizeAddresses\(/,
           "canonicalizeAddresses must be part of the normalizeMarkdown chain, or " <>
             "it never runs on what the editor writes back to the form field"
  end

  test "it undoes BOTH remark spellings, not just the autolink one" do
    js = editor_js()

    assert js =~ ~S|.replace(/<([A-Za-z0-9._%+-]+@|,
           "the autolink form `<user@host>` must lose its brackets"

    assert js =~ ~S|.replace(/([A-Za-z0-9._%+-]+)\\@|,
           "the escaped form `user\\@host` must lose its backslash — this is the " <>
             "one that also breaks the mention-existence check"
  end

  describe "why the bare form is the only correct store" do
    test "a bare fediverse handle is not read as a local mention" do
      assert Mentions.local_handles("Account @php@tags.vutuv.de folgen.") == []
    end

    test "the escaped form splits one handle into two nonexistent local ones" do
      # The calibration for the fix: this is what the composer used to store,
      # and it is why saving such a post failed with "the handle @php does not
      # exist". If this ever returns [] the escape is being seen through
      # somewhere and this test has stopped guarding anything.
      assert Mentions.local_handles("Account @php\\@tags.vutuv.de folgen.") == ["php", "tags"]
    end

    test "the autolink form hides the handle from mention detection entirely" do
      assert Mentions.local_handles("Account @<php@tags.vutuv.de> folgen.") == []
    end
  end
end
