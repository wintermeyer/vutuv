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

  alias Vutuv.Accounts.User

  # `user: nil` resolves the low-bandwidth pref to the installation default,
  # which in the test env is the shipped one (the Prefs cache is off here) —
  # so the plain `editor()` below is the full-bandwidth editor everybody gets.
  defp editor(overrides \\ %{}) do
    assigns =
      Map.merge(
        %{
          id: "ed",
          name: "post[body]",
          user: nil,
          value: "hello **world**",
          label: "Body",
          placeholder: "Write something…"
        },
        overrides
      )

    render_component(&VutuvWeb.UI.markdown_editor/1, assigns)
  end

  # A member who asked for low-bandwidth mode. No DB: `Prefs.get/2` reads the
  # struct's own column and only falls back to the defaults when it is nil.
  defp thrifty_editor(overrides \\ %{}) do
    editor(Map.put(overrides, :user, %User{low_bandwidth?: true}))
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

  test "nothing stands between the member and the field (issue #1886)" do
    html = editor()

    # The eighteen-button toolbar is gone. This is the whole point of the
    # change, so it is asserted directly rather than left to follow from the
    # tests below: anything that re-grows a persistent command row above the
    # prose has to come and delete this line first.
    refute html =~ "mde__toolbar"
    refute html =~ "mde__more-row"
    refute html =~ ~s(data-mde-cmd="toggle-toolbar")
  end

  test "every rendered Markdown feature is still reachable (issue #1886)" do
    html = editor()

    # Marks ride the selection bubble: they only mean anything with something
    # selected, which is exactly when the bubble appears. The two headings ride
    # it too — the slash menu can only make a heading of a line before it is
    # written, and promoting a paragraph that already stands needs a selection.
    for cmd <- ~w(strong em strike code link h1 h2) do
      assert html =~ ~s(data-mde-mark="#{cmd}"), "missing bubble control: #{cmd}"
    end

    # Blocks ride the slash menu, reached by typing "/" on an empty line.
    for cmd <- ~w(h1 h2 blockquote code_block bullet_list ordered_list) do
      assert html =~ ~s(data-mde-block="#{cmd}"), "missing slash-menu block: #{cmd}"
    end

    # `table`, `hr` and `h3` are deliberately NOT offered as controls any more
    # — they are rare enough that a button for each cost every member a wider
    # toolbar forever. The Markdown source view is how they are reached, which
    # is why the switch below is not optional decoration but the thing that
    # keeps this cut honest.
    for cmd <- ~w(table hr h3) do
      refute html =~ ~s(data-mde-block="#{cmd}"), "#{cmd} should not be a control"
      refute html =~ ~s(data-mde-mark="#{cmd}"), "#{cmd} should not be a control"
    end

    assert html =~ ~s(data-mde-view="source")
  end

  test "task lists are intentionally NOT offered (server renders them as text)" do
    html = editor()
    refute html =~ ~s(data-mde-cmd="task)
    refute html =~ "checkbox"
  end

  test "the emoji picker is gone, the :shortcode: type-through is not (issue #1886)" do
    html = editor()

    # The picker panel went with the toolbar it hung off (Stefan, 2026-09-01:
    # "Die Emojis brauchen wir nicht"). What is NOT removed is typing `:tada:`
    # and getting 🎉 — that costs no pixels and no button, and members who use
    # it would lose it silently. If that should go too it is its own change.
    refute html =~ ~s(data-mde-cmd="emoji")

    for attr <- ~w(data-emoji-title data-emoji-search data-emoji-close
                   data-emoji-empty data-emoji-groups) do
      refute html =~ attr, "picker label attribute survived the picker: #{attr}"
    end
  end

  test "the @-mention picker's endpoints and labels ride the editor (issue #1748)" do
    html = editor()

    # Where the picker asks. Every editor gets them, because every one of these
    # bodies is rendered with mentions linked — a picker on the composer alone
    # would make the same `@handle` guesswork everywhere else.
    assert html =~ ~s(data-mention-url="/system/mentions/suggest")
    assert html =~ ~s(data-mention-check-url="/system/mentions/check")

    # And its copy, from the server for the same reason the emoji picker's is.
    assert html =~ "data-mention-label="
    assert html =~ "data-mention-empty="
  end

  test "the mention budget is shown only where a cap exists" do
    # A post may name at most `Mentions.max_post_mentions/0` accounts, so the
    # post composer passes the cap and the picker counts down against it. A
    # message has no cap; a counter there would invent a rule.
    with_limit = editor(%{mention_limit: 5})
    assert with_limit =~ ~s(data-mention-max="5")
    assert with_limit =~ "data-mention-budget="

    refute editor() =~ "data-mention-max="
    refute editor() =~ "data-mention-budget="
  end

  test "inserting a picture is a slash-menu block, where images are allowed" do
    # Not a bubble mark: a mark acts on a selection, and putting a picture at
    # the cursor is an insert. The composer's own bottom bar keeps its separate
    # "attach photos" — that one adds to the post, this one places one in the
    # prose. Message, organization and job bodies get neither.
    assert editor(%{images: true}) =~ ~s(data-mde-block="image")
    refute editor() =~ ~s(data-mde-block="image")
  end

  test "image alignment rides the bubble, for when an image is selected" do
    # Four controls that were permanently in the toolbar while meaning nothing
    # unless a picture was selected. In the bubble they appear exactly then.
    html = editor(%{images: true})

    for cmd <- ~w(img-full img-left img-center img-right) do
      assert html =~ ~s(data-mde-mark="#{cmd}"), "missing alignment control: #{cmd}"
    end

    refute editor() =~ ~s(data-mde-mark="img-full")
  end

  test "the slash menu is worded by the server (a German member types / too)" do
    Gettext.put_locale(VutuvWeb.Gettext, "de")
    on_exit(fn -> Gettext.put_locale(VutuvWeb.Gettext, "en") end)

    html = editor()

    # Same deal as the lightbox's data-label-*: the server is the only side
    # that knows the reader's language, so every word in the menu comes from
    # here and the JS ships no fallback copy of its own.
    assert html =~ "Überschrift 1"
    assert html =~ "Aufzählung"
    assert html =~ "Codeblock"
    refute html =~ ">Heading 1<"
  end

  # ── Low-bandwidth mode ──
  #
  # Every refute below is paired with the assert that proves it is not vacuous:
  # a refute on a misspelt attribute passes for the wrong reason and would hide
  # exactly the regression these tests exist to catch.

  test "a low-bandwidth member is never told where the editor bundle lives" do
    full = editor()
    thrifty = thrifty_editor()

    # The whole mechanism. A browser cannot fetch a URL that is not on the
    # page, so this one refute is the promise the setting makes.
    assert full =~ ~s(data-mde-src="/assets/markdown_editor.js")
    refute thrifty =~ "markdown_editor.js"
    refute thrifty =~ "data-mde-src"

    # And no hook to go looking for it either.
    assert full =~ ~s(phx-hook="MarkdownEditor")
    refute thrifty =~ "phx-hook"
  end

  test "a low-bandwidth member still gets a working Markdown field" do
    html = thrifty_editor()

    # The point of the setting is a cheaper composer, not a broken one: this is
    # the same real form field the no-JS fallback has always shown, carrying
    # the same value, and components.css shows it whenever data-mde-ready is
    # absent.
    assert html =~ ~s(<textarea)
    assert html =~ ~s(name="post[body]")
    assert html =~ "data-mde-source"
    assert html =~ "hello **world**"
    assert html =~ ~s(placeholder="Write something…")
    # The sr-only label keeps the field named for a screen reader.
    assert html =~ "Body"
  end

  test "none of the editor's furniture is rendered for a low-bandwidth member" do
    full = editor(%{images: true, mention_limit: 5})
    thrifty = thrifty_editor(%{images: true, mention_limit: 5})

    # The frame, the mount point, the bubble and the slash menu are the
    # editor's own scaffolding — dead markup without the hook, and on a slow
    # line the bytes are the thing being saved.
    for marker <- ["mde__frame", "data-mde-mount", "data-mde-bubble", "data-mde-slash"] do
      assert full =~ marker, "the full editor should render #{marker}"
      refute thrifty =~ marker, "low bandwidth should not render #{marker}"
    end

    # Nor the words, endpoints and language registry that only ever fed it.
    # data-mde-langs is the biggest single attribute on the root.
    for marker <- ["data-mde-langs", "data-mention-url", "data-mde-value", "data-mde-images"] do
      assert full =~ marker, "the full editor should carry #{marker}"
      refute thrifty =~ marker, "low bandwidth should not carry #{marker}"
    end
  end

  # The gate costs the OTHER member nothing.
  #
  # Two shapes make this component re-send its whole attribute list on every
  # keystroke, and both are the tidier-looking way to write the gate: collecting
  # the attributes into a `{editor_hook(assigns)}` spread (handing `assigns` to
  # a function is a strong taint in Phoenix.LiveView.Engine), and deriving
  # `low_bandwidth?` with `assign/3` instead of `Map.put/3` (which marks it
  # changed on every render). Either one re-sends the 1.6 kB fence-language
  # table per keystroke, to every member who did NOT turn low bandwidth on —
  # the exact opposite of the point. Both were measured at 2,353 bytes against
  # 422 here, which is also what the component cost before the feature existed.
  test "a keystroke does not re-send the editor's constants (change tracking)" do
    assigns = %{
      id: "ed",
      name: "post[body]",
      user: nil,
      value: String.duplicate("a", 200),
      label: "Body",
      placeholder: "Write",
      rows: 6,
      submit_on: nil,
      compact: false,
      seed: nil,
      images: false,
      help: false,
      mention_limit: nil,
      class: nil,
      rest: %{},
      # What LiveView hands a component on a re-render where only the body moved.
      __changed__: %{value: true}
    }

    rendered = VutuvWeb.UI.markdown_editor(assigns)

    # The language table is the canary: it is a compile-time constant, so it
    # must ride the full render and never a keystroke.
    assert langs?(rendered, false), "the fence-language table is not being sent at all"
    refute langs?(rendered, true), "the fence-language table is re-sent on every keystroke"

    # And the whole re-send stays in the hundreds of bytes, not the thousands.
    assert diff_size(rendered, true) < 1_000
  end

  # Every byte the socket would carry for this render, following nested
  # Rendered structs the way the diff engine does. `track?` false is a full
  # render, true is what a re-render actually re-sends.
  defp diff_size(%Phoenix.LiveView.Rendered{dynamic: dynamic}, track?),
    do: dynamic.(track?) |> Enum.map(&diff_size(&1, track?)) |> Enum.sum()

  defp diff_size(list, track?) when is_list(list),
    do: list |> Enum.map(&diff_size(&1, track?)) |> Enum.sum()

  defp diff_size(binary, _track?) when is_binary(binary), do: byte_size(binary)
  defp diff_size(_other, _track?), do: 0

  defp langs?(%Phoenix.LiveView.Rendered{dynamic: dynamic}, track?),
    do: dynamic.(track?) |> Enum.any?(&langs?(&1, track?))

  defp langs?(list, track?) when is_list(list), do: Enum.any?(list, &langs?(&1, track?))
  defp langs?(binary, _track?) when is_binary(binary), do: String.contains?(binary, "php:PHP")
  defp langs?(_other, _track?), do: false

  test "an explicit no and an untouched nil both still get the editor" do
    # The three states of a Prefs boolean, and only one of them is thrifty
    # (that one is the test above). An explicit false is a member who said no;
    # nil is a member who never chose and inherits the installation default,
    # which ships off.
    assert editor(%{user: %User{low_bandwidth?: false}}) =~ "data-mde-src"
    assert editor(%{user: %User{low_bandwidth?: nil}}) =~ "data-mde-src"
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

  test "the source view is named, not an icon (issue #1886)" do
    html = editor()

    # The old control was a button reading "MD" — the source view is how a
    # member reaches everything the smaller control set no longer offers, so it
    # cannot be a two-letter guess. Both states are named and both are on
    # screen, which is also what tells a reader the source view exists at all.
    assert html =~ ~s(data-mde-view="rich")
    assert html =~ ~s(data-mde-view="source")
    assert html =~ ">Text<"
    assert html =~ ">Markdown<"
    refute html =~ ~s(data-mde-cmd="mode")
  end

  test "the Markdown help link rides the footer row, not a line of its own" do
    html = editor(%{help: true})

    # It belongs to the source view, so it belongs beside the switch that
    # reaches it — one row rather than two. `.mde__help` is the handle
    # components.css gates it by.
    assert html =~ "mde__help"
    assert html =~ "/system/markdown"

    [above_foot, _] = String.split(html, "data-mde-foot", parts: 2)
    refute above_foot =~ "/system/markdown", "the help link still hangs above the footer"

    # Off by default: the message composer's panel has no room for it.
    refute editor() =~ "/system/markdown"
  end

  test "the footer is reachable by contract attribute, not by style class" do
    # The hook looks it up to wire the view switch and full screen. Every other
    # handle beside it (`frame`, `bubble`, `slash`, `mount`, `source`) is a
    # `data-mde-*` contract; the footer was the one taken off `.mde__foot`, so
    # a stylesheet rename would have killed both controls silently.
    assert editor() =~ "data-mde-foot"
  end

  test "the footer is NOT frozen against the server (issue #1886)" do
    html = editor()

    # `applyState/0` re-stamps `aria-pressed` inside the same patch, so the
    # subtree does not need `phx-update="ignore"` — and freezing it would strand
    # these gettext strings against a locale change and swallow anything the
    # server later renders here. If a future change adds the wrapper back it
    # owes an answer to both.
    refute html =~ ~s(id="ed-foot" phx-update="ignore")
  end

  test "every slash-menu option carries an id (issue #1886)" do
    # `aria-activedescendant` is how a screen reader follows a listbox whose
    # user is not focused on it — the caret stays in the prose while ↑/↓ walk
    # the menu, so without ids on the options the movement is announced to
    # nobody. The hook writes the attribute; the ids have to exist for it.
    assert editor() =~ ~s(id="ed-slash")
  end

  test "the full-screen control survives the toolbar it used to sit in" do
    # A shipped feature, and nobody asked for it to go: writing a long post in
    # a 3-row box is what it exists for. It moved to the footer row beside the
    # view switch rather than disappearing with the toolbar.
    assert editor() =~ ~s(data-mde-cmd="fullscreen")
  end

  test "German names both sides of the view switch" do
    Gettext.put_locale(VutuvWeb.Gettext, "de")
    on_exit(fn -> Gettext.put_locale(VutuvWeb.Gettext, "en") end)

    html = editor()

    # "Text" is the same word in both languages; "Markdown" is a proper noun.
    # What must be translated is the accessible naming around them, or a
    # screen-reader user gets an unlabelled pair of buttons.
    assert html =~ "Ansicht"
    assert html =~ "Vollbild"
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
