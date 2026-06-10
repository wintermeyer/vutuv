defmodule VutuvWeb.AgentDocs.VCard do
  @moduledoc """
  Renders a profile doc (see `VutuvWeb.AgentDocs.ProfileDoc`) as a vCard
  3.0 — the successor of the former `VutuvWeb.Api.VCardJSON`, fed from the
  same doc map as the Markdown / text / JSON formats. The photo rides in the
  doc as `:vcard_photo` (built only when the profile doc is requested as a
  vCard); emails are whatever the doc carries (public ones by default, the
  legacy session-aware route passes its permitted set).
  """

  def render(%{type: "profile"} = doc) do
    "BEGIN:VCARD\nVERSION:3.0" <>
      "\nN:" <>
      sanitize(doc.last_name) <>
      ";" <>
      sanitize(doc.first_name) <>
      ";" <>
      sanitize(doc.middle_name) <>
      ";" <>
      sanitize(doc.honorific_prefix) <>
      "\nFN:" <>
      sanitize(doc.first_name) <>
      " " <>
      sanitize(doc.last_name) <>
      "\nORG:#{organization(doc)}" <>
      "\nTITLE:#{title(doc)}" <>
      "\nURL:#{doc.url}" <>
      "\n" <>
      photo(doc) <>
      Enum.map_join(doc.phone_numbers, "", fn phone ->
        "TEL;TYPE=" <> sanitize(phone.type) <> ":" <> sanitize(phone.value) <> "\n"
      end) <>
      Enum.map_join(doc.addresses, "", &address/1) <>
      Enum.map_join(doc.emails, "", fn email -> "EMAIL:" <> sanitize(email) <> "\n" end) <>
      twitter(doc) <>
      "REV:#{timestamp(doc)}Z\nEND:VCARD"
  end

  @doc "The download filename, e.g. `stefan_wintermeyer_vcard.vcf`."
  def filename(doc) do
    name =
      [doc.first_name, doc.last_name]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join("_")
      |> String.downcase()
      # Strip the characters that would break (or crash) the quoted-string
      # Content-Disposition header: control chars, double-quote, backslash.
      # Unicode letters are kept.
      |> String.replace(~r/[\x00-\x1f\x7f"\\]/, "")

    if(name == "", do: "profile", else: name) <> "_vcard.vcf"
  end

  defp organization(%{current_position: nil}), do: ""
  defp organization(%{current_position: position}), do: sanitize(position.organization)

  defp title(%{current_position: nil}), do: ""
  defp title(%{current_position: position}), do: sanitize(position.title)

  defp photo(%{vcard_photo: "data:image/jpeg;base64," <> data}),
    do: "PHOTO;ENCODING=b;TYPE=JPEG:" <> data <> "\n"

  defp photo(%{vcard_photo: "data:image/png;base64," <> data}),
    do: "PHOTO;ENCODING=b;TYPE=PNG:" <> data <> "\n"

  defp photo(_doc), do: ""

  # The same (historical) field order the old export used, so existing
  # consumers keep parsing it: line_1..line_4;city;state;zip;country.
  defp address(address) do
    "ADR;TYPE=WORK:" <>
      Enum.map_join(
        [
          address.line_1,
          address.line_2,
          address.line_3,
          address.line_4,
          address.city,
          address.state,
          address.zip_code,
          address.country
        ],
        ";",
        &sanitize/1
      ) <>
      "\nLABEL;TYPE=WORK:" <>
      ([
         address.line_1,
         address.line_2,
         address.line_3,
         address.line_4,
         city_line(address),
         address.country
       ]
       |> Enum.filter(&(&1 not in [nil, ""]))
       # The "\n" joiner is the escaped-newline vCard token between label
       # lines; the components themselves still need their own escaping.
       |> Enum.map_join("\\n", &sanitize/1)) <>
      "\n"
  end

  defp city_line(address) do
    [address.zip_code, address.city, address.state]
    |> Enum.filter(&(&1 not in [nil, ""]))
    |> Enum.join(" ")
  end

  defp twitter(doc) do
    case Enum.find(doc.social_media, &(&1.provider == "Twitter")) do
      nil -> ""
      account -> "X-SOCIALPROFILE;type=twitter:#{account.url}\n"
    end
  end

  defp timestamp(doc), do: Calendar.strftime(doc.generated_at, "%Y%m%d%H%M%S")

  # vCard 3.0 (RFC 2426) text-value escaping: backslash first (so we don't
  # double-escape the ones we add), then the structural separators and
  # newlines. Carriage returns are dropped. The unescaped ";" separators of
  # the N/ADR fields are written by render/1 itself, not by sanitize.
  defp sanitize(nil), do: ""

  defp sanitize(value) do
    value
    |> to_string()
    |> String.replace("\\", "\\\\")
    |> String.replace("\r", "")
    |> String.replace("\n", "\\n")
    |> String.replace(";", "\\;")
    |> String.replace(",", "\\,")
  end
end
