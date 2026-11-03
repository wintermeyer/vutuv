defmodule Vutuv.Profiles.OrcidImport do
  @moduledoc """
  "Import from ORCID" on the publications editor (issue #2383): the works a
  member's own public ORCID record lists, offered as publication candidates
  the way the LinkedIn import offers its archive — a preview with a box per
  entry, duplicates unticked, then one transaction that inserts the picks.

  The record is the one behind the member's listed ORCID account
  (`Vutuv.Profiles.SocialMediaAccount`, provider `"ORCID"`); nobody can import
  from a record they have not put on their profile. Whether the account is
  *verified* is deliberately not required: the works land on the importing
  member's own profile, so the worst a wrong iD can do is fill their own list
  with a stranger's papers, which the preview shows them before anything is
  written.

  Gated by `:import_orcid_works` (env `IMPORT_ORCID_WORKS=false`), the
  outbound-call switch for installations that must not reach pub.orcid.org.
  The dedup rule is `Publication.dedup_key/1`, shared with the LinkedIn
  import: a paper already on the profile under the same title is skipped,
  here and on a re-import.
  """

  import Ecto.Query

  alias Vutuv.Accounts.User
  alias Vutuv.Orcid
  alias Vutuv.Profiles.Publication
  alias Vutuv.Profiles.SocialMediaAccount
  alias Vutuv.Repo

  @doc "Whether the import is switched on for this installation."
  def enabled?, do: Orcid.works_enabled?()

  @doc "The member's listed ORCID account, or nil."
  def account(%User{id: user_id}) do
    Repo.one(
      from(a in SocialMediaAccount,
        where: a.user_id == ^user_id and a.provider == "ORCID",
        limit: 1
      )
    )
  end

  @doc """
  What the publications editor may offer: `:available` (switched on and the
  member lists an ORCID iD), `:no_account` (switched on, nothing to read from
  yet), `:disabled`.
  """
  def offer(%User{} = user) do
    cond do
      not enabled?() -> :disabled
      is_nil(account(user)) -> :no_account
      true -> :available
    end
  end

  @doc """
  The record's works as candidates, newest first, each marked `duplicate?`
  (already on the profile under the same title) and `select?` (ticked in the
  preview — everything that is not a duplicate).

  `{:error, :disabled | :no_account | :gone | :transient}` otherwise; `:gone`
  is a record the API does not know or has deactivated, `:transient` an API
  that could not be asked — try again, not a verdict.
  """
  def candidates(%User{} = user) do
    case offer(user) do
      :available -> fetch_candidates(user, account(user).value)
      :no_account -> {:error, :no_account}
      :disabled -> {:error, :disabled}
    end
  end

  defp fetch_candidates(user, id) do
    with {:ok, works} <- Orcid.fetch_works(id) do
      existing = existing_keys(user)

      candidates =
        works
        |> Enum.map(&candidate/1)
        |> Enum.reject(&is_nil(&1.key))
        # ORCID groups by identifier, so the same paper under two DOIs (a
        # preprint and the article) is two groups; here it is one title.
        |> Enum.uniq_by(& &1.key)
        |> Enum.map(fn c ->
          duplicate? = MapSet.member?(existing, c.key)
          Map.merge(c, %{duplicate?: duplicate?, select?: not duplicate?})
        end)

      {:ok, candidates}
    end
  end

  defp candidate(work) do
    key = Publication.dedup_key(work.title)

    %{
      id: "orcid_" <> Integer.to_string(:erlang.phash2({:orcid, key})),
      key: key,
      title: work.title,
      facts: facts(work),
      type: work.type,
      params: %{
        "title" => work.title,
        "authors" => work.authors,
        "publisher" => work.publisher,
        "published_year" => work.published_year,
        "published_month" => work.published_month,
        "url" => work.url
      }
    }
  end

  # "Fenner, M. · Nature · 2019": what the preview row says beside the title.
  defp facts(work) do
    [work.authors, work.publisher, work.published_year && Integer.to_string(work.published_year)]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" · ")
  end

  @doc "The candidates as the hidden payload the confirm step reads back."
  def payload_map(candidates), do: Enum.map(candidates, &Map.take(&1, [:id, :params]))

  @doc """
  Rebuilds the selection from the decoded payload (string keys) and the
  checkbox ids the member submitted. The payload is client-controlled, but
  every insert goes through the owner-scoped `Publication.changeset/2`, so a
  tampered payload can only ever add entries to the member's own profile —
  exactly what the new-publication form already allows.
  """
  def selection_from_payload(payload, selected) when is_list(payload) and is_list(selected) do
    set = MapSet.new(selected)

    for %{"id" => id, "params" => %{} = params} <- payload,
        MapSet.member?(set, id),
        do: %{params: params}
  end

  def selection_from_payload(_payload, _selected), do: []

  @doc """
  Inserts the selected candidates for `user` in one transaction, skipping
  anything already on the profile under the same title (so a re-import never
  doubles a row). Returns `{:ok, %{created: n, skipped: n, blocked: n}}`:
  `skipped` is "you already have this", `blocked` is "could not be added" (a
  value the changeset refused).
  """
  def apply_selection(%User{} = user, selection) when is_list(selection) do
    Repo.transaction(fn ->
      {_seen, tally} =
        Enum.reduce(selection, {existing_keys(user), %{created: 0, skipped: 0, blocked: 0}}, fn
          %{params: params}, {seen, tally} ->
            insert_one(user, params, seen, tally)
        end)

      tally
    end)
  end

  defp insert_one(user, params, seen, tally) do
    key = Publication.dedup_key(params["title"])

    if is_nil(key) or MapSet.member?(seen, key) do
      {seen, Map.update!(tally, :skipped, &(&1 + 1))}
    else
      changeset = user |> Ecto.build_assoc(:publications) |> Publication.changeset(params)

      case Repo.insert(changeset) do
        {:ok, _publication} -> {MapSet.put(seen, key), Map.update!(tally, :created, &(&1 + 1))}
        {:error, _changeset} -> {seen, Map.update!(tally, :blocked, &(&1 + 1))}
      end
    end
  end

  defp existing_keys(%User{id: user_id}) do
    from(p in Publication, where: p.user_id == ^user_id, select: p.title)
    |> Repo.all()
    |> Enum.map(&Publication.dedup_key/1)
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
  end
end
