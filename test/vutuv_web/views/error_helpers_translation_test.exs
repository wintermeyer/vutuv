defmodule VutuvWeb.ErrorHelpersTranslationTest do
  use ExUnit.Case, async: true

  # A changeset message reaches the page through `translate_error/1`, which
  # reads the "errors" domain only. Messages written in schema modules, and two
  # of Ecto's own, were never in that catalog, so a German, French or Italian
  # page showed them in English. One per source, in every non-English locale.

  alias VutuvWeb.ErrorHelpers

  @samples [
    {"has already been taken", []},
    {"must be less than or equal to %{number}", [number: 250, validation: :number]},
    {"Please enter a valid phone number", []},
    {"must be a valid email address", []},
    {"End date must be later than start date", []},
    {"may use at most %{max} wildcards (*).", [max: 5]}
  ]

  for locale <- ~w(de fr it) do
    test "the schema messages are translated in #{locale}" do
      for {msg, _opts} = error <- @samples do
        english =
          Gettext.with_locale(VutuvWeb.Gettext, "en", fn ->
            ErrorHelpers.translate_error(error)
          end)

        translated =
          Gettext.with_locale(VutuvWeb.Gettext, unquote(locale), fn ->
            ErrorHelpers.translate_error(error)
          end)

        refute translated == english, "#{unquote(locale)}: #{inspect(msg)} is untranslated"
        refute translated =~ "%{", "#{unquote(locale)}: #{inspect(msg)} left a placeholder"
      end
    end
  end
end
