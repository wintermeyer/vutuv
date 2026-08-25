defmodule VutuvWeb.MastodonApi.ErrorsTest do
  @moduledoc """
  `VutuvWeb.MastodonApi.Errors` is the one place that decides what the adapter's
  refusals say and which status they carry.

  It exists because those four answers had been written out by hand across nine
  controllers — `not_found/1` in nine files, the changeset renderer
  byte-identical in four — and had already drifted: the same refusal read
  `"This identity cannot perform that action"` in two controllers and
  `"…action."` with a full stop in a third, so a client matching the string saw
  two different errors for one refusal.

  The grep test is what keeps that from happening again; it is calibrated
  against the un-fixed tree, where it named all nine.
  """
  use ExUnit.Case, async: true

  alias Ecto.Changeset
  alias VutuvWeb.MastodonApi.Errors

  @owner "lib/vutuv_web/mastodon_api/errors.ex"

  # The auth plug counts as the adapter too: it answers 401/403 in the same
  # `%{error:}` shape, and the first version of this list did not cover
  # `plugs/`, so it kept its own hand-built copy of the body.
  defp adapter_sources do
    Path.wildcard("lib/vutuv_web/controllers/mastodon_api/*.ex") ++
      Path.wildcard("lib/vutuv_web/mastodon_api/*.ex") ++
      ["lib/vutuv_web/plugs/mastodon_api_auth.ex"]
  end

  test "no adapter controller builds an error body by hand" do
    offenders =
      for path <- adapter_sources(),
          path != @owner,
          {line, n} <- Enum.with_index(String.split(File.read!(path), "\n"), 1),
          line =~ ~r/json\(%\{error:/,
          do: "#{path}:#{n}: #{String.trim(line)}"

    assert offenders == [],
           "answer through VutuvWeb.MastodonApi.Errors instead:\n" <> Enum.join(offenders, "\n")
  end

  test "nothing re-implements the changeset renderer" do
    offenders =
      for path <- adapter_sources(),
          path != @owner,
          String.contains?(File.read!(path), "traverse_errors"),
          do: path

    assert offenders == [],
           "use Errors.changeset_error/1:\n" <> Enum.join(offenders, "\n")
  end

  test "the identity refusal has exactly one spelling" do
    spellings =
      for path <- adapter_sources(),
          path != @owner,
          line <- String.split(File.read!(path), "\n"),
          line =~ "cannot perform that action",
          do: String.trim(line)

    assert spellings == [],
           "this sentence lives in Errors.unsupported_identity/0:\n" <>
             Enum.join(spellings, "\n")

    # And it is a bare sentence, since `validation_error/2` prefixes it with
    # "Validation failed: " on one of the two paths that use it.
    refute String.ends_with?(Errors.unsupported_identity(), ".")
  end

  test "changeset_error/1 flattens field errors, and falls back without one" do
    changeset =
      {%{}, %{status: :string}}
      |> Changeset.cast(%{}, [:status])
      |> Changeset.add_error(:status, "is too long")

    assert Errors.changeset_error(changeset) == "status is too long"
    assert Errors.changeset_error(:some_atom) == "The status is invalid."
  end
end
