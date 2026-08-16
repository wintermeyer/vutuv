defmodule VutuvWeb.AgentDocs.InvestorsDoc do
  @moduledoc """
  The `/system/investors` page as a data map for the agent formats, and the
  owner of every figure that page states.

  `facts/0` is queried once per request and handed to both the template and the
  doc, so the HTML and its `.md`/`.txt`/`.json`/`.xml` siblings cannot disagree
  about a number — the drift the whole `VutuvWeb.AgentDocs` system exists to
  prevent, and doubly worth it here, where the numbers are the argument.

  Nothing here is translated: the page is English only in every locale (see
  `VutuvWeb.CompanyController`).
  """

  alias Vutuv.Ads
  alias Vutuv.Fediverse
  alias Vutuv.NodeInfo
  alias Vutuv.PeopleHistory
  alias VutuvWeb.AgentDocs

  # LinkedIn's own newsroom, read 2026-08-15. Quoted rather than estimated, and
  # dated, because the whole cost argument rests on this being checkable: the
  # page states "more than 17,000 full-time employees" and "+1.3B Members".
  @linkedin_source "https://news.linkedin.com/about-us"
  @linkedin_employees "17,000+"
  @linkedin_members "1.3 billion+"

  @doc "The public figures the investor page quotes, read live."
  def facts do
    usage = NodeInfo.usage()

    %{
      members: usage.users.total,
      active_month: usage.users.active_month,
      active_halfyear: usage.users.active_halfyear,
      posts: usage.local_posts,
      replies: usage.local_comments,
      fediverse_accounts: Fediverse.distinct_follower_count(),
      fediverse_servers: Fediverse.follower_host_count()
    }
  end

  @doc "What LinkedIn's own newsroom reports, with the source that says it."
  def linkedin do
    %{employees: @linkedin_employees, members: @linkedin_members, source: @linkedin_source}
  end

  @doc "The one-line answer to what vutuv is, the same one the page opens with."
  def positioning do
    "An alternative to LinkedIn: a professional profile, a CV, the people you work " <>
      "with and the posts they write, with quieter manners and a cost base that lets " <>
      "us keep them."
  end

  @doc """
  The gated-community contrast, the argument the page leads with after the
  positioning line. Kept here so the agent formats carry it too.

  Both LinkedIn observations were checked against the live site on 2026-08-15
  from an anonymous client, and both are the kind of claim a reader can repeat
  in one command.
  """
  def openness do
    %{
      linkedin:
        "Anonymous requests are gated: /feed/ answers 302 to the sign-in form, and a " <>
          "public profile loads as a teaser behind \"Sign in to view … full profile\". " <>
          "Checked 2026-08-15.",
      vutuv:
        "A profile is a whole public web page at a stable address: work history, " <>
          "qualifications, contacts and posts, readable with no account, with " <>
          "Markdown/text/JSON/XML siblings, an RSS feed and an ActivityPub actor. The " <>
          "personal timeline sits behind a login on both sides.",
      why_it_matters:
        "Acquisition cost: every profile is a public page that search engines index " <>
          "and language models read, so the network is its own front door."
    }
  end

  @doc """
  Where an investor writes to. The operator-notice recipient rather than a
  literal address, so a third-party installation names its own operator and
  never ours.
  """
  def contact_email do
    {_name, email} = Application.fetch_env!(:vutuv, :operator_recipient)
    email
  end

  @doc "The /system/investors page as a doc map."
  def build(facts, series) do
    growth = PeopleHistory.growth(series)

    AgentDocs.doc_meta("investors", "/system/investors")
    |> Map.merge(%{
      title: "Investors",
      description:
        "vutuv is an alternative to LinkedIn: the same job, quieter manners, and a cost " <>
          "base that lets us keep them.",
      language: "en",
      positioning: positioning(),
      openness: openness(),
      operator: %{
        name: Application.fetch_env!(:vutuv, :operator_name),
        url: Application.fetch_env!(:vutuv, :operator_url)
      },
      contact: contact_email(),
      figures: facts,
      growth:
        growth && %{growth | from: Date.to_iso8601(growth.from), to: Date.to_iso8601(growth.to)},
      history:
        Enum.map(series, fn snapshot ->
          %{
            day: Date.to_iso8601(snapshot.day),
            members: snapshot.members,
            fediverse_accounts: snapshot.fediverse_accounts
          }
        end),
      comparison: linkedin(),
      business_model: "Advertising: one text-only ad per calendar day.",
      # nil where the ad system is switched off, because `/ads` 404s then and a
      # doc that names a missing page is worse than one that stays quiet.
      business_model_url: Ads.enabled?() && AgentDocs.abs_url("/ads"),
      media_kit_url: AgentDocs.abs_url("/system/media-kit")
    })
  end
end
