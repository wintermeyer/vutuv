defmodule VutuvWeb.PageHTML do
  @moduledoc false
  use VutuvWeb, :html

  # The sign-up form's email-type radios: the values and their order come from
  # the schema, the labels from the same helper the email pages use, so all
  # three renderings of Personal/Work/Other stay in step.
  import VutuvWeb.EmailHTML, only: [email_type_label: 1]
  alias Vutuv.Accounts.Email
  alias Vutuv.Fediverse
  alias Vutuv.Landing
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
  The heading block every example section under the sign-up form wears: a small
  uppercase eyebrow, the heading itself and one lead sentence.

  Written once because the four sections differ only in their words, and a
  landing page where the third heading sits two pixels off the second reads as
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
  The static screenshots of a profile shown under the sign-up form.

  Screenshots rather than live profile cards, so the block names nobody: being
  on the front page is louder than having a public profile, and the difference
  between the two is somebody's consent. A picture also shows what a card
  cannot, namely the whole page at once, rails and all, which is the question a
  visitor actually has.

  **The arrangement is a fanned deck, but only from `md` up.** Overlapping,
  tilted pictures are a marketing gesture, and a phone has no room for the
  gesture: at 390px three tilted cards would be three unreadable slivers. So
  below `md` they are a plain vertical stack at full width, and the tilt, the
  overlap and the straighten-on-hover only exist where there is space for them.
  The rotations are fixed values, not random: "random" would mean a different
  page on every render, and the point is a deliberate-looking scatter, not
  noise.

  They carry **no visible caption**. Three overlapping pictures leave nowhere to
  put one that does not land on the picture below, and a label under a fanned
  deck reads as a mistake. The description lives in the `alt` text, which is
  where a reader who cannot see the pictures needs it anyway.

  `drop-shadow`, not `shadow`: the images are window screenshots with rounded
  corners and transparency, so a box shadow would draw a rectangle around the
  transparent bounding box instead of hugging the window.

  They are `loading="lazy"` and carry their intrinsic size: three of them sit
  below the fold of the most requested page in the app, so they must neither be
  fetched before they are needed nor shift the layout when they arrive.

  The images are committed under `priv/static/images/`, which is **gitignored** —
  a new one needs `git add -f` or it 404s in production while rendering fine in
  dev.
  """
  def profile_shots(assigns) do
    assigns =
      assigns |> assign(:shots, profile_shot_list()) |> assign(:hook, "data-profile-shots")

    ~H"<.shot_deck shots={@shots} hook={@hook} />"
  end

  @doc """
  The screenshots explaining how people talk to each other here.

  Two pictures rather than prose, and these two because they are the halves
  people get wrong: the feed showing posts that arrived from *other* networks,
  and the settings page where a member subscribes to an account out there by
  typing its address. Together they say "both directions" without a diagram.
  """
  def communication_shots(assigns) do
    assigns =
      assigns
      |> assign(:shots, communication_shot_list())
      |> assign(:hook, "data-communication-shots")

    ~H"<.shot_deck shots={@shots} hook={@hook} />"
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

  **AVIF only, by decision.** The five weigh 316 KB as AVIF against 750 KB as
  WebP, and carrying both formats to keep pre-16.4 Safari served was judged not
  worth the second set of files. A browser without AVIF shows the `alt` text
  instead of the picture, which is why those alt texts describe what is in each
  screenshot rather than merely labelling it.

  The files are committed under `priv/static/images/`, which is **gitignored** —
  a new one needs `git add -f` or it 404s in production while rendering fine in
  dev.
  """
  attr(:shots, :list, required: true)
  attr(:hook, :string, required: true, doc: "the bare data attribute tests key on")

  def shot_deck(assigns) do
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

  # The alt text says what is IN the picture, because for a reader who cannot
  # see it that is the entire content of this block. `deck` is that card's place
  # in the fan: tilt, overlap and stacking order, all `md:`-only.
  defp profile_shot_list do
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

  # Two cards, so they lean away from each other around a shared centre rather
  # than fanning from a middle one.
  defp communication_shot_list do
    [
      %{
        src: ~p"/images/landing-feed-fediverse.avif",
        width: 1800,
        height: 1134,
        deck: "md:z-20 md:-mr-10 md:-rotate-3",
        alt:
          gettext(
            "The vutuv feed with the Fediverse tab selected: posts by news accounts on ard.social, mastodon.social and bonn.social, each with the server it came from, and heart, reply and repost counts underneath."
          )
      },
      %{
        src: ~p"/images/landing-fediverse-following.avif",
        width: 1800,
        height: 1134,
        deck: "md:z-10 md:-ml-10 md:rotate-3",
        alt:
          gettext(
            "The settings page for followed Fediverse accounts: a field to enter an address like @name@server, and a table of accounts already followed with their server and an unfollow link."
          )
      }
    ]
  end

  @doc """
  The "try it out" link beside the profile screenshots, or `nil` where the
  installation dropped it (`:landing_example_profile_url` set to "").

  A full URL rather than a local path: the default points at the reference
  installation, which is the useful answer on an installation that has no
  filled-in profile of its own yet, and a local path would be a dead link there.
  """
  def example_profile_url do
    case Application.get_env(:vutuv, :landing_example_profile_url) do
      url when is_binary(url) -> if String.trim(url) == "", do: nil, else: String.trim(url)
      _other -> nil
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
  The posts block's heading and lead, following the window the posts actually
  came from.

  Two written-out strings rather than one with a number in it: German wants
  "sieben Tagen" and "vier Wochen", the same sentence cannot carry both, and a
  heading that says "the past seven days" over four weeks of posts is the one
  outcome worse than a short carousel.
  """
  def posts_heading(days) do
    if days <= Landing.preferred_window_days() do
      gettext("Posts from the past seven days, not screenshots")
    else
      gettext("Posts from the past four weeks, not screenshots")
    end
  end

  @doc "The lead under `posts_heading/1`, matching the same window."
  def posts_lead(days) do
    if days <= Landing.preferred_window_days() do
      gettext(
        "The most liked posts of the past seven days, everybody's best one first. Some were answered from Mastodon and other independent networks."
      )
    else
      gettext(
        "The most liked posts of the past four weeks, everybody's best one first. Some were answered from Mastodon and other independent networks."
      )
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
  The nine things vutuv does, in three groups of three.

  Three groups rather than one long list because the three answer three
  different questions a visitor actually has: what do I get out of a profile,
  what happens here day to day, and what happens to my data if I stop liking
  the place. Nine rather than the three big claims a smaller network can get
  away with: breadth is the honest argument here, and every line below is
  something that is built and running.

  This is our own copy, so it needs no member and shows on every installation,
  including a brand-new empty one. The one line that is not true everywhere is
  the Fediverse one, which drops out where the operator turned federation off
  (`FEDIVERSE_ENABLED=false`, the intranet case) — leaving that group with two
  entries rather than promising something whose every endpoint 404s there.
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

  defp feature_groups do
    [
      %{
        title: gettext("Your profile"),
        items: [
          gettext(
            "A CV with positions, education, certificates including proof, spoken languages and tags other members endorse you for."
          ),
          gettext(
            "CV download as PDF, Word, OpenDocument, LaTeX or JSON Resume, and you pick what goes in before you download it."
          ),
          gettext(
            "A permanent public address, readable without an account and downloadable as a vCard."
          )
        ]
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
