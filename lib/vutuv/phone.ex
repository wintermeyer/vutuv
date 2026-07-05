defmodule Vutuv.Phone do
  @moduledoc """
  Phone-number presentation helpers built on `ExPhoneNumber`, a port of
  Google's libphonenumber.

  Stored numbers are free-form strings (`Vutuv.Profiles.PhoneNumber` only
  loosely validates the shape), so every function here tolerates anything: an
  unparseable value falls back to the original text for display and to a
  digit-stripped target for the `tel:` link.
  """

  alias ExPhoneNumber.Metadata
  alias Vutuv.Cldr.Territory

  # Numbers are stored by a mostly-German userbase; this is the region used to
  # interpret a value typed without an international `+` prefix.
  @default_region "DE"
  @german_country_code 49

  @doc """
  The number as it should be *shown* to a viewer using `locale`.

  German viewers (`"de"`) see German numbers (`+49…`) in national format, which
  drops the `+49` in favour of the leading `0` trunk code (`"+49 261 9886803"`
  -> `"0261 9886803"`). Every other displayed number keeps its international
  `+country` prefix but is grouped with spaces (`"+447840875616"` ->
  `"+44 7840 875616"`), so a foreign number, or any number shown to a non-German
  viewer, reads cleanly instead of running together. A country code is never
  stripped off a foreign number such as `+421…` or `+41…`; an unparseable or
  invalid value returns the stored text unchanged.
  """
  def national(value, locale)

  def national(value, "de") when is_binary(value) do
    case parse(value) do
      {:ok, %{country_code: @german_country_code} = number} ->
        format_valid(number, :national, value)

      {:ok, number} ->
        format_valid(number, :international, value)

      _ ->
        value
    end
  end

  def national(value, _locale) when is_binary(value), do: display(value)

  def national(value, _locale), do: value

  @doc """
  The number in a readable, **locale-independent** form: canonical international
  format (`"+44 7840 875616"`) whenever it parses as a valid number, else the
  stored text unchanged.

  This is the form used wherever a number is shown without a viewer locale — the
  phone-number section/show pages and the agent-doc siblings (Markdown / text /
  JSON / XML / vCard) — so a legacy value stored without spaces
  (`"+447840875616"`) still reads cleanly. Newly entered numbers are already
  stored in this shape by `normalize/1`, so `display/1` leaves them untouched.
  """
  def display(value) when is_binary(value) do
    case parse(value) do
      {:ok, number} -> format_valid(number, :international, value)
      _ -> value
    end
  end

  # Formats `number` in `format` only when libphonenumber recognises it as a
  # *valid* number, otherwise falls back to the original `value` text. Same
  # guard `normalize/1` uses: junk that merely parses (wrong length or pattern)
  # is never reformatted, it passes through untouched.
  defp format_valid(number, format, value) do
    if ExPhoneNumber.is_valid_number?(number) do
      ExPhoneNumber.format(number, format)
    else
      value
    end
  end

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
  The country annotation for a number *as it is displayed to a `locale` viewer*,
  or `nil` when there is nothing to annotate (issue #892).

  Returns `{flag, region, calling_code}` — e.g. `{"🇩🇪", "DE", 49}` — where the
  flag is the CLDR unicode flag emoji for the number's ISO region (from
  `Vutuv.Cldr.Territory`) and `region`/`calling_code` feed the "+49 is the
  calling code of DE" tooltip.

  It is deliberately gated on `national/2`: the flag appears **only when the
  displayed number still carries its international `+` prefix**. A German number
  shown to a German viewer renders in national form (`0261 9886803`, no prefix),
  so it gets no flag; a foreign number, or any number shown to a non-German
  viewer, keeps its `+…` prefix and is annotated. Unparseable values and unknown
  regions return `nil`.
  """
  def country_flag(value, locale) when is_binary(value) do
    if String.starts_with?(national(value, locale), "+") do
      with {:ok, number} <- parse(value),
           region when is_binary(region) <- Metadata.get_region_code_for_number(number),
           {:ok, flag} <- Territory.to_unicode_flag(region) do
        {flag, region, number.country_code}
      else
        _ -> nil
      end
    end
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
