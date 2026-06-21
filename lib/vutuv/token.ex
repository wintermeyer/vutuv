defmodule Vutuv.Token do
  @moduledoc """
  The one place the app's opaque secret tokens are minted and hashed. The
  per-session login token (`Vutuv.Sessions`) and the API tokens, OAuth codes and
  client / webhook secrets (`Vutuv.ApiAuth` and friends) all share this shape:
  only the SHA-256 of a token is ever stored, and the raw token is shown or sent
  exactly once.

  `random_token/1` is base32 (strictly alphanumeric, so it double-click selects):
  32 random bytes -> 52 characters, ~165 bits of entropy.

  Security-sensitive: keep both functions byte-identical — every hash already in
  the database was computed with exactly this encoding.
  """

  @doc "Lowercase-hex SHA-256 of `plaintext` — the stored form of a token."
  def hash_token(plaintext) do
    :sha256 |> :crypto.hash(plaintext) |> Base.encode16(case: :lower)
  end

  @doc "A random opaque token: `bytes` (default 32) of entropy, lowercase base32, unpadded."
  def random_token(bytes \\ 32) do
    bytes |> :crypto.strong_rand_bytes() |> Base.encode32(case: :lower, padding: false)
  end
end
