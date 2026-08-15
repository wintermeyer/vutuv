defmodule Vutuv.Dns.Backend do
  @moduledoc """
  The two DNS primitives `Vutuv.Dns` needs, behind a behaviour so tests can
  answer them from their own data instead of the network.
  """

  @doc "A plain recursive lookup through the configured resolver."
  @callback lookup(name :: String.t(), type :: :ns | :a | :aaaa | :txt) :: [term()]

  @doc """
  A TXT query sent straight to the given name servers. `{:ok, records}` only for
  an **authoritative** answer (the `aa` bit set); anything else is an error, so
  the caller can move on to the next server rather than trust a referral.
  """
  @callback txt_at(name :: String.t(), nameservers :: [{:inet.ip_address(), 1..65_535}]) ::
              {:ok, [[charlist()]]} | {:error, term()}
end
