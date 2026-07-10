defmodule VutuvWeb.AgentDocs.MarkdownFormatTest do
  @moduledoc """
  The CommonMark shape of the agent-doc Markdown (`VutuvWeb.AgentDocs.Markdown`):
  a valid YAML frontmatter (issue #924), a blank line between list items
  (issue #925) and indented continuation lines for multi-paragraph list-item
  content (issue #926). Content parity lives in `agent_docs_drift_test.exs`;
  this file guards the *formatting* those issues were about.
  """

  use VutuvWeb.ConnCase, async: true

  setup do
    user = insert_activated_user(username: "md_shape", first_name: "Mona", last_name: "Down")
    %{user: user}
  end

  # Everything between the opening and closing `---` of the Markdown document.
  defp frontmatter(body) do
    ["", yaml, _rest] = String.split(body, "---\n", parts: 3)
    yaml
  end

  describe "YAML frontmatter (#924)" do
    test "carries no bare value line — every line is a key/value pair", %{user: user} do
      yaml = frontmatter(get(build_conn(), "/#{user.username}.md").resp_body)

      for line <- String.split(yaml, "\n"), line != "" do
        assert line =~ ~r/^[a-z_]+: /,
               "frontmatter line is not a `key: value` pair: #{inspect(line)}"
      end
    end

    test "a member who has not opted out emits no noindex/noai lines (never a bare false)",
         %{user: user} do
      yaml = frontmatter(get(build_conn(), "/#{user.username}.md").resp_body)

      refute yaml =~ ~r/^false$/m
      refute yaml =~ "noindex:"
      refute yaml =~ "noai:"
    end

    test "a noindexed profile emits the real key, still no bare false" do
      # Only noindex?: setting both flags blocks the agent docs entirely
      # (AgentExportOptOut), so a rendered profile doc never carries both.
      user = insert_activated_user(username: "opted_out", noindex?: true, noai?: false)
      yaml = frontmatter(get(build_conn(), "/#{user.username}.md").resp_body)

      assert yaml =~ "noindex: true"
      refute yaml =~ "noai:"
      refute yaml =~ ~r/^false$/m
    end

    test "a section page carries both real noindex/noai keys, no bare false", %{user: user} do
      insert(:work_experience, user: user, title: "Ranger", organization: "Parks")
      # The section pages run through the NoIndex pipeline, so both flags are true.
      yaml = frontmatter(get(build_conn(), "/#{user.username}/work_experiences.md").resp_body)

      assert yaml =~ "noindex: true"
      assert yaml =~ "noai: true"
      refute yaml =~ ~r/^false$/m
    end
  end

  describe "multi-paragraph list-item content is indented (#926)" do
    test "a work experience description's continuation paragraphs stay inside the item",
         %{user: user} do
      insert(:work_experience,
        user: user,
        title: "Ranger",
        organization: "Parks",
        description: "First paragraph.\n\nSecond paragraph.\n\nThird paragraph."
      )

      body = get(build_conn(), "/#{user.username}.md").resp_body

      # The first paragraph rides the `- ` marker line; the rest are indented
      # two columns (the marker width) so they render as the item's own
      # paragraphs, not top-level text that broke out of the list.
      assert body =~ "First paragraph.\n\n  Second paragraph.\n\n  Third paragraph."

      # And never the broken form where a continuation sits at column zero.
      refute body =~ "\n\nSecond paragraph."
    end

    test "the same holds on a single work-experience show page", %{user: user} do
      work =
        insert(:work_experience,
          user: user,
          title: "Ranger",
          organization: "Parks",
          description: "Intro line.\n\nDetail line."
        )

      body = get(build_conn(), "/#{user.username}/work_experiences/#{work.slug}.md").resp_body

      assert body =~ "Intro line.\n\n  Detail line."
    end
  end

  describe "list items are blank-line separated (#925)" do
    test "consecutive profile tags are separated by a blank line", %{user: user} do
      for {name, slug} <- [{"alpha", "alpha"}, {"beta", "beta"}] do
        insert(:user_tag, user: user, tag: insert(:tag, name: name, slug: slug))
      end

      body = get(build_conn(), "/#{user.username}.md").resp_body

      # Two adjacent `- [tag]` items with a blank line between them.
      assert body =~ ~r/^- \[alpha\].*\n\n- \[beta\]/m
    end

    test "a section index page separates its entries with a blank line", %{user: user} do
      insert(:work_experience, user: user, title: "First role", organization: "One")
      insert(:work_experience, user: user, title: "Second role", organization: "Two")

      body = get(build_conn(), "/#{user.username}/work_experiences.md").resp_body

      # Some pair of bullet lines is blank-line separated (order is date-based).
      assert body =~ ~r/^- .+\n\n- /m
    end
  end
end
