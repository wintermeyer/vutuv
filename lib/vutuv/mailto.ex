defmodule Vutuv.Mailto do
  @moduledoc """
  Builds a `mailto:` URL, so the one rule that is easy to get wrong is written
  down once.

  **A `mailto:` query is percent-encoded, never form-encoded** (RFC 6068): a
  `+` there is a literal plus sign and not a space. `URI.encode_query/1` and
  `URI.encode_www_form/1` produce exactly that plus, so a subject built with
  them reaches the reader as `Bewerbung:+Senior+Elixir+Developer` in every mail
  client that follows the spec — which is most of them, Apple Mail and
  Thunderbird included. Some webmail handlers read the `+` as a space anyway,
  which is why the mistake survives being looked at.

  It has one home because it had four: the job board's apply button, the
  unsubscribe fallback, the operator contact on the error pages, and the media
  kit's press address.
  """

  @doc """
  `mailto:address`, with an optional prefilled subject.

  The subject is plain text, not a pre-encoded string: encoding is this
  function's job and doing it twice would show the reader the `%20`.
  """
  def to(address, subject \\ nil)

  def to(address, nil) when is_binary(address), do: "mailto:" <> address

  def to(address, subject) when is_binary(address) and is_binary(subject),
    do: to(address) <> "?subject=" <> URI.encode(subject, &URI.char_unreserved?/1)
end
