defmodule VutuvWeb.AgentDocs.InvestorsDoc do
  @moduledoc """
  The `/system/investors` page as a data map for the agent formats, and the
  owner of every figure that page states.

  `facts/0` is queried once per request and handed to both the template and the
  doc, so the HTML and its `.md`/`.txt`/`.json`/`.xml` siblings cannot disagree
  about a number — the drift the whole `VutuvWeb.AgentDocs` system exists to
  prevent, and doubly worth it here, where the numbers are the argument.

  Unlike the media kit beside it, this page **follows the reader's language**
  (see `VutuvWeb.CompanyController`), so the labels here go through gettext and
  the doc reports the locale it was built in.

  It states **no email address**: an investor writes through vutuv itself,
  which is both the least spammable inbox we have and a minute spent inside the
  product they are about to be told about. The operator's profile here is
  linked beside that, because somebody about to put six figures somewhere wants
  to see who is on the other side first.
  """

  use Gettext, backend: VutuvWeb.Gettext

  alias Vutuv.Accounts
  alias Vutuv.Accounts.User
  alias Vutuv.Fediverse
  alias Vutuv.PeopleHistory
  alias VutuvWeb.AgentDocs
  alias VutuvWeb.UI

  @doc """
  The public figures the investor page quotes, read live: the two counts the
  people total adds up, the daily `series` the curve is drawn from, and the
  `growth` over its span.

  **Two counts and not seven.** Activity and post volume were here and read as
  a dashboard: an investor asked what the number in the top bar is made of, and
  the answer is these two. `/system/nodeinfo/2.1` still publishes the rest for
  whoever wants it, which is also why `Accounts.count_users/0` is read directly
  rather than through `NodeInfo.usage/0` — that one costs three more queries
  for figures this page no longer shows.

  The series is loaded for every format although only the HTML draws a chart,
  because `growth/1` is derived from it and the **sentence** that reading turns
  into goes into all five (`growth_sentence/1`). The two counts say how big
  this is; the movement is the half an investor came for.
  """
  def facts do
    reach = Fediverse.follower_reach()
    series = PeopleHistory.series()

    %{
      members: Accounts.count_users(),
      fediverse_accounts: reach.accounts,
      fediverse_servers: reach.hosts,
      series: series,
      growth: PeopleHistory.growth(series)
    }
  end

  @doc """
  The figures as an ordered `{label, value}` list, so the `.md` and `.txt`
  renderings name them identically. The HTML is deliberately its own
  arrangement (two tiles, the server count folded into a note under the second),
  not a third copy of this list.
  """
  def figure_rows(facts) do
    [
      {gettext("Members"), facts.members},
      {gettext("Fediverse accounts"), facts.fediverse_accounts},
      {gettext("Fediverse servers"), facts.fediverse_servers}
    ]
  end

  @doc """
  The page's headline: the one claim an investor should leave with, in the
  reader's language. Shared with the agent formats so a `.md` reader is handed
  the same argument and not a bare list of counts.
  """
  def headline do
    gettext("A professional network that works without an account")
  end

  @doc """
  What this page is for, in the reader's language. The HTML lead paragraph and
  the agent formats' description both come from here.
  """
  def purpose do
    gettext(
      "This page is for potential investors. It says what vutuv is, where the network stands today, and how it is meant to earn money one day."
    )
  end

  @doc """
  The case, as an ordered list of `%{title:, body:, source:}` in the reader's
  language, where `source` is `%{label:, url:}` or `nil`.

  Deliberately link-free prose in one place rather than five paragraphs in the
  template and five more in each renderer: the argument is the page, and a
  version of it that only the HTML carries would leave every `.md` reader (an
  agent summarising us for somebody) with the figures and none of the reasoning.
  A claim that rests on somebody else's measurement carries that measurement's
  source beside it rather than inside the sentence, so every format can put the
  citation where it belongs and the prose stays a paragraph.
  """
  def case_points do
    [
      %{
        title: gettext("Readable without an account"),
        body:
          gettext(
            "LinkedIn shows a profile to whoever is logged in and asks everybody else to sign up first. Everybody who is inside knows the other half: you go looking for one person and get a feed, suggestions you did not ask for, and a note that the rest is behind Premium. A vutuv profile is an ordinary public web page: a search engine indexes it, an AI agent reads it as Markdown, JSON or vCard, and a person who has never heard of us reads it without handing over an address first. That is why somebody arrives at all, and why a member puts their work here."
          ),
        source: nil
      },
      %{
        title: gettext("Fast pages win"),
        body:
          gettext(
            "A page that answers in milliseconds is not a matter of polish, it decides whether somebody stays. Google had 55 and Deloitte measure that across 37 European and American brands and more than 30 million sessions: a tenth of a second faster raised conversions by 8.4% in retail and by 10.1% in travel."
          ),
        source: %{
          label: "Milliseconds Make Millions, Google / 55 / Deloitte, 2020",
          url: "https://web.dev/case-studies/milliseconds-make-millions"
        }
      },
      %{
        title: gettext("The market behind the slow connection"),
        body:
          gettext(
            "Networks are not equal, and neither are the markets on them: in 2025 the ITU counted 84% of people in high-income countries with access to 5G against 4% in low-income ones, and somebody online in a wealthy country moves nearly eight times as much mobile data as somebody in a poor one. A site that assumes a fast line is shut to most of them in practice. A vutuv page loads less data than a LinkedIn page to begin with, and a data-saving mode cuts that again for anybody on a slow connection or paying by the megabyte."
          ),
        source: %{
          label: "ITU, Facts and Figures 2025",
          url: "https://www.itu.int/en/mediacentre/Pages/PR-2025-11-17-Facts-and-Figures.aspx"
        }
      },
      %{
        title: gettext("Advertising instead of a paywall"),
        body:
          gettext(
            "Text ads are to carry the operation, which is why there is no premium tier and will not be one. Nothing is held back from somebody who will not pay for it, and a paid tier is the single thing that stops most people from ever starting. Leaving it out is what lets the network grow, and only a growing network makes the ads worth anything."
          ),
        source: nil
      }
    ]
  end

  @doc """
  The sum in the top bar written out as the arithmetic it is: the two tiles it
  adds and the figure they add up to, as one sentence for the agent formats.

  The HTML sets the same three figures as a written addition
  (`people_sum_rows/1`); both read them from the same `facts` map, so they
  cannot disagree.

  Investors have asked how that number comes about, which is the whole reason
  it is spelled out — a figure nobody can decompose is a figure nobody
  believes, and the two summands are on the same page as tiles anyway.

  The equation always holds, and not by luck: the member tile reads
  `Accounts.count_users/0` and the Fediverse tile the same distinct count over
  `foreign_followers/0` that `Vutuv.PeopleCounter` adds up for the top bar. The
  bar may lag this page by up to a minute, because it reads its cached cell
  rather than the database.
  """
  def people_sum(facts) do
    gettext(
      "%{members} members + %{fediverse} Fediverse accounts = %{total} people",
      members: UI.delimited_count(facts.members),
      fediverse: UI.delimited_count(facts.fediverse_accounts),
      total: UI.delimited_count(facts.members + facts.fediverse_accounts)
    )
  end

  @doc """
  The three lines of the addition above, as an ordered list of
  `%{key:, sign:, value:, label:}`: the two summands and the figure they add up
  to, the last one keyed `:total`.

  A stacked addition rather than a sentence, because that is how a person reads
  an arithmetic they were about to check anyway — the digits line up under each
  other and the rule replaces the "=". The agent formats keep the sentence
  (`people_sum/1`), where a column of numbers has nothing to align against.
  Both read the same `facts` map, so the two shapes cannot name different
  figures; the test that says so is in `company_controller_test.exs`, because
  only discipline keeps them naming the same **summands** if a third population
  is ever added.

  The labels are the tiles' own msgids on purpose: the addition stands beside
  those tiles, and a row that called the same figure something else would read
  as a different figure.
  """
  def people_sum_rows(facts) do
    [
      %{
        key: :members,
        sign: nil,
        value: UI.delimited_count(facts.members),
        label: gettext("Members")
      },
      %{
        key: :fediverse,
        sign: "+",
        value: UI.delimited_count(facts.fediverse_accounts),
        label: gettext("Fediverse accounts")
      },
      %{
        key: :total,
        sign: nil,
        value: UI.delimited_count(facts.members + facts.fediverse_accounts),
        label: gettext("People")
      }
    ]
  end

  @doc """
  What that sum means, in the one sentence the addition above cannot say.
  `/system/members` spells out the rest for whoever wants it.
  """
  def counter_explainer do
    gettext("A Fediverse account following several profiles here still counts as one person.")
  end

  @doc """
  The operator's own profile on **this** installation, or `nil`.

  Built on `contact_handle/0`, so it exists exactly when that handle really
  resolves to a member here. `VutuvWeb.AgentDocs.MediaKitDoc` shows the same
  link to a journalist.
  """
  def contact_profile_url do
    if handle = contact_handle() do
      AgentDocs.abs_url("/" <> handle)
    end
  end

  @doc """
  The one-line reading of the growth curve: how many people arrived over its
  span and how many of those were members here, from the `growth` map
  `facts/0` derives. `nil` for a series too short to have a span, or one where
  nothing grew — a sentence about zero is worse than no sentence.

  Here rather than beside the chart, because it is a sentence about the network
  rather than about the drawing: a `.md` reader summarising us for somebody
  otherwise gets the standing counts and nothing about the movement.
  """
  def growth_sentence(%{total: total, members: members, days: days}) when total > 0 do
    gettext(
      "Over these %{days} days %{total} people arrived, %{members} of them as members here.",
      days: days,
      total: UI.delimited_count(total),
      members: UI.delimited_count(members)
    )
  end

  def growth_sentence(_none), do: nil

  @doc "How to get in touch, given that this page states no address."
  def contact_note do
    gettext(
      "Write to me here, on vutuv. Creating an account takes a minute and costs nothing, and you will have seen the product before the first sentence about it."
    )
  end

  @doc """
  The handle an investor writes to on **this** installation, or `nil`.

  Same rule as the media kit's press contact: built from `:operator_handle` and
  returned only once that handle really resolves to a member here, so a
  third-party installation running the shipped default renders no contact at
  all rather than pointing a reader at a stranger on somebody else's site.
  """
  def contact_handle do
    handle = Application.get_env(:vutuv, :operator_handle) || ""

    with true <- handle != "",
         %User{username: username} <- Accounts.get_user_by_username(handle) do
      username
    else
      _ -> nil
    end
  end

  @doc """
  The /system/investors page as a doc map: what the page is for, the case it
  makes, the floor under a conversation, the figures, and the way to write.
  """
  def build(facts) do
    # Bound once: each call is a lookup of that handle against the members here.
    handle = contact_handle()

    AgentDocs.doc_meta("investors", "/system/investors")
    |> Map.merge(%{
      title: gettext("Investors"),
      description: purpose(),
      language: Gettext.get_locale(VutuvWeb.Gettext),
      headline: headline(),
      operator: %{
        name: Application.fetch_env!(:vutuv, :operator_name),
        url: Application.fetch_env!(:vutuv, :operator_url),
        source: nil
      },
      case_points: case_points(),
      people_sum: people_sum(facts),
      counter_explainer: counter_explainer(),
      contact_note: contact_note(),
      contact_handle: handle,
      contact_url: handle && AgentDocs.abs_url("/messages/with/" <> handle),
      contact_profile_url: handle && AgentDocs.abs_url("/" <> handle),
      growth_sentence: growth_sentence(facts.growth),
      # The daily rows themselves are the chart's business; the doc carries the
      # reading of them.
      figures: Map.drop(facts, [:series, :growth]),
      media_kit_url: AgentDocs.abs_url("/system/media-kit")
    })
  end
end
