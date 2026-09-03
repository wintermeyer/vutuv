defmodule Vutuv.Welcome do
  @moduledoc """
  The accounts a brand-new member is offered to follow, on the last step of the
  welcome window (`VutuvWeb.WelcomeComponents.welcome_modal/1`).

  A fresh account follows nobody, so its feed is empty and stays empty until
  the member goes looking — and "find people to follow" is a chore, while three
  named accounts are one tick each. Which accounts is **per installation and
  per locale**: `config :vutuv, :welcome_suggestions` maps a locale to a list of
  fediverse addresses, `WELCOME_SUGGESTIONS` overrides it at boot, and a locale
  with no list gets no third step at all. Today only German has one, which is
  what makes the window three steps for a German visitor and two for everyone
  else.

  Two address spellings, and each becomes the follow it actually is:

    * `@name` — a **member on this installation**. Resolved against the local
      username and followed with `Vutuv.Fediverse.follow_local_member/2`, and
      dropped from the list when nobody here is called that, so the shipped
      default (`@wintermeyer`) costs another installation nothing.
    * `@name@host` — an account **somewhere else**, followed over ActivityPub
      with `Vutuv.Fediverse.follow_remote/2`. Offered **only to a member who
      has a fediverse of their own**: without their sign-up opt-in, or on an
      installation with federation switched off, the `Follow` could never
      leave, so the step lists none of them rather than offering a tick that
      does nothing.

  Nothing here is trusted from the form: `follow_suggested/2` intersects what
  was submitted with what is configured *and* resolves it again, so neither an
  address nobody configured nor a remote one a member was never offered can
  make this server send a `Follow`.
  """

  alias Vutuv.Accounts
  alias Vutuv.Accounts.User
  alias Vutuv.Fediverse
  alias Vutuv.Fediverse.RemoteAccount
  alias Vutuv.Fediverse.RemoteFollow
  alias Vutuv.Identity
  alias Vutuv.Repo

  import Ecto.Query

  # One suggestion as the window shows it: what to call the account, the
  # address the checkbox posts back, and either a member struct (for the
  # avatar) or the remote account we already hold, if we hold it.
  defstruct [:address, :name, :handle, :user, :remote_account]

  @type t :: %__MODULE__{}

  # The two questions every member is asked, in order. The suggested accounts
  # are a third step only where there is anything to suggest.
  @questions [:location, :job]

  @doc """
  Everything a render of the window needs: `%{steps: [...], suggestions: [...]}`.

  One call, because the two answers come from one resolution — the step list
  *is* "the questions, plus the accounts step if any resolved". Asking for them
  separately meant resolving twice per render, and two places deciding how many
  steps there are.

  Resolved rather than merely configured, so a step that would open on an empty
  list never exists — and the "Schritt 1 von N" the member reads is the number
  of steps they will actually be shown.
  """
  def window(%User{} = user, locale) do
    case suggested_accounts(user, locale) do
      [] -> %{steps: @questions, suggestions: []}
      accounts -> %{steps: @questions ++ [:accounts], suggestions: accounts}
    end
  end

  @doc "Just the step list — see `window/2`."
  def steps(%User{} = user, locale), do: window(user, locale).steps

  @doc """
  The step after `step`, or `:done` when that was the last one.

  **The window only goes forward.** There is no way back to a step, which is
  why each one saves as it is left: what the member typed is theirs from the
  moment they press Weiter, not from the moment they reach the end.
  """
  def next_step(steps, step) do
    case Enum.drop_while(steps, &(&1 != step)) do
      [^step, next | _rest] -> next
      _last_or_unknown -> :done
    end
  end

  @doc """
  The step a session's stored value names, defaulting to the first one.

  A stored step that this member no longer has (the accounts step in a locale
  that lost its list) falls back to the first, rather than leaving the window
  with nothing to render.
  """
  def current_step(steps, stored) do
    if stored in steps, do: stored, else: hd(steps)
  end

  @doc """
  The suggestions `user` can be offered in `locale`, resolved and filtered.

  Empty for a locale with no configured list, for an installation that cleared
  the config, and — for the remote half — for a member who does not federate.
  An empty answer is what makes the window two steps instead of three.
  """
  def suggested_accounts(%User{} = user, locale) when is_binary(locale) do
    locale
    |> configured()
    |> Enum.map(&resolve(&1, user))
    |> Enum.reject(&is_nil/1)
    |> load_remote_accounts()
  end

  @doc """
  Follows the suggestions `user` ticked.

  `addresses` comes from the form, so it is intersected with the configured
  lists of **every** locale first — the render locale and the submit locale can
  differ, and an address nobody configured is never followed whatever it says.

  Each follow is one network round trip (`Vutuv.Fediverse.follow_remote/2`:
  WebFinger, the actor document, then the signed `Follow`), so they run
  concurrently and under a deadline. A failure is dropped on purpose: the
  welcome questions are finished either way, and an account that did not take
  is one the member can still follow from its own page. Returns the number that
  went through.
  """
  def follow_suggested(%User{} = user, addresses) when is_list(addresses) do
    allowed = configured_addresses()

    addresses
    |> Enum.filter(&(&1 in allowed))
    |> Enum.uniq()
    |> Enum.map(&resolve(&1, user))
    |> Enum.reject(&is_nil/1)
    |> Task.async_stream(&follow(user, &1),
      max_concurrency: 4,
      timeout: 8_000,
      on_timeout: :kill_task,
      ordered: false
    )
    |> Enum.count(&match?({:ok, {:ok, _followed}}, &1))
  end

  def follow_suggested(%User{}, _addresses), do: 0

  # Resolving before following does two things beyond finding the account. It
  # re-applies the filter on the WRITE path, so a member with no fediverse
  # cannot follow a remote suggestion by posting its address even though the
  # step never offered it. And it keeps a member on this installation off the
  # address route entirely: `follow_remote/2` would have to parse
  # `@name@<our host>` and hand it back to us, and `Endpoint.host/0` is
  # "localhost" in dev and test, which no address parser accepts — so the
  # shipped `@wintermeyer` suggestion would have worked in production and
  # nowhere else.
  defp follow(%User{} = user, %__MODULE__{user: %User{} = member}),
    do: Fediverse.follow_local_member(user, member)

  defp follow(%User{} = user, %__MODULE__{address: address}),
    do: Fediverse.follow_remote(user, address)

  @doc """
  The name to show for a suggestion: the member's or the remote account's
  display name where we have one, else the name part of the address — a
  suggestion we have never seen before still reads as "tagesschau" rather than
  as a machine address.
  """
  def label(%__MODULE__{name: name}) when is_binary(name) and name != "", do: name

  def label(%__MODULE__{handle: handle}),
    do: handle |> String.trim_leading("@") |> String.split("@") |> hd()

  defp configured(locale) do
    :vutuv
    |> Application.get_env(:welcome_suggestions, %{})
    |> Map.get(locale, [])
  end

  defp configured_addresses do
    :vutuv
    |> Application.get_env(:welcome_suggestions, %{})
    |> Map.values()
    |> List.flatten()
  end

  defp resolve("@" <> name = address, user) do
    case String.split(name, "@", parts: 2) do
      [username] -> local_suggestion(address, username)
      [_name, host] -> remote_suggestion(address, host, user)
    end
  end

  defp resolve(_malformed, _user), do: nil

  defp local_suggestion(address, username) do
    case Accounts.get_user_by_username(String.downcase(username)) do
      %User{} = member ->
        %__MODULE__{
          address: address,
          name: Identity.display_name(member),
          handle: "@" <> member.username,
          user: member
        }

      nil ->
        nil
    end
  end

  # A member on our own host written the long way is the same local member;
  # anything else needs both the installation switch and this member's own
  # participation, or the Follow could never leave.
  defp remote_suggestion(address, host, user) do
    cond do
      Fediverse.local_host?(host) ->
        [_at, username | _rest] = String.split(address, "@")
        local_suggestion(address, username)

      Fediverse.enabled?() and Fediverse.federated?(user) ->
        %__MODULE__{address: address, handle: address}

      true ->
        nil
    end
  end

  # One query for every remote suggestion, so the window's third step costs a
  # lookup per kind rather than per account. An account we have never seen
  # stays nameless and pictureless, which is honest: the handle is all we know
  # about it until somebody follows it.
  defp load_remote_accounts(suggestions) do
    pairs =
      for %__MODULE__{user: nil, handle: handle} <- suggestions,
          {:ok, {name, host}} <- [RemoteFollow.parse_address(handle)],
          do: {String.downcase(name), String.downcase(host)}

    accounts = remote_accounts_by_pair(pairs)

    Enum.map(suggestions, fn
      %__MODULE__{user: nil, handle: handle} = suggestion ->
        with {:ok, {name, host}} <- RemoteFollow.parse_address(handle),
             %RemoteAccount{} = account <-
               Map.get(accounts, {String.downcase(name), String.downcase(host)}) do
          %{
            suggestion
            | remote_account: account,
              name: RemoteAccount.display_name(account)
          }
        else
          _none -> suggestion
        end

      suggestion ->
        suggestion
    end)
  end

  defp remote_accounts_by_pair([]), do: %{}

  defp remote_accounts_by_pair(pairs) do
    {handles, hosts} = Enum.unzip(pairs)

    RemoteAccount
    |> where([a], fragment("lower(?)", a.handle) in ^handles)
    |> where([a], fragment("lower(?)", a.host) in ^hosts)
    |> Repo.all()
    |> Map.new(&{{String.downcase(&1.handle || ""), String.downcase(&1.host)}, &1})
  end
end
