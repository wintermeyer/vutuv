defmodule VutuvWeb.PageHTML do
  @moduledoc false
  use VutuvWeb, :html

  # The sign-up form's own imports left with it: it is three steps now and
  # lives in `VutuvWeb.RegistrationLive`, which the landing template embeds.
  alias Vutuv.Fediverse
  alias Vutuv.SourceRepo
  alias VutuvWeb.Teaser
  alias VutuvWeb.VideoComponents

  embed_templates("../templates/page/*")

  @doc """
  The founder quote at the top of the logged-out landing page.

  One sentence about LinkedIn, one about us. It won a split test against a
  warmer, wordier invitation, and on 2026-09-07 the rotation came out with the
  loser, so the page says one thing to everybody now.
  """
  def founder_quote do
    gettext("“LinkedIn is annoying. vutuv is not.”")
  end

  @doc """
  The founder quote as the hero heading's text, with every short sentence kept
  on one line.

  On a phone the German quote broke between "vutuv" and "nicht", which read as
  two fragments. How many words a sentence has depends on the catalog, so the
  rule reads the translation instead of naming a locale: a sentence of at most
  two words is wrapped in `whitespace-nowrap`, a longer one is left to the
  browser. Punctuation is not a word, so the French closing « » » stays glued
  to "vutuv non." rather than dropping to a line of its own. A sentence without
  a space has nothing to protect and gets no wrapper, which also keeps a script
  written without spaces from gluing its whole sentence into one line.
  """
  attr(:text, :string, required: true)

  def quote_sentences(assigns) do
    assigns = assign(assigns, :sentences, sentences(assigns.text))

    # Not a `:for` on the span: it renders the spans back to back, and the
    # template whitespace between iterations is the only break point left
    # between two sentences.
    ~H"""
    <%= for {sentence, keep_whole?} <- @sentences do %>
      <%= if keep_whole? do %>
        <span class="whitespace-nowrap">{sentence}</span>
      <% else %>
        {sentence}
      <% end %>
    <% end %>
    """
  end

  # A new sentence starts after `.`, `!`, `?` or `…` at a space whose next
  # token holds a letter or a digit, so a lone closing « » » stays with the
  # sentence it closes.
  @sentence_break ~r/(?<=[.!?…]) +(?=\S*[\p{L}\p{N}])/u

  defp sentences(text) do
    for sentence <- String.split(text, @sentence_break, trim: true) do
      words = sentence |> String.split() |> Enum.count(&(&1 =~ ~r/[\p{L}\p{N}]/u))
      {sentence, words <= 2 and String.contains?(sentence, " ")}
    end
  end

  @doc """
  The three claims under the founder quote, inside the hero panel.

  One line each, with nothing behind it: the half-sentence two of them used to
  carry to explain themselves came out with the headline test, because a claim
  that needs propping up is not a claim.

  Two of the three are properties of the software and hold on every
  installation; the import is a feature of this codebase, so all three survive
  a third-party install without the operator having to promise anything.

  Deliberately not links. `/import/linkedin` needs an account, so a logged-out
  click would trade the sign-up form beside them for a login screen.
  """
  def hero_points(assigns) do
    assigns = assign(assigns, :points, hero_point_list())

    ~H"""
    <%!-- On a phone the three run on as one wrapped line, so the panel stays
          short enough for the sign-up form to show below it. --%>
    <ul
      data-hero-points
      class="mt-3 flex flex-wrap gap-x-4 gap-y-1 md:mt-8 md:block md:space-y-2.5"
    >
      <li :for={claim <- @points} class="flex gap-1.5 text-xs leading-snug md:gap-2.5 md:text-sm">
        <span aria-hidden="true" class="shrink-0 font-bold text-brand-200">✓</span>
        <span class="font-semibold text-white">{claim}</span>
      </li>
    </ul>
    """
  end

  defp hero_point_list do
    [
      gettext("Easy LinkedIn profile import."),
      gettext("Fast."),
      gettext("No paid premium accounts.")
    ]
  end

  @doc """
  The example profile the questions under the sign-up form point at, or `nil`
  where the installation dropped it (`:landing_example_profile_url` set to "").

  A full URL rather than a local path: the default points at the reference
  installation, which is the useful answer on an installation that has no
  filled-in profile of its own yet, and a local path would be a dead link there.

  The trailing slash a configured URL may carry comes off here, once: the API
  answer appends `.json` to this, and `example_profile_label/1` strips the slash
  for the visible text, so a join at a call site once rendered
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
  The text-link recipe (the design rule's "Text link" pair, dark half
  included), shared by the questions below the sign-up form, the community
  page and `VutuvWeb.ReportHTML`.
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
  Where this installation's data lives, or `nil` where the operator cleared it.

  Only the *place* is configurable, and that is the point: "no third-party
  cookies" and "delete your account yourself" are promises the software keeps
  on every installation, while "our own servers in X" is a promise only the
  operator can make. An operator on rented cloud infrastructure
  clears this and the whole "Where does my data live?" question goes with it,
  rather than the start page claiming something untrue on their behalf.
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
  The questions under the sign-up form, in the order the page asks them.

  Ten questions somebody has *before* signing up, each answered in a
  sentence or two (Stefan, 2026-09-25). A list rather than markup, because
  the FAQPage block (`VutuvWeb.JsonLd.faq_page/1`) is built from the same
  entries the page renders and so cannot say something the page does not.
  Each entry carries a `key` for the tests, the `question`, the `answer` (built
  from sentences here, because some of them depend on the installation, and
  joined once so the page and the JSON-LD block read the same string), and the
  `links` a reader checks the answer with, the explaining one first (the
  JSON-LD block carries that one as the Answer's `url`).

  What depends on the installation drops out per answer, not per section:
  the example profile (`:landing_example_profile_url`) carries the link of
  the public-profile answer and the JSON example of the API answer; the
  data-location question exists only where the operator named a place
  (`:data_location`, see `data_location/0`), because "our own servers" is a
  promise only they can make; and the Fediverse question exists only where
  the installation federates — with FEDIVERSE_ENABLED=false (the intranet
  case) every endpoint behind it 404s, so promising it there would be a lie.
  The cookie question holds everywhere: it describes the software.

  The deletion answer names the settings row by its own label (bound from the
  catalog, so the two cannot drift apart) and deliberately does not link it,
  and the LinkedIn answer links nothing: both pages need a login, so a
  logged-out click would trade the sign-up form for the login page. The
  organization kinds in that question are prose, not `Organization.kinds/0`:
  German gives every noun its own case ending.
  """
  def landing_faq do
    example = example_profile_url()
    place = data_location()

    [
      entry("price", gettext("What does vutuv cost?"), [
        gettext(
          "Nothing. There are no paid premium accounts, every account has the same features."
        )
      ]),
      entry(
        "public",
        gettext("Can I look at profiles and posts on vutuv without signing up?"),
        [gettext("Yes. Every profile and every public post can be read without an account.")] ++
          List.wrap(example && gettext("For example:")),
        List.wrap(example && check_link(example_profile_label(example), example))
      ),
      data_entry(place),
      entry(
        "tracking",
        gettext("Does vutuv use third-party cookies or any other external tracking?"),
        [
          gettext(
            "No. vutuv sets a single cookie, the one that keeps you signed in, and loads nothing from anybody else's server."
          )
        ]
      ),
      entry("linkedin", gettext("Can I bring my LinkedIn profile along?"), [
        gettext(
          "Yes. The import reads the data export LinkedIn hands you and takes over your CV; you check and save."
        )
      ]),
      entry(
        "organizations",
        gettext(
          "How does my organization (a business, an association, a public authority …) get a page?"
        ),
        [
          gettext(
            "First you create your own account. Signed in, you then create the organization and give yourself and other members rights within it, for example admin or editorial."
          )
        ]
      ),
      fediverse_entry(),
      entry(
        "open_source",
        gettext("Is vutuv open source?"),
        [gettext("Yes, the whole source code under the MIT license.")],
        [check_link(gettext("Source code"), SourceRepo.url(), external: true)]
      ),
      entry(
        "api",
        gettext("Is there an API?"),
        [
          gettext(
            "For developers there is a clean REST API, described in the developer documentation. If you only want to pull a profile's data quickly, append .md or .json to its address."
          )
        ],
        [check_link(gettext("Developer documentation"), ~p"/developers")] ++
          List.wrap(example && example_json_link(example <> ".json"))
      ),
      entry("delete", gettext("Can I delete my account again?"), [
        gettext(
          "Any time, and it takes a minute: look for “%{label}” in the settings, the red entry.",
          label: gettext("Delete account")
        )
      ])
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp entry(key, question, sentences, links \\ []),
    do: %{key: key, question: question, answer: Enum.join(sentences, " "), links: links}

  defp check_link(label, href, opts \\ []),
    do: %{label: label, href: href, external: Keyword.get(opts, :external, false)}

  # The label shows the address the link opens ("Example: vutuv.de/wintermeyer.json"),
  # because the answer tells the reader to append something to an address and
  # the link is the proof of what that looks like.
  defp example_json_link(href),
    do: check_link(gettext("Example: %{address}", address: example_profile_label(href)), href)

  # "Our own servers" is a promise only the operator can make, so the question
  # exists only where they named a place (see `data_location/0`).
  defp data_entry(nil), do: nil

  defp data_entry(place) do
    entry("data", gettext("Where does my data live?"), [
      gettext("On our own servers in %{place}, in no foreign cloud.", place: place)
    ])
  end

  # Both directions, said twice (at sign-up, and later in the settings), and
  # the whole stance in it: plenty of people want a business network and no
  # Fediverse at all, and they need to read that it is their choice, not
  # something that happens to them (Stefan, 2026-09-25).
  defp fediverse_entry do
    if Fediverse.enabled?() do
      entry("fediverse", gettext("What does vutuv have to do with the Fediverse?"), [
        gettext(
          "Every member decides for themselves whether their vutuv account takes part in the Fediverse. You make that choice at sign-up and can change it any time later in the settings, in either direction."
        )
      ])
    end
  end

  @doc """
  One question with its answer: the question as a heading, the answer as one
  paragraph, and the links that let the reader check it at the end of that
  paragraph. An external link wears ↗, a page on this site ›.
  """
  attr(:entry, :map, required: true)

  def faq_entry(assigns) do
    ~H"""
    <div data-landing-faq-entry={@entry.key}>
      <h3 class="font-semibold text-slate-900 dark:text-white">{@entry.question}</h3>
      <p class="mt-1 text-sm leading-relaxed text-slate-600 dark:text-slate-400">
        {@entry.answer}
        <a :for={link <- @entry.links} href={link.href} class={[link_class(), "mr-2"]}>
          {link.label}
          <span aria-hidden="true">{if link.external, do: "↗", else: "›"}</span>
        </a>
      </p>
    </div>
    """
  end

  @doc """
  The teaser video, German for German readers and English for everybody else.

  The hero is too narrow to watch a film in, so it shows the poster as a play
  button, and the video sits in a dialog that button opens, as large as the
  screen allows. The dialog starts it on opening and stops it on closing.

  The sources are `VutuvWeb.Teaser`'s: the 16:9 cut at 960×540, which the
  quality choice under the film swaps for 1920×1080 and back, and the 9:16 cut
  a phone plays full screen. Nothing but the poster loads before a click,
  since the page promises "Fast." and is the most requested one in the app.
  """
  attr(:class, :string, default: nil)

  def teaser_video(assigns) do
    assigns = assign(assigns, lang: Teaser.lang(), phone: Teaser.phone())

    ~H"""
    <button
      type="button"
      data-modal-open="landing-teaser-dialog"
      aria-label={gettext("Play the video")}
      class={[
        "group relative block aspect-video w-full overflow-hidden rounded-xl bg-slate-900 shadow-lg ring-1 ring-black/10 focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-white",
        @class
      ]}
    >
      <img src={Teaser.poster(@lang)} alt="" class="h-full w-full object-cover" />
      <span
        aria-hidden="true"
        class="absolute inset-0 m-auto flex h-14 w-14 items-center justify-center rounded-full bg-slate-900/75 text-white transition group-hover:scale-110 group-hover:bg-brand-600"
      >
        <VideoComponents.play_icon class="ml-1 h-7 w-7" />
      </span>
    </button>
    <.modal_dialog id="landing-teaser-dialog" size="video" aria-label={gettext("Play the video")}>
      <video
        id="landing-teaser"
        data-play-on-open
        data-fullscreen-below={@phone}
        poster={Teaser.poster(@lang)}
        preload="none"
        muted
        playsinline
        controls
        class="block aspect-video max-h-[calc(90vh-3.5rem)] w-full object-contain"
      >
        <Teaser.sources lang={@lang} />
      </video>
      <%!-- The controls sit in a bar under the film, never on it: a lone "HD"
            on the picture read as a badge, not a switch. So both choices are
            named and the chosen one is pressed. A phone plays full screen and
            never shows this bar. --%>
      <div data-video-bar class="flex items-center justify-between gap-3 bg-slate-950 px-3 py-2 text-sm text-slate-300">
        <div role="group" aria-labelledby="landing-teaser-quality" class="flex items-center gap-2">
          <span id="landing-teaser-quality">{pgettext("video quality", "Quality")}</span>
          <div class="flex rounded-full bg-white/10 p-0.5">
            <button
              :for={{quality, label, title} <- quality_choices()}
              type="button"
              data-video-quality="landing-teaser"
              data-quality={quality}
              aria-pressed={to_string(quality == "sd")}
              title={title}
              class="h-9 rounded-full px-3 font-semibold text-slate-300 hover:text-white focus-visible:outline focus-visible:outline-2 focus-visible:outline-white aria-pressed:bg-white aria-pressed:text-slate-900"
            >
              {label}
            </button>
          </div>
        </div>
        <button
          type="button"
          data-modal-close
          aria-label={gettext("Close")}
          class="flex h-10 w-10 items-center justify-center rounded-full text-slate-300 hover:bg-white/10 hover:text-white focus-visible:outline focus-visible:outline-2 focus-visible:outline-white"
        >
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" class="h-5 w-5">
            <path d="M6 6l12 12M18 6L6 18" />
          </svg>
        </button>
      </div>
    </.modal_dialog>
    """
  end

  defp quality_choices do
    [
      {"sd", pgettext("video quality", "Standard"), nil},
      {"hd", "HD", gettext("Full resolution")}
    ]
  end
end
