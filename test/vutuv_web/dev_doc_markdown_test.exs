defmodule VutuvWeb.DevDocMarkdownTest do
  use ExUnit.Case, async: true

  alias VutuvWeb.DevDocMarkdown

  describe "slug/1" do
    test "matches the GitHub-style anchors the docs link to" do
      assert DevDocMarkdown.slug("OAuth 2 for third-party apps") ==
               "oauth-2-for-third-party-apps"

      assert DevDocMarkdown.slug("Audiences: the denial model") ==
               "audiences-the-denial-model"

      assert DevDocMarkdown.slug("Public data, without a token") ==
               "public-data-without-a-token"

      assert DevDocMarkdown.slug("Errors") == "errors"
    end
  end

  describe "to_html/1" do
    test "gives every heading an id anchor so #section links resolve" do
      html = DevDocMarkdown.to_html("## OAuth 2 for third-party apps\n\nbody\n\n### Images\n")

      assert html =~ ~s(id="oauth-2-for-third-party-apps")
      assert html =~ ~s(id="images")
    end

    test "still renders the usual Markdown (links, code, lists)" do
      html = DevDocMarkdown.to_html("A [link](/x) and `code`.\n\n```bash\ncurl x\n```\n\n* one\n")

      assert html =~ ~s(<a href="/x">link</a>)
      assert html =~ "<code"
      assert html =~ "<pre>"
      assert html =~ "<li>"
    end

    test "de-duplicates repeated headings with numeric suffixes" do
      html = DevDocMarkdown.to_html("## Errors\n\nx\n\n## Errors\n\ny")

      assert html =~ ~s(id="errors")
      assert html =~ ~s(id="errors-1")
    end
  end
end
