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

  alias Vutuv.Accounts
  alias Vutuv.Accounts.User
  alias Vutuv.Fediverse
  alias Vutuv.NodeInfo
  alias VutuvWeb.AgentDocs
  alias VutuvWeb.Endpoint

  @doc "The public figures the investor page quotes, read live."
  def facts do
    usage = NodeInfo.usage()
    reach = Fediverse.follower_reach()

    %{
      members: usage.users.total,
      active_month: usage.users.active_month,
      active_halfyear: usage.users.active_halfyear,
      posts: usage.local_posts,
      replies: usage.local_comments,
      fediverse_accounts: reach.accounts,
      fediverse_servers: reach.hosts
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
      {"Members", facts.members},
      {"Active this month", facts.active_month},
      {"Active this half year", facts.active_halfyear},
      {"Posts", facts.posts},
      {"Replies", facts.replies},
      {"Fediverse accounts", facts.fediverse_accounts},
      {"Fediverse servers", facts.fediverse_servers}
    ]
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

  @doc """
  That person's profile on this installation, where the rest of their contact
  details live (phone, messengers, other addresses), or `nil`.

  Built from `:operator_handle` on **this** installation's own host, and
  returned only once the handle really resolves to a member here. That is what
  makes the vutuv.de default safe to ship: an installation that has no such
  member renders no link instead of pointing a reader at a stranger's profile
  on somebody else's site, and nobody can leave a dead link behind by renaming
  their handle.
  """
  def contact_profile_url do
    handle = Application.get_env(:vutuv, :operator_handle) || ""

    with true <- handle != "",
         %User{username: username} <- Accounts.get_user_by_username(handle) do
      Endpoint.url() <> "/" <> username
    else
      _ -> nil
    end
  end

  @doc """
  The /system/investors page as a doc map: the contact and the figures, which
  is everything the page itself shows.
  """
  def build(facts) do
    AgentDocs.doc_meta("investors", "/system/investors")
    |> Map.merge(%{
      title: "Investors",
      description: "Who to contact about investing in vutuv, and where the network stands.",
      language: "en",
      operator: %{
        name: Application.fetch_env!(:vutuv, :operator_name),
        url: Application.fetch_env!(:vutuv, :operator_url)
      },
      contact: contact_email(),
      contact_profile_url: contact_profile_url(),
      figures: facts,
      media_kit_url: AgentDocs.abs_url("/system/media-kit")
    })
  end
end
