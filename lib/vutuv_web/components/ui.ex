defmodule VutuvWeb.UI do
  @moduledoc """
  Direction A design-system components — reuse these on hand-written pages so the
  visual language stays consistent and DRY. See `.claude/rules/design.md` for the
  full spec and raw-utility recipes. Legacy controller pages are styled centrally
  in `assets/css/components.css`, not here.

  Imported into every HTML view and LiveView via `VutuvWeb` (`html`, `live_view`,
  `live_component`), so all of these are available everywhere with no explicit
  import: `<.card>`, `<.section_title>`, `<.section_header>`, `<.card_menu>`,
  `<.chip>`, `<.button>`, `<.avatar>`, `<.count_badge>`, `<.pager>`.
  """
  use Phoenix.Component
  use Gettext, backend: VutuvWeb.Gettext

  # `<.follow_button>` owns the ~p"/follows…" route shapes, so it needs the
  # verified-route sigil and the `button/2` helper for its icon/text variants.
  use Phoenix.VerifiedRoutes,
    endpoint: VutuvWeb.Endpoint,
    router: VutuvWeb.Router,
    statics: ~w(assets fonts images favicon.ico)

  import PhoenixHTMLHelpers.Link, only: [button: 2]
  # `<.announce_to_followers_field>` is shared by the three CV section forms
  # (different view modules), so it lives here and needs the form helper the
  # legacy templates get from `use PhoenixHTMLHelpers`.
  import PhoenixHTMLHelpers.Form, only: [checkbox: 3]

  alias Vutuv.Accounts.User
  alias Vutuv.DateRegions
  alias Vutuv.Organizations.Organization
  alias Vutuv.Organizations.OrganizationImage
  alias Vutuv.Posts
  alias Vutuv.Tags.UserTag
  alias Vutuv.Uploads.Spec
  alias Vutuv.ViewerClock
  alias VutuvWeb.AgentDocs
  alias VutuvWeb.CodeHighlight.Languages
  alias VutuvWeb.JsonLd
  alias VutuvWeb.Markdown

  @doc """
  Render a user-written Markdown prose field — a work-experience or education
  `description` (issue #905) — as sanitized HTML in the Direction A `.markdown`
  body recipe. It runs through `VutuvWeb.Markdown.render/1`, so a description
  gets the same treatment a post and the profile tagline do: paragraphs and
  line breaks, bold / italic, bullet and numbered lists, links, `@handle` /
  `#hashtag` linking, raw HTML escaped and images stripped. Headings flatten to
  bold body text (`markdown--post`) so a stray heading can't blow up a compact
  timeline card. `class` carries the surrounding text size / colour utilities.
  """
  attr(:text, :string, required: true)
  attr(:class, :any, default: nil)

  def markdown_prose(assigns) do
    ~H"""
    <div class={["markdown markdown--post", @class]}>{Markdown.render(@text)}</div>
    """
  end

  @doc """
  The horizontal page gutter, widened to clear a display cutout (issue #1464).

  The installed web app declares `viewport-fit=cover`, so the page paints edge
  to edge and a landscape phone lays its sensor housing over one side of it —
  about 47px on the notched iPhones. Where a container holds the page's own
  1rem gutter, it takes the larger of the two instead, which is exactly 1rem
  on every device that reports no inset (portrait, desktop, anything without a
  cutout).

  Used by the containers that carry the reading width: the top bar's inner
  track, `<main>` and the footer's content column. A container that is already
  inside one of those needs nothing — the insets do not stack.
  """
  def gutter_class do
    "pl-[max(1rem,env(safe-area-inset-left))] pr-[max(1rem,env(safe-area-inset-right))]"
  end

  @doc """
  Shared input class for hand-written (kit-page) form fields — the Direction A
  input recipe (full width, rounded, slate border, brand focus ring, dark-aware).
  The single source for the post composer, the auth pages and any green-field
  form, so the field look stays consistent. Compose with utilities via a list,
  e.g. `class={[input_class(), "resize-y"]}`.
  """
  def input_class do
    "w-full rounded-lg border border-slate-300 bg-white px-3 py-2 text-sm focus:border-brand-500 focus:outline-none focus:ring-3 focus:ring-brand-500/40 dark:border-slate-700 dark:bg-slate-800 dark:text-slate-100"
  end

  @doc """
  Like `input_class/0`, but aware of a specific field's validation state: once
  `field` carries an error the calm slate border swaps for the error red (with
  a matching red focus border), so the failed field is marked on the input
  itself — the promise the `<.form_error>` banner makes ("the fields marked in
  red"). A clean field renders exactly `input_class/0`. Pair it with
  `aria-invalid` on the input and `error_tag/2` below it; compose extra
  utilities the same way: `class={[input_class(f, :value), "resize-y"]}`.

  The two strings are the same recipe except for the border colours — keep
  them in step when the input recipe changes (see .claude/rules/design.md).
  """
  def input_class(form, field), do: input_class(form.errors[field] != nil)

  @doc """
  The same recipe keyed on a bare validity flag, for hand-built forms that
  carry no changeset (the admin preference forms): `input_class(true)` is the
  error-red variant, `input_class(false)` is exactly `input_class/0`.
  """
  def input_class(invalid?) when is_boolean(invalid?) do
    if invalid? do
      "w-full rounded-lg border border-red-400 bg-white px-3 py-2 text-sm focus:border-red-500 focus:outline-none focus:ring-3 focus:ring-red-500/40 dark:border-red-500/70 dark:bg-slate-800 dark:text-slate-100"
    else
      input_class()
    end
  end

  @doc """
  Shared checkbox class for hand-written (kit-page) consent/opt-in boxes —
  the companion to `input_class/0` (brand check on a rounded slate box,
  top-aligned beside its label text, dark-aware). The single source for
  the sign-up form's consent checkboxes.
  """
  def checkbox_class do
    "mt-0.5 h-4 w-4 rounded border-slate-300 text-brand-600 focus:ring-2 focus:ring-brand-500 focus:ring-offset-2 dark:border-slate-600 dark:bg-slate-800 dark:focus:ring-offset-slate-900"
  end

  @doc """
  Shared classes for a hand-written radio group: the control itself and the
  label row it sits in. The radio companions to `input_class/0` and
  `checkbox_class/0`, and deliberately not derived from `checkbox_class/0` —
  that one carries `rounded`, `mt-0.5` and a ring offset a radio does not want.

  The single source for the groups that render one: the sign-up form's gender
  and email-type choices, the one-time welcome page, and the profile editor's
  gender question. Those spelled the same two strings out four times over
  before this existed.
  """
  def radio_class do
    "h-4 w-4 border-slate-300 text-brand-600 focus:ring-brand-500 dark:border-slate-600 dark:bg-slate-800"
  end

  @doc "The label row wrapping a `radio_class/0` control and its wording."
  def radio_label_class do
    "flex items-center gap-2 text-sm font-normal text-slate-700 dark:text-slate-200"
  end

  @doc """
  The shared **tag pill box** — one component for every field where a member
  types a batch of tags: the add-tag form, the sign-up landing page, the
  invitation form, the post composer and both job-posting tag fields (DRY).

  A comma, and nothing else, separates two tags (`Vutuv.Tags.parse_tag_names/1`).
  A plain text box shows no seam between one tag and the next, so members read
  the space as a separator too and created tags they never meant to. Here each
  finished tag turns into a pill the moment its comma is typed, and every pill
  carries its own ✕ — the rule is visible in the box rather than explained in a
  hint below it.

  Progressive enhancement, not a widget: this renders one ordinary
  `<input type="text">` holding the comma-joined value, which **is** the feature
  with JS off. `assets/js/tag_input.js` then switches that input to `hidden`
  (it stays the form field, so nothing about the request or the server changes),
  builds the pill box beside it and mirrors every change back — including the
  half-typed tail, so a submit mid-word keeps that word.

  It works on both page styles from one call: inside a LiveView the `TagInput`
  hook enhances it, on a classic controller page the `[data-tag-input]` sweep in
  `app.js` does. The root is `phx-update="ignore"` because the pills are the
  client's, while its attributes still patch — which is how a server-driven
  value change reaches the box: `data-value` mirrors `@value` and the hook
  re-seeds the pills from it (a restored draft, the composer clearing after a
  post), ignoring the echo of what it sent itself.

  `field_class` styles the no-JS input (`input_class/0` on a kit page, nothing on
  a classic `.editform` page, which styles its inputs centrally); the enhanced
  box reproduces that same look from `components.css`. Pass `field_id` when a
  `<label for=…>` or an `error_tag/2` span points at the field — the JS moves
  that id onto the box the member types in, so the label keeps working.

  `max` caps how many pills the box takes (issue #1237). Past it the box keeps
  the refused text in the entry instead of swallowing it and names the limit
  underneath, so nothing a member typed disappears. It is deliberately **per
  instance**: only a post has a tag cap (`Vutuv.Posts.max_tags_per_post/0`), and
  a number baked into the component or the JS would silently cap the profile,
  invitation, landing-page and job-posting fields too.
  """
  attr(:id, :string, required: true, doc: "DOM id of the widget root")
  attr(:name, :string, required: true, doc: "the form field name, e.g. user[tag_list]")
  attr(:field_id, :string, default: nil, doc: "id of the input; defaults to <id>-field")
  attr(:value, :string, default: "")
  attr(:placeholder, :string, default: "")
  attr(:field_class, :any, default: nil, doc: "class for the plain (no-JS) input")
  attr(:invalid?, :boolean, default: false, doc: "mark the box as failed validation")
  attr(:max, :integer, default: nil, doc: "cap on the number of pills; nil = uncapped")
  attr(:class, :any, default: nil)
  attr(:rest, :global, doc: "lands on the field (phx-debounce, aria-describedby, …)")

  def tag_input(assigns) do
    ~H"""
    <div
      id={@id}
      class={["tag-input", @invalid? && "tag-input--error", @class]}
      phx-hook="TagInput"
      phx-update="ignore"
      data-tag-input
      data-value={@value}
      data-more-placeholder={gettext("Add another tag")}
      data-remove-label={remove_tag_label()}
      data-max={@max}
      data-limit-message={@max && tag_limit_message(@max)}
    >
      <input
        type="text"
        id={@field_id || "#{@id}-field"}
        name={@name}
        value={@value}
        placeholder={@placeholder}
        class={@field_class}
        autocomplete="off"
        data-tag-input-field
        {@rest}
      />
    </div>
    """
  end

  # The ✕ button's accessible name. The `%{name}` deliberately survives
  # translation: the JS fills the tag in, so a screen reader announces "Remove
  # the tag Elixir" rather than fifteen identical "Remove" buttons.
  defp remove_tag_label, do: gettext("Remove the tag %{name}", name: "%{name}")

  # What the box says once it is full. It names the way out, not just the rule:
  # the pills are all removable, so the member is one ✕ away from adding the tag
  # they actually want.
  defp tag_limit_message(max),
    do: gettext("At most %{max} tags. Remove one to add another.", max: max)

  @doc """
  The shared **Milkdown WYSIWYG Markdown editor** — one component for the post
  composer and the message composer (DRY). It is a rich-text surface over a
  plain-Markdown store: the real form field is the `<textarea name={@name}>`
  holding Markdown *source*, and the `MarkdownEditor` JS hook renders/edits that
  source with Milkdown. Nothing on the server changes — `VutuvWeb.Markdown`
  still renders the stored source and the agent-format siblings are untouched.

  Everyone gets the WYSIWYG view by default; the "MD" toolbar button toggles to
  a raw-Markdown source view for power users, and "⤢" expands to a near
  full-page editor. With JS off the plain textarea shows through as the fallback.

  The offered features are exactly the subset `VutuvWeb.Markdown` renders: bold,
  italic, strikethrough (durchgestrichen), links, bullet / ordered / nested
  lists, headings, blockquote, inline + fenced code, tables and horizontal
  rules. Task-list checkboxes are deliberately absent (Earmark renders them as
  literal text).

  `@value` is the current Markdown source. It seeds the editor once, at mount;
  after that the editor owns the prose and the server's echo of it is ignored,
  because a re-render lands on every keystroke and re-parsing the document
  would move the caret. To hand the editor new text later — the post-save
  reset, "Discard draft", the message-send clear — change `@seed`: the hook
  re-seeds from `@value` when, and only when, that token changes. Pass
  `submit_on="cmd-enter"` so Cmd/Ctrl+Enter submits the surrounding form —
  the post and the message composers both do (issue #1196); the hook skips
  the shortcut while the form's submit button is disabled.
  """
  attr(:id, :string, required: true)
  attr(:name, :string, required: true, doc: "the form field name, e.g. post[body]")
  attr(:value, :string, default: "")
  attr(:label, :string, required: true, doc: "sr-only label for the field")
  attr(:placeholder, :string, default: "")
  attr(:rows, :integer, default: 6, doc: "rows of the source/fallback textarea")
  attr(:submit_on, :string, default: nil, values: [nil, "cmd-enter"])
  attr(:compact, :boolean, default: false, doc: "tighter min-height (messages)")

  attr(:seed, :any,
    default: nil,
    doc:
      "re-seed token: change it (a counter is enough) to make the editor take " <>
        "`value` again — the post-save reset, \"Discard draft\", the " <>
        "message-send clear. A form that is only ever seeded at mount leaves it nil"
  )

  attr(:images, :boolean,
    default: false,
    doc:
      "allow inline post images: enables the 🖼 toolbar button (opens the form's " <>
        "file input), drop/paste-to-upload, the per-image alignment controls and " <>
        "own-upload `![](…)` nodes in the prose. Post composer only — message, " <>
        "organization and job bodies stay image-free"
  )

  attr(:help, :boolean,
    default: false,
    doc:
      "render the quiet `/system/markdown` link under the editor. On the post " <>
        "composer, where a member writes prose; off in the message composer, " <>
        "whose panel has no room for a second line"
  )

  attr(:class, :string, default: nil)
  attr(:rest, :global)

  def markdown_editor(assigns) do
    ~H"""
    <div
      id={@id}
      phx-hook="MarkdownEditor"
      data-mde-src={~p"/assets/markdown_editor.js"}
      data-mde-value={@value}
      data-mde-seed={@seed}
      data-mde-placeholder={@placeholder}
      data-mde-submit={@submit_on}
      data-mde-images={@images && "1"}
      data-mde-link-prompt={gettext("Link URL")}
      data-emoji-title={gettext("Emoji")}
      data-emoji-search={gettext("Search emoji")}
      data-emoji-close={gettext("Close")}
      data-emoji-empty={gettext("No emoji found.")}
      data-emoji-groups={emoji_group_labels()}
      data-mde-langs={code_fence_labels()}
      class={["mde", @compact && "mde--compact", @class]}
      {@rest}
    >
      <div id={"#{@id}-frame"} data-mde-frame phx-update="ignore" class="mde__frame">
        <div data-mde-toolbar class="mde__toolbar" role="toolbar" aria-label={gettext("Formatting")}>
          <div class="mde__group">
            <.mde_button cmd="strong" title={gettext("Bold")}>
              <span class="font-bold">B</span>
            </.mde_button>
            <.mde_button cmd="em" title={gettext("Italic")}>
              <span class="font-serif italic">I</span>
            </.mde_button>
            <.mde_button cmd="link" title={gettext("Link")}>
              <.mde_icon d="M13.19 8.688a4.5 4.5 0 0 1 1.242 7.244l-4.5 4.5a4.5 4.5 0 0 1-6.364-6.364l1.757-1.757m13.35-.622 1.757-1.757a4.5 4.5 0 0 0-6.364-6.364l-4.5 4.5a4.5 4.5 0 0 0 1.242 7.244" />
            </.mde_button>
            <%!-- Emoji: offered on every editor, posts and DMs alike. The button
            stays in the first group so it is one tap away on a phone, where the
            secondary groups are collapsed behind the chevron. --%>
            <.mde_button cmd="emoji" title={gettext("Emoji")}>
              <.mde_icon d="M12 21.75a9.75 9.75 0 1 0 0-19.5 9.75 9.75 0 0 0 0 19.5ZM8.4 14.4a4.5 4.5 0 0 0 7.2 0M9 9.75h.008v.008H9zM15 9.75h.008v.008H15z" />
            </.mde_button>
            <.mde_button :if={@images} cmd="image" title={gettext("Insert image")}>
              <.mde_icon d="m2.25 15.75 5.159-5.159a2.25 2.25 0 0 1 3.182 0l5.159 5.159m-1.5-1.5 1.409-1.409a2.25 2.25 0 0 1 3.182 0l2.909 2.909m-18 3.75h16.5a1.5 1.5 0 0 0 1.5-1.5V6a1.5 1.5 0 0 0-1.5-1.5H3.75A1.5 1.5 0 0 0 2.25 6v12a1.5 1.5 0 0 0 1.5 1.5Zm10.5-11.25h.008v.008h-.008V8.25Z" />
            </.mde_button>
          </div>

          <%!-- Image alignment: shown only while an image node is selected in
          the prose (the hook stamps data-mde-img on the root). The choice is
          stored as a `#left`/`#right`/`#center` fragment on the image src; no
          fragment = full text width (VutuvWeb.Markdown maps it to the
          post-inline-image--* modifier at render time). --%>
          <div :if={@images} class="mde__group mde__group--image">
            <span class="mde__sep" aria-hidden="true"></span>
            <.mde_button cmd="img-full" title={gettext("Full width")}>
              <.mde_icon d="M3 5h18v10H3zM3 19h18" />
            </.mde_button>
            <.mde_button cmd="img-left" title={gettext("Float left")}>
              <.mde_icon d="M3 5h8v8H3zM14 6h7M14 10h7M3 17h18" />
            </.mde_button>
            <.mde_button cmd="img-center" title={gettext("Center")}>
              <.mde_icon d="M8 5h8v8H8zM3 17h18" />
            </.mde_button>
            <.mde_button cmd="img-right" title={gettext("Float right")}>
              <.mde_icon d="M13 5h8v8h-8zM3 6h7M3 10h7M3 17h18" />
            </.mde_button>
          </div>

          <%!-- Mobile only: collapses the toolbar to one row (the inline group +
          controls); tapping it reveals the `--more` groups below. Hidden on sm+,
          where the whole toolbar fits on one line. The chevron flips when open. --%>
          <button
            type="button"
            data-mde-cmd="toggle-toolbar"
            class="mde__btn mde__more-toggle"
            title={gettext("More formatting")}
            aria-label={gettext("More formatting")}
            aria-expanded="false"
            tabindex="-1"
          >
            <.mde_icon d="M6 9l6 6 6-6" />
          </button>

          <div class="mde__more-row">
            <span class="mde__sep" aria-hidden="true"></span>

            <%!-- Strikethrough and inline code live HERE, not in the first group:
            on a phone the top row is the scarce resource, and these two are used
            far less often than link / emoji / photo. They are the first thing the
            chevron reveals, and on sm+ they simply read as their own cluster
            between the always-visible marks and the block controls. --%>
            <div class="mde__group">
              <.mde_button cmd="strike" title={gettext("Strikethrough")}>
                <span class="line-through">S</span>
              </.mde_button>
              <.mde_button cmd="code" title={gettext("Inline code")}>
                <.mde_icon d="M17.25 6.75 22.5 12l-5.25 5.25m-10.5 0L1.5 12l5.25-5.25" />
              </.mde_button>
            </div>

            <span class="mde__sep" aria-hidden="true"></span>

            <div class="mde__group">
            <.mde_button cmd="h1" title={gettext("Heading 1")}>
              <span class="text-xs font-bold">H1</span>
            </.mde_button>
            <.mde_button cmd="h2" title={gettext("Heading 2")}>
              <span class="text-xs font-bold">H2</span>
            </.mde_button>
            <.mde_button cmd="h3" title={gettext("Heading 3")}>
              <span class="text-xs font-bold">H3</span>
            </.mde_button>
            <.mde_button cmd="blockquote" title={gettext("Quote")}>
              <.mde_icon d="M6 5v14M10 8h8M10 12h8M10 16h5" />
            </.mde_button>
            <.mde_button cmd="code_block" title={gettext("Code block")}>
              <.mde_icon d="M14.25 9.75 16.5 12l-2.25 2.25m-4.5 0L7.5 12l2.25-2.25M5.25 4.5h13.5A.75.75 0 0 1 19.5 5.25v13.5a.75.75 0 0 1-.75.75H5.25a.75.75 0 0 1-.75-.75V5.25a.75.75 0 0 1 .75-.75Z" />
            </.mde_button>
          </div>

          <span class="mde__sep" aria-hidden="true"></span>

          <div class="mde__group">
            <.mde_button cmd="bullet_list" title={gettext("Bullet list")}>
              <.mde_icon d="M8.25 6.75h12M8.25 12h12M8.25 17.25h12M3.9 6.75h.008v.008H3.9zM3.9 12h.008v.008H3.9zM3.9 17.25h.008v.008H3.9z" />
            </.mde_button>
            <.mde_button cmd="ordered_list" title={gettext("Numbered list")}>
              <span class="font-mono text-xs font-bold">1.</span>
            </.mde_button>
          </div>

          <span class="mde__sep" aria-hidden="true"></span>

          <div class="mde__group">
            <.mde_button cmd="table" title={gettext("Table")}>
              <.mde_icon d="M3.75 6.75h16.5v10.5H3.75zM3.75 10.5h16.5M3.75 14.25h16.5M9.75 6.75v10.5" />
            </.mde_button>
            <.mde_button cmd="hr" title={gettext("Divider")}>
              <.mde_icon d="M4 12h16" />
            </.mde_button>
          </div>
          </div>

          <span class="mde__spacer"></span>

          <div class="mde__controls">
            <.mde_button cmd="mode" title={gettext("Toggle Markdown source")}>
              <span class="text-xs font-bold tracking-tight">MD</span>
            </.mde_button>
            <.mde_button cmd="fullscreen" title={gettext("Full screen")}>
              <.mde_icon d="M3.75 8.25v-4.5h4.5M20.25 8.25v-4.5h-4.5M3.75 15.75v4.5h4.5M20.25 15.75v4.5h-4.5" />
            </.mde_button>
          </div>
        </div>

        <div data-mde-mount class="mde__mount"></div>
      </div>

      <label for={"#{@id}-source"} class="sr-only">{@label}</label>
      <textarea
        id={"#{@id}-source"}
        name={@name}
        data-mde-source
        rows={@rows}
        placeholder={@placeholder}
        class="mde__source"
      >{@value}</textarea>

      <p :if={@help} class="mt-1 text-right">
        <.markdown_help_link />
      </p>
    </div>
    """
  end

  @doc """
  The quiet link to `/system/markdown`, the page that shows what a member may
  write and what it will look like.

  One component rather than a sentence per form: the wording, the target and
  the muted styling are the same wherever somebody writes prose, and the page
  is the only place the syntax is documented, so a form that has a "Markdown is
  supported" hint but no way to find out what that means is a dead end. Opens
  in a new tab, since the reader is in the middle of writing something.
  """
  attr(:class, :string, default: nil)

  def markdown_help_link(assigns) do
    ~H"""
    <.link
      href="/system/markdown"
      target="_blank"
      rel="noopener"
      class={[
        "text-xs font-medium text-slate-600 hover:text-brand-700 dark:hover:text-brand-300",
        "dark:text-slate-400 dark:hover:text-brand-300",
        @class
      ]}
    >
      {gettext("Markdown help")}
    </.link>
    """
  end

  attr(:cmd, :string, required: true)
  attr(:title, :string, required: true)
  slot(:inner_block, required: true)

  defp mde_button(assigns) do
    ~H"""
    <button
      type="button"
      data-mde-cmd={@cmd}
      class="mde__btn"
      title={@title}
      aria-label={@title}
      tabindex="-1"
    >
      {render_slot(@inner_block)}
    </button>
    """
  end

  attr(:d, :string, required: true)

  defp mde_icon(assigns) do
    ~H"""
    <svg
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      stroke-width="1.7"
      stroke-linecap="round"
      stroke-linejoin="round"
      class="h-4 w-4"
      aria-hidden="true"
    >
      <path d={@d} />
    </svg>
    """
  end

  # The emoji picker's group tabs, as "key:Label|key:Label" for the JS to parse
  # (`data-emoji-groups`). The keys are the groups of `EMOJI_GROUPS` in
  # `assets/js/emoji_data.js`; the labels are the only translated words in the
  # picker, since the emoji themselves are named by their language-neutral
  # shortcode. A group in the dataset with no label here would render its bare
  # key — `markdown_editor_test.exs` fails the build on that drift.
  # A label may not contain a "|" (the pair separator); a ":" is fine, the JS
  # splits on the first one only.
  defp emoji_group_labels do
    [
      {"smileys", gettext("Smileys")},
      {"people", gettext("People")},
      {"nature", gettext("Animals & nature")},
      {"food", gettext("Food & drink")},
      {"activity", gettext("Activities")},
      {"travel", gettext("Travel & places")},
      {"objects", gettext("Objects")},
      {"symbols", gettext("Symbols")}
    ]
    |> Enum.map_join("|", fn {key, label} -> "#{key}:#{label}" end)
  end

  # The fence-language display names for the composer's code-block preview
  # (issues #1108, #1137, #1138), as "word:Label|word:Label" on the editor root
  # (`data-mde-langs`) — the same arrangement as the emoji group labels above:
  # the server is the only side that holds the registry, so the preview names a
  # block exactly the way the published page will ("PHP", not "php"), and the
  # "no language" words carry an empty label, the sign to leave such a block
  # alone. Built at compile time: the registry is static, and the composer
  # re-renders on every keystroke. A fence word never contains `:` or `|` and a
  # label never `|` (code_highlight_test.exs pins that), so the format is safe.
  @code_fence_labels Languages.editor_labels()
                     |> Enum.sort()
                     |> Enum.map_join("|", fn {word, label} -> "#{word}:#{label}" end)

  defp code_fence_labels, do: @code_fence_labels

  @doc """
  Wraps every case-insensitive occurrence of `needles` (a string or a list of
  strings) in `text` in a brand-tinted `<mark>` — the search result match
  marker. Returns safe HTML built from escaped parts; `nil`/empty needles
  return the text unchanged (HEEx escapes it as usual).
  """
  def highlight(text, needles) when is_binary(text) do
    needles = needles |> List.wrap() |> Enum.filter(&(is_binary(&1) and &1 != ""))

    if needles == [] do
      text
    else
      downcased = Enum.map(needles, &String.downcase/1)
      pattern = compiled_needle_pattern(Enum.map_join(needles, "|", &Regex.escape/1))

      marked =
        text
        |> String.split(pattern, include_captures: true)
        |> Enum.map(&mark_part(&1, downcased))

      {:safe, marked}
    end
  end

  # `highlight/2` is called once per row on /search and the follower/following/
  # tag listings, always with the *same* needle within a render, so compiling
  # the identical pattern per row is wasted work. Memoize the last needle
  # source -> %Regex{} in the process dictionary: a render loop shares one
  # compile, and the single-entry cache stays O(1) memory even as the search
  # term changes between requests on a long-lived LiveView process.
  defp compiled_needle_pattern(source) do
    case Process.get(:ui_highlight_pattern) do
      {^source, regex} ->
        regex

      _ ->
        regex = Regex.compile!(source, "iu")
        Process.put(:ui_highlight_pattern, {source, regex})
        regex
    end
  end

  defp mark_part(part, downcased) do
    escaped = part |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()

    if String.downcase(part) in downcased do
      [
        ~s(<mark class="rounded-sm bg-brand-100 text-brand-900 dark:bg-brand-500/30 dark:text-brand-100">),
        escaped,
        "</mark>"
      ]
    else
      escaped
    end
  end

  @doc """
  Dev convenience flag: in dev the Swoosh local adapter drops login / sign-up
  PINs into the mailbox preview at `/sent_emails`. The logged-out auth and PIN
  templates link there when this is on (`config/dev.exs`); it stays off in
  test/prod where that route is absent. Lives here so every `:html` view shares
  it (the login form, both PIN pages).
  """
  def dev_mailbox?, do: Application.get_env(:vutuv, :dev_mailbox, false)

  @doc """
  The link to that mailbox, rendered only where it exists — the whole block the
  login screen and both PIN screens each carried a byte-identical copy of.
  Untranslated on purpose: it is a developer's convenience and never reaches a
  member's browser.
  """
  def dev_mailbox_link(assigns) do
    ~H"""
    <p :if={dev_mailbox?()} class="mt-2 text-sm text-slate-600 dark:text-slate-400">
      <a
        href="/sent_emails"
        target="_blank"
        rel="noopener"
        class="font-semibold text-brand-600 hover:text-brand-700 dark:text-brand-400 dark:hover:text-brand-300"
      >
        Open the dev email inbox
      </a>
    </p>
    """
  end

  @doc """
  The "stuck on the PIN page" escape hatches, shared by both PIN-entry screens
  (login and post-registration). "Resend PIN" re-mints and re-mails the one-time
  PIN for the pending email (rate limited); the second control abandons the
  pending identity so the visitor is no longer pinned to the PIN form. Both are
  CSRF-protected POSTs.

  Two things above them follow `context`, which
  `VutuvWeb.ControllerHelpers.render_pin_screen/2` takes from the signed cookie
  so a screen cannot contradict the flow it belongs to. Only `:login` suggests
  trying another of the member's addresses — at registration they have given
  exactly one and have no account yet — and only `:login` calls the second
  control "Use a different email address", which at registration is
  "Cancel registration".

  Naming the address never reveals whether it is registered: it is the address
  the visitor themself just typed, and the screen stays byte-identical for known
  and unknown ones (the enumeration guard in `Vutuv.Accounts`).
  """
  attr(:email, :string,
    required: true,
    doc: "the pending address, named so a typo in it is visible"
  )

  attr(:context, :atom,
    required: true,
    values: [:login, :registration],
    doc: "which PIN screen this is; only :login may suggest another address"
  )

  def pin_actions(assigns) do
    # One paragraph, three short questions in the order a member asks them:
    # nothing arrived, is the address right, did it land in spam. The spam
    # advice used to be a separate paragraph above, which split one problem
    # across two blocks and said more words than either needed.
    #
    # The address is spelled out and set in semibold, because the single most
    # likely reason no PIN arrives is that it was mistyped one screen ago, and a
    # member cannot spot that in an address they cannot see. Split on a
    # placeholder with `split_marker/2` rather than matching the translated
    # sentence, which would turn a .po slip into a 500.
    {before_email, after_email} =
      split_marker(
        gettext(
          "PIN not arriving? Is the email address {email} correct? Have you checked your spam folder?"
        ),
        "{email}"
      )

    assigns = assign(assigns, before_email: before_email, after_email: after_email)

    ~H"""
    <div class="mt-4 text-sm">
      <p class="text-slate-600 dark:text-slate-400">
        {@before_email}<span class="font-semibold text-slate-800 dark:text-slate-200">{@email}</span>{@after_email}
        <%!-- Only the login screen may say this. At registration the member has
              given exactly one address and has no account yet, so advice to
              "log in with one of your other addresses" describes a situation
              that cannot exist and reads as a page written for somebody else. --%>
        <span :if={@context == :login}>
          {gettext(
            "If you have added other addresses to your vutuv account, try logging in with one of those instead."
          )}
        </span>
      </p>
      <div class="mt-2 flex flex-wrap items-center gap-x-3 gap-y-2">
        <.form for={%{}} action={~p"/login/resend"} method="post" id="resend-pin-form">
          <button type="submit" class="font-semibold text-brand-600 hover:text-brand-700 dark:text-brand-400 dark:hover:text-brand-300">
            {gettext("Resend PIN")}
          </button>
        </.form>
        <span aria-hidden="true" class="text-slate-300 dark:text-slate-600">&middot;</span>
        <%!-- The same action either way: it drops the pending-identity cookie,
              which is what frees the landing page from the PIN screen. Only the
              label differs, because what the member is leaving differs. At
              registration "Use a different email address" describes a step that
              does not exist there - they gave one address, and what they
              actually want is out. NOTE the label is honest about the *step*,
              not about the data: the account row was created before the PIN was
              sent and outlives this click. Making cancel really undo the
              registration is deliberately not decided here (Stefan,
              2026-08-04). --%>
        <.form for={%{}} action={~p"/login/cancel"} method="post" id="cancel-pin-form">
          <button
            type="submit"
            class="font-semibold text-slate-500 hover:text-slate-700 dark:text-slate-400 dark:hover:text-slate-200"
          >
            {if @context == :registration,
              do: gettext("Cancel registration"),
              else: gettext("Use a different email address")}
          </button>
        </.form>
      </div>
    </div>
    """
  end

  @doc """
  The quiet line under the PIN field saying how much of the PIN's life is left,
  and the anchor the countdown in `app.js` ticks.

  A PIN is good for 30 minutes and the screen used to say nothing about it, so a
  member who came back to the tab later met a form that refused their PIN with
  no word about why. It is deliberately **one muted line and no clock face**: the
  window is half an hour, and a digit ticking away every second beside a field
  somebody is trying to read a number into is a nag, not information. It counts
  in whole minutes almost all the way down and only switches to seconds inside
  the last one, where the number finally means something.

  `expires_at` is the deadline out of the signed pending-PIN cookie
  (`Vutuv.Accounts.pending_pin/1`, assigned as `:pin_expires_at` by
  `VutuvWeb.ControllerHelpers.render_pin_screen/2`). What reaches the browser is
  the **remaining seconds**, not that timestamp: a countdown against an absolute
  server stamp is only as good as the reader's own clock, and a device running a
  few minutes fast would blank a perfectly valid form. Anchoring the client to
  its own `Date.now()` at load costs nothing and cannot be skewed, while the
  server keeps recomputing the true remainder on every render.

  With no JavaScript, or with a legacy cookie that carries no deadline
  (`expires_at` is nil), the server-rendered sentence stands on its own and
  simply does not tick.

  The four label strings ride the element because the server is the only side
  that knows the reader's language (the lightbox and emoji picker do the same).
  Each is a **whole** sentence per plural form rather than a unit word the JS
  glues onto a number: word order and plural rules are not ours to assemble.
  `{n}` is the project's plain-text marker convention (see `split_marker/2`),
  which gettext leaves alone because it only ever interpolates `%{…}`.
  """
  attr(:expires_at, :any,
    default: nil,
    doc: "the PIN's deadline as a DateTime, or nil for a cookie that carries none"
  )

  attr(:id, :string, default: "pin-time-left")
  attr(:class, :string, default: nil)

  def pin_time_left(assigns) do
    labels = pin_time_left_labels()
    seconds = pin_seconds_left(assigns.expires_at)

    assigns =
      assign(assigns,
        labels: labels,
        seconds: seconds,
        text: pin_time_left_text(labels, seconds || Vutuv.Accounts.pin_validity_minutes() * 60)
      )

    ~H"""
    <p
      id={@id}
      class={["mt-2 text-xs text-slate-600 dark:text-slate-400", @class]}
      data-pin-time-left
      data-pin-seconds-left={@seconds}
      data-label-minute-one={@labels.minute_one}
      data-label-minute-other={@labels.minute_other}
      data-label-second-one={@labels.second_one}
      data-label-second-other={@labels.second_other}
    >{@text}</p>
    """
  end

  defp pin_time_left_labels do
    %{
      minute_one: gettext("The PIN is valid for one more minute."),
      minute_other: gettext("The PIN is valid for {n} more minutes."),
      second_one: gettext("The PIN is valid for one more second."),
      second_other: gettext("The PIN is valid for {n} more seconds.")
    }
  end

  defp pin_seconds_left(nil), do: nil

  defp pin_seconds_left(%DateTime{} = expires_at) do
    max(DateTime.diff(expires_at, DateTime.utc_now()), 0)
  end

  # Whole minutes down to the last one, then seconds. Rounded up, the ordinary
  # countdown convention: it never says "one minute" while the member still has
  # nearly two.
  defp pin_time_left_text(labels, seconds) when seconds >= 60 do
    case ceil(seconds / 60) do
      1 -> labels.minute_one
      minutes -> String.replace(labels.minute_other, "{n}", Integer.to_string(minutes))
    end
  end

  defp pin_time_left_text(labels, 1), do: labels.second_one

  defp pin_time_left_text(labels, seconds) do
    String.replace(labels.second_other, "{n}", Integer.to_string(seconds))
  end

  @doc """
  Logged-out auth / welcome shell (Direction A): a brand-gradient hero panel
  beside a white form card, stacking to a single column on mobile. Shared by the
  sign-up, login and PIN screens so the logged-out entry flow matches the rest
  of the app instead of the old full-bleed photo "imagebox".

  Pass `title` (the hero headline) and optionally `subtitle`; the `:hero` slot
  adds extra hero content (a member count, say) and the default slot is the form
  card body.

  For a hero that needs full control over its heading typography (a founder
  quote with an attribution block, say), pass a `:headline` slot instead — it
  replaces the default `<h1>{@title}` + subtitle. `title` is still required and
  serves as the plain-text fallback.
  """
  attr(:title, :string, required: true)
  attr(:subtitle, :string, default: nil)
  slot(:headline)
  slot(:hero)
  slot(:inner_block, required: true)

  def auth_layout(assigns) do
    ~H"""
    <div class="mx-auto grid max-w-5xl items-stretch gap-6 py-8 md:grid-cols-2 md:gap-8 md:py-12">
      <section class="relative isolate overflow-hidden rounded-2xl bg-gradient-to-br from-brand-700 to-brand-500 p-8 text-white shadow-sm md:p-10 dark:from-brand-800 dark:to-brand-700">
        <%!-- Soft decorative rings — the signature flourish, purely cosmetic. --%>
        <div aria-hidden="true" class="pointer-events-none absolute -right-16 -top-20 -z-10 h-60 w-60 rounded-full bg-white/10"></div>
        <div aria-hidden="true" class="pointer-events-none absolute -bottom-24 -left-12 -z-10 h-52 w-52 rounded-full bg-white/5"></div>
        <div class="flex h-full flex-col justify-center">
          <%= if @headline != [] do %>
            {render_slot(@headline)}
          <% else %>
            <h1 class="text-2xl font-bold leading-tight md:text-3xl">{@title}</h1>
            <p :if={@subtitle} class="mt-4 max-w-sm text-base leading-relaxed text-brand-50">
              {@subtitle}
            </p>
          <% end %>
          {render_slot(@hero)}
        </div>
      </section>
      <.card class="flex flex-col justify-center">
        {render_slot(@inner_block)}
      </.card>
    </div>
    """
  end

  @doc "The Direction A card surface (white, rounded, ring, soft shadow; dark-aware)."
  attr(:class, :string, default: nil)
  attr(:rest, :global)
  slot(:inner_block, required: true)

  def card(assigns) do
    ~H"""
    <section
      class={[
        "rounded-2xl bg-white p-6 shadow-sm ring-1 ring-slate-200 dark:bg-slate-900 dark:ring-slate-800",
        @class
      ]}
      {@rest}
    >
      {render_slot(@inner_block)}
    </section>
    """
  end

  @doc """
  Uppercase muted section heading used inside cards.

  `dark:text-slate-400` is not decoration: bare `slate-500` on a dark card is
  about 3.8:1, under the AA floor, and `text-sm font-semibold` at 14px does not
  qualify as large text. The component was the one place still missing it while
  six hand-rolled copies of the same heading had each added it for themselves —
  which is the drift a component exists to prevent.
  """
  attr(:class, :string, default: nil)
  slot(:inner_block, required: true)

  def section_title(assigns) do
    ~H"""
    <h2 class={[
      "text-sm font-semibold uppercase tracking-wide text-slate-500 dark:text-slate-400",
      @class
    ]}>
      {render_slot(@inner_block)}
    </h2>
    """
  end

  @doc """
  The small emerald ✓ shown next to a member's **verified webpage** link
  (`Vutuv.Profiles.LinkVerification`) — the people-side twin of the organization
  `<.verified_badge>`. Icon-only, so it carries a `title` / `aria-label`.
  """
  attr(:title, :string, default: nil)
  attr(:class, :string, default: "h-4 w-4")

  def verified_mark(assigns) do
    assigns = assign_new(assigns, :label, fn -> assigns.title || gettext("Verified webpage") end)

    ~H"""
    <svg
      class={["inline-block shrink-0 text-emerald-600 dark:text-emerald-400", @class]}
      viewBox="0 0 20 20"
      fill="currentColor"
      role="img"
      aria-label={@label}
    >
      <title>{@label}</title>
      <path
        fill-rule="evenodd"
        d="M16.704 4.153a.75.75 0 0 1 .143 1.052l-8 10.5a.75.75 0 0 1-1.127.075l-4.5-4.5a.75.75 0 0 1 1.06-1.06l3.894 3.893 7.48-9.817a.75.75 0 0 1 1.05-.143Z"
        clip-rule="evenodd"
      />
    </svg>
    """
  end

  @doc """
  The turning hourglass shown while a photo waits for the AI image scan
  (issue #1104).

  An hourglass rather than a spinner on purpose: a spinner says "loading", and
  what is happening here is not a load but a wait for something being *judged*
  — with a duration the reader cannot control and should not expect to be
  instant. The rotation is CSS (`.hourglass`, `components.css`) and stops
  under `prefers-reduced-motion`; the glyph reads the same either way.
  """
  attr(:class, :string, default: "h-5 w-5")

  def hourglass(assigns) do
    ~H"""
    <svg
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      stroke-width="1.5"
      class={["hourglass shrink-0", @class]}
      aria-hidden="true"
    >
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        d="M6.75 2.25h10.5M6.75 21.75h10.5M7.5 2.25v3.336c0 .58.226 1.136.63 1.55L12 11l3.87-3.864c.404-.414.63-.97.63-1.55V2.25M7.5 21.75v-3.336c0-.58.226-1.136.63-1.55L12 13l3.87 3.864c.404.414.63.97.63 1.55v3.336"
      />
    </svg>
    """
  end

  @doc """
  The badge on a picture the AI image scan has not released yet: the turning
  hourglass and the two words that say what the reader is looking at.

  It sits in `VutuvWeb.UI` rather than beside the post card because four
  surfaces carry it — a held post photo, a held link screenshot, a held picture
  from another network, and the profile Links tile — and the fourth is in this
  module, which cannot import `VutuvWeb.PostComponents` (that module imports
  this one). While the markup was copied per surface the four drifted on the
  first commit: the one here had no glyph at all.

  Positioned by the caller (`absolute` in a `relative` tile, or in the flow),
  so a surface keeps its own geometry.
  """
  attr(:class, :any, default: "absolute bottom-2 left-2")

  def checking_badge(assigns) do
    ~H"""
    <span class={[
      "inline-flex items-center gap-1 rounded-full bg-slate-900/75 px-2 py-1 text-xs font-semibold text-white",
      @class
    ]}>
      <.hourglass class="h-3.5 w-3.5" />{gettext("Being checked")}
    </span>
    """
  end

  @doc """
  The 400×264 preview tile of a profile link, in whichever of its three states
  the link is in — the one place that decides what a link looks like when there
  is no screenshot.

    * a stored capture renders as the thumbnail (`Vutuv.Screenshot.url/2`);
    * a capture the AI scan has not judged yet renders as its **pixelated preview**
      (issue #1720) with a badge saying so — the capture exists, and 64 cells
      of averaged colour is what may be shown of it before the verdict;
    * a link this installation never captures (`Vutuv.ScreenshotBlocklist` — a
      consent-banner or login-walled site) renders a calm tile naming the site,
      because "a screenshot has not been created yet" would be a promise that
      never comes true here;
    * anything else is a capture still on its way and keeps the bundled
      placeholder image.

  Carries `data-link-thumb` with that state (`shot` / `mosaic` / `site` /
  `pending`) for tests. Sizing lives in the component, so both the profile Links card (kit
  page) and the `/:slug/links` list (classic page) render one tile.
  """
  attr(:url, :map, required: true, doc: "a %Vutuv.Profiles.Url{}")
  attr(:class, :any, default: nil)

  def link_thumb(assigns) do
    src = Vutuv.Screenshot.url({assigns.url.screenshot, assigns.url}, :thumb)
    pixelated_url = Vutuv.Screenshot.pixelated_url(assigns.url)

    assigns =
      assigns
      |> assign(:src, src)
      |> assign(:pixelated_url, pixelated_url)
      |> assign(:state, link_thumb_state(assigns.url, src, pixelated_url))

    ~H"""
    <span :if={@state == "pixelated"} class={["relative block", @class]} data-link-thumb="pixelated">
      <img
        src={@pixelated_url}
        alt=""
        width="400"
        height="264"
        loading="lazy"
        class="aspect-[400/264] w-full object-cover"
      />
      <.checking_badge />
    </span>
    <div
      :if={@state == "site"}
      data-link-thumb="site"
      class={[
        "flex aspect-[400/264] w-full items-center justify-center bg-slate-50 px-3 dark:bg-slate-800",
        @class
      ]}
    >
      <span class="truncate text-sm font-semibold text-slate-600 dark:text-slate-400">
        {VutuvWeb.UrlHTML.display_url(@url.value)}
      </span>
    </div>
    <img
      :if={@state in ["shot", "pending"]}
      data-link-thumb={@state}
      src={@src}
      alt={@url.description || VutuvWeb.UrlHTML.display_url(@url.value)}
      width="400"
      height="264"
      loading="lazy"
      class={["aspect-[400/264] w-full object-cover", @class]}
    />
    """
  end

  # Which of the four tiles this link gets, decided once so the three branches
  # above read as one choice rather than as three conditions that must agree.
  #
  # "shot" is read off the **resolved src**, not off the column: a row can name
  # a capture whose file is not on disk, and `Screenshot.url/2` then answers the
  # placeholder (issue #1443) — calling that tile "shot" would be a state
  # nobody could act on.
  defp link_thumb_state(url, src, pixelated_url) do
    cond do
      pixelated_url -> "pixelated"
      is_nil(url.screenshot) and Vutuv.ScreenshotBlocklist.blocked?(url.value) -> "site"
      src != Vutuv.Screenshot.placeholder_url() -> "shot"
      true -> "pending"
    end
  end

  @doc """
  The "Other formats" rail card: links to a page's `VutuvWeb.AgentDocs` agent
  siblings (Markdown / plain text / JSON / XML, and the profile additionally
  vCard) under the same URL plus an extension. Shared by the **profile** aside
  (`base_path={"/" <> @user.username} vcard`), the **`/feed` rail**
  (`base_path="/feed"`) and the **post permalink** (`base_path={Posts.path(@post)}`).

  `base_path` is the page's extension-free path; each chip is that path plus the
  format extension. A German visitor browsing with `?lang=de` keeps that locale
  on the agent links via `locale`; the vCard carries no translatable labels, so
  it skips the `?lang=` suffix. The feed renders it twice (desktop rail + a
  `md:hidden` bottom copy), so pass `id` / `class` through the global `rest`.

  `machine_formats={false}` (a fully machine-opted-out member, see
  `VutuvWeb.ContentPolicy.agent_docs_blocked?/1`) drops the Markdown / text /
  JSON / XML chips — those URLs answer 404 for such a profile — and shows a
  short note in their place; the vCard chip stays when `vcard` is set.

  `rss_path` (the profile passes `VutuvWeb.Feeds.user_feed_path/1`) appends an
  RSS chip so members can find and hand out their feed URL — autodiscovery via
  `<link rel="alternate">` is invisible. Like the vCard it survives
  `machine_formats={false}`: the feed serves for every member and signals the
  opt-outs per response (`VutuvWeb.FeedController`), and it skips `?lang=`
  (the feed is one canonical document).
  """
  attr(:base_path, :string, required: true)
  attr(:locale, :any, default: nil)
  attr(:vcard, :boolean, default: false)
  attr(:machine_formats, :boolean, default: true)
  attr(:rss_path, :string, default: nil)
  attr(:rest, :global)

  def other_formats_card(assigns) do
    lang = if assigns.locale in [nil, "en"], do: "", else: "?lang=#{assigns.locale}"
    base = assigns.base_path

    machine_chips =
      if assigns.machine_formats do
        [
          {gettext("Markdown"), base <> ".md" <> lang},
          {gettext("Text only"), base <> ".txt" <> lang},
          {"JSON", base <> ".json" <> lang},
          {"XML", base <> ".xml" <> lang}
        ]
      else
        []
      end

    vcard_chip = if assigns.vcard, do: [{gettext("vCard"), base <> ".vcf"}], else: []
    rss_chip = if assigns.rss_path, do: [{"RSS", assigns.rss_path}], else: []

    assigns = assign(assigns, :formats, machine_chips ++ vcard_chip ++ rss_chip)

    ~H"""
    <.card {@rest}>
      <.section_title class="mb-4">{gettext("Other formats")}</.section_title>
      <p :if={!@machine_formats} class="mb-3 text-xs text-slate-600 dark:text-slate-400">
        {gettext("This profile is not offered as a Markdown, text, JSON or XML export.")}
      </p>
      <%!-- Chips: a wrapping row of small tags instead of a one-per-row list. --%>
      <div :if={@formats != []} class="flex flex-wrap gap-1.5">
        <.link :for={{label, href} <- @formats} href={href} class={format_chip_class()}>
          {label}
        </.link>
      </div>
    </.card>
    """
  end

  # The small format chip shared by <.other_formats_card> and <.cv_card>.
  defp format_chip_class do
    "inline-flex items-center rounded-md bg-slate-100 px-2.5 py-1 text-xs font-medium text-slate-600 transition hover:bg-brand-50 hover:text-brand-700 dark:bg-slate-800 dark:text-slate-300 dark:hover:bg-brand-900/30 dark:hover:text-brand-200"
  end

  @doc """
  The **subscribe-by-feed** pill: the visible way to a feed
  (`VutuvWeb.Feeds.user_feed_path/1` and its organization sibling), since
  autodiscovery via `<link rel="alternate">` is invisible.

  Glyph **and** the word "RSS": the arcs are famous among people who use
  feeds and meaningless to everyone else, while "RSS" alone in a row of
  section headings does not read as something to click. `type` states the
  media type so a browser or reader extension knows what it is being handed
  before fetching. The `aria-label` spells the action out (and the `title`
  shows the same sentence on hover) because the visible word alone would put
  a second link named just "RSS" — the rail's format chip points at the same
  URL — into a screen reader's link list; it keeps the visible label inside
  the accessible name (WCAG 2.5.3).

  Two call sites: the feed half of `<.subscribe_card>`, and the `/:slug/posts`
  archive header, a page that is nothing but posts. It is **not** in a Posts
  card header any more — see `<.subscribe_link>` for why.

  The pill is the app's `<.tag_follow_button>` / `<.follow_button
  variant="text">` outline pill grown to a full `min-h-10` (40px) touch
  target, since it stands alone with room around it rather than in a dense
  list row. Deliberately slate-to-brand, not the RSS orange: a bespoke colour
  for one control would be the only one in the app.
  """
  attr(:href, :string, required: true)
  attr(:id, :string, default: nil)
  attr(:class, :any, default: nil)

  def feed_button(assigns) do
    ~H"""
    <.link
      id={@id}
      href={@href}
      type="application/rss+xml"
      title={gettext("Subscribe to this feed in your RSS reader")}
      aria-label={gettext("Subscribe to this feed in your RSS reader")}
      data-feed-button
      class={[
        "inline-flex min-h-10 shrink-0 items-center justify-center gap-1.5 rounded-full border px-3.5 text-xs font-semibold transition-colors",
        "border-slate-300 text-slate-600 hover:border-brand-300 hover:bg-brand-50 hover:text-brand-700 dark:hover:text-brand-300",
        "dark:border-slate-700 dark:text-slate-400 dark:hover:border-brand-500 dark:hover:bg-brand-900/30 dark:hover:text-brand-200",
        @class
      ]}
    >
      <.icon_rss class="h-4 w-4" />RSS
    </.link>
    """
  end

  @doc """
  The **subscribe shortcut** in a Posts card header: one quiet text link to the
  page's Subscribe card at the foot of the page.

  It replaces the `<.feed_button>` pill that used to sit here (issue #1287).
  The pill was the most prominent control on a profile's posts section — a
  40px pill, first thing beside the heading — for the one way to follow a
  member that almost nobody uses, while the Fediverse address, which is what a
  visitor arriving from Mastodon came for, had no link above the fold at all.
  Both ways now live in one card named after what a reader wants ("Subscribe"),
  and this is the sign that points at it. So the header keeps a visible path to
  the feed, which is all #1287 was really about, at a fraction of the space.

  A plain in-page anchor, so it costs no request and works without JavaScript;
  `min-h-10` keeps the 40px touch target the pill had.
  """
  attr(:href, :string, required: true)
  attr(:id, :string, default: nil)

  def subscribe_link(assigns) do
    ~H"""
    <.link
      id={@id}
      href={@href}
      class={[
        "inline-flex min-h-10 shrink-0 items-center gap-1 text-sm font-semibold",
        "text-slate-600 transition-colors hover:text-brand-700 dark:hover:text-brand-300",
        "dark:text-slate-400 dark:hover:text-brand-200"
      ]}
    >
      {gettext("Subscribe")}<span aria-hidden="true">›</span>
    </.link>
    """
  end

  @doc """
  The **Subscribe card** at the foot of a profile or an organization page: the
  one place that answers "how do I follow this without a vutuv account", with
  every way to do it under a heading of its own.

  Three parts, each optional, in the order the page recommends them. First the
  **account offer**, for a logged-out visitor only: an account here is the best
  way to follow somebody — the posts arrive in a feed the reader can answer in
  — and a card that listed only the two ways around registering would be
  quietly talking people out of the product. It is also the one thing an
  anonymous visitor is offered on a profile at all, since the header's follow
  pill needs a session. A signed-in reader has an account already, so the half
  disappears and the card opens with the ways that need none.

  A bridging line then says out loud what the rest is for ("No vutuv account?
  These ways work too:"), because the point is not that the offer was ignored
  but that there is a way for people who do not want one. It renders only
  beneath the offer, so a signed-in reader never reads an answer to a question
  nobody asked them.

  Then the halves that need no account. The `:fediverse` slot carries the
  address block
  (`<.follow_us_from_elsewhere>`, a moved member's forwarding address, or an
  owner's invite to switch federation on) — the page owns that body because
  the three cases differ per page. The feed half is here: the
  `<.feed_button>` pill beside the feed's absolute address as a copy target.
  Both, because the two ways people subscribe are different acts — a reader
  extension takes the click on the pill, while a standalone feed reader wants
  the URL pasted into its own "add feed" box, and hunting that out of the
  address bar after the browser has rendered raw XML is the step where people
  give up. `<.feed_button>` alone is right on `/:slug/posts`, which is one
  page about one feed; a card that hands out an address should hand out the
  address.

  `account_offer` (a logged-out viewer) needs `name` for its sentence; the
  wording stays clear of pronouns, since it names a member on one page and an
  organization on the other.

  `id` is the page's prefix, not a full id: the card is `<prefix>-subscribe`
  and the Fediverse half keeps `<prefix>-fediverse`, the id the whole card
  carried before it grew a second half, so older links still land on the
  address they were written for. Both are anchor targets, so both clear the
  sticky top bar. `feed_href` falsy renders no feed half, and a card with
  neither half renders nothing at all — which is what keeps the
  `<.subscribe_link>` pointing at it from ever being a dead jump.

  The feed half's heading says "Or" only when there is something above it to
  be an alternative to; on the great majority of profiles, which do not
  federate, the card is the feed alone.
  """
  attr(:id, :string, required: true)
  attr(:feed_href, :any, default: nil, doc: "feed path; falsy renders no feed half")
  attr(:account_offer, :boolean, default: false, doc: "true for a logged-out viewer")
  attr(:name, :string, default: nil, doc: "whose profile or page this is, for the offer")
  attr(:class, :any, default: nil)
  slot(:fediverse)

  def subscribe_card(assigns) do
    ~H"""
    <.card
      :if={@account_offer or @fediverse != [] or @feed_href}
      id={"#{@id}-subscribe"}
      class={subscribe_card_class(@class)}
    >
      <.section_title>{gettext("Subscribe")}</.section_title>

      <div :if={@account_offer} id={"#{@id}-account"}>
        <h3 class={subscribe_heading_class()}>{gettext("With a vutuv account")}</h3>
        <p class="mt-1 text-sm leading-relaxed text-slate-600 dark:text-slate-400">
          {gettext(
            "The best way: follow %{name} here. New posts land in your feed, and you can reply and join in.",
            name: @name
          )}
        </p>
        <div class="mt-3 flex flex-wrap items-center gap-x-4 gap-y-2">
          <.button href={~p"/"} id={"#{@id}-account-signup"}>
            {gettext("Create a free account")}
          </.button>
          <.link
            href={~p"/login"}
            class="text-sm font-semibold text-brand-600 hover:text-brand-700 dark:text-brand-400 dark:hover:text-brand-300"
          >
            {gettext("Already a member? Sign in here.")}
          </.link>
        </div>
      </div>

      <p
        :if={@account_offer and (@fediverse != [] or @feed_href)}
        class={[subscribe_divider_class(), "text-sm text-slate-600 dark:text-slate-400"]}
      >
        {gettext("No vutuv account? These ways work too:")}
      </p>

      <div
        :if={@fediverse != []}
        id={"#{@id}-fediverse"}
        class={["scroll-mt-24", @account_offer && "mt-4"]}
      >
        <h3 class={subscribe_heading_class()}>{gettext("Fediverse")}</h3>
        {render_slot(@fediverse)}
      </div>

      <div
        :if={@feed_href}
        class={
          cond do
            @fediverse != [] -> subscribe_divider_class()
            @account_offer -> "mt-4"
            true -> nil
          end
        }
      >
        <h3 class={subscribe_heading_class()}>
          {if @fediverse != [],
            do: gettext("Or with an RSS reader"),
            else: gettext("With an RSS reader")}
        </h3>
        <p class="mt-1 text-sm leading-relaxed text-slate-600 dark:text-slate-400">
          {gettext("New public posts arrive in any feed reader. No account needed either.")}
        </p>
        <div class="mt-3 flex flex-wrap items-center gap-2">
          <.feed_button id={"#{@id}-posts-feed"} href={@feed_href} />
          <.copy_field
            id={"#{@id}-posts-feed-url"}
            class="min-w-0 flex-1 items-center"
            code_class="text-xs"
          >{AgentDocs.abs_url(@feed_href)}</.copy_field>
        </div>
      </div>
    </.card>
    """
  end

  # Every part of the Subscribe card is named by the same small heading.
  defp subscribe_heading_class, do: "text-sm font-semibold text-slate-900 dark:text-white"

  # The hairline that sets one part off from the one above it.
  defp subscribe_divider_class,
    do: "mt-6 border-t border-slate-100 pt-5 dark:border-slate-800"

  # `<.card>` takes a plain class string, and the card is always an anchor
  # target, so `scroll-mt-24` is not the caller's to remember.
  defp subscribe_card_class(nil), do: "scroll-mt-24"
  defp subscribe_card_class(class), do: "scroll-mt-24 #{class}"

  @doc """
  The outline RSS icon (24×24 stroke) — the broadcast arcs over their dot.
  Size it via `class`; `<.feed_button>` is its one call site so far.
  """
  attr(:class, :any, default: "h-5 w-5")

  def icon_rss(assigns) do
    ~H"""
    <svg
      class={@class}
      fill="none"
      stroke="currentColor"
      stroke-width="1.8"
      viewBox="0 0 24 24"
      aria-hidden="true"
    >
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        d="M12.75 19.5v-.75a7.5 7.5 0 0 0-7.5-7.5H4.5m0-6.75h.75c7.87 0 14.25 6.38 14.25 14.25v.75M6 18.75a.75.75 0 1 1-1.5 0 .75.75 0 0 1 1.5 0Z"
      />
    </svg>
    """
  end

  @doc """
  The profile rail's **CV / Lebenslauf card** (issue #841): this profile as
  a formatted CV for a job application, offered to **every** viewer. One
  affordance only — an "Open CV" button to the builder (`/:slug/cv`), where
  any viewer picks what to include, anonymizes, prints or downloads (the
  format chips live there, not here). The CV (`VutuvWeb.CV`) carries only
  data the viewer can already see, so a private email never leaves the
  owner's own download.
  """
  attr(:user, Vutuv.Accounts.User, required: true)
  attr(:rest, :global)

  def cv_card(assigns) do
    ~H"""
    <.card {@rest}>
      <%!-- Not plain "CV": the German label would double the Experience
      card's "Lebenslauf" heading on the same page. --%>
      <.section_title class="mb-4">{gettext("CV download")}</.section_title>
      <p class="mb-3 text-xs text-slate-600 dark:text-slate-400">
        {gettext(
          "This profile as a formatted CV for job applications. Open it to pick what to include, anonymize it, print or download."
        )}
      </p>
      <.link
        href={~p"/#{@user}/cv"}
        class="block w-full rounded-lg bg-brand-600 px-4 py-2 text-center text-sm font-semibold text-white hover:bg-brand-700"
      >
        {gettext("Open CV")}
      </.link>
    </.card>
    """
  end

  @doc """
  Card header row: a `<.section_title>` plus an optional right-aligned `:action`
  slot. Under the unified card UX the owner's **Add** is no longer a header
  button — it is the dashed `<.empty_add>` tile in the card body, shown the same
  way whether the card is empty or already has entries (the whole point: one add
  affordance, never two). So most call sites pass just `title`; the `:action`
  slot remains for the rare non-add header control.
  """
  attr(:title, :string, required: true)
  slot(:action)

  def section_header(assigns) do
    ~H"""
    <div class="mb-4 flex items-center justify-between gap-3">
      <.section_title>{@title}</.section_title>
      <div :if={@action != []} class="flex items-center gap-3">
        {render_slot(@action)}
      </div>
    </div>
    """
  end

  @doc """
  Per-card ⋯ menu for hand-written (kit-page) profile sections — the quiet
  home for the owner's rare actions (add entry, manage entries) so they are
  not always in the viewer's face. A native `<details data-menu>` dropdown:
  no JS framework, keyboard-accessible out of the box; `app.js` closes any
  open menu on outside click and Escape. Items render via the `:item` slot
  (`href` required, optional `method`, and `target`/`rel` for an item that
  leaves the site — the fediverse card's "View the original"); the owner guard
  stays at the call site, e.g. inside `<.section_header>`'s `:action` slot:

      <:action :if={owner?}>
        <.card_menu id="profile-links-menu">
          <:item href={~p"/…/new"}>{gettext("Add entry")}</:item>
          <:item href={~p"/…"}>{gettext("Manage entries")}</:item>
        </.card_menu>
      </:action>

  Profile-section deletion intentionally does not live here — the manage
  pages carry per-row edit/delete and every edit form has
  `<.form_actions delete_to={…} />`. The post card's author menu is the
  exception: its Delete item (`method="delete"` + `confirm` + `danger`)
  is the post's primary delete affordance.
  """
  attr(:id, :string, required: true)

  slot :item, required: true do
    attr(:id, :string, doc: "optional DOM id for the item link (tests, anchors)")
    attr(:href, :any, doc: "link target (a navigation/CSRF item); omit when using `click`")
    attr(:method, :string)

    attr(:target, :string,
      doc: "browsing context, e.g. `_blank` for an item that leaves the site (a remote original)"
    )

    attr(:rel, :string,
      doc: "link relationship, e.g. `nofollow noopener noreferrer` with `_blank`"
    )

    attr(:click, :string,
      doc: "phx-click event name — renders a `<button>` (a LiveView action) instead of a link"
    )

    attr(:value, :any, doc: "phx-value-id sent with the `click` event")
    attr(:confirm, :string, doc: "data-confirm prompt for destructive items")
    attr(:danger, :boolean, doc: "style the item red")

    attr(:hint, :string,
      doc:
        "a long name the label cannot hold — a fediverse `@user@host` handle — rendered as a quiet second line that truncates instead of overflowing the panel"
    )
  end

  def card_menu(assigns) do
    ~H"""
    <details data-menu class="relative" id={@id}>
      <summary
        title={gettext("Options")}
        class={[
          "flex h-7 w-7 cursor-pointer list-none items-center justify-center rounded-full text-slate-600 dark:text-slate-400",
          "hover:bg-slate-100 hover:text-slate-600 dark:hover:bg-slate-800 dark:hover:text-slate-300",
          "[&::-webkit-details-marker]:hidden"
        ]}
      >
        <svg class="h-5 w-5" fill="currentColor" viewBox="0 0 24 24" aria-hidden="true">
          <path d="M6.75 12a1.5 1.5 0 1 1-3 0 1.5 1.5 0 0 1 3 0Zm6.75 0a1.5 1.5 0 1 1-3 0 1.5 1.5 0 0 1 3 0Zm6.75 0a1.5 1.5 0 1 1-3 0 1.5 1.5 0 0 1 3 0Z" />
        </svg>
        <span class="sr-only">{gettext("Options")}</span>
      </summary>
      <%!-- `w-60`, not the old `w-52`: an ordinary fediverse address
      (`@user@mastodon.social`) fits a `hint` line at this width and starts
      losing its host below it, and a right-aligned 15rem panel still sits
      inside the narrowest phone. --%>
      <div class="absolute right-0 z-20 mt-1 w-60 rounded-xl bg-white py-1 shadow-lg ring-1 ring-slate-200 dark:bg-slate-900 dark:ring-slate-700">
        <%!-- An item with `click` is a LiveView action (a phx-click <button>, no
        reload); otherwise it is a navigation / CSRF <.link>. Both wear the same
        item styling so one menu can mix them. --%>
        <%= for item <- @item do %>
          <button
            :if={item[:click]}
            type="button"
            id={item[:id]}
            phx-click={item[:click]}
            phx-value-id={item[:value]}
            data-confirm={item[:confirm]}
            class={["block w-full text-left", card_menu_item_class(item[:danger])]}
          >
            <.card_menu_item_body item={item} />
          </button>
          <.link
            :if={!item[:click]}
            id={item[:id]}
            href={item[:href]}
            method={item[:method]}
            target={item[:target]}
            rel={item[:rel]}
            data-confirm={item[:confirm]}
            class={["block", card_menu_item_class(item[:danger])]}
          >
            <.card_menu_item_body item={item} />
          </.link>
        <% end %>
      </div>
    </details>
    """
  end

  # One item's label, plus the optional `hint` line under it. A name is what
  # outgrows this panel — a fediverse handle is `@user@host` and is longer on
  # its own than the whole menu is wide — so it gets a line of its own and
  # truncates there (the full string stays in the `title`). Folding it into the
  # label instead is what looked broken: German puts the verb last, so a
  # one-line ellipsis eats "stummschalten" and leaves the reader with a name and
  # no act, and without one the handle simply spills out of the white panel.
  attr(:item, :map, required: true)

  defp card_menu_item_body(assigns) do
    ~H"""
    <span class="block truncate">{render_slot(@item)}</span>
    <span
      :if={@item[:hint]}
      title={@item[:hint]}
      class="mt-0.5 block truncate text-xs font-normal text-slate-500 dark:text-slate-400"
    >
      {@item[:hint]}
    </span>
    """
  end

  # Shared look for a `<.card_menu>` item, whether it renders as a link or a
  # phx-click button: the calm row, red for a danger item.
  defp card_menu_item_class(danger?) do
    [
      "px-4 py-2 text-sm font-medium",
      if(danger?,
        do: "text-red-600 hover:bg-red-50 dark:text-red-400 dark:hover:bg-red-950/40",
        else: "text-slate-700 hover:bg-slate-50 dark:text-slate-200 dark:hover:bg-slate-800"
      )
    ]
  end

  @doc """
  The owner's **add tile** / onboarding scaffold: a full-width dashed-outline
  tile (plus glyph + a clear label) that links straight to the new-entry form, so
  a non-technical owner sees an obvious place to start filling a section — no
  header button, no hidden ⋯ menu.

  On the **profile** it shows only while the card is **empty** (guard with
  `:if={same_user?(…) and <collection empty>}`); once there are entries the card
  is a clean showcase with a `<.card_footer_link>` "Verwalten ›" instead. The
  exceptions are Beiträge (whose compose affordance stays always but is the
  avatar-card `<.composer_trigger>` in `VutuvWeb.PostComponents`, not this tile)
  and General Info (empty tile graduates to an "Ändern ›" footer). On the legacy
  **management pages** `<.card_section>` renders it above the list, empty or
  populated (those are the editor). Pass the call-to-action label as the inner
  block (e.g. `gettext("Add work experience")`); carries a `data-empty-add` hook
  for tests.
  """
  attr(:href, :any, required: true, doc: "the new-entry form this tile links to")
  attr(:class, :any, default: nil)
  attr(:rest, :global)
  slot(:inner_block, required: true)

  @empty_add_class "flex items-center justify-center gap-2 rounded-xl border-2 border-dashed border-slate-200 px-4 py-4 text-sm font-semibold text-slate-500 transition hover:border-brand-400 hover:bg-brand-50 hover:text-brand-700 dark:border-slate-700 dark:text-slate-400 dark:hover:border-brand-500 dark:hover:bg-brand-900/20 dark:hover:text-brand-300"

  def empty_add(assigns) do
    assigns = assign(assigns, :base_class, @empty_add_class)

    ~H"""
    <.link href={@href} data-empty-add class={[@base_class, @class]} {@rest}>
      <.empty_add_glyph />
      {render_slot(@inner_block)}
    </.link>
    """
  end

  defp empty_add_glyph(assigns) do
    ~H"""
    <svg class="h-5 w-5 shrink-0" fill="none" stroke="currentColor" stroke-width="1.8" viewBox="0 0 24 24" aria-hidden="true">
      <path stroke-linecap="round" stroke-linejoin="round" d="M12 4.5v15m7.5-7.5h-15" />
    </svg>
    """
  end

  @doc """
  Tag chip (brand tint). Pass `navigate`/`href` to render it as a link.

  `size="sm"` is the same chip at rail scale — the feed's "New here" card puts
  three of a newcomer's tags under their name in a column a third of the page
  wide, where the default chip wraps nearly every one of them onto a line of
  its own. Tint, radius and link behaviour are unchanged, so a small chip still
  reads as the same object; only the type size and the padding shrink. It is a
  variant rather than a `class` override because a padding utility passed in
  `class` does not reliably win against the base one (same layer, and CSS
  source order decides, not attribute order).
  """
  attr(:navigate, :string, default: nil)
  attr(:href, :string, default: nil)
  attr(:size, :string, values: ~w(md sm), default: "md")
  attr(:class, :string, default: nil)
  attr(:rest, :global)
  slot(:inner_block, required: true)

  def chip(assigns) do
    ~H"""
    <.link
      :if={@navigate || @href}
      navigate={@navigate}
      href={@href}
      class={[chip_class(@size), "hover:bg-brand-100 dark:hover:bg-brand-900/70", @class]}
      {@rest}
    >
      {render_slot(@inner_block)}
    </.link>
    <span :if={!(@navigate || @href)} class={[chip_class(@size), @class]} {@rest}>
      {render_slot(@inner_block)}
    </span>
    """
  end

  defp chip_class("sm"),
    do:
      "inline-flex items-center gap-1 rounded-md bg-brand-50 px-2 py-0.5 text-xs font-medium text-brand-700 dark:bg-brand-900/40 dark:text-brand-100"

  defp chip_class(_md),
    do:
      "inline-flex items-center gap-2 rounded-lg bg-brand-50 px-3 py-1.5 text-sm font-medium text-brand-700 dark:bg-brand-900/40 dark:text-brand-100"

  @doc """
  The member's **employment-status badge** (issue #870): a small brand-tint
  pill that reads "Open to offers" or "Looking for a job", shown next to the
  tagline in the profile header so a visitor can see at a glance whether the
  member is available. Renders **nothing** for the unset default (`nil`) or any
  unknown value, so it is safe to drop in unconditionally. The wording is the
  schema's single source (`Vutuv.Accounts.User.employment_status_label/1`), so
  the badge, the edit form's select and the agent documents can never disagree.

  `workplace` appends the member's preferred workplace forms ("Remote",
  "Hybrid, Remote", …) to the same pill, so "Looking for a job · Hybrid,
  Remote" reads as one signal instead of competing badges. It is a **list** —
  the three do not exclude each other — rendered through
  `User.desired_workplace_line/1` in the canonical order. It shows only
  alongside a status (a preference without one is cleared by the changeset) and
  is governed by the very same visibility, so the caller needs no second gate.
  """
  attr(:status, :string, default: nil)
  attr(:workplace, :list, default: [])
  attr(:class, :string, default: nil)
  attr(:rest, :global)

  def employment_status_badge(assigns) do
    label = User.employment_status_label(assigns.status)
    workplace_label = User.desired_workplace_line(assigns.workplace)

    assigns =
      assigns
      |> assign(:label, label)
      |> assign(:workplace_label, workplace_label)
      # One text node, joined here rather than in the markup: a separator
      # interpolated between two tags loses its surrounding whitespace and the
      # pill renders "Auf Jobsuche· Remote".
      |> assign(:text, Enum.join(Enum.reject([label, workplace_label], &is_nil/1), " · "))

    ~H"""
    <span
      :if={@label}
      class={[
        "inline-flex items-center whitespace-nowrap rounded-full bg-brand-50 px-2.5 py-0.5 text-xs font-semibold text-brand-700 ring-1 ring-brand-100 dark:bg-brand-900/40 dark:text-brand-100 dark:ring-brand-900/60",
        @class
      ]}
      data-employment-status={@status}
      data-desired-workplace={@workplace_label && Enum.join(@workplace, " ")}
      {@rest}
    >
      {@text}
    </span>
    """
  end

  @doc """
  The profile **Tags** chip: a tag whose name links to the tag page, the
  visible-endorsement count shown as a calm brand-blue pill right after the name (the
  shell unread counter's shape, recoloured, a vouch count is social proof, not an
  alert), and the named voter roster (`<.voter_popover>`) revealed on hover/focus,
  pure CSS, no JS.

  For the owner and logged-out visitors the pill is **read-only and hidden at 0**. A
  logged-in non-owner gets the **same pill as the endorse toggle**: clicking it
  endorses (POST) or undoes (DELETE); it fills in (brand-600) once endorsed, and a
  zero-count tag shows a "+" so there is something to click. It is a CSRF `<.form>`
  (the no-JS fallback) that the `TagVote` enhancement in `app.js` drives over fetch,
  flipping `data-endorsed` and popping the count when it changes. The count is the
  visible endorsement tally (`compact_count`); the hover roster shows the latest
  endorsers' avatars and names.
  """
  attr(:user, :map, required: true, doc: "the profile owner whose tag this is")

  attr(:user_tag, :map,
    required: true,
    doc: "a UserTag with `endorsements` (and their `:user`) preloaded"
  )

  attr(:viewer, :any,
    default: nil,
    doc: "the current viewer's user struct, or nil when logged out"
  )

  attr(:live?, :boolean,
    default: false,
    doc:
      "on the profile LiveView, toggle the endorsement with a `phx-click` \"endorse\"/\"unendorse\" (the LiveView re-renders the pill + roster, no fetch); otherwise the CSRF form the `TagVote` enhancement drives"
  )

  attr(:roster?, :boolean,
    default: true,
    doc:
      "raise the named voter roster on hover; pass false where the page already shows the endorsers next to the chip (the tag list page's avatar strip), so the chip doesn't duplicate them behind a popover the legacy card would clip anyway"
  )

  def tag_vote(assigns) do
    user_tag = assigns.user_tag
    # An honor tag is an authoritative, admin-granted badge, not a peer vouch:
    # never votable, no count pill, no roster — just the name + the honor marker.
    honor? = UserTag.tag(user_tag).honor?
    viewer = assigns.viewer
    viewer_id = viewer && viewer.id
    total = Enum.count(user_tag.endorsements)
    can_vote? = !honor? && viewer_id && viewer_id != assigns.user.id

    endorsed? =
      !honor? && viewer_id && Enum.any?(user_tag.endorsements, &(&1.user_id == viewer_id))

    # An actionable viewer's own row is pre-rendered in the popover (hidden until
    # they endorse, then revealed by the JS toggle), so keep them out of the server
    # roster to avoid showing them twice.
    {others, others_total} = roster_for(user_tag, can_vote? && viewer_id, 6)

    assigns =
      assigns
      |> assign(:honor?, honor?)
      |> assign(:can_vote?, can_vote?)
      |> assign(:endorsed?, endorsed?)
      |> assign(:total, total)
      |> assign(:count, compact_count(total))
      |> assign(:others, others)
      |> assign(:extra, max(others_total - length(others), 0))
      # Whether the hover roster has anything to show right now. An actionable viewer
      # on a still-unendorsed, no-other-endorser tag still gets the popover in the DOM
      # (so the JS can reveal their row on endorse) but with hover disabled until then.
      |> assign(:roster_active?, !honor? && (others != [] || endorsed?))

    ~H"""
    <div class="group relative inline-flex items-center gap-1.5 rounded-lg bg-brand-50 px-3 py-1.5 text-sm font-medium hover:z-30 focus-within:z-30 dark:bg-brand-900/40">
      <.link
        navigate={~p"/#{@user}/tags/#{@user_tag}"}
        class="inline-flex items-center gap-1 text-brand-700 hover:underline dark:text-brand-100"
      >
        {UserTag.truncated_name(@user_tag)}
        <.honor_tag_badge :if={@honor?} />
      </.link>
      <%!-- Actionable viewer (logged-in non-owner): the count pill itself is the
      endorse toggle. It looks just like the read-only pill until you endorse, then
      fills in (brand-600); a zero-count tag shows a "+" so there is something to
      click. In `live?` mode (the profile LiveView) it is a phx-click <button> and
      the LiveView re-renders the pill + roster; otherwise the CSRF <.vote_form>
      (the no-JS fallback the TagVote enhancement in app.js drives over fetch). --%>
      <button
        :if={@can_vote? && @live?}
        type="button"
        phx-click={if(@endorsed?, do: "unendorse", else: "endorse")}
        phx-value-id={@user_tag.id}
        data-tag-vote-count
        data-endorsed={to_string(@endorsed?)}
        aria-pressed={to_string(@endorsed?)}
        title={if(@endorsed?, do: gettext("Remove endorsement"), else: gettext("Endorse"))}
        class={tag_vote_pill_class()}
      >{if(@total > 0, do: @count, else: "+")}</button>
      <.vote_form :if={@can_vote? && !@live?} user={@user} user_tag={@user_tag} endorsed?={@endorsed?}>
        <button
          type="submit"
          data-tag-vote-count
          data-endorsed={to_string(@endorsed?)}
          aria-pressed={to_string(@endorsed?)}
          title={if(@endorsed?, do: gettext("Remove endorsement"), else: gettext("Endorse"))}
          class={tag_vote_pill_class()}
        >{if(@total > 0, do: @count, else: "+")}</button>
      </.vote_form>
      <%!-- Read-only count (owner / logged-out): the tally as a calm brand-tint pill
      inline after the name, no endorsement-word so the Tags section stays about tags
      (tag_wording_test). The actionable viewer above gets the same pill as a button. --%>
      <span
        :if={!@can_vote? && @total > 0 && !@honor?}
        class="inline-flex h-[18px] min-w-[18px] items-center justify-center rounded-full bg-brand-100 px-1 text-[11px] font-bold tabular-nums text-brand-700 dark:bg-brand-800 dark:text-brand-100"
      >{@count}</span>
      <.voter_popover
        :if={@roster? && (@total > 0 || @can_vote?) && !@honor?}
        user={@user}
        user_tag={@user_tag}
        others={@others}
        extra={@extra}
        self={@can_vote? && @viewer}
        self_endorsed?={@endorsed?}
        active?={@roster_active?}
      />
    </div>
    """
  end

  @doc """
  The small **honor marker** on an honor tag: an icon only (no text in the
  flow, so `tag_wording_test` stays about tags), labelled for assistive tech via
  title/aria-label. Marks a vutuv-granted badge as distinct from a self-claimed
  tag. Rendered by `<.tag_vote>`'s chip and by the tag list page's rows.
  """
  def honor_tag_badge(assigns) do
    ~H"""
    <span
      class="inline-flex shrink-0 text-brand-600 dark:text-brand-400"
      title={gettext("Honor tag")}
      aria-label={gettext("Honor tag")}
    >
      <svg class="h-3.5 w-3.5" viewBox="0 0 24 24" fill="currentColor" aria-hidden="true">
        <path
          fill-rule="evenodd"
          d="M8.603 3.799A4.49 4.49 0 0 1 12 2.25c1.357 0 2.573.6 3.397 1.549a4.49 4.49 0 0 1 3.498 1.307 4.491 4.491 0 0 1 1.307 3.497A4.49 4.49 0 0 1 21.75 12a4.49 4.49 0 0 1-1.549 3.397 4.491 4.491 0 0 1-1.307 3.497 4.491 4.491 0 0 1-3.497 1.307A4.49 4.49 0 0 1 12 21.75a4.49 4.49 0 0 1-3.397-1.549 4.49 4.49 0 0 1-3.498-1.306 4.491 4.491 0 0 1-1.307-3.498A4.49 4.49 0 0 1 2.25 12c0-1.357.6-2.573 1.549-3.397a4.49 4.49 0 0 1 1.307-3.497 4.49 4.49 0 0 1 3.5-1.307Zm7.007 6.387a.75.75 0 1 0-1.22-.872l-3.236 4.53L9.53 12.22a.75.75 0 0 0-1.06 1.06l2.25 2.25a.75.75 0 0 0 1.14-.094l3.75-5.25Z"
          clip-rule="evenodd"
        />
      </svg>
    </span>
    """
  end

  @doc """
  The **endorsers' faces** for one of a member's tags (issue #895): a stacked
  `<.avatar_stack>` that is one link to that tag's full endorser list
  (`/:slug/tags/:tag/endorsers`).

  It carries the tag list page (`/:slug/tags`), where each row is the tag chip
  on the left and this strip on the right. The strip shows **no sentence**: a
  row of faces reads as "these people vouch for this" at a glance, and the
  names beside it made every row a wall of prose that drowned out the tags
  themselves. The sentence lives on as the strip's `title` / `aria-label`, so
  hover and assistive tech still name the newest endorser and count the rest,
  and one tap on the strip opens the page that names them all — the reason
  this page exists, since `<.tag_vote>`'s hover roster is a popover no touch
  device can open.

  **The strip is a bar chart.** Its *length* carries the tally: `scale_to` (the
  largest endorsement count among the member's tags) fills the bar, and every
  other row shows proportionally fewer faces, so a glance down the page ranks
  the tags without reading a single number. The bars grow **leftwards from a
  common right baseline**: each strip is padded to the full bar width and its
  faces are right-aligned inside it, and the `+N` value label past the bar's
  end sits in its own fixed-width column, so a two-digit remainder can't shove
  one row's bar out of line with the next. The faces are real endorsers (newest
  first), never repeated filler, and a tag with any endorsement keeps at least
  one — a bar that rounded away to nothing would read as "nobody".

  The **`+N` past the bar's end is how many endorsers the bar leaves out**
  (`total - faces`), the one number this strip states outright; the tally
  itself is the chip's count pill in the same row, and the two add up. It is a
  quiet muted label, not a chip, so it reads as the bar's value rather than as
  one more face.

  Renders **nothing** when nobody endorses the tag (an unendorsed row stays
  quiet instead of repeating an empty state down the whole list) and nothing
  for an honor tag, which is an admin-granted badge, not a peer vouch. Reads
  the `endorsements` preload (with their `:user`), so it costs no query.
  """
  attr(:user, :map, required: true, doc: "the profile owner whose tag this is")

  attr(:user_tag, :map,
    required: true,
    doc: "a UserTag with `endorsements` (and their `:user`) preloaded"
  )

  attr(:scale_to, :integer,
    required: true,
    doc:
      "the largest visible-endorsement count among the member's tags — the count that fills the bar"
  )

  attr(:class, :any, default: nil)

  # A full bar. Seven `xs` faces are 188px, which leaves room for the value
  # label beside the tag chip on a laptop and still fits on its own wrapped line
  # on the narrowest phone; seven steps is enough resolution to rank a member's
  # tags (they cap at 15).
  @bar_max_faces 7

  # One `xs` face is 32px and each following one is shingled 6px over the last.
  @face_px 32
  @face_step_px 26

  def endorsed_by(assigns) do
    endorsers = endorsers_of(assigns.user_tag, nil)
    total = length(endorsers)
    faces = bar_faces(total, assigns.scale_to)

    assigns =
      assigns
      |> assign(:shown, endorsers |> Enum.take(faces) |> Enum.with_index())
      |> assign(:hidden, total - faces)
      |> assign(:bar_width, bar_width(min(@bar_max_faces, assigns.scale_to)))
      |> assign(:primary, List.first(endorsers))
      # Everyone besides the named (newest) endorser: the "and N others" tail.
      |> assign(:others, max(total - 1, 0))

    ~H"""
    <.link
      :if={@primary && !UserTag.tag(@user_tag).honor?}
      navigate={~p"/#{@user}/tags/#{@user_tag}/endorsers"}
      title={endorsed_by_label(@primary, @others)}
      aria-label={endorsed_by_label(@primary, @others)}
      class={["flex shrink-0 items-center", @class]}
      style={"--endorser-bar: #{@bar_width}"}
    >
      <span class="flex w-[var(--endorser-bar)] max-w-full items-center justify-end">
        <.stack_faces shown={@shown} size="xs" pull="-ml-1.5" />
      </span>
      <%!-- Always rendered, even at 0, so every row's bar ends at the same x. --%>
      <span class="w-10 shrink-0 pl-1.5 text-xs font-medium tabular-nums text-slate-600 dark:text-slate-400">
        <%= if @hidden > 0 do %>
          +{compact_count(@hidden)}
        <% end %>
      </span>
    </.link>
    """
  end

  # How many faces stand for `count` endorsements when `scale_to` fills the bar.
  # Rounded, floored at one face for any endorsed tag, and never more faces than
  # there are endorsers to show (a short list simply makes for a short bar).
  defp bar_faces(0, _scale_to), do: 0
  defp bar_faces(_count, scale_to) when scale_to <= 0, do: 0

  defp bar_faces(count, scale_to) do
    (count / scale_to * @bar_max_faces)
    |> round()
    |> max(1)
    |> min(@bar_max_faces)
    |> min(count)
  end

  # The width of a bar of `n` shingled faces — the strip is padded to this even
  # when it shows fewer, so every row's bar ends at the same x.
  defp bar_width(n) when n > 0, do: "#{@face_px + (n - 1) * @face_step_px}px"
  defp bar_width(_), do: "#{@face_px}px"

  # The sentence the faces stand in for, kept as the strip's accessible name and
  # hover tooltip: who endorses this tag, newest first, and how many more.
  defp endorsed_by_label(primary, 0) do
    gettext("Endorsed by %{name}", name: endorser_name(primary))
  end

  defp endorsed_by_label(primary, others) do
    ngettext(
      "Endorsed by %{name} and %{formatted} other",
      "Endorsed by %{name} and %{formatted} others",
      others,
      name: endorser_name(primary),
      formatted: compact_count(others)
    )
  end

  attr(:organization, :map, required: true)
  attr(:version, :string, default: "feed")
  attr(:class, :string, default: "h-16 w-16")

  @doc """
  An organization's logo, or a brand-tint initials tile when it has none — the
  page's twin of `<.avatar>`. Lives in the kit (issue #1410) because the shared
  face strips render it too, and `VutuvWeb.OrganizationComponents` cannot be
  imported here (it imports this module).

  **`object-contain`, not `object-cover`** — this is where it differs from
  `<.avatar>`. Every slot that shows a logo is square, and a mark is rarely
  square: cover filled the box by cropping the sides off, which turned abuuba's
  four-dot logo (30×24) into two-and-a-half dots on its own page. A face
  survives being cropped; a wordmark or a logotype does not. Contain fits the
  whole mark inside the box and leaves the card's own background in the
  margins, which is what the ring and the rounded corners frame.
  """
  def organization_logo(assigns) do
    ~H"""
    <%= if @organization.logo do %>
      <img
        src={OrganizationImage.token_url(@organization.logo, @version)}
        alt={@organization.name}
        class={[@class, "rounded-2xl object-contain ring-1 ring-slate-200 dark:ring-slate-800"]}
      />
    <% else %>
      <span
        class={[
          @class,
          "flex items-center justify-center rounded-2xl bg-brand-50 font-bold text-brand-700 dark:bg-brand-900/40 dark:text-brand-100"
        ]}
        aria-hidden="true"
      >
        {organization_initial(@organization.name)}
      </span>
    <% end %>
    """
  end

  # A page's monogram is deliberately ONE letter — the shipped look of every
  # organization tile — where a member's `name_initials/1` takes two.
  defp organization_initial(name) do
    name
    |> String.trim()
    |> String.first()
    |> Kernel.||("?")
    |> String.upcase()
  end

  @doc """
  A **stack of overlapping avatars**, each linking to that member's profile and
  carrying their name as its tooltip, with the rest collapsing into a trailing
  `+N` chip once the list runs past `cap`. The compact way to show "these people
  did this" beside a sentence that names them, so the stack itself is
  `aria-hidden` decoration. Used by the post card's "Reposted by" banner; the
  tag list page's bar (`<.endorsed_by>`) shares only the faces, since it is one
  link and needs its own geometry.

  An entry is a member **or a page** (issue #1410, the permalink's "Liked by"
  row): a `%Organization{}` renders its logo, named and linked to its own page.
  """
  attr(:users, :list, required: true)
  attr(:cap, :integer, default: 5)
  attr(:size, :string, default: "2xs")

  attr(:total, :integer,
    default: nil,
    doc:
      "how many people the strip stands for, when that is more than `users` holds " <>
        "(the post permalink's likes: everyone counts, but a member who opted out " <>
        "of attribution has no face, so they ride in the `+N` instead). " <>
        "nil = the list is everybody."
  )

  attr(:overlap, :boolean,
    default: true,
    doc:
      "shingle the faces (the dense default); pass false for a spaced row, which keeps the initials of a picture-less member readable instead of hiding half of them under the next face"
  )

  attr(:class, :any, default: nil)

  def avatar_stack(assigns) do
    shown = Enum.take(assigns.users, assigns.cap)

    assigns =
      assigns
      |> assign(:shown, Enum.with_index(shown))
      |> assign(:overflow, (assigns.total || length(assigns.users)) - length(shown))
      |> assign(:pull, assigns.overlap && "-ml-1.5")

    ~H"""
    <div class={["flex shrink-0 items-center", !@overlap && "gap-1", @class]} aria-hidden="true">
      <.stack_faces shown={@shown} size={@size} pull={@pull} link? />
      <span
        :if={@overflow > 0}
        class={[
          "inline-flex h-5 items-center rounded-full bg-slate-100 px-1.5 text-[10px] font-bold text-slate-600 ring-2 ring-white dark:bg-slate-800 dark:text-slate-300 dark:ring-slate-900",
          @pull
        ]}
      >
        +{compact_count(@overflow)}
      </span>
    </div>
    """
  end

  # The shingled faces, shared by `<.avatar_stack>` and the tag page's bar: a
  # profile link per face where the strip is decoration beside a sentence, plain
  # spans where the strip is itself one link (an <a> inside an <a> is invalid).
  attr(:shown, :list, required: true, doc: "{member-or-page, index} pairs")
  attr(:size, :string, required: true)
  attr(:pull, :any, required: true)
  attr(:link?, :boolean, default: false)

  defp stack_faces(assigns) do
    ~H"""
    <%= for {account, i} <- @shown do %>
      <.link
        :if={@link?}
        href={Posts.author_path(account)}
        title={VutuvWeb.UserHelpers.author_name(account)}
        class={["rounded-full ring-2 ring-white dark:ring-slate-900", i > 0 && @pull]}
        data-stack-face
      >
        <.stack_face account={account} size={@size} />
      </.link>
      <span
        :if={!@link?}
        title={VutuvWeb.UserHelpers.author_name(account)}
        class={["rounded-full ring-2 ring-white dark:ring-slate-900", i > 0 && @pull]}
        data-stack-face
      >
        <.stack_face account={account} size={@size} />
      </span>
    <% end %>
    """
  end

  attr(:account, :map, required: true)
  attr(:size, :string, required: true)

  # A page's logo at the avatar's size: `rounded-2xl` on a face this small is a
  # circle anyway, so the wrapper's `rounded-full` ring still hugs it.
  defp stack_face(%{account: %Organization{}} = assigns) do
    ~H"""
    <.organization_logo organization={@account} class={avatar_size(@size)} />
    """
  end

  defp stack_face(assigns) do
    ~H"""
    <.avatar user={@account} size={@size} />
    """
  end

  # The endorse/undo pill's look, shared by the phx-click (live) and CSRF-form
  # renderings so they stay identical: a calm brand-tint pill that fills in
  # (brand-600) once `data-endorsed` flips true.
  defp tag_vote_pill_class do
    [
      "inline-flex h-[18px] min-w-[18px] items-center justify-center rounded-full px-1 text-[11px] font-bold tabular-nums transition-colors",
      "bg-brand-100 text-brand-700 hover:bg-brand-200 dark:bg-brand-800 dark:text-brand-100 dark:hover:bg-brand-700",
      "data-[endorsed=true]:bg-brand-600 data-[endorsed=true]:text-white data-[endorsed=true]:hover:bg-brand-700 dark:data-[endorsed=true]:bg-brand-600"
    ]
  end

  # The endorsers (preloaded users) for a tag's hover roster, newest first by the
  # endorsement id (a UUID v7, so id order is creation order), optionally excluding
  # one user (the actionable viewer, who gets their own pre-rendered row). Returns
  # `{capped_rows, total_rows}` so the caller can compute the "and N more" count.
  # In-memory off the profile's `visible_with_endorser` preload (no per-tag query).
  defp roster_for(user_tag, exclude_id, limit) do
    rows = endorsers_of(user_tag, exclude_id)

    {Enum.take(rows, limit), length(rows)}
  end

  # The same roster uncapped, for a caller that caps it itself (the avatar strip,
  # which needs the full list to fold the tail into its `+N` chip).
  defp endorsers_of(user_tag, exclude_id) do
    user_tag.endorsements
    |> Enum.reject(&(exclude_id && &1.user_id == exclude_id))
    |> Enum.sort_by(& &1.id, :desc)
    |> Enum.map(& &1.user)
  end

  # First + last name joined, "" when nameless. Excludes honorifics (unlike
  # full_name/1) so it feeds both the monogram and the endorser label.
  defp first_last(user) do
    [Map.get(user, :first_name), Map.get(user, :last_name)]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" ")
  end

  # An endorser's display name, falling back to their @handle when nameless.
  defp endorser_name(user) do
    case first_last(user) do
      "" -> "@" <> to_string(Map.get(user, :username))
      name -> name
    end
  end

  # The hover roster: a small card of the voters' avatars + names that rises above
  # the chip on hover/focus. Visibility is driven by the chip's `group-hover` /
  # `group-focus-within`; each row is a link to the endorser's profile, so the card
  # accepts pointer events and an invisible `after:` strip bridges the `mb-2` gap so
  # the cursor can travel from chip to card without the hover collapsing. Long names
  # truncate; the roster is capped (endorsers_for) with an "and N more" link to this
  # member's per-tag endorser list (/:slug/tags/:tag/endorsers), which carries the
  # full roster.
  attr(:user, :map, required: true)
  attr(:user_tag, :map, required: true)
  attr(:others, :list, required: true, doc: "endorser rows, the viewer excluded")
  attr(:extra, :integer, default: 0)
  attr(:self, :any, default: nil, doc: "the actionable viewer's user struct, for their own row")
  attr(:self_endorsed?, :any, default: false)
  attr(:active?, :boolean, default: true, doc: "enable hover now (else the JS turns it on)")

  defp voter_popover(assigns) do
    ~H"""
    <div
      data-roster
      class={[
        "absolute bottom-full left-0 z-30 mb-2 hidden w-max max-w-[14rem] rounded-xl bg-white p-2 shadow-lg ring-1 ring-slate-200 after:absolute after:inset-x-0 after:top-full after:h-2 after:content-[''] dark:bg-slate-800 dark:ring-slate-700",
        @active? && "group-hover:block group-focus-within:block"
      ]}
    >
      <ul class="space-y-0.5">
        <%!-- The viewer's own row is always pre-rendered (when they can endorse) but
        hidden until they have, so the JS toggle reveals it without a reload. --%>
        <li :if={@self} data-roster-row data-self-endorser class={[not @self_endorsed? && "hidden"]}>
          <.roster_entry user={@self} />
        </li>
        <li :for={endorser <- @others} data-roster-row>
          <.roster_entry user={endorser} />
        </li>
      </ul>
      <.link
        :if={@extra > 0}
        navigate={~p"/#{@user}/tags/#{@user_tag}/endorsers"}
        class="mt-1 block px-1 text-[11px] text-slate-500 hover:text-brand-600 dark:text-slate-400 dark:hover:text-brand-300"
      >
        {gettext("and %{count} more", count: compact_count(@extra))}
      </.link>
    </div>
    """
  end

  # One endorser row in the hover roster: avatar + name, a link to their profile.
  attr(:user, :map, required: true)

  defp roster_entry(assigns) do
    ~H"""
    <.link
      navigate={~p"/#{@user}"}
      class="flex items-center gap-2 rounded-lg px-1 py-0.5 hover:bg-slate-100 dark:hover:bg-slate-700/60"
    >
      <.avatar user={@user} size="xs" />
      <span class="min-w-0 truncate text-xs font-medium text-slate-700 dark:text-slate-200">
        {endorser_name(@user)}
      </span>
    </.link>
    """
  end

  # The CSRF endorse/undo form shared by every tag_vote variant: action/method are
  # the no-JS fallback (POST to endorse, DELETE to undo), the data-* attributes feed
  # the `TagVote` fetch enhancement in app.js. The inner button is variant-specific.
  attr(:user, :map, required: true)
  attr(:user_tag, :map, required: true)
  attr(:endorsed?, :any, required: true)
  slot(:inner_block, required: true)

  defp vote_form(assigns) do
    ~H"""
    <.form
      for={%{}}
      action={
        if(@endorsed?,
          do: ~p"/#{@user}/user_tag_endorsements/#{@user_tag}",
          else: ~p"/#{@user}/user_tag_endorsements?#{[id: @user_tag]}"
        )
      }
      method={if(@endorsed?, do: "delete", else: "post")}
      class="contents"
      data-tag-vote="true"
      data-endorse-url={~p"/#{@user}/user_tag_endorsements?#{[id: @user_tag]}"}
      data-unendorse-url={~p"/#{@user}/user_tag_endorsements/#{@user_tag}"}
      data-label-endorse={gettext("Endorse")}
      data-label-unendorse={gettext("Remove endorsement")}
    >
      {render_slot(@inner_block)}
    </.form>
    """
  end

  @doc """
  Splits a translated string on a `{marker}` placeholder into `{before, after}`,
  so a sentence can carry a link exactly where the placeholder sits — in the
  place German and English each want it. Split twice for two links (the
  landing-page consent line and the notifications welcome note both do).

  Deliberately **total**: `parts: 2` collapses a doubled placeholder (a botched
  translation) to one split, and a missing placeholder returns `{text, ""}`, so
  a malformed translation renders slightly wrong text and never raises. A hard
  `[a, b] = String.split(...)` here 500ed vutuv.de for every German visitor when
  a `.po` merge duplicated the German consent sentence (two placeholders where
  the code expected one); `page_locale_render_test.exs` guards against it.
  """
  def split_marker(text, marker) do
    case String.split(text, marker, parts: 2) do
      [before, rest] -> {before, rest}
      [whole] -> {whole, ""}
    end
  end

  @doc """
  Button. Renders a `<.link>` when given `navigate`/`patch`/`href` (with optional
  `method` for POST/DELETE actions), otherwise a `<button>` (set `type`). Variants:
  `primary` (default), `secondary`, `ghost`, `danger`.
  """
  attr(:variant, :string, default: "primary", values: ~w(primary secondary ghost danger))
  attr(:navigate, :string, default: nil)
  attr(:patch, :string, default: nil)
  attr(:href, :string, default: nil)
  attr(:method, :string, default: nil)
  attr(:type, :string, default: nil)
  attr(:class, :string, default: nil)

  attr(:rest, :global,
    include:
      ~w(download name value disabled form title target rel phx-click phx-value-id phx-disable-with)
  )

  slot(:inner_block, required: true)

  def button(assigns) do
    ~H"""
    <.link
      :if={@navigate || @patch || @href}
      navigate={@navigate}
      patch={@patch}
      href={@href}
      method={@method}
      class={[button_class(@variant), @class]}
      {@rest}
    >
      {render_slot(@inner_block)}
    </.link>
    <button
      :if={!(@navigate || @patch || @href)}
      type={@type || "button"}
      class={[button_class(@variant), @class]}
      {@rest}
    >
      {render_slot(@inner_block)}
    </button>
    """
  end

  @button_base "inline-flex items-center justify-center gap-1.5 rounded-lg px-4 py-2 text-sm font-semibold"
  defp button_class("secondary"),
    do:
      "#{@button_base} bg-slate-100 text-slate-700 hover:bg-slate-200 dark:bg-slate-800 dark:text-slate-200 dark:hover:bg-slate-700"

  defp button_class("ghost"),
    do:
      "#{@button_base} text-brand-600 hover:bg-brand-50 hover:text-brand-700 dark:text-brand-400 dark:hover:bg-slate-800 dark:hover:text-brand-300"

  defp button_class("danger"), do: "#{@button_base} bg-red-600 text-white hover:bg-red-700"
  defp button_class(_), do: "#{@button_base} bg-brand-600 text-white hover:bg-brand-700"

  @doc """
  Follow / unfollow control — the single owner of the two `~p"/follows…"`
  route shapes: a CSRF-protected **DELETE** `/follows/<follow_id>` to
  unfollow, or a **POST** `/follows?follow[follower_id][followee_id]` to
  follow, branched on whether `follow_id` is set (`nil` = not following). The
  following-state lookup (`following_by_id` / `user_follows_user?/2`) stays at the
  call site; this component just consumes its result via `follow_id`.

  Pass `follower_id` (the viewer's id) and `followee_id` (the target's id) plus
  the resolved `follow_id`. The owner/visitor/logged-in guards stay at the
  call site too. Three visual variants reproduce the four hand-written call
  sites byte-for-byte:

    * `"icon"` — the `button button--icon` icon-glyph track (`card_list`):
      `i.icon.icon--unfollow` / `i.icon.icon--follow`, rendered through
      `button/2` (a `<button>` with `data-method`).
    * `"text"` — the bespoke pill-toggle track (`user_row`): a small
      `rounded-full` pill that reads as one toggle in two states — the brand
      call-to-action "Follow" while you do not follow, a calm slate "Following"
      pill once you do that turns rose and swaps to "Unfollow" on hover.
    * `"button"` — the `<.button>` track (`show`, `teaser`): a secondary
      `<.button>` "Following" / a primary `<.button>` "Follow". `teaser` renders
      only the follow half — pass `follow_id={nil}` (a non-follower can only
      follow) and it emits exactly that one button.
    * `"segment"` — the **clickable outbound cell** of the profile header's
      segmented `<.follow_relationship>` control: a flush, square-cornered,
      `flex-1` `<.link>` whose colour encodes your follow state — green
      "✓ Following" once you follow, the brand call-to-action "Follow" while you
      do not. Sized to sit inside the pill (the wrapper clips the corners). Not
      used on its own.
  """
  attr(:variant, :string, required: true, values: ~w(icon text button segment))
  attr(:follower_id, :any, required: true)
  attr(:followee_id, :any, required: true)
  attr(:follow_id, :any, default: nil, doc: "the follow id, or nil when not following")

  attr(:live?, :boolean,
    default: false,
    doc:
      "in a LiveView (the profile), fire `phx-click` \"follow\"/\"unfollow\" instead of a CSRF link, so the page never reloads. Currently honored by the `segment` variant only."
  )

  def follow_button(%{variant: "icon"} = assigns) do
    ~H"""
    <%= if is_binary(@follow_id) do %>
      <%!-- Icon-only, so it must name itself (hover tooltip + screen-reader
      label), the same way <.mute_button> does — otherwise the glyph is a
      mystery button. --%>
      <%= button to: ~p"/follows/#{@follow_id}", method: :delete, class: "button button--icon",
            title: gettext("Unfollow"), aria: [label: gettext("Unfollow")] do %>
        <i class="icon icon--unfollow"></i>
      <% end %>
    <% else %>
      <%= button to: ~p"/follows?#{[follow: %{follower_id: @follower_id, followee_id: @followee_id}]}", method: :post, class: "button button--icon",
            title: gettext("Follow"), aria: [label: gettext("Follow")] do %>
        <i class="icon icon--follow"></i>
      <% end %>
    <% end %>
    """
  end

  def follow_button(%{variant: "text"} = assigns) do
    ~H"""
    <%= cond do %>
      <% @live? and is_binary(@follow_id) -> %>
        <button type="button" phx-click="unfollow" phx-value-id={@follow_id} class={text_follow_class(:following)}>
          <.following_label />

        </button>
      <% @live? -> %>
        <button type="button" phx-click="follow" phx-value-followee={@followee_id} class={text_follow_class(:follow)}>
          {gettext("Follow")}
        </button>
      <% is_binary(@follow_id) -> %>
        <%= button to: ~p"/follows/#{@follow_id}", method: :delete, class: text_follow_class(:following) do %>
          <.following_label />

        <% end %>
      <% true -> %>
        <%= button to: ~p"/follows?#{[follow: %{follower_id: @follower_id, followee_id: @followee_id}]}", method: :post, class: text_follow_class(:follow) do %>
          {gettext("Follow")}
        <% end %>
    <% end %>
    """
  end

  def follow_button(%{variant: "button"} = assigns) do
    ~H"""
    <.button :if={is_binary(@follow_id)} variant="secondary" href={~p"/follows/#{@follow_id}"} method="delete">
      {gettext("Following")}
    </.button>
    <.button
      :if={!is_binary(@follow_id)}
      href={~p"/follows?#{[follow: %{follower_id: @follower_id, followee_id: @followee_id}]}"}
      method="post"
    >
      {gettext("Follow")}
    </.button>
    """
  end

  def follow_button(%{variant: "segment"} = assigns) do
    ~H"""
    <%!-- The outbound half fills the left of the <.follow_relationship> pill;
    flex-1 keeps it the same width as the inbound half. Its colour encodes your
    follow state: a green "active" cell (with a check) once you follow, the brand
    call-to-action while you do not. The `title` carries the label for hover and
    screen readers. In `live?` mode it is a phx-click <button> (the profile
    LiveView, no reload); otherwise the CSRF <.link> (the no-JS fallback). Both
    share segment_class/1 so the two render identically. --%>
    <.link
      :if={is_binary(@follow_id) and not @live?}
      href={~p"/follows/#{@follow_id}"}
      method="delete"
      title={gettext("Following")}
      class={segment_class(:following)}
    >
      <span aria-hidden="true">✓</span><span class="whitespace-nowrap">{gettext("Following")}</span>
    </.link>
    <button
      :if={is_binary(@follow_id) and @live?}
      type="button"
      phx-click="unfollow"
      phx-value-id={@follow_id}
      title={gettext("Following")}
      class={segment_class(:following)}
    >
      <span aria-hidden="true">✓</span><span class="whitespace-nowrap">{gettext("Following")}</span>
    </button>
    <.link
      :if={!is_binary(@follow_id) and not @live?}
      href={~p"/follows?#{[follow: %{follower_id: @follower_id, followee_id: @followee_id}]}"}
      method="post"
      title={gettext("Follow")}
      class={segment_class(:follow)}
    >
      <span class="whitespace-nowrap">{gettext("Follow")}</span>
    </.link>
    <button
      :if={!is_binary(@follow_id) and @live?}
      type="button"
      phx-click="follow"
      phx-value-followee={@followee_id}
      title={gettext("Follow")}
      class={segment_class(:follow)}
    >
      <span class="whitespace-nowrap">{gettext("Follow")}</span>
    </button>
    """
  end

  # The two outbound-cell looks of the <.follow_relationship> pill, shared by the
  # CSRF-link and phx-click renderings so they stay pixel-identical: green
  # "active" once you follow, the brand call-to-action while you do not.
  defp segment_class(:following),
    do:
      "flex min-w-0 flex-1 items-center justify-center gap-1.5 overflow-hidden bg-emerald-700 px-2 py-1.5 text-white transition-colors hover:bg-emerald-800 active:bg-emerald-900"

  defp segment_class(:follow),
    do:
      "flex min-w-0 flex-1 items-center justify-center gap-1.5 overflow-hidden bg-brand-600 px-2 py-1.5 text-white transition-colors hover:bg-brand-700 active:bg-brand-800"

  # The `text` follow-button look (the `user_row` rail), shared by the live
  # phx-click and the classic CSRF renderings. Both states are the same small
  # rounded-full pill so they read as one toggle in two states (not a button
  # next to a dead status label): the brand call-to-action "Follow" while you do
  # not follow, a calm slate "Following" pill once you do — which turns rose +
  # swaps its label to "Unfollow" on hover (see `following_label/1`), the
  # X/GitHub unfollow affordance. `self-start` keeps the pill level with the
  # name's first line in the two-line `user_row`. Deliberately brand/slate, not
  # emerald: the green "✓" status language is reserved for the header pill.
  defp text_follow_class(:following),
    do:
      "group ml-auto self-start inline-flex shrink-0 items-center justify-center gap-1 min-w-[5.5rem] rounded-full border px-3 py-1 text-xs font-semibold transition-colors border-slate-300 text-slate-600 hover:border-rose-300 hover:text-rose-600 dark:border-slate-700 dark:text-slate-400 dark:hover:border-rose-800 dark:hover:text-rose-400"

  defp text_follow_class(:follow),
    do:
      "ml-auto self-start inline-flex shrink-0 items-center justify-center gap-1 min-w-[5.5rem] rounded-full border px-3 py-1 text-xs font-semibold transition-colors border-brand-600 text-brand-700 hover:bg-brand-50 dark:border-brand-500 dark:text-brand-400 dark:hover:bg-brand-900"

  # The label inside the "Following" pill: the resting "Following" swaps to a red
  # "Unfollow" on hover/focus (CSS group-hover, no JS), so the pill states what
  # clicking it does. The two German labels ("Folge ich" / "Entfolgen") are close
  # in width, so the pill barely resizes on hover.
  defp following_label(assigns) do
    ~H"""
    <span class="group-hover:hidden group-focus:hidden">{gettext("Following")}</span>
    <span class="hidden group-hover:inline group-focus:inline">{gettext("Unfollow")}</span>
    """
  end

  @doc """
  The tag page's **follow / unfollow** pill (issue #872) — the topic twin of
  `<.follow_button variant="text">`. It reuses the same "one control, two states"
  pill (brand-outline "Follow" while you don't follow; a calm slate "Following"
  that turns rose and swaps its label to "Unfollow" on hover/focus once you do,
  the X/GitHub unfollow affordance), so following a tag reads exactly like
  following a person — with a leading `#` glyph marking it as a *tag* follow, so
  it never reads as the per-person "Follow" pills in the endorsed-users list
  below it. It owns the two `~p"/tag_follows…"` route shapes (CSRF POST to follow,
  DELETE `/tag_follows/:tag_id` to unfollow), branched on `following?`. The tag
  page is a classic controller page, so this is the CSRF (page-reload) path; the
  feed rail renders its own reload-free `phx-click` chip. Keep the logged-in
  guard on a `:if` at the call site.
  """
  attr(:following?, :boolean, required: true)
  attr(:tag, :map, required: true)

  def tag_follow_button(%{following?: true} = assigns) do
    ~H"""
    <%= button to: ~p"/tag_follows/#{@tag.id}", method: :delete, class: tag_follow_class(:following) do %>
      <span aria-hidden="true">#</span>
      <.following_label />
    <% end %>
    """
  end

  def tag_follow_button(assigns) do
    ~H"""
    <%= button to: ~p"/tag_follows?#{[tag_follow: %{tag_id: @tag.id}]}", method: :post, class: tag_follow_class(:follow) do %>
      <span aria-hidden="true">#</span><span class="whitespace-nowrap">{gettext("Follow")}</span>
    <% end %>
    """
  end

  # The two looks of the tag-follow pill, mirroring `text_follow_class/1` (the
  # person pill) minus its `ml-auto self-start` list-row positioning, since the
  # tag pill stands on its own in the tag page header.
  defp tag_follow_class(:following),
    do:
      "group inline-flex shrink-0 items-center justify-center gap-1 rounded-full border px-3 py-1.5 text-xs font-semibold transition-colors border-slate-300 text-slate-600 hover:border-rose-300 hover:text-rose-600 dark:border-slate-700 dark:text-slate-400 dark:hover:border-rose-800 dark:hover:text-rose-400"

  defp tag_follow_class(:follow),
    do:
      "inline-flex shrink-0 items-center justify-center gap-1 rounded-full border px-3 py-1.5 text-xs font-semibold transition-colors border-brand-600 text-brand-700 hover:bg-brand-50 dark:border-brand-500 dark:text-brand-400 dark:hover:bg-brand-900"

  @doc """
  The profile header's **follow relationship** control — one fixed-width
  segmented pill (`w-80`) with two **equal-width halves** (`flex-1`) that is
  **always rendered in full**, so its size never changes between states; the
  relationship status reads at a glance from the text, colour and icon of each
  half. Three segments, always present in this order:

    1. **Outbound toggle** (`a`) — the clickable Follow / Following half, owned by
       `<.follow_button variant="segment">`. Brand call-to-action "Follow" while
       you do not follow; green "✓ Following" once you do.
    2. **Seam** (`span`) — a fixed-width `aria-hidden` glyph that encodes the
       follow direction: `·` none, `→` you follow them, `←` they follow you,
       `⇄` mutual (the seam goes emerald to mark a "vernetzt" mutual follow).
    3. **Inbound status** (`span`) — the read-only inbound half. Always states
       the inbound direction: green "✓ Follows you" when this member follows you,
       muted grey "✗ Doesn't follow you" otherwise.

  A mutual follow lights **both** halves green and the ring emerald, so
  "vernetzt" is unmistakable at a glance.

  `follow_id` is the viewer's follow of this member (`nil` = not following);
  `follows_viewer?` is whether this member follows the viewer back. Keep the
  owner / visitor / logged-in guard on the `:if` at the call site, like
  `<.follow_button>`.
  """
  attr(:follower_id, :any, required: true)
  attr(:followee_id, :any, required: true)
  attr(:follow_id, :any, default: nil, doc: "the viewer's follow id, or nil when not following")
  attr(:follows_viewer?, :boolean, default: false, doc: "does this member follow the viewer back")

  attr(:live?, :boolean,
    default: false,
    doc: "fire the outbound toggle as a `phx-click` (the profile LiveView) instead of a CSRF link"
  )

  def follow_relationship(assigns) do
    follows? = is_binary(assigns.follow_id)
    follows_viewer? = assigns.follows_viewer?
    mutual? = follows? and follows_viewer?

    {seam_glyph, seam_title} =
      cond do
        mutual? -> {"⇄", gettext("You follow each other")}
        follows? -> {"→", gettext("You follow this member")}
        follows_viewer? -> {"←", gettext("This member follows you")}
        true -> {"·", nil}
      end

    assigns =
      assigns
      |> assign(:follows_viewer?, follows_viewer?)
      |> assign(:mutual?, mutual?)
      |> assign(:seam_glyph, seam_glyph)
      |> assign(:seam_title, seam_title)

    ~H"""
    <%!-- Two equal-width halves (flex-1) whose size never changes between follow
    states. Green with a check = an active follow direction, grey with a cross =
    an inactive one; a mutual "vernetzt" follow lights both halves green and the
    ring emerald. The seam glyph (· → ← ⇄) shows the direction. The pill is a
    horizontal row at every width. On a phone it sizes to its labels (`w-auto`,
    each half one line via whitespace-nowrap) with the seam hidden, so it stays
    one short row in the white area beside the avatar (measured ~115px at a 374px
    viewport, well inside the space below the cover) rather than riding up into the
    cover banner. From sm up it is the fixed w-80 pill with the seam. --%>
    <div class={[
      "flex w-52 items-stretch divide-x overflow-hidden rounded-lg text-xs font-semibold ring-1 sm:w-80 sm:text-sm",
      if(@mutual?,
        do: "divide-emerald-300 ring-emerald-300 dark:divide-emerald-700 dark:ring-emerald-700",
        else: "divide-slate-300 ring-slate-200 dark:divide-slate-600 dark:ring-slate-700"
      )
    ]}>
      <.follow_button
        variant="segment"
        follower_id={@follower_id}
        followee_id={@followee_id}
        follow_id={@follow_id}
        live?={@live?}
      />
      <span
        aria-hidden="true"
        title={@seam_title}
        class={[
          "flex w-7 shrink-0 items-center justify-center text-xs",
          if(@mutual?,
            do: "bg-emerald-50 text-emerald-600 dark:bg-emerald-900/40 dark:text-emerald-300",
            else: "bg-slate-50 text-slate-400 dark:bg-slate-800/60 dark:text-slate-500"
          )
        ]}
      >
        {@seam_glyph}
      </span>
      <span
        title={if(@follows_viewer?, do: gettext("This member follows you"), else: gettext("This member doesn't follow you"))}
        class={[
          "flex min-w-0 flex-1 items-center justify-center gap-1.5 overflow-hidden px-2 py-1.5",
          if(@follows_viewer?,
            do: "bg-emerald-700 text-white",
            else: "bg-slate-100 text-slate-600 dark:bg-slate-800 dark:text-slate-400"
          )
        ]}
      >
        <%= if @follows_viewer? do %>
          <span aria-hidden="true">✓</span><span class="whitespace-nowrap">{gettext("Follows you")}</span>
        <% else %>
          <%!-- They don't follow you: the full label, no cross. Dropping the ✗ (and
          the segment divider added on the pill) keeps this half from blending into
          the seam glyph beside it. It can truncate on a very narrow phone; the
          title preserves the meaning. --%>
          <span class="whitespace-nowrap">{gettext("Doesn't follow you")}</span>
        <% end %>
      </span>
    </div>
    """
  end

  @doc """
  The **mute / unmute** toggle for a follow you own — silences the followee's
  posts in your feed while keeping the follow (and any mutual "vernetzt"
  status). Owns the `~p"/follows/:id/mute"` PUT route; `muted?` flips the
  state (the icon fills brand-tint while muted) and the title/label. A square
  icon button sized to sit beside the header's follow / message controls. Keep
  the "only when you follow them" guard (`:if={is_binary(@follow_id)}`) at the
  call site, like `<.follow_button>`.
  """
  attr(:follow_id, :any, required: true)
  attr(:muted?, :boolean, default: false)

  def mute_button(assigns) do
    ~H"""
    <%= button to: ~p"/follows/#{@follow_id}/mute", method: :put,
          title: mute_label(@muted?), aria: [label: mute_label(@muted?)],
          class: save_toggle_class(@muted?) do %>
      <.icon_bell_slash />
    <% end %>
    """
  end

  defp mute_label(true), do: gettext("Unmute")
  defp mute_label(false), do: gettext("Mute")

  # Bell-with-slash glyph (heroicons "bell-slash", outline). The muted state is
  # carried by the button's brand-tint background, not a separate solid icon.
  defp icon_bell_slash(assigns) do
    ~H"""
    <svg class="h-5 w-5" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor" aria-hidden="true">
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        d="M9.143 17.082a24.248 24.248 0 0 0 3.844.148m-3.844-.148a23.856 23.856 0 0 1-5.455-1.31 8.964 8.964 0 0 0 2.3-5.542m3.155 6.852a3 3 0 0 0 5.667 1.97m1.965-2.277L21 21m-4.225-4.225a23.81 23.81 0 0 0 3.536-1.003 8.967 8.967 0 0 1-2.302-5.39m0 0V9a6 6 0 0 0-9.5-4.875m8.5 4.875c0-1.79-.78-3.4-2.018-4.508M3 3l3.75 3.75M9.5 4.125 12 1.5"
      />
    </svg>
    """
  end

  # Square icon-toggle styling for the mute control, sized to sit beside the
  # header's text buttons. The active fill is the brand tint, matching the post
  # action bar's bookmark; inactive is the calm secondary outline.
  defp save_toggle_class(active?) do
    base =
      "inline-flex h-9 w-9 items-center justify-center rounded-lg ring-1 ring-inset transition"

    state =
      if active? do
        "text-brand-600 bg-brand-50 ring-brand-200 hover:bg-brand-100 dark:text-brand-300 dark:bg-brand-900/30 dark:ring-brand-900/50"
      else
        "text-slate-500 ring-slate-200 hover:bg-slate-50 hover:text-slate-700 dark:text-slate-400 dark:ring-slate-700 dark:hover:bg-slate-800"
      end

    [base, state] |> Enum.join(" ")
  end

  @doc """
  The wrapper `assets/js/lightbox.js` opens photos out of: it marks the group a
  click can step through and carries the overlay's own chrome wording, because
  the server is the only side that knows the reader's language.

  It exists as a component because there are two kinds of gallery now — a post's
  photos and the profile header's single avatar (issue #1528) — and the four
  labels are the part neither may spell differently from the other.
  """
  attr(:class, :any, default: nil)
  attr(:rest, :global)
  slot(:inner_block, required: true)

  def lightbox_gallery(assigns) do
    ~H"""
    <div
      class={@class}
      data-lightbox-gallery
      data-label-close={gettext("Close")}
      data-label-prev={gettext("Previous photo")}
      data-label-next={gettext("Next photo")}
      data-label-download={gettext("Download the original")}
      {@rest}
    >
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc """
  User avatar. Pass `user` (a `%Vutuv.Accounts.User{}`, resolved via `Vutuv.Avatar`)
  or a raw `src`. Sizes `2xs|xs|sm|md|lg` (`2xs` is the 20px inline size for
  compact attribution strips like the post card's "Reposted by" avatar stack);
  `shape` `circle` (default) or `square`.

  Set `presence` to overlay the real-time green "online" dot: the avatar is
  wrapped in a `[data-presence-user-id]` span that the Presence JS hook toggles
  on and off as that member comes and goes (see `assets/js/app.js` and the
  `.presence-dot` rule). The id is read from `user.id`; pass `presence_id` when
  you only have a `src`. The dot stays hidden until the hook confirms the member
  is online, so it never falsely shows on a classic (non-live) page.
  """
  attr(:user, :any, default: nil)
  attr(:src, :string, default: nil)
  attr(:alt, :string, default: "")
  attr(:size, :string, default: "md", values: ~w(2xs xs sm md lg))
  attr(:shape, :string, default: "circle", values: ~w(circle square))
  attr(:class, :string, default: nil)
  attr(:presence, :boolean, default: false)
  attr(:presence_id, :any, default: nil)
  # Lazy by default: list/grid pages (followers, search, the most-followed
  # listing) render ~100 avatars, almost all below the fold, so eager-loading
  # them all fires ~100 image requests on open. An above-the-fold hero (the
  # profile-header avatar) passes loading="eager" so it is not deprioritised.
  attr(:loading, :string, default: "lazy", values: ~w(lazy eager))

  # Neutral placeholder so a call with neither `user` nor `src` still renders a
  # valid <img> instead of a broken one.
  @fallback_avatar "data:image/svg+xml,%3Csvg%20xmlns='http://www.w3.org/2000/svg'%20viewBox='0%200%2024%2024'%3E%3Crect%20width='24'%20height='24'%20fill='%23e2e8f0'/%3E%3Ccircle%20cx='12'%20cy='9'%20r='4'%20fill='%2394a3b8'/%3E%3Cpath%20d='M4%2022c0-4%204-6%208-6s8%202%208%206'%20fill='%2394a3b8'/%3E%3C/svg%3E"

  # Public entry point: wraps the rendered avatar in the presence shell when
  # asked (and an id is resolvable), otherwise renders the bare avatar so the
  # hundreds of dot-less call sites are byte-for-byte unchanged.
  def avatar(assigns) do
    presence_id =
      if assigns.presence do
        raw = assigns.presence_id || (assigns.user && assigns.user.id)
        if raw, do: to_string(raw)
      end

    assigns = assign(assigns, :presence_resolved_id, presence_id)

    ~H"""
    <.presence_wrap id={@presence_resolved_id} size={@size}>
      <.avatar_inner
        user={@user}
        src={@src}
        alt={@alt}
        size={@size}
        shape={@shape}
        class={@class}
        loading={@loading}
      />
    </.presence_wrap>
    """
  end

  @doc """
  Online-presence shell shared by `<.avatar presence>` and the notifications
  kind-glyph: wraps the inner content in a `[data-presence-user-id]` span the
  Presence JS hook toggles the green `.presence-dot` on as that member comes and
  goes. Renders the content **bare** when `id` is nil (no actor, or a source
  without a resolvable id), so non-presence call sites are byte-for-byte
  unchanged. `isolate` + the dot's `z-10` keep the dot above an inner element
  that carries its own z-index (the profile-header avatar over the cover banner,
  which would otherwise hide the dot behind the photo).
  """
  attr(:id, :any, default: nil)
  attr(:size, :string, default: "sm", values: ~w(2xs xs sm md lg))
  slot(:inner_block, required: true)

  def presence_wrap(%{id: nil} = assigns) do
    ~H"{render_slot(@inner_block)}"
  end

  def presence_wrap(assigns) do
    ~H"""
    <span class="relative isolate inline-flex shrink-0" data-presence-user-id={to_string(@id)}>
      {render_slot(@inner_block)}
      <.presence_dot size={@size} hook />
    </span>
    """
  end

  @doc """
  The green "online" dot itself, the one definition of its colour, ring, size
  and position. Each mode owns its own visibility, so a call can never render an
  always-on dot by forgetting a guard:

    * `hook` (inside `<.presence_wrap>`): adds the `.presence-dot` class, hidden
      by default and revealed by the Presence JS hook's generated stylesheet,
      keyed on the wrapper's `data-presence-user-id`.
    * `online` (the shell's own avatar, the messages sidebar): server-driven —
      renders only when `online` is true, from the caller's own online state.

  With neither, it renders nothing (the safe default).
  """
  attr(:size, :string, default: "sm", values: ~w(2xs xs sm md lg))
  attr(:hook, :boolean, default: false)
  attr(:online, :boolean, default: false)

  # Server-driven and offline: render nothing, so no call site can leave an
  # ungated dot stuck on.
  def presence_dot(%{hook: false, online: false} = assigns), do: ~H""

  def presence_dot(assigns) do
    ~H"""
    <span class={[
      @hook && "presence-dot",
      "absolute z-10 rounded-full bg-emerald-500 ring-2 ring-white dark:ring-slate-900",
      presence_dot_pos(@size)
    ]}>
      <span class="sr-only">{gettext("Online")}</span>
    </span>
    """
  end

  # A user without a picture gets an initials tile (matching the shell's
  # top-bar avatar) instead of the anonymous placeholder image — initials
  # tell people apart in lists, a shared grey silhouette does not.
  defp avatar_inner(%{src: nil, user: %{avatar: nil} = user} = assigns) do
    assigns = assign(assigns, :initials, name_initials(user))

    ~H"""
    <span
      data-avatar
      role={@alt != "" && "img"}
      aria-label={@alt != "" && @alt}
      aria-hidden={@alt == "" && "true"}
      class={[
        avatar_size(@size),
        if(@shape == "square", do: "rounded-2xl", else: "rounded-full"),
        "inline-flex shrink-0 select-none items-center justify-center bg-brand-100 font-semibold text-brand-700 dark:bg-brand-900/40 dark:text-brand-100",
        initials_text_size(@size),
        @class
      ]}
    >{@initials}</span>
    """
  end

  defp avatar_inner(assigns) do
    src =
      assigns.src ||
        (assigns.user && Vutuv.Avatar.display_url(assigns.user, avatar_url_size(assigns.size))) ||
        @fallback_avatar

    assigns = assign(assigns, :resolved_src, src)

    ~H"""
    <img
      data-avatar
      src={@resolved_src}
      alt={@alt}
      loading={@loading}
      decoding="async"
      class={[
        avatar_size(@size),
        if(@shape == "square", do: "rounded-2xl", else: "rounded-full"),
        "object-cover",
        @class
      ]}
    />
    """
  end

  @doc """
  Up to two uppercased initials for a member, `"?"` when there is nothing to
  abbreviate. Accepts either a **user map** (built from `first_name` + `last_name`
  only, so an honorific like `"Dr."` never leaks into the monogram) or an already
  composed **display-name string** (`"Greta Tester"` → `"GT"`). This is the one
  definition of a member's monogram, shared by `<.avatar>` and the shell's
  top-bar tile so the two always agree.
  """
  def name_initials(nil), do: "?"

  def name_initials(%{first_name: _, last_name: _} = user) do
    user
    |> first_last()
    |> name_initials()
  end

  def name_initials(name) do
    name
    |> String.split(~r/\s+/, trim: true)
    |> Enum.take(2)
    |> Enum.map_join(&String.first/1)
    |> String.upcase()
    |> case do
      "" -> "?"
      initials -> initials
    end
  end

  defp avatar_size("2xs"), do: "h-5 w-5"
  defp avatar_size("xs"), do: "h-8 w-8"
  defp avatar_size("sm"), do: "h-9 w-9"
  defp avatar_size("lg"), do: "h-24 w-24"
  defp avatar_size(_), do: "h-12 w-12"

  defp initials_text_size("2xs"), do: "text-[9px]"
  defp initials_text_size("xs"), do: "text-xs"
  defp initials_text_size("sm"), do: "text-xs"
  defp initials_text_size("lg"), do: "text-3xl"
  defp initials_text_size(_), do: "text-base"

  defp avatar_url_size(size) when size in ["2xs", "xs", "sm"], do: :thumb
  defp avatar_url_size(_), do: :medium

  # Presence-dot position + size, scaled to the avatar. Nudged just outside the
  # lower-right so the white ring reads as a status badge on the corner.
  defp presence_dot_pos("2xs"), do: "-bottom-0.5 -right-0.5 h-2 w-2"
  defp presence_dot_pos("xs"), do: "-bottom-0.5 -right-0.5 h-2.5 w-2.5"
  defp presence_dot_pos("sm"), do: "-bottom-0.5 -right-0.5 h-3 w-3"
  defp presence_dot_pos("lg"), do: "bottom-1 right-1 h-4 w-4"
  defp presence_dot_pos(_), do: "-bottom-0.5 -right-0.5 h-3.5 w-3.5"

  # ── The profile cover banner's shape ──────────────────────────────────────
  #
  # One constant behind every rendering of a cover, because the crop dialog and
  # the banner have to frame the same rectangle. They did not: the dialog framed
  # 4:1 while the banner was a fixed-height `h-28` box of whatever width the
  # column happened to have (~6.6:1 on a desktop, ~3:1 on a phone), so the strip
  # a member positioned was cropped a second time, by a different amount on
  # every screen (issue #1518). Anything showing a cover — banner, settings
  # preview, the fresh-pick preview — takes `cover_aspect_class/0` and lets
  # `object-cover` do the rest.
  @cover_aspect_w 4
  @cover_aspect_h 1

  @doc "The cover banner's shape as `{width, height}` parts of its aspect ratio."
  def cover_aspect, do: {@cover_aspect_w, @cover_aspect_h}

  @doc """
  The `aspect-*` utility every cover frame carries. Spelled out rather than
  interpolated from `cover_aspect/0` because Tailwind's scanner only sees
  literal class strings; `cover_aspect_test.exs` fails the build if the two
  drift apart.
  """
  def cover_aspect_class, do: "aspect-[4/1]"

  @doc """
  The same shape as the number `assets/js/image_crop.js` reads out of the file
  input's `data-crop-aspect` (frame width divided by its height).
  """
  def cover_crop_aspect do
    ratio = @cover_aspect_w / @cover_aspect_h
    if ratio == trunc(ratio), do: Integer.to_string(trunc(ratio)), else: Float.to_string(ratio)
  end

  @doc "The shape as members read it in the upload hint: `\"4:1\"`."
  def cover_aspect_label, do: "#{@cover_aspect_w}:#{@cover_aspect_h}"

  @doc """
  Pixel size to aim for when uploading a cover: the widest version we store, at
  the banner's own shape. More pixels than this are thrown away by the resize.
  """
  def recommended_cover_size do
    width = Spec.max_width(:cover)
    {width, div(width * @cover_aspect_h, @cover_aspect_w)}
  end

  @doc """
  Pixel size to aim for when uploading an avatar: double what we store, rounded
  up to a figure a person can hold in their head. Double, because the crop
  dialog zooms up to 4x and a member who keeps a quarter of their photo should
  still have a sharp square left.
  """
  def recommended_avatar_size do
    size = ceil(Spec.max_width(:avatar) * 2 / 100) * 100
    {size, size}
  end

  @doc """
  Compact display form for counted numbers, used site-wide wherever a count is
  shown: exact up to 999, then `1K`, `80K`, `5M`, `2B`. Floored, so a count is
  never overstated ("1K" means at least a thousand).
  """
  def compact_count(n) when is_integer(n) and n >= 1_000_000_000,
    do: "#{div(n, 1_000_000_000)}B"

  def compact_count(n) when is_integer(n) and n >= 1_000_000, do: "#{div(n, 1_000_000)}M"
  def compact_count(n) when is_integer(n) and n >= 1_000, do: "#{div(n, 1_000)}K"
  def compact_count(n), do: to_string(n)

  @doc """
  An upload budget as the label a member reads (`4_000_000` -> `"4 MB"`), for
  the hint under a file field and the message that refuses an oversized one.
  Both say the same number because both call this.
  """
  def megabyte_label(bytes) when is_integer(bytes), do: "#{div(bytes, 1_000_000)} MB"

  @doc """
  The formats an extension whitelist accepts, as a member-readable list
  (`~w(.jpg .jpeg .png)` -> `"JPEG, PNG"`).

  Derived rather than written out because a whitelist is not the same on every
  installation — SVG needs librsvg in libvips, HEIC an HEVC decoder — and a
  hint naming a format the box then refuses is worse than no hint. An
  extension with no name here is dropped rather than shown raw.
  """
  @format_names %{
    ".jpg" => "JPEG",
    ".jpeg" => "JPEG",
    ".png" => "PNG",
    ".svg" => "SVG",
    ".webp" => "WebP",
    ".heic" => "HEIC",
    ".heif" => "HEIC",
    ".pdf" => "PDF"
  }

  def format_list(extensions) do
    extensions
    |> Enum.map(&Map.get(@format_names, &1))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.join(", ")
  end

  @doc """
  The translated name of a calendar month (`1..12`) — the one home of the
  month-name strings the work-experience form options and the profile/ad date
  labels share, instead of a copy of the twelve `gettext` literals per view.
  """
  def month_name(1), do: gettext("January")
  def month_name(2), do: gettext("February")
  def month_name(3), do: gettext("March")
  def month_name(4), do: gettext("April")
  def month_name(5), do: gettext("May")
  def month_name(6), do: gettext("June")
  def month_name(7), do: gettext("July")
  def month_name(8), do: gettext("August")
  def month_name(9), do: gettext("September")
  def month_name(10), do: gettext("October")
  def month_name(11), do: gettext("November")
  def month_name(12), do: gettext("December")

  @doc """
  The two-letter names of the weekdays, Monday first — the column headings of
  any calendar grid.

  Here for the same reason `month_name/1` is: one home for the seven strings
  rather than a copy per view. Moved up from `VutuvWeb.AdHTML`, which shipped
  them for the ad booking calendar long before the feed calendar wanted the
  same row; both call this now.

  Deliberately whole msgids and not `String.slice/3` on the full weekday names:
  the abbreviation is a translator's decision, not a substring, and slicing
  would have added seven more one-word msgids of exactly the kind
  `gettext.extract --merge` likes to fuzzy-fill.
  """
  def weekday_initials do
    [
      gettext("Mo"),
      gettext("Tu"),
      gettext("We"),
      gettext("Th"),
      gettext("Fr"),
      gettext("Sa"),
      gettext("Su")
    ]
  end

  @doc """
  Exact, thousands-grouped form of a count (`60123` -> `"60,123"`, or
  `"60.123"` under the German locale), for the rare place that wants the full
  number rather than the floored `compact_count/1` — the live member counter on
  the landing page. Grouping separator follows the active Gettext locale.
  """
  def delimited_count(n) when is_integer(n) do
    # German and Italian group thousands with a dot (60.023), English with a
    # comma (60,023). The separators invert between locales, so the wrong one
    # is misread rather than untidy.
    separator = if Gettext.get_locale(VutuvWeb.Gettext) in ~w(de it), do: ".", else: ","

    digits =
      n
      |> abs()
      |> Integer.to_string()
      |> String.reverse()
      |> String.graphemes()
      |> Enum.chunk_every(3)
      |> Enum.map_join(separator, &Enum.join/1)
      |> String.reverse()

    if n < 0, do: "-" <> digits, else: digits
  end

  @doc """
  The show-once credential reveal: a brand-tint box with a `select-all`
  `<code>` line, rendered only while the one-shot flash under `key` holds a
  freshly minted secret (access tokens, client secrets, webhook signing
  secrets). `label` is the "copy it now" sentence; `class` adds margin
  utilities at the call site.
  """
  attr(:flash, :map, required: true)
  attr(:key, :atom, required: true)
  attr(:label, :string, required: true)
  attr(:class, :any, default: nil)

  def secret_once(assigns) do
    assigns = assign(assigns, :secret, Phoenix.Flash.get(assigns.flash, assigns.key))

    ~H"""
    <div
      :if={@secret}
      class={[
        "rounded-lg bg-brand-50 p-4 ring-1 ring-brand-200 dark:bg-brand-900/40 dark:ring-brand-800",
        @class
      ]}
      data-secret-once={@key}
    >
      <p class="text-sm font-semibold text-brand-800 dark:text-brand-100">{@label}</p>
      <code class="mt-2 block select-all break-all rounded bg-white px-3 py-2 text-sm text-slate-800 dark:bg-slate-900 dark:text-slate-100">{@secret}</code>
    </div>
    """
  end

  @doc """
  A value the member is meant to hand out — a profile address, a Fediverse
  handle, an authenticator key — in a tinted box beside a Copy button.

  The button is the `data-copy` enhancement in `app.js`, which swaps its label
  to "Copied" for a moment; with JavaScript off the `<code>` is still
  `select-all`, so the value is one click and a keystroke away either way. Pass
  `copy_text` when what belongs in the clipboard differs from what is shown (the
  TOTP key is displayed in groups of four and copied without the spaces).

  Distinct from `secret_once/1`, which is the brand-tinted one-shot reveal of a
  credential that will never be shown again; this box is for a value the member
  can come back and read any time.

  `variant="inline"` drops the tinted surface and the block layout so the value
  can ride a line of page meta beside other facts (the tag page's Fediverse
  address, next to the follower count). Same `<code>` and same copy button, so
  the copy contract lives in one place either way — the surface is all that
  changes.
  """
  attr(:id, :string, required: true)

  attr(:variant, :string,
    default: "box",
    values: ~w(box inline),
    doc:
      "`box` is the tinted field a card gives a value of its own; `inline` drops the surface so the value can ride a meta line beside other facts"
  )

  attr(:class, :any, default: nil)
  attr(:code_class, :any, default: "text-sm")
  attr(:copy_text, :string, default: nil)
  slot(:inner_block, required: true)

  def copy_field(assigns) do
    ~H"""
    <div class={[
      @variant == "box" &&
        "flex gap-2 rounded-lg bg-slate-50 px-3 py-2 ring-1 ring-slate-200 dark:bg-slate-800/50 dark:ring-slate-700",
      @variant == "inline" && "inline-flex max-w-full items-center gap-1.5 align-middle",
      @class || (@variant == "box" && "mt-3 items-start")
    ]}>
      <code
        id={@id}
        class={["min-w-0 flex-1 select-all break-all text-slate-800 dark:text-slate-100", @code_class]}
      >{render_slot(@inner_block)}</code>
      <button
        type="button"
        data-copy
        data-copy-target={@id}
        data-copy-text={@copy_text}
        data-label-copy={gettext("Copy")}
        data-label-copied={gettext("Copied")}
        class="shrink-0 rounded-md bg-white px-2 py-1 text-xs font-semibold text-slate-700 ring-1 ring-slate-200 hover:bg-slate-100 dark:bg-slate-800 dark:text-slate-200 dark:ring-slate-700 dark:hover:bg-slate-700"
      >
        {gettext("Copy")}
      </button>
    </div>
    """
  end

  @doc """
  The single rendering of a viewer-localized timestamp — the `<time>` element
  the `LocalTime` pass rewrites into the viewer's timezone (the LiveView hook on
  live pages, the `time[data-localtime]` DOMContentLoaded sweep on classic ones;
  see `assets/js/app.js`). The server text inside is the no-JS fallback.

  Stored timestamps are UTC, so the `datetime`/`title` is always emitted as
  unambiguous ISO-8601 with a trailing `Z` (a naive datetime is treated as UTC,
  a `DateTime` is rendered with its own offset), the form every browser parses as
  UTC. Hand-rolling the element with a space-separated stamp (no `T`) made some
  browsers read it as *local* time — the bug this component centralizes away.

  Pass `id` when the element lives inside a LiveView so the `LocalTime` hook can
  attach (the hook needs a DOM id); omit it on classic pages, where the
  `data-localtime` sweep handles it.

  **Who writes the text.** Once a member has picked a time zone of their own
  (`users.time_zone`, issue #1502) the server renders in it and the element
  carries no `data-localtime`, so the client leaves it alone: their setting has
  to beat the machine they happen to be reading on. Without one — an anonymous
  visitor, or a member who never chose — nothing on the server knows the
  reader's zone, so the browser keeps the last word exactly as before.

  `style` picks the shape from the viewer's date region (`Vutuv.DateRegions`):
  `:datetime` (the default), `:date`, `:short_date`, `:time`,
  `:datetime_seconds`. Pass `format` instead to pin a literal
  `Calendar.strftime/2` pattern — what the admin tables do, where an ISO date
  is the point and a member's German or American shape would only get in the
  way of comparing rows.

  `precision="second"` makes the *rewritten* text carry seconds
  (`data-localtime="second"`, which the JS reads); pair it with
  `style={:datetime_seconds}` or a seconds-carrying `format` so both halves
  agree. Minutes are right for everything that is merely "when did this
  arrive"; the account-activity log (issue #1087) is the case where they are
  not — support answering "you changed this at 14:32:07" needs the second, and
  two events inside one minute have to be distinguishable in the order they are
  shown in.
  """
  attr(:at, :any, required: true, doc: "a NaiveDateTime (treated as UTC) or a UTC DateTime")
  attr(:id, :string, default: nil, doc: "DOM id; when set, the LocalTime hook attaches")
  attr(:format, :string, default: nil, doc: "a literal strftime pattern; overrides style")

  attr(:style, :atom,
    values: ~w(date short_date time datetime short_datetime datetime_seconds)a,
    default: :datetime
  )

  attr(:precision, :string, values: ~w(minute second), default: "minute")
  attr(:class, :any, default: nil)
  attr(:rest, :global)

  def local_time(assigns) do
    server_final? = ViewerClock.own_zone?()

    assigns =
      assign(assigns,
        iso: iso_utc(assigns.at),
        text: local_time_text(assigns, server_final?),
        localtime: !server_final? && assigns.precision
      )

    ~H"""
    <time
      id={@id}
      phx-hook={@id && @localtime && "LocalTime"}
      data-localtime={@localtime}
      datetime={@iso}
      title={@iso}
      class={@class}
      {@rest}
    >{@text}</time>
    """
  end

  # The visible text: the reader's shape either way, but only shifted into their
  # zone when the server has the last word. Otherwise the instant stays UTC, as
  # the no-JavaScript fallback it has always been — writing an
  # installation-default zone into text the browser is about to overwrite would
  # only make the pre-rewrite flash wrong in a second way, and the ISO `title`
  # carries the unambiguous stamp regardless.
  defp local_time_text(assigns, server_final?) do
    pattern = assigns.format || ViewerClock.pattern(assigns.style)

    if server_final?,
      do: assigns.at |> ViewerClock.naive() |> Calendar.strftime(pattern),
      else: Calendar.strftime(assigns.at, pattern)
  end

  defp iso_utc(%DateTime{} = dt), do: dt |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  defp iso_utc(%NaiveDateTime{} = ndt), do: NaiveDateTime.to_iso8601(ndt) <> "Z"

  @doc """
  A **post** timestamp, rendered entirely on the server in the **reader's own**
  time zone and date shape (`Vutuv.ViewerClock`, issue #1502; before that every
  post was stamped in Europe/Berlin for everybody). Unlike `<.local_time>` there
  is never a client-side rewrite, because the wording is relative to the
  reader's calendar day and only the server knows which day that is: a post from
  **today** shows just the time ("08:42 Uhr" in German on a 24-hour clock, a
  bare "8:42 AM" on a 12-hour one), one from **yesterday** the word plus the
  time, older posts the short date and time in the reader's region ("02.07.26,
  08:42" / "7/2/26, 8:42 AM"). The `<time>` keeps the UTC `datetime` for
  machines/agents and a full-date `title` for hover, but the visible text is
  final from the server, so it deliberately carries **no** `data-localtime`
  marker (the JS localizer skips it).

  Because today/yesterday moves with the clock, `Vutuv.DayClock` broadcasts
  `:day_changed` on every whole UTC hour and the LiveViews that show posts
  (feed, profile, notifications) re-render their stamps then, so an open page
  rolls "08:42 Uhr" over to "Gestern, 08:42 Uhr" at the reader's own midnight
  without a reload. Used by the post card and the thread/notification post
  preview; every other timestamp uses `<.local_time>`.
  """
  attr(:at, :any, required: true, doc: "a NaiveDateTime (treated as UTC) or a UTC DateTime")
  attr(:id, :string, default: nil)
  attr(:class, :any, default: nil)

  def post_time(assigns) do
    local = ViewerClock.naive(assigns.at)
    bucket = day_bucket(ViewerClock.date(assigns.at), ViewerClock.today())
    locale = Gettext.get_locale(VutuvWeb.Gettext)
    region = ViewerClock.region()

    assigns =
      assign(assigns,
        iso: iso_utc(assigns.at),
        text: post_stamp(local, bucket, locale, region),
        full: post_stamp(local, :older, locale, region)
      )

    ~H"""
    <time id={@id} datetime={@iso} title={@full} class={@class}>{@text}</time>
    """
  end

  # Which of the reader's days a post falls in, relative to their today. The
  # `Vutuv.DayClock` re-renders open pages on the hour so a post moves
  # `:today -> :yesterday -> :older` as the day rolls over. A stamp from the
  # future (clock skew) is never possible in practice, so it collapses to `:older`.
  defp day_bucket(post_date, today) do
    cond do
      post_date == today -> :today
      post_date == Date.add(today, -1) -> :yesterday
      true -> :older
    end
  end

  # Two independent axes, which is why both are passed: the **language** picks
  # the words ("Gestern" / "Yesterday") and the **region** the digits. German
  # adds an "Uhr" suffix to a bare time, but only on a 24-hour clock — "2:30 PM
  # Uhr" is not a thing anyone says. The full-date form (`:older`) also backs
  # every stamp's hover `title`, so machines and hovers keep the date.
  defp post_stamp(local, :today, locale, region) do
    time = Calendar.strftime(local, DateRegions.pattern(region, :time))

    if locale == "de" and DateRegions.clock(region) == :h24, do: time <> " Uhr", else: time
  end

  defp post_stamp(local, :yesterday, locale, region) do
    yesterday = relative_yesterday(locale)
    yesterday <> ", " <> post_stamp(local, :today, locale, region)
  end

  defp post_stamp(local, :older, _locale, region) do
    Calendar.strftime(local, ViewerClock.pattern(region, :short_datetime))
  end

  # One clause per interface language rather than a two-way `if`: the word is
  # not a Gettext string because this runs outside a request in the agent
  # formats, where the process locale is not the reader's.
  defp relative_yesterday("de"), do: "Gestern"
  defp relative_yesterday("it"), do: "Ieri"
  defp relative_yesterday(_), do: "Yesterday"

  @doc "Coral unread-count badge. Renders nothing when `count` is 0. Pass `class` to position it."
  attr(:count, :integer, default: 0)
  attr(:class, :string, default: nil)

  def count_badge(assigns) do
    ~H"""
    <span
      :if={@count > 0}
      class={[
        "inline-flex h-[18px] min-w-[18px] items-center justify-center rounded-full bg-accent px-1 text-[11px] font-bold text-white",
        @class
      ]}
    >
      {compact_count(@count)}
    </span>
    """
  end

  @doc """
  The owner-facing moderation freezer notice — the one rendering of "only you
  can see this while a report is handled" (post card, profile header). A
  quiet amber strip with the ⚑ glyph and a "Review" link to the owner's case
  list; `class` sets the per-surface shell (radius, padding, text size).
  Guard visibility (`:if={owner and frozen}`) at the call site.
  """
  attr(:class, :any, default: nil)
  slot(:inner_block, required: true)

  def frozen_banner(assigns) do
    ~H"""
    <p
      data-frozen-banner
      class={[
        "flex flex-wrap items-center gap-1.5 bg-amber-50 font-semibold text-amber-800 ring-1 ring-amber-200 dark:bg-amber-900/30 dark:text-amber-200 dark:ring-amber-900",
        @class
      ]}
    >
      <span aria-hidden="true">⚑</span>
      {render_slot(@inner_block)}
      <.link href={~p"/moderation/cases"} class="underline hover:no-underline">
        {gettext("Review")}
      </.link>
    </p>
    """
  end

  @doc """
  The status pill in the admin oversight tables (jobs, organizations, users):
  the shape is fixed, the colour is not. `tone` is the tint the host's own
  `*_status_badge/1` picked for this row — "frozen" is amber wherever it
  appears, and only the host knows what frozen means for its records.

  Beside `admin_pager/1` because it has the same reach: seven copies of the
  five base utilities sat across four admin LiveViews, so a change to the pill
  shape was a change in four files, and one of them drifting was invisible.
  """
  attr(:tone, :string, required: true)
  attr(:rest, :global)
  slot(:inner_block, required: true)

  def admin_pill(assigns) do
    ~H"""
    <span
      class={["inline-flex items-center rounded-full px-2 py-0.5 text-xs font-semibold", @tone]}
      {@rest}
    >
      {render_slot(@inner_block)}
    </span>
    """
  end

  @doc """
  The prev / "Page N of M" / next control shared by the admin oversight
  LiveViews (jobs, organizations, users). Distinct from `pager/1` (URL links):
  this fires `phx-click="page"` with `phx-value-page`, so the host LiveView owns
  the paging. `prev_id`/`next_id` add button ids (the user browser's tests key
  on `#prev-page`/`#next-page`); a nil id omits the attribute, and a nil
  `disabled_class` drops out of the class list. Renders nothing for a single page.
  """
  attr(:page, :integer, required: true)
  attr(:pages, :integer, required: true)
  attr(:prev_id, :string, default: nil)
  attr(:next_id, :string, default: nil)
  attr(:disabled_class, :string, default: nil)

  def admin_pager(assigns) do
    ~H"""
    <nav
      :if={@pages > 1}
      class="mt-6 flex items-center justify-center gap-3 text-sm font-semibold"
      aria-label={gettext("Pagination")}
    >
      <button
        type="button"
        phx-click="page"
        phx-value-page={@page - 1}
        disabled={@page <= 1}
        id={@prev_id}
        class={[
          "rounded-lg px-3 py-1.5 text-slate-600 hover:bg-slate-100 disabled:opacity-40 dark:text-slate-300 dark:hover:bg-slate-800",
          @disabled_class
        ]}
      >
        ‹ {gettext("Previous")}
      </button>
      <span class="text-slate-600 dark:text-slate-400">
        {gettext("Page %{page} of %{pages}", page: @page, pages: @pages)}
      </span>
      <button
        type="button"
        phx-click="page"
        phx-value-page={@page + 1}
        disabled={@page >= @pages}
        id={@next_id}
        class={[
          "rounded-lg px-3 py-1.5 text-slate-600 hover:bg-slate-100 disabled:opacity-40 dark:text-slate-300 dark:hover:bg-slate-800",
          @disabled_class
        ]}
      >
        {gettext("Next")} ›
      </button>
    </nav>
    """
  end

  @doc """
  The like + bookmark toggle pair on job cards and the job / organization
  pages: a heart with the visible like count and a bookmark flag, firing
  `toggle_like` / `toggle_bookmark` on the host LiveView. `engagement` is the
  `%{likes:, liked?:, bookmarked?:}` map the Jobs / Organizations contexts
  return; `value_id` (optional) rides along as `phx-value-id` when one
  LiveView hosts many cards (the board). Just the two buttons — the layout
  wrapper stays at the call site. Guard rendering with `:if={@engagement}`.
  """
  attr(:engagement, :map, required: true)
  attr(:value_id, :string, default: nil)

  def engagement_bar(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="toggle_like"
      phx-value-id={@value_id}
      aria-pressed={@engagement.liked?}
      class={[
        "flex items-center gap-1.5 text-sm font-medium",
        @engagement.liked? && "text-accent"
      ]}
    >
      <.icon_heart filled?={@engagement.liked?} class="h-5 w-5" />
      <span class="tabular-nums">{compact_count(@engagement.likes)}</span>
      <span class="sr-only">{gettext("Like")}</span>
    </button>

    <button
      type="button"
      phx-click="toggle_bookmark"
      phx-value-id={@value_id}
      aria-pressed={@engagement.bookmarked?}
      class={[
        "flex items-center gap-1.5 text-sm font-medium",
        @engagement.bookmarked? && "text-brand-600 dark:text-brand-300"
      ]}
    >
      <.icon_bookmark filled?={@engagement.bookmarked?} class="h-5 w-5" />
      <span class="sr-only">{gettext("Bookmark")}</span>
    </button>
    """
  end

  @doc """
  The overview stat tile the admin oversight dashboards share (`/admin/jobs`,
  `/admin/organizations`): a small card with a big `delimited_count/1` figure
  over an uppercase label. `attention` (default false) switches the tile to
  the amber "needs a look" treatment (the open-cases tile).
  """
  attr(:label, :string, required: true)
  attr(:value, :integer, required: true)
  attr(:attention, :boolean, default: false)

  def admin_stat_tile(assigns) do
    ~H"""
    <div class={[
      "rounded-2xl bg-white p-4 text-center shadow-sm ring-1 dark:bg-slate-900",
      if(@attention,
        do: "ring-amber-300 dark:ring-amber-700",
        else: "ring-slate-200 dark:ring-slate-800"
      )
    ]}>
      <div class={[
        "text-2xl font-bold",
        if(@attention,
          do: "text-amber-700 dark:text-amber-300",
          else: "text-slate-900 dark:text-slate-100"
        )
      ]}>
        {delimited_count(@value)}
      </div>
      <div class="text-xs font-semibold uppercase tracking-wide text-slate-500 dark:text-slate-400">
        {@label}
      </div>
    </div>
    """
  end

  @doc """
  Numbered pagination for offset-paginated pages (followers, tags, users, the
  notifications feed). Pass the params (for the current `?page`) and the total
  row count; windowing comes from `Vutuv.Pages`. Renders nothing when one page
  fits everything. The endless newsfeed uses `<.load_more>` instead.

  `per_page` overrides the page size (default the site-wide
  `Vutuv.Pages.max_page_items/0`); it must match the `per_page` the query was
  paginated with. `query` is extra query params to carry onto every page link
  (e.g. the active sort), so pagination does not drop the current sort/filter
  — `?page=N` alone would.

  `path` makes it the **LiveView** variant: page links become `patch`
  navigation to that path (`/notifications?page=3`), so paging stays on the
  socket and the host's `handle_params` loads the page. Without it the links
  are plain hrefs, the right thing on a classic controller page.
  """
  attr(:params, :map, required: true)
  attr(:total, :integer, required: true)
  attr(:per_page, :integer, default: nil)
  attr(:query, :map, default: %{})
  attr(:path, :string, default: nil)

  def pager(assigns) do
    per_page = assigns.per_page || Vutuv.Pages.max_page_items()
    total_pages = Vutuv.Pages.total_pages(assigns.total, per_page)
    current = Vutuv.Pages.effective_page(assigns.params, assigns.total, per_page)
    window = Enum.filter((current - 5)..(current + 5), &(&1 in 1..total_pages))

    assigns =
      assigns
      |> assign(:total_pages, total_pages)
      |> assign(:current, current)
      |> assign(:window, window)

    ~H"""
    <nav
      :if={@total_pages > 1}
      aria-label={gettext("Pagination")}
      class="mt-6 flex items-center justify-center gap-1 text-sm font-semibold"
    >
      <%!-- The two ends are always reachable. On a list long enough to have
      hundreds of pages (a member's Fediverse followers), a window of eleven
      numbers with a dead "…" beside it strands you in the middle with no way
      back to the first page or forward to the last. --%>
      <.pager_link :if={List.first(@window) > 1} num={1} path={@path} query={@query} />
      <span :if={List.first(@window) > 2} class="px-1 text-slate-600 dark:text-slate-400">…</span>
      <%= for num <- @window do %>
        <%= if num == @current do %>
          <span
            aria-current="page"
            class="flex h-9 min-w-9 items-center justify-center rounded-lg bg-brand-600 px-2 text-white"
          >
            {num}
          </span>
        <% else %>
          <.pager_link num={num} path={@path} query={@query} />
        <% end %>
      <% end %>
      <span
        :if={List.last(@window) < @total_pages - 1}
        class="px-1 text-slate-600 dark:text-slate-400"
      >
        …
      </span>
      <.pager_link
        :if={List.last(@window) < @total_pages}
        num={@total_pages}
        path={@path}
        query={@query}
      />
    </nav>
    """
  end

  # One page link, in the pager's two modes: a plain href on a classic page, a
  # `patch` when the host is a LiveView that reloads from `handle_params`.
  defp pager_link(assigns) do
    ~H"""
    <.link
      href={if(is_nil(@path), do: page_query(@query, @num))}
      patch={if(@path, do: @path <> page_query(@query, @num))}
      class="flex h-9 min-w-9 items-center justify-center rounded-lg px-2 text-slate-600 hover:bg-slate-100 dark:text-slate-300 dark:hover:bg-slate-800"
    >
      {@num}
    </.link>
    """
  end

  defp page_query(query, num), do: "?" <> URI.encode_query(Map.put(query, "page", num))

  @doc """
  Classic-page (components.css-styled) page top shared by the controller pages: the `.profile-header`
  h1 block and/or the `.breadcrumbs` row. This is the boilerplate that opened ~47
  page templates (and the breadcrumbs row ~65). Styled by `components.css`, not
  Tailwind — do not swap in utilities.

  Pass `title` to render the `<div class="profile-header"><div class="profile-header__info"><h1>…</h1></div></div>`
  block (the title is a plain string the call site already builds, e.g.
  `gettext("Emails belonging to ") <> full_name(@user)` or
  `gettext("Tags of %{name}", name: full_name(@user))`); omit it on the new/edit
  pages that only carry breadcrumbs. Pass `crumbs` (the list you used to hand to
  `gen_breadcrumbs/1`) to render the `.breadcrumbs` row; `gen_breadcrumbs/1` is
  called **fully qualified** here because `VutuvWeb.UI` does not import
  `UserHelpers`. Pages whose header carries more than the single h1 (avatar,
  buttons, …) keep their hand-written markup.

  Use it as `<.page_header title={…} crumbs={[gettext("Users"), {full_name(@user), ~p"/…"}, gettext("Emails")]} />`.

  `manage_to` (optional, falsy = absent) renders a quiet right-aligned
  "Manage ›" link in the title row — the owner's bridge from a public section
  page (/:slug/links) to its /settings editor. Gate it at the call site
  (`manage_to={same_user?(@user, @current_user) && ~p"/settings/links"}`), so
  a visitor's page carries nothing.
  """
  attr(:title, :string, default: nil)
  attr(:crumbs, :list, default: nil)
  attr(:manage_to, :any, default: nil)

  def page_header(assigns) do
    ~H"""
    <div :if={@title} class="profile-header">
      <div class="profile-header__info">
        <h1>{@title}</h1>
      </div>
      <.link :if={@manage_to} navigate={@manage_to} class="profile-header__manage">
        {gettext("Manage")} ›
      </.link>
    </div>
    <%!-- New/edit forms pass only crumbs; still give the page one h1 (the last
    crumb is its identity) so screen-reader and keyboard heading navigation work. --%>
    <h1 :if={is_nil(@title) and @crumbs} class="sr-only">{crumbs_title(@crumbs)}</h1>
    <div :if={@crumbs} class="breadcrumbs">
      {VutuvWeb.UserHelpers.gen_breadcrumbs(@crumbs)}
    </div>
    <%!-- The same visible trail as schema.org BreadcrumbList, so search
    engines show the page's place under the profile instead of a bare URL. --%>
    <JsonLd.script :if={@crumbs} data={JsonLd.breadcrumb_trail(@crumbs)} />
    """
  end

  defp crumbs_title(crumbs) do
    crumbs |> List.last() |> crumb_text()
  end

  defp crumb_text(text) when is_binary(text), do: text
  defp crumb_text({text, _href}) when is_binary(text), do: text
  defp crumb_text(other), do: to_string(other)

  @doc """
  Changeset-error banner shared by the `editform` `form_content` templates and
  the sign-up form. Renders the `.alert.alert-danger` strip only when the
  changeset has been acted on **and** actually carries errors: a warning glyph
  plus one actionable sentence ("Please check the fields marked in red."),
  announced to assistive tech via `role="alert"`. The sentence must stay true
  wherever the banner shows — classic editform pages mark errored fields via
  `.editform__field--error`, kit forms via `input_class/2`.

  The `errors` half of that condition is what makes it true. A live-validating
  form (`phx-change="validate"`) stamps `action: :validate` on **every**
  keystroke and on picking a file, so an `action`-only test put the banner up
  against a form with nothing marked in red — which is what a member gets on
  `/organizations/:slug/edit` the moment they choose a logo, and reads as "my
  picture was refused". Styled by `components.css`, not Tailwind — do not swap
  in utilities. Use it as `<.form_error changeset={@changeset} />`.
  """
  attr(:changeset, :any, required: true)

  def form_error(assigns) do
    ~H"""
    <div :if={@changeset.action && @changeset.errors != []} class="alert alert-danger" role="alert">
      <svg class="alert__icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" aria-hidden="true">
        <path
          stroke-linecap="round"
          stroke-linejoin="round"
          d="M12 9v4m0 4h.01M10.29 3.86 1.82 18a2 2 0 0 0 1.71 3h16.94a2 2 0 0 0 1.71-3L13.71 3.86a2 2 0 0 0-3.42 0Z"
        />
      </svg>
      <p>{gettext("Please check the fields marked in red.")}</p>
    </div>
    """
  end

  @doc """
  Everything a `live_file_input` upload is currently refusing, as red lines
  under the field: `<.upload_problems upload={@uploads.logo} />`.

  Both levels, because a form that renders only one of them is silent for the
  common half. `upload_errors(@uploads.x)` carries the *config* errors (too
  many files); the error that matters to somebody who just picked a file —
  too large, wrong type — hangs off the **entry** and needs
  `upload_errors(@uploads.x, entry)`. Leaving the entry half out is what made
  the organization logo field accept a file and then quietly drop it, which
  reads as "my format was refused"; the job-posting form rendered neither.

  The sentences come from the upload's own config, so the size in the message
  is the size that rejected the file.
  """
  attr(:upload, :any, required: true, doc: "an `@uploads.<name>` config")

  def upload_problems(assigns) do
    assigns = assign(assigns, :messages, upload_problem_messages(assigns.upload))

    ~H"""
    <p :for={message <- @messages} class="text-xs text-red-600">{message}</p>
    """
  end

  defp upload_problem_messages(upload) do
    entry_errors =
      for entry <- upload.entries, error <- upload_errors(upload, entry), do: error

    (upload_errors(upload) ++ entry_errors)
    |> Enum.uniq()
    |> Enum.map(&upload_problem_message(&1, upload))
  end

  defp upload_problem_message(:too_large, upload) do
    gettext("That file is larger than %{limit}. Please upload a smaller one.",
      limit: megabyte_label(upload.max_file_size)
    )
  end

  defp upload_problem_message(:too_many_files, upload) do
    ngettext(
      "You can upload one file at a time.",
      "You can upload at most %{count} files at a time.",
      upload.max_entries
    )
  end

  defp upload_problem_message(:not_accepted, _upload),
    do: gettext("That file type is not allowed.")

  defp upload_problem_message(_other, _upload), do: gettext("The upload failed.")

  @doc """
  Classic-page (components.css-styled) `editform__field` wrapper shared by the `editform`
  `form_content` templates: the `<div class="editform__field">` that turns
  `editform__field--error` on when `field` has an error, with the label / input /
  hints / error tags supplied verbatim in the inner block. Replaces the
  hand-rolled `class={"editform__field\#{if error_tag(f, :x), do: " …--error"}"}`
  interpolation across ~50 sites; the `--error` class is driven straight off the
  form's `errors` (same condition `error_tag/2` checks), so the DOM is identical.
  Styled by `components.css`. Use as:

      <.editform_field form={f} field={:value}>
        {label f, :value, gettext("URL")}
        {text_input f, :value}
        {error_tag f, :value}
      </.editform_field>
  """
  attr(:form, :any,
    required: true,
    doc: "the Phoenix.HTML form (the `f` from `<.form :let={f}>`)"
  )

  attr(:field, :atom, required: true, doc: "the field whose error toggles the --error class")
  slot(:inner_block, required: true)

  def editform_field(assigns) do
    ~H"""
    <div class={["editform__field", @form.errors[@field] && "editform__field--error"]}>
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc """
  One settings opt-in row shared by the Privacy and Notifications pages: a
  `<label>` holding a checkbox, a bold heading and a muted helper line. The
  checkbox stays in the `:checkbox` slot at the call site (so the inverted
  `checked_value`/`unchecked_value` consent boxes need no special handling here),
  `label` is the heading, and the inner block is the helper text. Replaces the
  ~6 hand-rolled copies of this `flex items-start gap-3` block. Use as:

      <.setting_toggle label={gettext("New followers")}>
        <:checkbox>{checkbox(f, :email_on_follower?, class: checkbox_class())}</:checkbox>
        {gettext("When someone starts following you.")}
      </.setting_toggle>
  """
  attr(:label, :string, required: true, doc: "the bold heading line")
  slot(:checkbox, required: true, doc: "the checkbox input (kept at the call site)")
  slot(:inner_block, required: true, doc: "the muted helper line under the heading")

  def setting_toggle(assigns) do
    ~H"""
    <label class="flex items-start gap-3 text-sm text-slate-600 dark:text-slate-300">
      {render_slot(@checkbox)}
      <span>
        <span class="block font-medium text-slate-900 dark:text-white">{@label}</span>
        <span class="block font-normal">{render_slot(@inner_block)}</span>
      </span>
    </label>
    """
  end

  @doc """
  The new-CV-entry form's "tell my followers about this" checkbox (issue #980),
  shared verbatim by the three CV sections (work experience, education,
  certificates & licenses) so the author reads the same promise everywhere.

  Renders **nothing** when the member has no followers yet — there is nobody to
  tell, and a dead switch on a form is noise. It is deliberately absent from the
  edit forms too: only a brand-new entry announces itself
  (`Vutuv.Profiles.CvSection.cast_announcement/2` enforces that server-side).

  Sits inside a legacy `.editform` page, so it wraps the shared
  `<.setting_toggle>` row in an `.editform__field`.
  """
  attr(:form, :any, required: true, doc: "the section form (`:let={f}`)")
  attr(:followers, :integer, required: true, doc: "how many people follow the author")

  def announce_to_followers_field(assigns) do
    ~H"""
    <div :if={@followers > 0} class="editform__field">
      <.setting_toggle label={
        ngettext(
          "Tell my follower about this",
          "Tell my %{formatted} followers about this",
          @followers,
          formatted: compact_count(@followers)
        )
      }>
        <:checkbox>
          {checkbox(@form, :announce_to_followers?, class: checkbox_class())}
        </:checkbox>
        {gettext(
          "They see one notification linking to this entry. No email is sent, and it only ever happens for a new entry."
        )}
      </.setting_toggle>
    </div>
    """
  end

  @doc """
  A profile section index's body: the owner's drag-and-drop reorder tool
  (`VutuvWeb.SectionReorderLive`, embedded once they have entries) or, for a
  visitor / an empty list, the read-only `card_list` passed as the inner block.
  `section` is the SectionReorderLive key (`"emails"`, `"links"`, …), `slug` the
  owner's username, `editable` whether to show the reorder tool. Folds the
  identical owner-vs-visitor branch the five section index pages repeated.
  """
  attr(:conn, :any, required: true)
  attr(:section, :string, required: true)
  attr(:slug, :string, required: true)
  attr(:editable, :boolean, required: true)
  slot(:inner_block, required: true)

  def reorderable_section(assigns) do
    ~H"""
    <%= if @editable do %>
      {live_render(@conn, VutuvWeb.SectionReorderLive,
        id: "reorder-#{@section}",
        session: %{"section" => @section, "slug" => @slug})}
    <% else %>
      {render_slot(@inner_block)}
    <% end %>
    """
  end

  @doc """
  Classic-page (components.css-styled) Cancel/Submit actions row shared by the `editform`
  `form_content` templates. Emits the same `.editform__actions` markup the
  `link/2` + `submit/2` helpers produced (a `.button.button--cancel` link to
  `@backlink` and a `.button` submit button), styled by `components.css`. Use it
  as `<.form_actions backlink={@backlink} />`. Forms with a custom submit label
  or no Cancel keep their hand-written row.

  Pass `delete_to` on **edit** forms to append the canonical delete control
  (`id="delete-entry"`, a `.button--danger` link sending a CSRF-protected
  DELETE behind a `data-confirm` prompt) — deletion lives on the edit form,
  one deliberate step away from the profile. The shared `form_content`
  templates thread it through as `delete_to={assigns[:delete_to]}` so the
  new-forms render without it.
  """
  attr(:backlink, :string, required: true)
  attr(:delete_to, :any, default: nil)
  attr(:confirm, :string, default: nil)

  attr(:submit, :string,
    default: nil,
    doc: ~S(the primary button's label; defaults to "Save". Never "Submit")
  )

  def form_actions(assigns) do
    ~H"""
    <div class="editform__actions">
      <%!-- Source order is submit → cancel → delete, which is also the
      keyboard order and (via .editform__actions' `order`) the visual one:
      the button you came to press leads, and the destructive one sits at the
      far end of the row. --%>
      <button class="button" type="submit">{@submit || gettext("Save")}</button>
      <a class="button button--cancel" href={@backlink}>{gettext("Cancel")}</a>
      <.link
        :if={@delete_to}
        id="delete-entry"
        href={@delete_to}
        method="delete"
        data-confirm={@confirm || gettext("Are you sure?")}
        class="button button--danger"
      >
        {gettext("Delete entry")}
      </.link>
    </div>
    """
  end

  @doc """
  Classic-page (components.css-styled) edit/delete (and optional view) icon-button group. Renders the
  canonical legacy anatomy from `design.md`: a `.btns-right` wrapper holding
  `.button.button--icon.button--small` controls with CSS-glyph icons
  (`i.icon.icon--edit|--delete|--search`), in **view → edit → delete** source
  order. Delete is rendered through Phoenix's `delete` method (so the
  `phoenix_html` JS issues a CSRF-protected DELETE, the same way the legacy
  `button to:, method: :delete` did) and additionally carries `button--danger`.

  Each control is optional — omit `edit_to`/`delete_to`/`show_to` to skip that
  button. The guard (`same_user?/2`, admin scoping, …) stays at the **call site**;
  this component is purely presentational. Pass `confirm` for a delete
  `data-confirm` prompt, `title_*` for tooltips, `class` for extra wrapper
  classes, and the optional `:extra` slot for a bespoke trailing button.

  Use it as e.g.
  `<.edit_delete_actions edit_to={~p"/…/edit"} delete_to={~p"/…"} confirm={gettext("Are you sure?")} />`.
  """
  attr(:show_to, :string, default: nil)
  attr(:edit_to, :string, default: nil)
  attr(:delete_to, :string, default: nil)
  attr(:confirm, :string, default: nil)
  attr(:title_show, :string, default: nil)
  attr(:title_edit, :string, default: nil)
  attr(:title_delete, :string, default: nil)
  attr(:class, :any, default: nil)
  slot(:extra)

  def edit_delete_actions(assigns) do
    assigns = assign(assigns, :wrapper_class, String.trim("btns-right #{assigns.class}"))

    ~H"""
    <div class={@wrapper_class}>
      <.link :if={@show_to} href={@show_to} title={@title_show} class="button button--icon button--small">
        <i class="icon icon--search"></i>
      </.link>
      <.link :if={@edit_to} href={@edit_to} title={@title_edit} class="button button--icon button--small">
        <i class="icon icon--edit"></i>
      </.link>
      <.link
        :if={@delete_to}
        href={@delete_to}
        method="delete"
        data-confirm={@confirm}
        title={@title_delete}
        class="button button--icon button--small button--danger"
      >
        <i class="icon icon--delete"></i>
      </.link>
      {render_slot(@extra)}
    </div>
    """
  end

  @doc """
  Calm, labeled per-entry actions for the management list/table rows — the
  unified replacement for the loud pencil + red trash-circle icon pair
  (`<.edit_delete_actions>`). Editing/removing an entry now reads the same on
  every management page and matches the calm Direction A surface instead of
  shouting. Renders an "Edit" (brand link) and "Delete" (muted red, CSRF DELETE
  behind a `data-confirm` prompt) text link; omit `edit_to` for delete-only rows
  (tags). Keep the owner guard at the call site. `align` is `:end` (default,
  right-aligned for table-row cells) or `:start` (left-aligned, e.g. under a
  role on the work-experience timeline).
  """
  attr(:edit_to, :string, default: nil)
  attr(:delete_to, :string, default: nil)
  attr(:confirm, :string, default: nil)
  attr(:align, :atom, default: :end)
  attr(:class, :any, default: nil)

  def row_actions(assigns) do
    ~H"""
    <div class={[
      "flex items-center gap-4 text-sm font-semibold",
      @align == :end && "justify-end",
      @class
    ]}>
      <.link :if={@edit_to} href={@edit_to} class="text-brand-600 hover:text-brand-700 dark:text-brand-400 dark:hover:text-brand-300">
        {gettext("Edit")}
      </.link>
      <.link
        :if={@delete_to}
        href={@delete_to}
        method="delete"
        data-confirm={@confirm || gettext("Are you sure?")}
        class="text-red-600 hover:text-red-700 dark:text-red-400 dark:hover:text-red-300"
      >
        {gettext("Delete")}
      </.link>
    </div>
    """
  end

  @doc """
  The quiet card **footer link** — the "View all (N)" / "Manage" / "View all N
  posts" navigation that sits below a card's entries. A centered, muted text
  link (slate → brand on hover) with a hairline top divider and a trailing
  chevron, so it reads as a calm footer subordinate to the prominent dashed
  `<.empty_add>` tile up top. Defining the look once keeps every card *aus einem
  Guss* instead of pairing the styled add tile with a bare brand link. Pass
  `href` and the label as the inner block; guard rendering with `:if` at the call
  site. `<.manage_footer>` wraps it with the owner/visitor label logic.
  """
  attr(:href, :any, required: true)
  attr(:rest, :global)
  slot(:inner_block, required: true)

  def card_footer_link(assigns) do
    ~H"""
    <.link
      href={@href}
      class={[
        "mt-4 flex items-center justify-center gap-1 border-t border-slate-100 pt-3 text-sm font-medium text-slate-500 transition",
        "hover:text-brand-600 dark:border-slate-800 dark:text-slate-400 dark:hover:text-brand-400"
      ]}
      {@rest}
    >
      {render_slot(@inner_block)}
      <svg class="h-4 w-4 shrink-0" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24" aria-hidden="true">
        <path stroke-linecap="round" stroke-linejoin="round" d="m8.25 4.5 7.5 7.5-7.5 7.5" />
      </svg>
    </.link>
    """
  end

  @doc """
  The owner's visible path from a profile section card to its dedicated
  management page, folded together with the public "View all" link — so swapping
  the quiet ⋯ menu for a visible `<.add_action>` does not strand the owner with
  no way to edit or remove existing entries. A `<.card_footer_link>` reading
  "View All (N)" once there are more entries than the profile previews
  (`total > preview`, shown to everyone), otherwise a plain "Manage" shown to the
  owner only when at least one entry exists. Renders nothing for a visitor who
  already sees everything.
  """
  attr(:href, :any, required: true)
  attr(:total, :integer, required: true)
  attr(:preview, :integer, required: true)
  attr(:owner, :boolean, default: false)
  attr(:manage_href, :any, default: nil)

  def manage_footer(assigns) do
    ~H"""
    <.card_footer_link
      :if={@total > @preview or (@owner and @total >= 1)}
      href={if @total > @preview, do: @href, else: @manage_href || @href}
    >
      <%= if @total > @preview do %>
        {gettext("View All")} ({compact_count(@total)})
      <% else %>
        {gettext("Manage")}
      <% end %>
    </.card_footer_link>
    """
  end

  @doc """
  Classic-page (components.css-styled) card shell shared by the owned-resource index pages and the
  new/edit form wrappers: the `<div class="card-list"><section class="card">…</section></div>`
  boilerplate that used to be copy-pasted into ~30 templates, styled by
  `components.css` (not Tailwind — do not swap in utilities). The `inner_block`
  goes inside the `.card`.

  Pass `add_href` for the owner "Add" affordance (a falsy value hides it, so
  `add_href={same_user?(@user, @current_user) && ~p"/…/new"}` reads naturally)
  and `add_label` to override its label. The add now follows the **unified card
  UX**: when the section has content it is the visible `<.add_action>` in a top
  header row (same look and spot as the profile's `<.section_header>`); when the
  section is empty it becomes the prominent dashed `<.empty_add>` tile instead of
  the old bottom `.card__morelink`. Set `empty` to switch to the empty state
  (a dashed add tile when `add_href` is set, otherwise the `<p class="card__empty">`
  line from `empty_text`). Use it as `<.card_section empty={…} add_href={…}>…</.card_section>`.
  """
  attr(:add_href, :any, default: nil)
  attr(:add_label, :string, default: nil)
  attr(:empty, :boolean, default: false)
  attr(:empty_text, :string, default: nil)

  attr(:variant, :atom,
    default: :list,
    values: [:list, :form],
    doc: "`:form` narrows the card to hug a single form instead of the full column"
  )

  slot(:inner_block, required: true)

  def card_section(assigns) do
    ~H"""
    <%!-- A plain string, not a class list: HEEx renders `["card-list", false]`
    as `class="card-list "` with a trailing space, which is both untidy output
    and enough to break an exact-match assertion. --%>
    <div class={if(@variant == :form, do: "card-list card-list--form", else: "card-list")}>
      <section class="card">
        <%= cond do %>
          <% @empty and @add_href -> %>
            <.empty_add href={@add_href}>{@add_label || gettext("Add")}</.empty_add>
          <% @empty -> %>
            <p class="card__empty">{@empty_text || gettext("Nothing here yet.")}</p>
          <% true -> %>
            <.empty_add :if={@add_href} href={@add_href} class="mb-4">
              {@add_label || gettext("Add")}
            </.empty_add>
            {render_slot(@inner_block)}
        <% end %>
      </section>
    </div>
    """
  end

  @doc """
  The cursor-pagination "Load more" control shared by the feed-style LiveViews
  (feed, likes/bookmarks, notifications): a centered secondary button that
  emits the `"load-more"` event. Render it with `:if={@more?}`; the inner block
  overrides the default label (the notifications page shows a remaining count).
  """
  attr(:class, :any, default: nil)
  slot(:inner_block)

  def load_more(assigns) do
    ~H"""
    <div class={["text-center", @class]}>
      <.button id="load-more" variant="secondary" phx-click="load-more" phx-disable-with="…">
        {render_slot(@inner_block) || gettext("Load more")}
      </.button>
    </div>
    """
  end

  @doc """
  The outline repost-arrows icon (24×24 stroke), shared by the post card's
  "Reposted by" line and the action bar. Size it via `class`.
  """
  attr(:class, :any, default: "h-5 w-5")

  def icon_repost(assigns) do
    ~H"""
    <svg class={@class} fill="none" stroke="currentColor" stroke-width="1.8" viewBox="0 0 24 24">
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        d="M19.5 12c0-1.232-.046-2.453-.138-3.662a4.006 4.006 0 0 0-3.7-3.7 48.678 48.678 0 0 0-7.324 0 4.006 4.006 0 0 0-3.7 3.7c-.017.22-.032.441-.046.662M19.5 12l3-3m-3 3-3-3m-12 3c0 1.232.046 2.453.138 3.662a4.006 4.006 0 0 0 3.7 3.7 48.656 48.656 0 0 0 7.324 0 4.006 4.006 0 0 0 3.7-3.7c.017-.22.032-.441.046-.662M4.5 12l3 3m-3-3-3 3"
      />
    </svg>
    """
  end

  @doc """
  The outline reply arrow icon (24×24 stroke), shared by the post card's
  "Replying to" banner and the action bar. Size it via `class`.
  """
  attr(:class, :any, default: "h-5 w-5")

  def icon_reply(assigns) do
    ~H"""
    <svg class={@class} fill="none" stroke="currentColor" stroke-width="1.8" viewBox="0 0 24 24">
      <path stroke-linecap="round" stroke-linejoin="round" d="M9 15 3 9m0 0 6-6M3 9h12a6 6 0 0 1 0 12h-3" />
    </svg>
    """
  end

  @doc """
  The outline bookmark icon (24×24 stroke), shared by the shell's saved-pages
  entry and the action bar; `filled?` switches to the solid fill. Size it via
  `class`.
  """
  attr(:class, :any, default: "h-5 w-5")
  attr(:filled?, :boolean, default: false)

  def icon_bookmark(assigns) do
    ~H"""
    <svg
      class={@class}
      fill={if(@filled?, do: "currentColor", else: "none")}
      stroke="currentColor"
      stroke-width="1.8"
      viewBox="0 0 24 24"
    >
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        d="M17.593 3.322c.1.128.157.288.157.456v16.444a.75.75 0 0 1-1.218.585L12 17.21l-4.532 3.597A.75.75 0 0 1 6.25 20.222V3.778c0-.168.057-.328.157-.456A2.25 2.25 0 0 1 8.25 2.5h7.5a2.25 2.25 0 0 1 1.843.822Z"
      />
    </svg>
    """
  end

  @doc """
  The outline heart icon (24×24 stroke), shared by the post action bar's Like
  toggle and the profile's "like this member" toggle; `filled?` switches to the
  solid fill. Size it via `class`.
  """
  attr(:class, :any, default: "h-5 w-5")
  attr(:filled?, :boolean, default: false)

  def icon_heart(assigns) do
    ~H"""
    <svg
      class={@class}
      fill={if(@filled?, do: "currentColor", else: "none")}
      stroke="currentColor"
      stroke-width="1.8"
      viewBox="0 0 24 24"
    >
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        d="M21 8.25c0-2.485-2.099-4.5-4.688-4.5-1.935 0-3.597 1.126-4.312 2.733-.715-1.607-2.377-2.733-4.313-2.733C5.1 3.75 3 5.765 3 8.25c0 7.22 9 12 9 12s9-4.78 9-12Z"
      />
    </svg>
    """
  end

  @doc """
  Outline glyph (Heroicons, MIT) for a detail row, drawn in `currentColor` so it
  inherits the row's colour. Size/tint it via `class`. It leads each entry of the
  profile's Contact / Phone Numbers / Addresses / General Info sections, and the
  organization page's Fediverse shortcut — which is why it lives in the kit
  rather than in `VutuvWeb.UserHTML`, where it started: a page is not a profile
  and must not import one to draw a globe.
  """
  attr(:name, :string, required: true)
  attr(:class, :any, default: "h-4 w-4")

  def detail_icon(%{name: "map-pin"} = assigns) do
    ~H"""
    <svg class={@class} fill="none" stroke="currentColor" stroke-width="1.8" viewBox="0 0 24 24" aria-hidden="true">
      <path stroke-linecap="round" stroke-linejoin="round" d="M15 10.5a3 3 0 1 1-6 0 3 3 0 0 1 6 0Z" />
      <path stroke-linecap="round" stroke-linejoin="round" d="M19.5 10.5c0 7.142-7.5 11.25-7.5 11.25S4.5 17.642 4.5 10.5a7.5 7.5 0 1 1 15 0Z" />
    </svg>
    """
  end

  # The globe the app already uses for "another network" (the admin dashboard's
  # Fediverse tile), drawn as a circle plus two meridians rather than one path,
  # so it stays crisp at 16px next to the brand glyphs of the Profiles card.
  def detail_icon(%{name: "globe"} = assigns) do
    ~H"""
    <svg class={@class} fill="none" stroke="currentColor" stroke-width="1.8" viewBox="0 0 24 24" aria-hidden="true">
      <circle cx="12" cy="12" r="8.5" />
      <path stroke-linecap="round" d="M3.5 12h17" />
      <path d="M12 3.5c2.3 2.3 3.7 5.3 3.7 8.5s-1.4 6.2-3.7 8.5c-2.3-2.3-3.7-5.3-3.7-8.5S9.7 5.8 12 3.5Z" />
    </svg>
    """
  end

  def detail_icon(assigns) do
    ~H"""
    <svg class={@class} fill="none" stroke="currentColor" stroke-width="1.8" viewBox="0 0 24 24" aria-hidden="true">
      <path stroke-linecap="round" stroke-linejoin="round" d={detail_icon_path(@name)} />
    </svg>
    """
  end

  defp detail_icon_path("user"),
    do:
      "M15.75 6a3.75 3.75 0 1 1-7.5 0 3.75 3.75 0 0 1 7.5 0ZM4.501 20.118a7.5 7.5 0 0 1 14.998 0A17.933 17.933 0 0 1 12 21.75c-2.676 0-5.216-.584-7.499-1.632Z"

  defp detail_icon_path("cake"),
    do:
      "M12 8.25v-1.5m0 1.5c-1.355 0-2.697.056-4.024.166C6.845 8.51 6 9.473 6 10.608v2.513m6-4.871c1.355 0 2.697.056 4.024.166C17.155 8.51 18 9.473 18 10.608v2.513M15 8.25v-1.5m-6 1.5v-1.5m12 9.75-1.5.75a3.354 3.354 0 0 1-3 0 3.354 3.354 0 0 0-3 0 3.354 3.354 0 0 1-3 0 3.354 3.354 0 0 0-3 0 3.354 3.354 0 0 1-3 0L3 16.5m15-3.379a48.474 48.474 0 0 0-6-.371c-2.032 0-4.034.126-6 .371m12 0c.39.049.777.102 1.163.16 1.07.16 1.837 1.094 1.837 2.175v5.169c0 .621-.504 1.125-1.125 1.125H4.125A1.125 1.125 0 0 1 3 20.625v-5.17c0-1.08.768-2.014 1.837-2.174A47.78 47.78 0 0 1 6 13.12"

  defp detail_icon_path("envelope"),
    do:
      "M21.75 6.75v10.5a2.25 2.25 0 0 1-2.25 2.25h-15a2.25 2.25 0 0 1-2.25-2.25V6.75m19.5 0A2.25 2.25 0 0 0 19.5 4.5h-15a2.25 2.25 0 0 0-2.25 2.25m19.5 0v.243a2.25 2.25 0 0 1-1.07 1.916l-7.5 4.615a2.25 2.25 0 0 1-2.36 0L3.32 8.91a2.25 2.25 0 0 1-1.07-1.916V6.75"

  defp detail_icon_path("phone"),
    do:
      "M2.25 6.75c0 8.284 6.716 15 15 15h2.25a2.25 2.25 0 0 0 2.25-2.25v-1.372c0-.516-.351-.966-.852-1.091l-4.423-1.106c-.44-.11-.902.055-1.173.417l-.97 1.293c-.282.376-.769.542-1.21.38a12.035 12.035 0 0 1-7.143-7.143c-.162-.441.004-.928.38-1.21l1.293-.97c.363-.271.527-.734.417-1.173L6.963 3.102a1.125 1.125 0 0 0-1.091-.852H4.5A2.25 2.25 0 0 0 2.25 4.5v2.25Z"

  defp detail_icon_path("lock"),
    do:
      "M16.5 10.5V6.75a4.5 4.5 0 1 0-9 0v3.75m-.75 11.25h10.5a2.25 2.25 0 0 0 2.25-2.25v-6.75a2.25 2.25 0 0 0-2.25-2.25H6.75a2.25 2.25 0 0 0-2.25 2.25v6.75a2.25 2.25 0 0 0 2.25 2.25Z"

  @doc """
  The grouped settings menu: the **one map** of everything a member can change
  about themselves, shared by the settings hub (`/settings`) and the desktop
  sidebar (`<.settings_sidebar>`). If a new editable area is added to the app,
  it joins this menu — if it is not on the hub, it does not exist.

  Returns `{group_label, [row]}`, where each row is a map:

    * `:key` — names the page for the sidebar's active state and the hub's
      per-section entry counts. Unique across the whole menu.
    * `:label` / `:path` — what the row reads and where it goes.
    * `:hint` — the one line under the label saying what is inside, so
      "Sign-in & security" no longer has to be guessed at from its name.
    * `:terms` — extra words the hub's search box matches on, for everything a
      member might call this that the label does not say ("Passwort",
      "Handle", "abmelden"). Never rendered as text.
    * `:danger` — the one red row (delete account).

  **The grouping is the point.** It used to be three groups of 12/5/8 whose
  last one was called "More" and held Privacy and Notifications — two of the
  three things members actually come here for — behind seventeen other rows.
  Each group now names its own subject, holds at most eight rows, and the two
  areas people hunt for stand on their own. Rows that used to appear only once
  a member had used the feature (followed tags, saved searches) are always
  listed: a menu that changes shape between visits cannot be learned, and a
  hidden row is unfindable by definition.

  Takes the member because two rows are member-specific: the Username row
  shows the handle itself, and the Export row leaves the user-agnostic
  /settings world (the GDPR download + the issue #841 CV live under the
  profile at `/:slug/export`).
  """
  def settings_menu(user) do
    [
      {gettext("Profile"),
       [
         row(:basics, gettext("Basics & photos"), ~p"/settings/profile",
           hint: gettext("Name, photo, cover picture, tagline"),
           terms: gettext("avatar portrait picture image birthday gender about me")
         ),
         row(:username, gettext("Username"), ~p"/settings/username",
           hint: "@" <> to_string(user.username),
           terms: gettext("handle nickname rename slug profile address url mention")
         ),
         row(:work, gettext("Experience"), ~p"/settings/work_experiences",
           hint: gettext("The jobs and roles on your CV"),
           terms: gettext("cv resume career employer position title company")
         ),
         row(:education, gettext("Education"), ~p"/settings/educations",
           hint: gettext("Schools, universities, degrees"),
           terms: gettext("cv resume study studies school university degree")
         ),
         row(:qualifications, gettext("Certificates & licenses"), ~p"/settings/qualifications",
           hint: gettext("Credentials, with proof documents"),
           terms: gettext("certificate licence diploma credential award proof document")
         ),
         row(:job_references, gettext("Employment references"), ~p"/settings/job_references",
           hint: gettext("Your Arbeitszeugnisse, private unless you publish them"),
           terms:
             gettext("arbeitszeugnis reference letter testimonial employer evaluation review")
         ),
         row(:languages, gettext("Language skills"), ~p"/settings/languages",
           hint: gettext("The languages you speak"),
           terms: gettext("language speak spoken fluent native mother tongue")
         ),
         row(:tags, gettext("Tags"), ~p"/settings/tags",
           hint: gettext("The topics you are known for"),
           terms: gettext("skill topic keyword expertise endorsement")
         )
       ]},
      {gettext("Contact details"),
       [
         row(:emails, gettext("Email addresses"), ~p"/settings/emails",
           hint: gettext("Where we reach you, and which address is public"),
           terms: gettext("mail e-mail address primary")
         ),
         row(:phones, gettext("Phone numbers"), ~p"/settings/phone_numbers",
           hint: gettext("Landline, mobile, fax"),
           terms: gettext("telephone mobile cell fax number")
         ),
         row(:addresses, gettext("Addresses"), ~p"/settings/addresses",
           hint: gettext("Postal addresses on your profile"),
           terms: gettext("street city postcode zip country post map")
         ),
         row(:links, gettext("Websites & links"), ~p"/settings/links",
           hint: gettext("Your homepage and other links"),
           terms: gettext("url website homepage blog link verify rel=me")
         ),
         row(:social, gettext("Social media profiles"), ~p"/settings/social_media_accounts",
           hint: gettext("Mastodon, Bluesky, GitHub and the rest"),
           terms:
             gettext(
               "mastodon bluesky github gitlab codeberg linkedin x twitter instagram social"
             )
         ),
         row(:messengers, gettext("Messengers"), ~p"/settings/messengers",
           hint: gettext("Signal, Threema, Matrix and the rest"),
           terms: gettext("signal threema matrix xmpp telegram whatsapp chat messenger")
         )
       ]},
      {gettext("Notifications & feed"),
       [
         row(:notifications, gettext("Notifications"), ~p"/settings/notifications",
           hint: gettext("Which emails we send, and what the bell tells you"),
           terms:
             gettext(
               "email mail unsubscribe newsletter bell alert quiet fewer browser desktop popup push benachrichtigung"
             )
         ),
         row(:filters, gettext("Muted words & tags"), ~p"/settings/filters",
           hint: gettext("Keep posts out of your feed"),
           terms: gettext("mute block hide filter keyword word tag feed")
         ),
         # Its own row rather than a card on "Language & display" (issue
         # #1672): that page is where the *interface* language is changed, a
         # different question sharing a word, and somebody whose feed is full
         # of a language they cannot read looks here.
         row(:feed_languages, gettext("Feed languages"), ~p"/settings/feed_languages",
           hint: gettext("Which languages reach you, and what happens to the rest"),
           terms:
             gettext(
               "language translate translation german english original hide foreign rank order sprache übersetzen fremdsprache reihenfolge"
             )
         ),
         row(:followed_tags, gettext("Tags you follow"), ~p"/settings/followed_tags",
           hint: gettext("Topics whose posts reach your feed"),
           terms: gettext("tag topic subscribe follow feed")
         ),
         # Under "feed" rather than beside Import: that page fills your profile
         # from a LinkedIn archive, this one fills your feed from it, and this
         # is the group a member reads when their feed is too quiet.
         row(
           :import_connections,
           gettext("Find your contacts"),
           ~p"/settings/import/linkedin/connections",
           hint: gettext("See which of your LinkedIn contacts are already on vutuv"),
           terms:
             gettext(
               "linkedin contacts connections address book find people know colleagues follow zip kontakte bekannte kollegen finden"
             )
         ),
         row(:saved_searches, gettext("Saved searches"), ~p"/settings/saved_searches",
           hint: gettext("Job and people searches that email you new matches"),
           terms: gettext("job alert search agent watchlist")
         )
       ]},
      {gettext("Privacy"),
       [
         row(:privacy, gettext("Visibility"), ~p"/settings/privacy",
           hint: gettext("Search engines, AI, online status"),
           terms: gettext("privacy google search engine ai llm crawler noindex online dot public")
         ),
         row(:blocks, gettext("Blocked members"), ~p"/blocks",
           hint: gettext("People who cannot interact with you"),
           terms: gettext("block ban mute report abuse harassment stalker")
         ),
         row(
           :auto_post_deletion,
           gettext("Automatic post deletion"),
           ~p"/settings/auto_post_deletion",
           hint: gettext("Let your posts age out after a time you set"),
           terms:
             gettext("delete remove erase posts age old expire automatic cleanup retention purge")
         ),
         row(:fediverse, gettext("Fediverse"), ~p"/settings/fediverse",
           hint: gettext("Follow accounts on Mastodon, and be followed from there"),
           terms:
             gettext(
               "mastodon activitypub federation follower following follow move migrate remote account"
             )
         )
       ]},
      {gettext("Account"),
       [
         row(:security, gettext("Sign-in & security"), ~p"/settings/security",
           hint: gettext("Passkeys, signed-in devices, login codes"),
           terms: gettext("password login sign in log out session device passkey totp 2fa pin")
         ),
         row(:activity, gettext("Account activity"), ~p"/settings/activity",
           hint: gettext("What changed on your account, and when"),
           terms:
             gettext("log history audit trail security was that me who changed when protocol")
         ),
         row(:preferences, gettext("Language & display"), ~p"/settings/preferences",
           hint:
             gettext(
               "Interface language, date format and time zone, maps, how posts are shortened"
             ),
           terms:
             gettext(
               "german english locale map font length hyphenation übersetzen sprache zeitzone timezone time zone utc datum date uhrzeit clock 24 hour datumsformat"
             )
         ),
         row(:import, gettext("Import"), ~p"/settings/import/linkedin",
           hint: gettext("Take your data over from LinkedIn"),
           terms: gettext("linkedin upload zip migrate transfer")
         ),
         row(:export, gettext("Export"), ~p"/#{user}/export",
           hint: gettext("Download everything we store about you"),
           terms: gettext("download gdpr dsgvo data backup json cv")
         ),
         row(:organizations, gettext("Organizations"), ~p"/settings/organizations",
           hint: gettext("Company pages you run"),
           terms: gettext("company employer firm business organisation page")
         ),
         row(:apps, gettext("Apps & API"), ~p"/settings/apps",
           hint: gettext("Mastodon apps, connected apps and access tokens"),
           terms:
             gettext(
               "api token oauth developer connected third party mastodon app phone client ivory tusky ice cubes sign in"
             )
         ),
         row(:delete, gettext("Delete account"), ~p"/settings/delete",
           hint: gettext("Remove your account and everything on it"),
           terms: gettext("delete remove close quit cancel leave erase"),
           danger: true
         )
       ]}
    ]
  end

  defp row(key, label, path, opts) do
    %{
      key: key,
      label: label,
      path: path,
      hint: Keyword.fetch!(opts, :hint),
      terms: Keyword.fetch!(opts, :terms),
      danger: Keyword.get(opts, :danger, false)
    }
  end

  @doc """
  The one lower-cased haystack the hub's search box matches a row against:
  its label, its hint and its `:terms` synonyms. Public so a test can pin the
  exact string the template renders into `data-search`.
  """
  def settings_search_text(%{label: label, hint: hint, terms: terms}),
    do: String.downcase("#{label} #{hint} #{terms}")

  @doc """
  One tappable row on the settings hub (and the profile editor's mobile
  "More profile sections" card): the whole row is the link (mobile-first tap
  target), the label over its hint line, with an optional entry count and a
  trailing chevron.

  Takes a whole `settings_menu/1` row, so the label, hint, search terms and
  the red delete treatment can never drift from the menu they came from. The
  count is wrapped in a bare `data-hub-count` span so tests can pin it, and
  formatted through `compact_count/1` like every rendered number.

  `data-settings-row` + `data-search` are what the hub's filter box reads; the
  `<li>` deliberately carries **no** display utility, so the filter can hide it
  with the plain `hidden` attribute instead of a class that a later-emitted
  Tailwind display utility would silently beat.
  """
  attr(:entry, :map, required: true, doc: "one row of settings_menu/1")
  attr(:count, :integer, default: nil)
  attr(:hint?, :boolean, default: true, doc: "false drops the hint line (the compact list)")

  def hub_row(assigns) do
    ~H"""
    <li data-settings-row data-search={settings_search_text(@entry)}>
      <.link
        navigate={@entry.path}
        class="flex items-center justify-between gap-4 px-4 py-3 hover:bg-slate-50 sm:px-5 dark:hover:bg-slate-800/60"
      >
        <span class="min-w-0">
          <span class={[
            "block font-medium",
            if(@entry.danger,
              do: "text-red-600 dark:text-red-400",
              else: "text-slate-900 dark:text-white"
            )
          ]}>
            {@entry.label}
          </span>
          <span
            :if={@hint? and @entry.hint != ""}
            class="mt-0.5 block text-sm text-slate-600 dark:text-slate-400"
          >
            {@entry.hint}
          </span>
        </span>
        <span class="flex shrink-0 items-center gap-3">
          <span :if={not is_nil(@count)} class="text-sm text-slate-600 dark:text-slate-400">
            <span data-hub-count={@entry.key}>{compact_count(@count)}</span>
          </span>
          <span aria-hidden="true" class="text-slate-600 dark:text-slate-400">›</span>
        </span>
      </.link>
    </li>
    """
  end

  @doc """
  The desktop settings sidebar (md and up): the full `settings_menu/1` as a
  persistent left navigation, so on a large screen you always see where you
  are. On phones the hub page plays this role instead. The "Delete account"
  entry is the one red link (danger, like its page).
  """
  attr(:user, Vutuv.Accounts.User, required: true)
  attr(:active, :atom, default: nil)
  attr(:class, :any, default: nil)

  def settings_sidebar(assigns) do
    assigns = assign(assigns, :groups, settings_menu(assigns.user))

    ~H"""
    <nav data-settings-sidebar aria-label={gettext("Settings")} class={["text-sm", @class]}>
      <.link
        navigate={~p"/settings"}
        class="block rounded-lg px-2 py-1.5 text-base font-bold text-slate-900 hover:text-brand-700 dark:text-white dark:hover:text-brand-300"
      >
        {gettext("Settings")}
      </.link>
      <div :for={{group, entries} <- @groups} class="mt-4">
        <p class="px-2 text-[11px] font-semibold uppercase tracking-wide text-slate-500 dark:text-slate-400">
          {group}
        </p>
        <ul class="mt-1 space-y-0.5">
          <li :for={entry <- entries}>
            <.link
              navigate={entry.path}
              aria-current={@active == entry.key && "page"}
              class={[
                "block rounded-lg px-2 py-1.5",
                sidebar_link_class(entry.key, @active)
              ]}
            >
              {entry.label}
            </.link>
          </li>
        </ul>
      </div>
    </nav>
    """
  end

  defp sidebar_link_class(:delete, _active),
    do:
      "text-red-600 hover:bg-red-50 hover:text-red-700 dark:text-red-400 dark:hover:bg-red-900/30"

  defp sidebar_link_class(key, key),
    do: "bg-brand-50 font-semibold text-brand-800 dark:bg-brand-900/40 dark:text-brand-100"

  defp sidebar_link_class(_key, _active),
    do:
      "text-slate-600 hover:bg-slate-100 hover:text-slate-900 dark:text-slate-400 dark:hover:bg-slate-800 dark:hover:text-slate-200"

  @doc """
  The shared settings shell: every page in the user-agnostic /settings scope —
  the hub's subpages and the section editors (manage.html) — renders inside
  it, so the whole editing surface has **one** navigation pattern. On phones:
  a "back to Settings" link above the page title. On md+: the persistent
  `<.settings_sidebar>` beside the content. Both carry a quiet "View profile"
  link, so wherever you came from, the hub and your profile are one tap away.
  The public /:slug section pages never render it — they use the classic
  `<.page_header>` with the owner's `manage_to` bridge instead.
  """
  attr(:user, Vutuv.Accounts.User, required: true)
  attr(:title, :string, required: true)
  attr(:active, :atom, default: nil)

  attr(:crumbs, :list,
    default: nil,
    doc: """
    Overrides the default two-level "Settings / <title>" trail. The new/edit
    form pages pass three levels ("Settings / Links / New") so the section
    they belong to stays one tap away while you fill the form in.
    """
  )

  slot(:inner_block, required: true)

  def settings_shell(assigns) do
    ~H"""
    <div data-settings-shell class="py-6 md:grid md:grid-cols-[13rem_minmax(0,1fr)] md:gap-8">
      <.settings_sidebar
        user={@user}
        active={@active}
        class="hidden self-start md:sticky md:top-20 md:block"
      />
      <div class="min-w-0">
        <div class="mb-4">
          <%!-- "Einstellungen / <page>" trail — the same classic .breadcrumbs
          rendering the new/edit forms show, so orientation and the way back
          read identically across the whole settings area (it replaced the
          mobile-only "‹ Settings" back link and shows at every width). mx-0
          overrides the class's centered 48rem measure so the trail
          left-aligns with the h1. --%>
          <div class="breadcrumbs mx-0">
            {VutuvWeb.UserHelpers.gen_breadcrumbs(
              @crumbs || [{gettext("Settings"), ~p"/settings"}, @title]
            )}
          </div>
          <div class="mt-1 flex flex-wrap items-baseline justify-between gap-x-4 gap-y-1">
            <h1 class="text-2xl font-bold text-slate-900 dark:text-white">{@title}</h1>
            <.link
              navigate={~p"/#{@user}"}
              class="text-sm font-medium text-slate-600 hover:text-brand-700 dark:text-slate-400 dark:hover:text-brand-300"
            >
              {gettext("View profile")} ›
            </.link>
          </div>
        </div>
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  @doc """
  The page chrome every classic `.editform` new/edit form under /settings
  wears: the `<.settings_shell>` (sidebar, visible h1, breadcrumb trail back
  to the section) around the form's own card.

  Before this existed each of those pages rendered `<.page_header crumbs=…>`
  plus a bare `<.card_section>`, which meant that the moment you pressed "Add"
  you fell out of the settings area entirely — the sidebar vanished, and the
  only heading was an `sr-only` h1 reading "New". So the pages carrying most
  of a member's data entry were the least finished ones in the app, while
  their siblings (Privacy, Language & display) had a proper shell. One
  component now owns that chrome for all of them.

  `title` names the task ("Add work experience"), not the step ("New").
  `section` is the `{label, path}` of the list the form belongs to, which
  supplies both the middle breadcrumb and the sidebar's active entry.

  Use it as:

      <.form_page
        user={@user}
        active={:links}
        section={{gettext("Links"), ~p"/settings/links"}}
        title={gettext("Add a link")}
      >
        <%= render "form_content.html", … %>
      </.form_page>
  """
  attr(:user, Vutuv.Accounts.User, required: true)
  attr(:title, :string, required: true, doc: "the visible h1: what this form does")
  attr(:active, :atom, default: nil, doc: "the settings_menu key to mark in the sidebar")

  attr(:section, :any,
    required: true,
    doc: ~S(`{label, path}` of the section list this form belongs to)
  )

  slot(:inner_block, required: true)

  def form_page(assigns) do
    ~H"""
    <.settings_shell
      user={@user}
      active={@active}
      title={@title}
      crumbs={[{gettext("Settings"), ~p"/settings"}, @section, @title]}
    >
      <.card_section variant={:form}>{render_slot(@inner_block)}</.card_section>
    </.settings_shell>
    """
  end
end
