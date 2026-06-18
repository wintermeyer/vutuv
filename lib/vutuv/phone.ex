defmodule Vutuv.Phone do
  @moduledoc """
  Phone-number presentation helpers built on `ExPhoneNumber`, a port of
  Google's libphonenumber.

  Stored numbers are free-form strings (`Vutuv.Profiles.PhoneNumber` only
  loosely validates the shape), so every function here tolerates anything: an
  unparseable value falls back to the original text for display and to a
  digit-stripped target for the `tel:` link.
  """

  # Numbers are stored by a mostly-German userbase; this is the region used to
  # interpret a value typed without an international `+` prefix.
  @default_region "DE"
  @german_country_code 49

  @doc """
  The number as it should be *shown* to a viewer using `locale`.

  Only German viewers (`"de"`) and only German numbers (`+49…`) are rewritten:
  they render in national format, which drops the `+49` in favour of the
  leading `0` trunk code (`"+49 261 9886803"` -> `"0261 9886803"`). Every other
  case (a non-German viewer, a foreign number, or an unparseable value) returns
  the stored value unchanged, so we never strip the country code off a foreign
  number such as `+421…` or `+41…`.
  """
  def national(value, locale)

  def national(value, "de") when is_binary(value) do
    case parse(value) do
      {:ok, %{country_code: @german_country_code} = number} ->
        if ExPhoneNumber.is_valid_number?(number) do
          ExPhoneNumber.format(number, :national)
        else
          value
        end

      _ ->
        value
    end
  end

  def national(value, _locale), do: value

  @doc """
  Canonicalises a typed phone number for storage, or rejects it.

  Parses `value` against the default region (`#{@default_region}`) and, **only**
  when it is a number libphonenumber recognises as *valid* (the right length and
  pattern for its region, so junk like `"12"` or `"not a phone"` never passes),
  returns `{:ok, formatted}` in international format: a German local number such
  as `"0261-123456"` becomes `{:ok, "+49 261 123456"}`. A foreign number keeps
  its own country code (`"+421903419345"` -> `{:ok, "+421 903 419 345"}`), so we
  never reinterpret it as German. Anything unparseable or not a valid number
  returns `:error`, so `Vutuv.Profiles.PhoneNumber.changeset/2` can refuse it.
  """
  def normalize(value) when is_binary(value) do
    with {:ok, number} <- parse(value),
         true <- ExPhoneNumber.is_valid_number?(number) do
      {:ok, ExPhoneNumber.format(number, :international)}
    else
      _ -> :error
    end
  rescue
    _ -> :error
  end

  @doc """
  The `tel:` target for a number: the canonical E.164 form (`+492619886803`)
  whenever the value parses, otherwise a digit-stripped fallback that keeps a
  leading `+`. `tel:` URIs must carry no spaces or punctuation.
  """
  def tel(value) when is_binary(value) do
    case parse(value) do
      {:ok, number} -> ExPhoneNumber.format(number, :e164)
      _ -> String.replace(value, ~r/(?!^\+)[^\d]/, "")
    end
  end

  # ExPhoneNumber.parse/2 returns {:error, _} for clearly-bad input; wrap it so
  # any unexpected raise on exotic input also degrades to the fallback path.
  defp parse(value) do
    ExPhoneNumber.parse(value, @default_region)
  rescue
    _ -> {:error, :unparseable}
  end
end
