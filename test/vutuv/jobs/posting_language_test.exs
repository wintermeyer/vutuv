defmodule Vutuv.Jobs.PostingLanguageTest do
  @moduledoc """
  A job posting may be written in any language the installation serves, and
  `:locales` is where that set lives.

  The trap this guards is that `:locales` sits under the **endpoint** config,
  not as a top-level `:vutuv` key, so `Application.get_env(:vutuv, :locales,
  ~w(en de))` compiles, runs, and silently answers its own default. That read
  pinned the accepted posting languages to en/de whatever the installation
  actually served — harmless while those were the only two, and a rejected
  posting the moment a third language shipped.

  Calibrated against the un-fixed code: put the `Application.get_env/3` read
  back in `JobPosting` and the Italian case below goes red.
  """
  use Vutuv.DataCase, async: true

  alias Vutuv.Jobs.JobPosting

  test "every configured interface locale is an acceptable posting language" do
    for locale <- configured_locales() do
      changeset = JobPosting.changeset(%JobPosting{}, %{title: "Tester", language: locale})

      refute Keyword.has_key?(changeset.errors, :language),
             "#{locale} is a configured interface locale but was rejected as a posting language"
    end
  end

  test "a language the installation does not serve is still rejected" do
    changeset = JobPosting.changeset(%JobPosting{}, %{title: "Tester", language: "kl"})

    assert Keyword.has_key?(changeset.errors, :language)
  end

  defp configured_locales do
    {:ok, config} = Application.fetch_env(:vutuv, VutuvWeb.Endpoint)
    config[:locales]
  end
end
