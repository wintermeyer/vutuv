defmodule Vutuv.Fediverse.BlockedInstance do
  @moduledoc """
  A remote server the operator has shut out (issue #1067).

  Anyone can run an ActivityPub server, so a server that talks to us is not a
  vetted party. A row here means: drop everything that host sends before it is
  verified or stored, and keep nothing of what it sent before. The blocklist is
  per-installation content, edited at `/admin/fediverse` — never a source edit.

  `host` is stored as a bare, lowercased hostname. Admins paste all sorts of
  things (`https://mastodon.example/users/bob`, `@bob@Mastodon.Example`), so
  `normalize_host/1` is the one place that turns any of them — and every actor
  URI the inbox checks — into the hostname the two are compared on.
  """

  use VutuvWeb, :model

  # Hostnames max out at 253 characters; the column is the usual varchar(255).
  @max_host 253
  @max_reason 255

  # A real server name: dot-separated labels of letters, digits and hyphens.
  # Deliberately strict — a blocklist entry that can never match anything (an
  # IP literal, "localhost", a typo with a slash left in) is worse than an
  # error, because it reads as protection that isn't there.
  @host_format ~r/\A[a-z0-9]([a-z0-9\-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9\-]*[a-z0-9])?)+\z/

  schema "fediverse_blocked_instances" do
    field(:host, :string)
    field(:reason, :string)

    belongs_to(:blocked_by, Vutuv.Accounts.User)

    timestamps()
  end

  def changeset(%__MODULE__{} = blocked, attrs) do
    blocked
    |> cast(attrs, [:host, :reason])
    |> update_change(:host, &normalize_host/1)
    |> validate_required([:host])
    |> validate_length(:host, max: @max_host)
    |> validate_length(:reason, max: @max_reason)
    |> validate_format(:host, @host_format, message: "is not a server name")
    |> unique_constraint(:host)
  end

  @doc """
  The bare, lowercased hostname behind whatever is offered: a full actor URL, a
  `@user@host` handle, a host with a port, or the plain hostname. Returns `nil`
  when nothing host-shaped is left, so callers can treat "unparseable" and
  "absent" the same way.
  """
  def normalize_host(value) when is_binary(value) do
    trimmed = value |> String.trim() |> String.downcase()

    # URI.parse only finds an authority behind a scheme, so give a bare host or
    # a handle one. It then does the rest: strips userinfo, port, path, query.
    candidate = if String.contains?(trimmed, "://"), do: trimmed, else: "https://" <> trimmed

    case URI.parse(candidate) do
      %URI{host: host} when is_binary(host) ->
        host |> String.trim_trailing(".") |> nil_if_empty()

      _ ->
        nil
    end
  end

  def normalize_host(_), do: nil

  defp nil_if_empty(""), do: nil
  defp nil_if_empty(value), do: value
end
