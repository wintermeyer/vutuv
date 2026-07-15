defmodule Vutuv.EmailDomain do
  @moduledoc """
  Shared email-domain helpers for the exclusion lists (issues #938 + #939).

  One place owns the "bare hostname" shape, the paste-forgiving normalizer and
  the host-suffix rule (`example.com` also matches `eu.example.com`), so a
  member's own exclusion list (`Vutuv.Accounts.ViewerExclusion`) and a job
  posting's / organization's exclusion list (`Vutuv.Jobs.JobExclusion`) can
  never drift on what a domain means.
  """

  # A bare hostname: lowercase labels of letters/digits/hyphens, at least two
  # labels (one dot), each label 1-63 chars, whole name <= 253. No scheme, no
  # path, no `@` — those are stripped by `normalize/1` before validation.
  @format ~r/^(?=.{1,253}$)[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$/

  @doc "The bare-hostname format regex."
  def format, do: @format

  @doc """
  Be forgiving about what the member pastes: a full URL, a `user@host` address
  or a stray space should still resolve to the bare host, so the editor accepts
  the common shapes and the format validation only rejects what genuinely is not
  a domain.
  """
  def normalize(nil), do: nil

  def normalize(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r{^[a-z][a-z0-9+.-]*://}, "")
    |> String.split("/", parts: 2)
    |> List.first()
    |> String.split("@")
    |> List.last()
    |> String.trim(".")
  end

  @doc """
  The lowercase host of an email address (everything after the last `@`), or
  `nil` when there is none. Used to resolve a viewer's confirmed-email hosts.
  """
  def host_of(nil), do: nil

  def host_of(email) when is_binary(email) do
    case email |> String.trim() |> String.downcase() |> String.split("@") do
      [_local, host | _] when host != "" -> host
      _ -> nil
    end
  end
end
