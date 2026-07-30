defmodule VutuvWeb.MarkdownEditorTest do
  @moduledoc """
  The shared Milkdown Markdown editor component (VutuvWeb.UI.markdown_editor/1),
  used by both the post composer and the message composer. These assert the
  server-rendered scaffold the `MarkdownEditor` JS hook enhances: the hidden
  textarea is still a real form field (so submit + the no-JS fallback keep
  working), the hook mount point is present, and every Markdown feature the
  server actually renders has a toolbar command — nothing more (no task lists).
  """
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest

  defp editor(overrides \\ %{}) do
    assigns =
      Map.merge(
        %{
          id: "ed",
          name: "post[body]",
          value: "hello **world**",
          label: "Body",
          placeholder: "Write something…"
        },
        overrides
      )

    render_component(&VutuvWeb.UI.markdown_editor/1, assigns)
  end

  test "the hidden textarea stays the form field and the no-JS fallback" do
    html = editor()

    # A real <textarea name=…> carrying the value: it submits with JS off and is
    # what Milkdown mirrors into, so the server pipeline is unchanged.
    assert html =~ ~s(<textarea)
    assert html =~ ~s(name="post[body]")
    assert html =~ "data-mde-source"
    assert html =~ "hello **world**"
    # Not a single-line input.
    refute html =~ ~s(<input name="post[body]")
  end

  test "the hook mount point carries the seed markdown and placeholder" do
    html = editor()

    assert html =~ ~s(id="ed")
    assert html =~ ~s(phx-hook="MarkdownEditor")
    # data-mde-value re-seeds the editor on server-driven changes (image insert,
    # post-save reset, message clear).
    assert html =~ ~s(data-mde-value="hello **world**")
    assert html =~ ~s(data-mde-placeholder="Write something…")
    assert html =~ "data-mde-mount"
  end

  test "every rendered Markdown feature has a toolbar command" do
    html = editor()

    for cmd <- ~w(strong em strike code link h1 h2 h3 blockquote code_block
                  bullet_list ordered_list table hr) do
      assert html =~ ~s(data-mde-cmd="#{cmd}"), "missing toolbar command: #{cmd}"
    end
  end

  test "task lists are intentionally NOT offered (server renders them as text)" do
    html = editor()
    refute html =~ ~s(data-mde-cmd="task)
    refute html =~ "checkbox"
  end

  test "the emoji picker button and its labels ride the toolbar (issue #1197)" do
    html = editor()

    # The picker is offered on every editor, posts and DMs alike — an emoji in a
    # direct message is the most natural use there is.
    assert html =~ ~s(data-mde-cmd="emoji")

    # Every word the picker shows comes from the server, because the server is
    # the only side that knows the reader's language (same deal as the
    # lightbox's data-label-*). The JS supplies no fallback copy of its own.
    for attr <- ~w(data-emoji-title data-emoji-search data-emoji-close
                   data-emoji-empty data-emoji-groups) do
      assert html =~ attr, "missing picker label attribute: #{attr}"
    end
  end

  test "the phone's top row keeps only the frequent controls" do
    html = editor(%{images: true})

    # The top row is the scarce resource on a phone (Stefan, 2026-07-30: the
    # emoji button pushed the toolbar onto two lines). Bold, italic, link, emoji
    # and photo stay up there; strikethrough and inline code moved behind the
    # chevron, into `.mde__more-row` — which is what these index comparisons
    # assert, since a "tidy-up" that moves them back would silently cost the
    # phone a whole toolbar row again.
    more_row = :binary.match(html, "mde__more-row") |> elem(0)

    for cmd <- ~w(strong em link emoji image) do
      {at, _} = :binary.match(html, ~s(data-mde-cmd="#{cmd}"))
      assert at < more_row, "#{cmd} belongs in the always-visible first group"
    end

    for cmd <- ~w(strike code h1 blockquote bullet_list table hr) do
      {at, _} = :binary.match(html, ~s(data-mde-cmd="#{cmd}"))
      assert at > more_row, "#{cmd} belongs behind the chevron, not in the top row"
    end
  end

  test "the group labels cover every group the dataset ships" do
    html = editor()

    labels =
      Regex.run(~r/data-emoji-groups="([^"]*)"/, html, capture: :all_but_first)
      |> hd()
      |> String.split("|")
      |> Enum.map(&(&1 |> String.split(":", parts: 2) |> hd()))

    # The keys of the EMOJI object in assets/js/emoji_data.js. A group added
    # there without a gettext label here would render its bare key at the
    # reader — this is the drift guard for that.
    data = File.read!("assets/js/emoji_data.js")

    groups =
      ~r/^  (\w+): \[$/m
      |> Regex.scan(data, capture: :all_but_first)
      |> List.flatten()

    assert groups != [], "could not read the groups out of emoji_data.js"

    for group <- groups do
      assert group in labels, "emoji group #{group} has no label in markdown_editor/1"
    end

    assert Enum.sort(labels) == Enum.sort(groups)
  end

  test "the picker labels are translated (a German member picks emoji too)" do
    Gettext.put_locale(VutuvWeb.Gettext, "de")
    on_exit(fn -> Gettext.put_locale(VutuvWeb.Gettext, "en") end)

    html = editor()

    assert html =~ ~s(data-emoji-title="Emoji")
    assert html =~ ~s(data-emoji-search="Emoji suchen")
    assert html =~ "Smileys"
    refute html =~ "Search emoji"
  end

  test "power users get a WYSIWYG/source toggle and a full-screen control" do
    html = editor()
    assert html =~ ~s(data-mde-cmd="mode")
    assert html =~ ~s(data-mde-cmd="fullscreen")
  end

  test "submit_on and compact are passed through for the message composer" do
    html = editor(%{name: "message[body]", submit_on: "cmd-enter", compact: true, rows: 2})

    assert html =~ ~s(name="message[body]")
    assert html =~ ~s(data-mde-submit="cmd-enter")
    assert html =~ "mde--compact"
    assert html =~ ~s(rows="2")
  end
end
