defmodule VutuvWeb.PageHTML do
  @moduledoc false
  use VutuvWeb, :html

  # The sign-up form's email-type radios: the values and their order come from
  # the schema, the labels from the same helper the email pages use, so all
  # three renderings of Personal/Work/Other stay in step.
  import VutuvWeb.EmailHTML, only: [email_type_label: 1]
  # The sign-up form's salutation radios share their options with the profile
  # editor and the invitation form, so no surface can offer a value the
  # changeset would reject.
  import VutuvWeb.UserHelpers, only: [salutation_options: 0]
  alias Vutuv.Accounts.Email
  alias Vutuv.Fediverse
  alias Vutuv.References.Checks
  alias VutuvWeb.Feeds
  alias VutuvWeb.JobReferenceHTML

  embed_templates("../templates/page/*")

  # Where a deck holds two cards they lean away from each other around a shared
  # centre rather than fanning from a middle one. Three decks are built that way,
  # so the geometry is named once: a tilt tweaked in one of them and not the
  # others is the kind of drift nobody notices and everybody sees.
  @lean_left "md:z-20 md:-mr-10 md:-rotate-3"
  @lean_right "md:z-10 md:-ml-10 md:rotate-3"

  @doc """
  Every deck on the page, in the order it appears.

  The single source for "which decks exist": `shot_deck/1` accepts exactly these
  and `landing_page_test` walks them rather than repeating the list.
  """
  def shot_decks, do: [:profile, :career, :reference, :communication]

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
  The heading block every example section under the sign-up form wears: a small
  uppercase eyebrow, the heading itself and one lead sentence.

  Written once because the sections differ only in their words, and a landing
  page where the third heading sits two pixels off the second reads as
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
  A fanned deck of screenshots: the shared arrangement behind every picture
  block on the landing page.

  **It fans only from `md` up.** Overlapping, tilted pictures are a marketing
  gesture and a phone has no room for the gesture: at 390px three tilted cards
  would be three unreadable slivers. Below `md` they are a plain vertical stack
  at full width, and the tilt, the overlap and the straighten-on-hover exist
  only where there is space for them. The rotations are fixed values per shot,
  not random: "random" would mean a different page on every render, and the
  point is a deliberate-looking scatter, not noise.

  The cards carry **no visible caption**. Overlapping pictures leave nowhere to
  put one that does not land on the picture below, and a label under a fanned
  deck reads as a mistake. The description lives in each shot's `alt`, which is
  where a reader who cannot see the pictures needs it anyway.

  `drop-shadow`, not `shadow`: these are window screenshots with rounded corners
  and transparency, so a box shadow would draw a rectangle around the
  transparent bounding box instead of hugging the window.

  Every image is `loading="lazy"` and carries its own intrinsic size (the decks
  do not share one aspect ratio): they all sit below the fold of the most
  requested page in the app, so they must neither be fetched before they are
  needed nor shift the layout when they arrive.

  **AVIF only, by decision.** The nine weigh 522 KB as AVIF, against roughly
  twice that as WebP, and carrying both formats to keep pre-16.4 Safari served
  was judged not worth the second set of files. A browser without AVIF shows the
  `alt` text instead of the picture, which is why those alt texts describe what
  is in each screenshot rather than merely labelling it. That decision rejected a
  second *format*; a second *width* (`srcset`) is untouched ground, and the
  figures render into roughly 361 CSS px, so there is real room there.

  The files live under `priv/static/images/`, which is **gitignored**, so a new
  one needs `git add -f`. Do not rely on remembering that: `landing_page_test`
  walks this catalog and fails the build if a shot is missing from the index,
  which is the only reason it cannot 404 in production while rendering in dev.

  One component, one `deck` key: the four decks differ in nothing but their
  pictures, so they are four clauses of `shot_list/1` rather than four
  components. The `data-…-shots` attribute the tests key on is derived from that
  key, so a new deck cannot ship with a hook nobody hooks.
  """
  attr(:deck, :atom, required: true, values: [:profile, :communication, :career, :reference])

  def shot_deck(assigns) do
    assigns =
      assigns
      |> assign(:shots, shot_list(assigns.deck))
      |> assign(:hook, "data-#{assigns.deck}-shots")

    ~H"""
    <div
      {%{@hook => true}}
      class="mt-8 flex flex-col items-center gap-6 md:flex-row md:items-center md:justify-center md:gap-0 md:px-[6%]"
    >
      <figure
        :for={shot <- @shots}
        class={[
          "relative w-full drop-shadow-xl md:w-2/5",
          # Hover straightens the card, lifts it clear of the deck and zooms in,
          # which is the only way to actually read one once they overlap. The
          # zoom is 25%: at 5% it read as a wobble rather than as "look at this".
          #
          # It is what the deck's `md:px-[6%]` is for. A transform costs no
          # layout, so a card growing past the page's content box does not push
          # anything — it just hangs over the edge and the browser answers with a
          # horizontal scrollbar. Measured: an edge card at 25% reaches 47px past
          # a 736px deck (the narrowest the fan runs at) and 61px past a 992px
          # one, and since that reach grows with the deck the reserve has to be a
          # percentage, not a fixed padding. 6% clears it at every width from 736
          # to 1024; 5% still spilled 5-6px at the wide end.
          "motion-safe:transition-transform motion-safe:duration-300",
          "md:hover:z-30 md:hover:rotate-0 md:hover:scale-125",
          shot.deck
        ]}
      >
        <img
          src={shot.src}
          alt={shot.alt}
          width={shot.width}
          height={shot.height}
          loading="lazy"
          decoding="async"
          class="w-full"
        />
      </figure>
    </div>
    """
  end

  @doc """
  The pictures of one deck.

  Public so `landing_page_test` can walk every deck and check that each file is
  really in the git index, `priv/static/` being gitignored.

  The alt text says what is IN the picture, because for a reader who cannot see
  it that is the entire content of these blocks. `deck` is that card's place in
  the fan: tilt, overlap and stacking order, all `md:`-only.
  """
  def shot_list(:profile) do
    [
      %{
        src: ~p"/images/landing-profile-overview.avif",
        width: 1800,
        height: 1322,
        deck: "md:z-10 md:-mr-12 md:-rotate-6",
        alt:
          gettext(
            "A vutuv profile: cover picture, photo, name, tagline and job title, follower counts and the first posts, with contact details and social media profiles in a column on the right."
          )
      },
      %{
        # The middle card sits on top and barely tilts: it is the one a reader
        # looks at first, so it is the one that stays legible.
        src: ~p"/images/landing-profile-cv.avif",
        width: 1800,
        height: 1322,
        deck: "md:z-20 md:-mb-6 md:rotate-2",
        alt:
          gettext(
            "The same profile further down: tags, each with the number of members who endorse it, and a CV as a timeline of positions with employer and duration."
          )
      },
      %{
        src: ~p"/images/landing-profile-links.avif",
        width: 1800,
        height: 1322,
        deck: "md:z-10 md:-ml-12 md:rotate-6",
        alt:
          gettext(
            "The lower part of the profile: spoken languages with levels, web links each shown as a preview image with a verification mark, and a panel offering the CV for download."
          )
      }
    ]
  end

  # Two pictures rather than prose, and these two because they are the halves
  # people get wrong: the feed showing posts that arrived from *other* networks,
  # and the settings page where a member subscribes to an account out there by
  # typing its address. Together they say "both directions" without a diagram.
  def shot_list(:communication) do
    [
      %{
        src: ~p"/images/landing-feed-fediverse.avif",
        width: 1800,
        height: 1134,
        deck: @lean_left,
        alt:
          gettext(
            "The vutuv feed with the Fediverse tab selected: posts by news accounts on ard.social, mastodon.social and bonn.social, each with the server it came from, and heart, reply and repost counts underneath."
          )
      },
      %{
        src: ~p"/images/landing-fediverse-following.avif",
        width: 1800,
        height: 1134,
        deck: @lean_right,
        alt:
          gettext(
            "The settings page for followed Fediverse accounts: a field to enter an address like @name@server, and a table of accounts already followed with their server and an unfollow link."
          )
      }
    ]
  end

  # The two halves of the promise: the checklist where you decide what goes into
  # the CV, and the finished document that comes out. Either alone leaves the
  # visitor guessing at the other. Both are shot LOGGED OUT, like the profile
  # deck: the builder is viewer-scoped (`VutuvWeb.CV`), so the owner's own view
  # of it also lists the addresses they have kept private, and a picture of that
  # on the most requested page in the app would publish them.
  def shot_list(:career) do
    [
      %{
        src: ~p"/images/landing-cv-builder.avif",
        width: 1800,
        height: 1215,
        deck: @lean_left,
        alt:
          gettext(
            "The CV builder: a checklist of everything that could go into the CV, with name, photo, tagline and contact details, and beside it a panel offering the download as PDF, Word, OpenDocument, LaTeX or JSON Resume."
          )
      },
      %{
        src: ~p"/images/landing-cv-print.avif",
        width: 1800,
        height: 1215,
        deck: @lean_right,
        alt:
          gettext(
            "The finished CV ready to print: name, tagline and contact details at the top, below them the positions held with employer and period, and further down the tags and the spoken languages."
          )
      }
    ]
  end

  # The list first, because two references graded 1 and 4-5 side by side say in
  # one glance that the thing really grades; then one report, and deliberately
  # the BAD one. A green report is reassuring and sells nothing, where a red one
  # shows the decoded wording that is the whole point of the feature. The good
  # grade sits in the list beside it, so the pair does not read as scaremongering
  # either.
  def shot_list(:reference) do
    [
      %{
        src: ~p"/images/landing-reference-list.avif",
        width: 1800,
        height: 1193,
        deck: @lean_left,
        alt:
          gettext(
            "The uploaded employment references, each marked private: one graded 1 (very good) on a green panel, one graded 4 to 5 (poor to unsatisfactory) on a red one, each with a link to its full report."
          )
      },
      %{
        src: ~p"/images/landing-reference-check.avif",
        width: 1800,
        height: 1193,
        deck: @lean_right,
        alt:
          gettext(
            "The review of a single employment reference: the overall grade on a red panel, then a report naming the kind of reference, the grade range, a traffic-light tally of its wordings and the main criticism."
          )
      }
    ]
  end

  @doc """
  The privacy promise under the Arbeitszeugnis screenshots, in the words the
  feature page itself uses.

  Composed from `VutuvWeb.JobReferenceHTML`'s own two sentences rather than
  written again here, because both name a country and a piece of hardware that
  come from this installation's configuration. A second copy of that claim on
  the front page is a second chance to state it wrongly, and this is the claim
  where being wrong costs the most.
  """
  def reference_privacy_line do
    JobReferenceHTML.check_location_heading() <> " " <> JobReferenceHTML.check_location_line()
  end

  @doc """
  The "try it out" link beside the profile screenshots, or `nil` where the
  installation dropped it (`:landing_example_profile_url` set to "").

  A full URL rather than a local path: the default points at the reference
  installation, which is the useful answer on an installation that has no
  filled-in profile of its own yet, and a local path would be a dead link there.

  `suffix` appends a subpage of that profile (the CV builder passes `"/cv"`).
  The join lives here rather than at the call site because the trailing slash a
  configured URL may carry has to come off first, and `example_profile_label/1`
  already strips it: doing it in markup rendered `…/wintermeyer//cv` under a
  label reading `…/wintermeyer/cv`.
  """
  def example_profile_url(suffix \\ "") do
    case Application.get_env(:vutuv, :landing_example_profile_url) do
      url when is_binary(url) ->
        case url |> String.trim() |> String.trim_trailing("/") do
          "" -> nil
          base -> base <> suffix
        end

      _other ->
        nil
    end
  end

  @doc """
  How that URL reads on the page: without the scheme, which is noise in running
  text and the one part nobody types any more.
  """
  def example_profile_label(url) do
    url |> String.replace(~r{^https?://}, "") |> String.trim_trailing("/")
  end

  @doc """
  The "Try it out:" line under a section heading, or nothing where the
  installation cleared the example profile.

  One component for both call sites: the profile deck offers the profile itself,
  the CV deck the same profile's `/cv`, and the two were a verbatim copy of each
  other down to the brand-link class string. `suffix` is the only difference.
  """
  attr(:suffix, :string, default: "")

  def try_it_out(assigns) do
    assigns = assign(assigns, :url, example_profile_url(assigns.suffix))

    ~H"""
    <p :if={@url} class="mt-3 text-base text-slate-600 dark:text-slate-400">
      {gettext("Try it out:")}
      <a
        href={@url}
        class="font-semibold text-brand-600 hover:text-brand-700 dark:text-brand-400 dark:hover:text-brand-300"
      >
        {example_profile_label(@url)}
      </a>
    </p>
    """
  end

  @doc """
  Where this installation's data lives, or `nil` where the operator cleared it.

  Only the *place* is configurable, and that is the point: "no third-party
  cookies", "export your data" and "delete your account yourself" are promises
  the software keeps on every installation, while "our own servers in X" is a
  promise only the operator can make. An operator on rented cloud infrastructure
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
  The ten things vutuv does, in three groups.

  Three groups rather than one long list because the three answer three
  different questions a visitor actually has: what do I get out of a profile,
  what happens here day to day, and what happens to my data if I stop liking
  the place. Ten rather than the three big claims a smaller network can get
  away with: breadth is the honest argument here, and every line below is
  something that is built and running.

  The groups are deliberately **not** kept to an even three each. They used to
  be, and when the Arbeitszeugnis review joined "Your profile" the choice was
  between dropping a real feature to preserve the shape and letting one column
  run a line longer. The list is read as a list, not as a grid, so the feature
  won.

  This is our own copy, so it needs no member and shows on every installation,
  including a brand-new empty one. Two lines are not true everywhere and drop
  out with the switch that turns their feature off: the Fediverse one where the
  operator federates nothing (`FEDIVERSE_ENABLED=false`, the intranet case),
  and the Arbeitszeugnis one where no model backs the review queue.
  """
  def landing_features(assigns) do
    assigns = assign(assigns, :groups, feature_groups())

    ~H"""
    <div data-landing-features class="mt-6 grid gap-4 md:grid-cols-3">
      <.card :for={group <- @groups} class="flex flex-col">
        <.section_title>{group.title}</.section_title>
        <ul class="mt-3 space-y-3">
          <li :for={item <- group.items} class="flex gap-2.5 text-sm">
            <span aria-hidden="true" class="mt-0.5 shrink-0 font-bold text-brand-600 dark:text-brand-400">
              ✓
            </span>
            <span class="text-slate-700 dark:text-slate-300">{item}</span>
          </li>
        </ul>
      </.card>
    </div>
    """
  end

  # Named separately so the installation switch reads as the reason it is
  # conditional, rather than as an `if` buried in a list literal.
  defp fediverse_feature do
    if Fediverse.enabled?() do
      [
        gettext(
          "The Fediverse: let people follow you from Mastodon, and your public posts show up there. You choose at sign-up, and can change it later."
        )
      ]
    else
      []
    end
  end

  # Gated like `fediverse_feature/0`, and for the same reason: an installation
  # with no model behind the queue (`REFERENCE_CHECKS_ENABLED=false`) cannot
  # keep this promise, and the feature list is where a visitor counts what they
  # get.
  defp reference_feature do
    if Checks.enabled?() do
      [
        gettext(
          "Employment references: upload them, keep them private, and have the wording read and graded on our own servers."
        )
      ]
    else
      []
    end
  end

  defp feature_groups do
    [
      %{
        title: gettext("Your profile"),
        items:
          [
            gettext(
              "A CV with positions, education, certificates including proof, spoken languages and tags other members endorse you for."
            ),
            gettext(
              "CV download as PDF, Word, OpenDocument, LaTeX or JSON Resume, and you pick what goes in before you download it."
            ),
            gettext(
              "A permanent public address, readable without an account and downloadable as a vCard."
            )
          ] ++ reference_feature()
      },
      %{
        title: gettext("People, posts, jobs"),
        items: [
          gettext("Posts, likes, reposts, replies and 1:1 messages, in real time."),
          gettext(
            "A job board with radius search and saved searches that email you when something matches."
          ),
          gettext(
            "Organization pages that only exist once somebody has proven control of the organization's domain."
          )
        ]
      },
      %{
        title: gettext("Your independence"),
        items:
          fediverse_feature() ++
            [
              gettext(
                "Sign in without a password, by emailed PIN, passkey, authenticator app or a printed list of codes."
              ),
              gettext(
                "Open source under the MIT license, and you can run your own installation on the internet or in your own intranet."
              )
            ]
      }
    ]
  end
end
