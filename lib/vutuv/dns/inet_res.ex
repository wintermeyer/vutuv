defmodule Vutuv.Dns.InetRes do
  @moduledoc """
  The production `Vutuv.Dns.Backend`, built on Erlang's own `:inet_res`. Every
  call answers with data or an error and never raises, because a name server is
  a third party and half of what it does is fail.
  """

  @behaviour Vutuv.Dns.Backend

  require Logger

  # A single query. Short on purpose: a verification click waits on this, and a
  # name server that needs longer than two seconds is one we ask again later.
  @timeout 2_000

  @impl true
  def lookup(name, type) do
    :inet_res.lookup(to_charlist(name), :in, type, timeout: @timeout)
  rescue
    _ -> []
  catch
    _, _ -> []
  end

  @impl true
  def txt_at(name, nameservers) do
    case :inet_res.resolve(to_charlist(name), :in, :txt,
           nameservers: nameservers,
           timeout: @timeout
         ) do
      {:ok, message} ->
        answer(message)

      # The name does not exist, said by the server that owns the zone. That is
      # a real answer, not a failure, so it must not send us back to the cache.
      {:error, {:nxdomain, _message}} ->
        {:ok, []}

      {:error, :nxdomain} ->
        {:ok, []}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    error ->
      Logger.debug("authoritative TXT query for #{name} failed: #{inspect(error)}")
      {:error, :exception}
  catch
    _, _ -> {:error, :exception}
  end

  # Only an answer carrying the `aa` bit is worth having: without it we are
  # holding a referral or a recursive server's cached copy, which is the very
  # thing this whole path exists to bypass.
  defp answer(message) do
    if message |> :inet_dns.msg(:header) |> :inet_dns.header(:aa) do
      records =
        message
        |> :inet_dns.msg(:anlist)
        |> Enum.filter(&(:inet_dns.rr(&1, :type) == :txt))
        |> Enum.map(&:inet_dns.rr(&1, :data))

      {:ok, records}
    else
      {:error, :not_authoritative}
    end
  end
end
