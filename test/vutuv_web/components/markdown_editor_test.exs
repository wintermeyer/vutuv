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
    # data-mde-value seeds the editor at mount.
    assert html =~ ~s(data-mde-value="hello **world**")
    assert html =~ ~s(data-mde-placeholder="Write something…")
    assert html =~ "data-mde-mount"
  end

  test "the re-seed token rides the root, and only a change of it means re-seed" do
    # The editor takes `value` again when `seed` CHANGES, never because the
    # rendered value differs from what it last sent: the composer echoes the
    # body back on every keystroke, and re-parsing the document on such an echo
    # moves the caret (and drops anything typed since that render was built).
    # A form that is only ever seeded at mount passes no seed at all.
    assert editor(%{seed: 3}) =~ ~s(data-mde-seed="3")
    refute editor() =~ "data-mde-seed"
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

  test "the fence-language labels ride the editor root (issues #1108/#1137/#1138)" do
    html = editor()

    # The composer's code-block preview names a block the way the published
    # page will (`PHP`, not `php`), and the display names come from the server
    # so VutuvWeb.CodeHighlight.Languages stays the only registry — the same
    # arrangement as the emoji group labels above.
    assert [langs] =
             Regex.run(~r/data-mde-langs="([^"]*)"/, html, capture: :all_but_first)

    pairs =
      langs
      |> String.split("|")
      |> Map.new(fn pair ->
        [name, label] = String.split(pair, ":", parts: 2)
        {name, label}
      end)

    assert pairs["php"] == "PHP"
    assert pairs["elixir"] == "Elixir"
    # An alias resolves to its language's label.
    assert pairs["js"] == "JavaScript"
    # The "no language" words are present with an EMPTY label, so the editor
    # knows to leave such a block alone (the published page shows no label
    # for them either).
    assert pairs["text"] == ""
    assert pairs["plain"] == ""
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

  # Every call site either hands the editor a re-seed token or is named here
  # with the reason it needs none. Silence is the hazard: an editor whose value
  # the server changes after mount without moving the token keeps showing the
  # old prose AND writes that old text back over the form field, so the save
  # stores it too. The two exempt forms never touch the value after mount —
  # they only echo it through `validate`, and every save path push_navigates
  # (which re-mounts). Add a seed the moment either grows a reset, a template
  # picker or any other server-driven rewrite.
  @seedless %{
    "lib/vutuv_web/live/organization_live/edit.ex" => "seeded at mount, saves navigate away",
    "lib/vutuv_web/live/job_posting_live/form.ex" => "seeded at mount, saves navigate away"
  }

  test "every markdown_editor call site passes a re-seed token, or is exempt by name" do
    call_sites =
      "lib/**/*.ex"
      |> Path.wildcard()
      |> Enum.filter(&(File.read!(&1) =~ "<.markdown_editor"))
      |> Enum.reject(&(&1 =~ "components/ui.ex"))

    # A guard that finds nothing has stopped guarding.
    assert length(call_sites) >= 4

    for path <- call_sites, not Map.has_key?(@seedless, path) do
      source = File.read!(path)

      assert source =~ ~r/<\.markdown_editor\b[^>]*\bseed=/s,
             "#{path} renders a markdown_editor without a seed. Bump a counter where " <>
               "the editor must take the server's value again, or add the file to " <>
               "@seedless in #{__ENV__.file |> Path.relative_to_cwd()} with the reason."
    end
  end

  # The Milkdown stack is 64% of the JS and rides its own esbuild entry point
  # (config/config.exs), so app.js no longer contains it: the hook reads this
  # attribute and `import()`s the bundle when a composer actually mounts. Lose
  # the attribute and nothing raises — the hook simply returns, and every
  # composer on the site quietly degrades to the plain textarea fallback. That
  # is precisely the kind of silent regression that survives a release, hence
  # this test.
  test "the mount point tells the hook where to fetch the editor bundle" do
    html = editor()

    assert html =~ "data-mde-src="

    assert html =~ ~r/data-mde-src="[^"]*\/assets\/markdown_editor[^"]*\.js/,
           "data-mde-src must resolve to the markdown_editor bundle: #{html}"
  end
end
