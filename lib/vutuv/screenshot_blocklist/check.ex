defmodule Vutuv.ScreenshotBlocklist.Check do
  @moduledoc """
  One host's last screenshot verdict: whether a capture of that site showed
  the page, or something standing in front of it.

  This is the memory that makes the automatic blocklist affordable and
  reviewable. Affordable, because a host is judged once and not again until
  the verdict ages out — the stored captures of this installation come from
  far fewer hosts than there are captures, and more than half of them from a
  single site. Reviewable, because the row keeps the model's own sentence, the
  page it looked at and the model that answered, so an admin can see why a
  site was dropped instead of finding a bare line in the blocklist.

  A verdict is machine output, so `reason` is capped rather than validated,
  and `model` is stored with it: a different model, or a rewritten prompt, is
  a different measurement, and a later release invalidates the old rows by
  name instead of trusting them.
  """

  use VutuvWeb, :model

  # `unknown` is a verdict about the *check*, not about the site: the picture
  # could not be decoded, or the model answered something that is not a
  # verdict. It exists so a host that cannot be judged still leaves the
  # backfill's due list — an oldest-first queue whose front holds work that can
  # never complete spends every batch on it and never reaches the rest.
  @verdicts ~w(usable blocked unknown)
  # Who decided. A measurement by the model expires; an admin's decision about
  # their own installation does not (see `ScreenshotBlocklist.fresh?/1`).
  @sources ~w(ai admin)
  @obstructions ~w(none consent ads login paywall captcha error blank other)
  @max_reason 1000

  schema "screenshot_page_checks" do
    field(:host, :string)
    field(:verdict, :string)
    field(:source, :string, default: "ai")
    field(:obstruction, :string)
    field(:coverage_percent, :integer)
    field(:reason, :string)
    field(:checked_url, :string)
    field(:model, :string)
    field(:checked_at, :utc_datetime)

    timestamps()
  end

  @doc "The verdicts a row may carry."
  def verdicts, do: @verdicts

  @doc "The obstruction vocabulary the model may answer with."
  def obstructions, do: @obstructions

  def changeset(%__MODULE__{} = check, attrs) do
    check
    |> cast(attrs, [
      :host,
      :verdict,
      :source,
      :obstruction,
      :coverage_percent,
      :reason,
      :checked_url,
      :model,
      :checked_at
    ])
    |> update_change(:reason, &String.slice(&1, 0, @max_reason))
    |> validate_required([:host, :verdict, :checked_at])
    |> validate_inclusion(:verdict, @verdicts)
    |> validate_inclusion(:source, @sources)
    |> validate_inclusion(:obstruction, @obstructions)
    |> validate_length(:host, max: 255)
    |> validate_length(:model, max: 255)
    |> unique_constraint(:host)
  end
end
