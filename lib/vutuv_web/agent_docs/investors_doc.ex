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

  It states **no email address and no profile URL**. An investor writes through
  vutuv itself, which is both the least spammable inbox we have and a minute
  spent inside the product they are about to be told about.
  """

  use Gettext, backend: VutuvWeb.Gettext

  alias Vutuv.Accounts
  alias Vutuv.Accounts.User
  alias Vutuv.Fediverse
  alias Vutuv.NodeInfo
  alias Vutuv.PeopleHistory
  alias Vutuv.Salary
  alias VutuvWeb.AgentDocs
  alias VutuvWeb.UI

  @doc """
  The public figures the investor page quotes, read live: the standing counts,
  the daily `series` the curve is drawn from, and the `growth` over its span.

  The series is loaded for every format although only the HTML draws a chart,
  because `growth/1` is derived from it and the **sentence** that reading turns
  into goes into all five (`growth_sentence/1`). Standing counts say how big
  this is; the movement is the half an investor came for.
  """
  def facts do
    usage = NodeInfo.usage()
    reach = Fediverse.follower_reach()
    series = PeopleHistory.series()

    %{
      members: usage.users.total,
      active_month: usage.users.active_month,
      active_halfyear: usage.users.active_halfyear,
      posts: usage.local_posts,
      replies: usage.local_comments,
      fediverse_accounts: reach.accounts,
      fediverse_servers: reach.hosts,
      series: series,
      growth: PeopleHistory.growth(series)
    }
  end

  @doc """
  The figures as an ordered `{label, value}` list, so the `.md` and `.txt`
  renderings name them identically. The HTML tiles are deliberately their own
  arrangement (six tiles, the server count folded into a note on the seventh
  figure), not a third copy of this list.
  """
  def figure_rows(facts) do
    [
      {gettext("Members"), facts.members},
      {gettext("Active this month"), facts.active_month},
      {gettext("Active this half year"), facts.active_halfyear},
      {gettext("Posts"), facts.posts},
      {gettext("Replies"), facts.replies},
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
      "This page is for investors. It says what vutuv is, how it earns money, where the network stands today, and from what size an investment is worth a conversation."
    )
  end

  @doc """
  The case, as an ordered list of `%{title:, body:}` in the reader's language.

  Deliberately link-free prose in one place rather than four paragraphs in the
  template and four more in each renderer: the argument is the page, and a
  version of it that only the HTML carries would leave every `.md` reader (an
  agent summarising us for somebody) with the figures and none of the reasoning.
  """
  def case_points do
    [
      %{
        title: gettext("Readable without an account"),
        body:
          gettext(
            "LinkedIn shows a profile to whoever is logged in, and asks everybody else to sign up first. A profile there works for the people already inside and for nobody else. A vutuv profile is an ordinary public web page: a search engine indexes it, an AI agent reads it as Markdown, JSON or vCard, and a person who has never heard of us reads it without handing over an address first. That is why somebody arrives at all, and why a member puts their work here."
          )
      },
      %{
        title: gettext("Fast enough for a thin line"),
        body:
          gettext(
            "Pages here are delivered in milliseconds, and a data-saving mode cuts what each one weighs for anybody on a slow connection. That is not a matter of polish. It decides whether the site is usable at all in the markets where the next hundred million professionals are, and where a heavy network is effectively closed. Reaching them costs us a switch, not a second product."
          )
      },
      %{
        title: gettext("Small enough to stay cheap"),
        body:
          gettext(
            "The software is Elixir and Phoenix. One modest server goes a long way, and a very large installation scales out across several nodes. There is no floor of staff under the operation, so the cost side barely moves when the member count does. A network that is cheap to run does not have to squeeze the people on it."
          )
      },
      %{
        title: gettext("Advertising instead of a paywall"),
        body:
          gettext(
            "Text ads pay for the operation, so there is no premium tier. Nothing is held back from somebody who will not pay for it, and a paid tier is the single thing that stops most people from ever starting. Leaving it out is what lets the network grow, and a growing network is what the ads are worth."
          )
      }
    ]
  end

  @doc """
  What the people total in the top bar is made of. Investors have asked, which
  is the whole reason it is written down: a figure nobody can decompose is a
  figure nobody believes.
  """
  def counter_explainer do
    gettext(
      "The number in the top bar adds up two groups: the members of this installation, and the accounts on other Fediverse servers that follow a member, a page or a topic here. Nobody is counted twice. An account following five things is one account, and somebody who is a member here is already in the first group."
    )
  end

  @doc """
  Why the figures can be checked from outside, with a `{nodeinfo}` placeholder
  where the URL belongs (`VutuvWeb.UI.split_marker/2` in the template, the
  plain URL in the agent formats).
  """
  def transparency_note do
    gettext(
      "Every figure here is read from the database on each request, and the same figures are published under {nodeinfo}, the standard format Fediverse servers describe themselves in. So they are not a claim on a slide. Anybody can fetch them, including a server that has never spoken to us."
    )
  end

  @doc """
  Why the floor is where it is. `{amount}` stands where the figure goes, so a
  translator can move it into the sentence their language wants; the HTML
  splits on it (`VutuvWeb.UI.split_marker/2`) to set the figure in bold, and
  `minimum_sentence/0` fills it in for the agent formats.
  """
  def minimum_reason do
    gettext(
      "An investment starts at {amount}. Below that a round costs both sides more than it brings in: the notary appointment, the shareholder agreement, the register entry and the reporting duty that follows are the same work for a small ticket as for a large one. Saying so here spares the smaller enquiry a week of waiting for a no."
    )
  end

  @doc """
  The minimum written as money: the digits grouped for the reader's locale
  (`300.000 €` in German, `300,000 €` in English), or `nil` where nothing is
  being raised.

  Symbol **after** the amount in every language, and the symbol itself out of
  `Vutuv.Salary.currency_symbol/1`, because that is how this site already
  writes money everywhere else — the pay line on every job posting reads
  "60.000 € / Jahr" whatever the locale. English convention would put the
  symbol first; two spellings of money on one site cost more than one slightly
  un-English one. An unknown currency keeps its ISO code, which reads correctly
  in the same arrangement ("300.000 CHF").
  """
  def minimum_text do
    case minimum() do
      %{amount: amount, currency: currency} ->
        # A non-breaking space: the amount must not be split from its symbol
        # across a line break.
        UI.delimited_count(amount) <> " " <> Salary.currency_symbol(currency)

      nil ->
        nil
    end
  end

  @doc """
  `minimum_reason/0` with the amount filled in, for the agent formats, which
  have nowhere to put a placeholder. `nil` where nothing is being raised.
  """
  def minimum_sentence do
    if amount = minimum_text() do
      String.replace(minimum_reason(), "{amount}", amount)
    end
  end

  @doc """
  `transparency_note/0` with the NodeInfo URL filled in, for the agent formats.
  """
  def transparency_sentence do
    String.replace(transparency_note(), "{nodeinfo}", AgentDocs.abs_url("/system/nodeinfo/2.1"))
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
  The smallest investment worth a conversation as `%{amount:, currency:}`, or
  `nil` where this installation is raising nothing (`INVESTOR_MINIMUM=0`).

  An amount and a currency code rather than a ready-made string, so the page
  can group the digits the way the reader's own locale does.
  """
  def minimum do
    amount = Application.get_env(:vutuv, :investor_minimum, 0)

    if is_integer(amount) and amount > 0 do
      %{amount: amount, currency: currency()}
    end
  end

  # An empty string is a configured value, so `||` does not catch it, and an
  # empty symbol would leave the amount trailing a stray space.
  defp currency do
    case Application.get_env(:vutuv, :investor_currency) do
      code when is_binary(code) and code != "" -> code
      _blank -> "EUR"
    end
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
        url: Application.fetch_env!(:vutuv, :operator_url)
      },
      case_points: case_points(),
      minimum: minimum(),
      # The finished sentences, not the `{amount}` / `{nodeinfo}` placeholder
      # forms: only the HTML has somewhere to put a placeholder, and a JSON
      # reader handed one would have to know our template's private convention.
      minimum_reason: minimum_sentence(),
      counter_explainer: counter_explainer(),
      transparency_note: transparency_sentence(),
      contact_note: contact_note(),
      contact_handle: handle,
      contact_url: handle && AgentDocs.abs_url("/messages/with/" <> handle),
      growth_sentence: growth_sentence(facts.growth),
      # The daily rows themselves are the chart's business; the doc carries the
      # reading of them.
      figures: Map.drop(facts, [:series, :growth]),
      media_kit_url: AgentDocs.abs_url("/system/media-kit"),
      nodeinfo_url: AgentDocs.abs_url("/system/nodeinfo/2.1")
    })
  end
end
