defmodule VutuvWeb.PageHTML do
  @moduledoc false
  use VutuvWeb, :html

  # The sign-up form's email-type radios: the values and their order come from
  # the schema, the labels from the same helper the email pages use, so all
  # three renderings of Personal/Work/Other stay in step.
  import VutuvWeb.EmailHTML, only: [email_type_label: 1]
  # The sign-up form's gender radios share their options with the profile
  # editor, so neither surface can offer a value the changeset would reject.
  import VutuvWeb.UserHelpers, only: [gender_options: 0]
  alias Vutuv.Accounts.Email
  alias Vutuv.Fediverse
  alias Vutuv.SourceRepo
  alias VutuvWeb.Feeds

  embed_templates("../templates/page/*")

  @doc """
  The founder quote at the top of the logged-out landing page, in the variant
  this visitor was assigned (`Vutuv.Experiments`).

  Both are one short question plus an answer, so the hero's typography holds
  either. An unknown key falls back to the default variant, which is what an
  installation with the split test switched off always renders.
  """
  def founder_quote("knapp") do
    gettext("“LinkedIn is annoying. vutuv is not.”")
  end

  def founder_quote(_stube) do
    gettext("“Tired of LinkedIn? Then come on in and make yourself at home.”")
  end

  @doc """
  The three claims under the founder quote, inside the hero panel.

  Each is a short claim, and each may carry the reason it is not filler. Both
  halves are their own `gettext` call: the claim is set in white and the reason
  in `brand-100`, so a translator gets two whole sentences rather than one
  sentence cut in half. Two of the three are properties of the software and hold
  on every installation; the import is a feature of this codebase, so all three
  survive a third-party install without the operator having to promise anything.

  **The reason is optional, and "Fast." is the one that has none.** A reason
  that only restates its claim ("Fast." — "vutuv is ridiculously fast.") is the
  filler the other two avoid, and the empty `msgstr` that would seem to remove
  it is a trap: gettext reads an empty translation as *untranslated* and falls
  back to the msgid, so blanking it in the catalog would have put the English
  sentence on the German page. A claim with no reason therefore drops the whole
  span rather than rendering an empty one.

  Deliberately not links. `/import/linkedin` needs an account, so a logged-out
  click would trade the sign-up form beside them for a login screen.
  """
  def hero_points(assigns) do
    assigns = assign(assigns, :points, hero_point_list())

    ~H"""
    <ul data-hero-points class="mt-8 space-y-2.5">
      <li :for={{claim, reason} <- @points} class="flex gap-2.5 text-sm leading-snug">
        <span aria-hidden="true" class="shrink-0 font-bold text-brand-200">✓</span>
        <span>
          <span class="font-semibold text-white">{claim}</span>
          <span :if={reason} class="text-brand-100">{reason}</span>
        </span>
      </li>
    </ul>
    """
  end

  defp hero_point_list do
    [
      {gettext("Easy profile import."), gettext("Your LinkedIn profile can come along.")},
      {gettext("Fast."), nil},
      {gettext("No paid premium accounts."), gettext("Nobody wants those anyway.")}
    ]
  end

  @doc """
  The heading block both sections under the sign-up form wear: a small
  uppercase eyebrow, the heading itself and an optional lead sentence.

  Written once because the sections differ only in their words, and a landing
  page where the second heading sits two pixels off the first reads as
  unfinished.
  """
  attr(:eyebrow, :string, required: true)
  attr(:title, :string, required: true)
  attr(:lead, :string, default: nil)

  def landing_heading(assigns) do
    ~H"""
    <.section_title>{@eyebrow}</.section_title>
    <h2 class="mt-1 text-2xl font-bold text-slate-900 md:text-3xl dark:text-white">
      {@title}
    </h2>
    <p :if={@lead} class="mt-3 max-w-2xl text-base leading-relaxed text-slate-600 dark:text-slate-400">
      {@lead}
    </p>
    """
  end

  @doc """
  The example profile the page offers as "try it out", or `nil` where the
  installation dropped it (`:landing_example_profile_url` set to "").

  A full URL rather than a local path: the default points at the reference
  installation, which is the useful answer on an installation that has no
  filled-in profile of its own yet, and a local path would be a dead link there.

  The trailing slash a configured URL may carry comes off here, once: the
  format chips append `.md` and friends to this, and `example_profile_label/1`
  strips the slash for the visible text, so a join at a call site once rendered
  `…/wintermeyer//cv` under a label reading `…/wintermeyer/cv`.
  """
  def example_profile_url do
    case Application.get_env(:vutuv, :landing_example_profile_url) do
      url when is_binary(url) ->
        case url |> String.trim() |> String.trim_trailing("/") do
          "" -> nil
          base -> base
        end

      _other ->
        nil
    end
  end

  @doc """
  The text-link recipe every link below the sign-up form wears (the design
  rule's "Text link" pair, dark half included). Named once here so the
  template and `try_it_out/1` cannot drift apart; a `<% %>` binding in the
  template would be out of reach of a component rendering into the same page.
  """
  def link_class do
    "font-semibold text-brand-600 hover:text-brand-700 dark:text-brand-400 dark:hover:text-brand-300"
  end

  @doc """
  How that URL reads on the page: without the scheme, which is noise in running
  text and the one part nobody types any more.
  """
  def example_profile_label(url) do
    url |> String.replace(~r{^https?://}, "") |> String.trim_trailing("/")
  end

  @doc """
  The "Curious?" line under the first heading, or nothing where the
  installation cleared the example profile.

  Two sentences, picked by whose profile the link opens. Where it is the
  founder's (the shipped default), the line says so by name, because a real
  person behind the invitation is the point of it (Stefan, 2026-09-06); where
  an operator pointed it at somebody else, the same invitation without the
  name, so a third-party installation never introduces its own member as the
  founder of vutuv. The link is the marker in a whole sentence rather than a
  label glued to a URL, so German and English can each put it where their
  grammar wants it; `split_marker/2` never raises on a translation that lost
  the marker.
  """
  def try_it_out(assigns) do
    url = example_profile_url()

    sentence =
      if founder_profile?(url),
        do:
          gettext(
            "Curious? Have a look at the profile of vutuv founder Stefan Wintermeyer: {profile}. With or without a vutuv account of your own."
          ),
        else:
          gettext(
            "Curious? Have a look at a real profile: {profile}. With or without a vutuv account of your own."
          )

    {pre, post} = split_marker(sentence, "{profile}")
    assigns = assign(assigns, url: url, pre: pre, post: post)

    ~H"""
    <p :if={@url} class="mt-3 max-w-2xl text-base text-slate-600 dark:text-slate-400">
      {@pre}<a href={@url} class={link_class()}>{example_profile_label(@url)}</a>{@post}
    </p>
    """
  end

  # Whether the configured example profile is the founder's own, i.e. the
  # shipped default. Matched on the profile address rather than on "is this
  # vutuv.de", because it decides a sentence about a person, not about a host.
  defp founder_profile?(url) when is_binary(url) do
    String.ends_with?(url, "vutuv.de/wintermeyer")
  end

  defp founder_profile?(_), do: false

  @doc """
  Where this installation's data lives, or `nil` where the operator cleared it.

  Only the *place* is configurable, and that is the point: "no third-party
  cookies" and "delete your account yourself" are promises the software keeps
  on every installation, while "our own servers in X" is a promise only the
  operator can make. An operator on rented cloud infrastructure
  clears this and the whole hosting sentence goes with it, rather than the start
  page claiming something untrue on their behalf.
  """
  def data_location do
    case Application.get_env(:vutuv, :data_location) do
      place when is_binary(place) ->
        if String.trim(place) == "", do: nil, else: String.trim(place)

      _other ->
        nil
    end
  end

  @doc """
  The agent-format chips: live links to the machine-readable siblings of one
  real profile.

  Anchored on the same profile the "try it out" link points at
  (`:landing_example_profile_url`), so the claim above them can be checked
  against a page with somebody's actual CV in it rather than against an
  abstraction — and so one setting moves both. Where an installation cleared
  that setting only `/llms.txt` is left, which is installation-wide and always
  there.

  The URL is absolute and the extensions are appended to it, the way
  `<.other_formats_card>` appends to its `base_path`: a verified route cannot
  carry an extension after an interpolated segment, and the example profile may
  well live on another installation anyway.
  """
  def landing_format_chips(assigns) do
    assigns = assign(assigns, :base, example_profile_url())

    ~H"""
    <.chip :if={@base} href={@base <> ".md"}>Markdown</.chip>
    <.chip :if={@base} href={@base <> ".txt"}>Text</.chip>
    <.chip :if={@base} href={@base <> ".json"}>JSON</.chip>
    <.chip :if={@base} href={@base <> ".xml"}>XML</.chip>
    <.chip :if={@base} href={@base <> ".vcf"}>vCard</.chip>
    <.chip :if={@base} href={@base <> Feeds.user_feed_suffix()}>RSS</.chip>
    <.chip href={~p"/llms.txt"}>llms.txt</.chip>
    """
  end

  @doc """
  One of the six promises under the sign-up form: a tile with a pictogram, a
  title and a sentence or two, and not a technical word in it.

  The tiles are a bento, not a grid of equals (Stefan picked that shape from
  seven on 2026-09-06): the organization promise gets the width its three
  steps need, the data promise a dark tile the eye lands on, the speed promise
  a coral corner, the rest plain cards. `tone` picks the surface and `class`
  the place in the six-column grid; the words live in the template and this
  only holds the frame. Hand-written card frames rather than `<.card>`, whose
  own `bg-white` a tinted tile could not override. `key` names the tile for
  the tests, which assert all six by name.
  """
  attr(:key, :string, required: true)
  attr(:title, :string, required: true)
  attr(:icon, :atom, required: true, values: [:users, :shield, :bolt, :cursor, :door, :server])
  attr(:tone, :atom, default: :card, values: [:card, :tint, :dark, :accent])
  attr(:class, :string, default: nil)
  slot(:inner_block, required: true)

  def promise(assigns) do
    ~H"""
    <section data-landing-promise={@key} class={[tile_class(@tone), @class]}>
      <div :if={@tone == :accent} aria-hidden="true" class="pointer-events-none absolute -right-8 -top-8 h-28 w-28 rounded-full bg-accent/20"></div>
      <div class="flex items-center gap-3">
        <span data-promise-icon class={disc_class(@tone)}><.promise_icon name={@icon} /></span>
        <h3 class={["text-lg font-bold", title_class(@tone)]}>{@title}</h3>
      </div>
      <div class={["mt-2 text-sm leading-relaxed", body_class(@tone)]}>
        {render_slot(@inner_block)}
      </div>
    </section>
    """
  end

  defp tile_class(:card),
    do:
      "rounded-2xl bg-white p-6 shadow-sm ring-1 ring-slate-200 dark:bg-slate-900 dark:ring-slate-800"

  defp tile_class(:tint), do: "rounded-2xl bg-brand-50 p-6 dark:bg-brand-900/40"

  defp tile_class(:dark),
    do: "flex flex-col rounded-2xl bg-brand-900 p-6 text-white dark:bg-brand-800"

  defp tile_class(:accent), do: "relative overflow-hidden " <> tile_class(:card)

  defp disc_class(tone) do
    [
      "inline-flex h-9 w-9 shrink-0 items-center justify-center rounded-lg",
      case tone do
        :dark -> "bg-white/15 text-white"
        :accent -> "bg-accent/15 text-accent-dark"
        _ -> "bg-brand-100 text-brand-700 dark:bg-brand-900/60 dark:text-brand-200"
      end
    ]
  end

  defp title_class(:dark), do: "text-white"
  defp title_class(:tint), do: "text-brand-800 dark:text-brand-100"
  defp title_class(_), do: "text-slate-900 dark:text-white"

  # The dark tile is a flex column so its place line can sit at the bottom
  # (`mt-auto` needs a flex parent); the legacy `p { margin-bottom }` is
  # zeroed there because flex items do not collapse it into the gap.
  defp body_class(:dark), do: "flex flex-1 flex-col gap-2 text-brand-100 [&>p]:mb-0"
  defp body_class(_), do: "space-y-2 text-slate-700 dark:text-slate-300"

  @doc """
  The pictogram of a promise tile: heroicons outline, drawn inline so the
  page ships no sprite for six glyphs.
  """
  attr(:name, :atom, required: true)

  def promise_icon(assigns) do
    ~H"""
    <svg class="h-5 w-5" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
      <path d={icon_path(@name)} />
    </svg>
    """
  end

  defp icon_path(:users),
    do:
      "M15 19.128a9.38 9.38 0 0 0 2.625.372 9.337 9.337 0 0 0 4.121-.952 4.125 4.125 0 0 0-7.533-2.493M15 19.128v-.003c0-1.113-.285-2.16-.786-3.07M15 19.128v.106A12.318 12.318 0 0 1 8.624 21c-2.331 0-4.512-.645-6.374-1.766l-.001-.109a6.375 6.375 0 0 1 11.964-3.07M12 6.375a3.375 3.375 0 1 1-6.75 0 3.375 3.375 0 0 1 6.75 0Zm8.25 2.25a2.625 2.625 0 1 1-5.25 0 2.625 2.625 0 0 1 5.25 0Z"

  defp icon_path(:shield),
    do:
      "M9 12.75 11.25 15 15 9.75m-3-7.036A11.959 11.959 0 0 1 3.598 6 11.99 11.99 0 0 0 3 9.749c0 5.592 3.824 10.29 9 11.623 5.176-1.332 9-6.03 9-11.622 0-1.31-.21-2.571-.598-3.751h-.152c-3.196 0-6.1-1.248-8.25-3.285Z"

  defp icon_path(:bolt), do: "m3.75 13.5 10.5-11.25L12 10.5h8.25L9.75 21.75 12 13.5H3.75Z"

  defp icon_path(:cursor),
    do:
      "M15.042 21.672 13.684 16.6m0 0-2.51 2.225.569-9.47 5.227 7.917-3.286-.672Zm-7.518-.267A8.25 8.25 0 1 1 20.25 10.5M8.288 14.212A5.25 5.25 0 1 1 17.25 10.5"

  defp icon_path(:door),
    do:
      "M15.75 9V5.25A2.25 2.25 0 0 0 13.5 3h-6a2.25 2.25 0 0 0-2.25 2.25v13.5A2.25 2.25 0 0 0 7.5 21h6a2.25 2.25 0 0 0 2.25-2.25V15m3 0 3-3m0 0-3-3m3 3H9"

  defp icon_path(:server),
    do:
      "M5.25 14.25h13.5m-13.5 0a3 3 0 0 1-3-3m3 3a3 3 0 1 0 0 6h13.5a3 3 0 1 0 0-6m-16.5-3a3 3 0 0 1 3-3h13.5a3 3 0 0 1 3 3m-19.5 0a4.5 4.5 0 0 1 .9-2.7L5.737 5.1a3.375 3.375 0 0 1 2.7-1.35h7.126c1.062 0 2.062.5 2.7 1.35l2.587 3.45a4.5 4.5 0 0 1 .9 2.7m0 0a3 3 0 0 1-3 3m0 3h.008v.008h-.008v-.008Zm0-6h.008v.008h-.008v-.008Zm-3 6h.008v.008h-.008v-.008Zm0-6h.008v.008h-.008v-.008Z"

  @doc """
  One line of the technical section: the claim in bold, then the sentence or
  two behind it and whatever links let the reader check.
  """
  attr(:title, :string, required: true)
  slot(:inner_block, required: true)

  def technical_line(assigns) do
    ~H"""
    <li class="text-sm leading-relaxed text-slate-700 dark:text-slate-300">
      <span class="font-semibold text-slate-900 dark:text-white">{@title}</span>
      {render_slot(@inner_block)}
    </li>
    """
  end
end
