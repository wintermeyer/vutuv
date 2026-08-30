defmodule Vutuv.ChangesetHelpers do
  @moduledoc false

  import Ecto.Changeset
  use Gettext, backend: VutuvWeb.Gettext

  def validate_url(changeset, field \\ :value) do
    url = get_change(changeset, field)

    if url do
      validate_parsed_url(changeset, field, URI.parse(url))
    else
      changeset
    end
  end

  defp validate_parsed_url(changeset, field, %URI{scheme: nil}) do
    add_error(changeset, field, gettext("Invalid URL"))
  end

  # Only http(s) links. A `javascript:`/`data:`/`vbscript:` value would reach a
  # rendered `href` on the public profile and execute on click (stored XSS);
  # the scheme check rejects it before it is ever stored.
  defp validate_parsed_url(changeset, field, %URI{scheme: scheme})
       when scheme not in ["http", "https"] do
    add_error(changeset, field, gettext("Invalid URL"))
  end

  # Syntax-only validation: a URI with a scheme and a plausibly-shaped host is
  # accepted. We deliberately do NOT resolve the host here. A DNS lookup inside
  # the changeset would block the request worker for the resolver timeout on an
  # unresolvable or blackholed host, make validation network-dependent and
  # non-deterministic, and act as a DNS-probe vector. Reachability, if wanted,
  # belongs out-of-band (e.g. the post-insert screenshot task setting `broken`).
  defp validate_parsed_url(changeset, field, %URI{host: host}) do
    if plausible_host?(host) do
      changeset
    else
      add_error(changeset, field, gettext("Invalid URL"))
    end
  end

  # A bare single-label host (e.g. "invalid_url") is rejected without touching
  # the network: a real public URL host is dotted (has a TLD), and we still
  # allow the non-dotted IP-literal exceptions. Internal targets are rejected
  # outright — a profile link is screenshotted server-side by headless
  # Chromium, so an internal host would be a readable SSRF (exfiltration via
  # the rendered thumbnail).
  defp plausible_host?(nil), do: false
  defp plausible_host?(""), do: false

  defp plausible_host?(host) do
    cond do
      Vutuv.Ssrf.internal_host?(host) -> false
      String.contains?(host, ".") -> true
      match?({:ok, _}, :inet.parse_address(to_charlist(host))) -> true
      true -> false
    end
  end

  def downcase_value(changeset) do
    update_change(changeset, :value, &String.downcase/1)
  end

  @doc """
  Trims leading/trailing whitespace from each of `fields`, collapsing a value
  left blank to `nil` so a whitespace-only entry counts as absent for
  `validate_required`. Run it right after `cast/3`, before the length
  validations, so they measure the trimmed value.
  """
  def trim_fields(changeset, fields) do
    Enum.reduce(fields, changeset, fn field, acc ->
      update_change(acc, field, &trim_or_nil/1)
    end)
  end

  defp trim_or_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp trim_or_nil(value), do: value

  @nul <<0>>

  @doc """
  Takes the NUL bytes out of every `:string` change on the changeset.

  A NUL is valid UTF-8 and Postgres refuses it (`22021
  character_not_in_repertoire`), so one in a value we store is not a display
  glitch — it is a raise on `Repo.insert`, which any server that can hand us a
  string can trigger (issue #1767).

  `Vutuv.RemoteHtml` already scrubs the bodies it reduces to text, but that
  guards one door. The display strings beside a body — an actor's handle and
  name, an attachment's alt text, the URIs — are copied straight out of the
  JSON, truncated and cast, and each new ingest path would have to remember the
  scrub again. So it goes at the write instead, where the byte would reach the
  driver: run it after the last `cast/3` and before the validations, so what is
  measured is what is stored.

  Only `:string` changes are walked. A `:binary` column holds bytes, and a NUL
  in those is data, not a mistake — silently rewriting one would corrupt it.
  """
  def scrub_nul(%Ecto.Changeset{changes: changes, types: types} = changeset) do
    Enum.reduce(changes, changeset, fn {field, value}, acc ->
      if is_binary(value) and Map.get(types, field) == :string and
           String.contains?(value, @nul) do
        put_change(acc, field, String.replace(value, @nul, ""))
      else
        acc
      end
    end)
  end

  def normalize_name(string) do
    string
    |> String.normalize(:nfd)
    |> String.replace(~r/\W/u, "")
  end

  @doc """
  Validates a profile "period" entry's dates — shared by the work-experience
  and education changesets so the two can't drift: a month requires its year,
  the end must not precede the start, and each year sits in
  `1920..current_year` (matching the form's year <select>).
  """
  def validate_period(changeset) do
    changeset
    |> validate_dates()
    |> validate_inclusion(:start_month, 1..12)
    |> validate_inclusion(:end_month, 1..12)
    |> validate_number(:start_year,
      greater_than_or_equal_to: 1920,
      less_than_or_equal_to: current_year()
    )
    |> validate_number(:end_year,
      greater_than_or_equal_to: 1920,
      less_than_or_equal_to: current_year()
    )
  end

  defp validate_dates(changeset) do
    end_month = get_field(changeset, :end_month)
    end_year = get_field(changeset, :end_year)
    start_month = get_field(changeset, :start_month)
    start_year = get_field(changeset, :start_year)

    changeset =
      if presence_correct?(start_year, start_month),
        do: changeset,
        else: add_error(changeset, :start_year, "If month is present, year must be present.")

    changeset =
      if presence_correct?(end_year, end_month),
        do: changeset,
        else: add_error(changeset, :end_year, "If month is present, year must be present.")

    changeset =
      if date_range_correct?(start_year, end_year),
        do: changeset,
        else: add_error(changeset, :end_month, "End date must be later than start date")

    if start_year && end_year && start_year == end_year do
      if date_range_correct?(start_month, end_month),
        do: changeset,
        else: add_error(changeset, :end_month, "End date must be later than start date")
    else
      changeset
    end
  end

  # A month without a year is the only invalid combination.
  defp presence_correct?(year, month) do
    not is_nil(year) or is_nil(month)
  end

  defp date_range_correct?(start, finish) when is_nil(start) or is_nil(finish), do: true
  defp date_range_correct?(start, finish), do: start <= finish

  # The upper bound on a period year, matching the form's year <select>
  # (@current_year..1920): a period can't start or end in a future year.
  defp current_year, do: Vutuv.BerlinTime.today().year
end
