defmodule VutuvWeb.AgentDocs.VCard do
  @moduledoc """
  Renders a profile doc (see `VutuvWeb.AgentDocs.ProfileDoc`) as a vCard
  3.0 — the successor of the former `VutuvWeb.Api.VCardJSON`, fed from the
  same doc map as the Markdown / text / JSON formats. The photo rides in the
  doc as `:vcard_photo` (built only when the profile doc is requested as a
  vCard); emails are whatever the doc carries (public ones by default, the
  legacy session-aware route passes its permitted set).

  URLs come from three places: the canonical vutuv profile URL (`URL:`), the
  member's personal website links (each an extra `URL:` line, `doc.links`),
  and their social media accounts (`doc.social_media`), which ride in
  `X-SOCIALPROFILE;type=<provider>` lines (the Apple/macOS-Contacts extension
  clients understand), one per account rather than the former Twitter-only line.

  Online messengers (`doc.messengers`, issue #949) ride in `IMPP;TYPE=<provider>`
  lines (RFC 4770), one per messenger, carrying the deep link that opens a chat.
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
      ";" <>
      sanitize(doc.honorific_suffix) <>
      "\nFN:" <>
      sanitize(doc.name) <>
      bday(doc) <>
      "\nORG:#{organization(doc)}" <>
      "\nTITLE:#{title(doc)}" <>
      "\nURL:#{uri(doc.url)}" <>
      "\n" <>
      links(doc) <>
      photo(doc) <>
      Enum.map_join(doc.phone_numbers, "", fn phone ->
        "TEL;TYPE=" <> sanitize(phone.type) <> ":" <> sanitize(phone.value) <> "\n"
      end) <>
      Enum.map_join(doc.addresses, "", &address/1) <>
      Enum.map_join(doc.emails, "", fn email ->
        "EMAIL;TYPE=" <> sanitize(email.type) <> ":" <> sanitize(email.value) <> "\n"
      end) <>
      social_profiles(doc) <>
      messengers(doc) <>
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

  # vCard 3.0 BDAY takes an ISO date (YYYY-MM-DD); doc.birthdate is a raw Date
  # or nil. The full date is already public in every other format (the HTML
  # profile and the md/txt/json/xml siblings all show it), so the vCard carries
  # it too. Omitted entirely when there is no birth date.
  defp bday(%{birthdate: %Date{} = date}), do: "\nBDAY:" <> Date.to_iso8601(date)
  defp bday(_doc), do: ""

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

  # The member's personal website links (the Links section), each in its own
  # URL: line. vCard 3.0 allows repeated URL properties; the profile URL is the
  # first, these follow. The description is dropped (vCard 3.0 has no portable
  # per-URL label), and the address itself is the point.
  defp links(doc) do
    Enum.map_join(doc.links, "", fn link -> "URL:#{uri(link.url)}\n" end)
  end

  # Every social media account, typed by its lowercased provider. Snapchat has
  # no canonical profile URL, so SocialMediaAccount.url/1 yields the bare handle
  # there; every other provider yields a full URL.
  defp social_profiles(doc) do
    Enum.map_join(doc.social_media, "", fn account ->
      "X-SOCIALPROFILE;type=#{String.downcase(account.provider)}:#{uri(account.url)}\n"
    end)
  end

  # Every online messenger (issue #949) as an IMPP line (RFC 4770), typed by its
  # lowercased provider. The value is the deep link where the provider has one,
  # else the bare contact (Session has no public web resolver).
  defp messengers(doc) do
    Enum.map_join(doc.messengers, "", fn messenger ->
      target = if messenger.url == "", do: messenger.contact, else: messenger.url
      "IMPP;TYPE=#{String.downcase(messenger.provider)}:#{uri(target)}\n"
    end)
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

  # URI values (URL, X-SOCIALPROFILE) are NOT text-escaped: a comma or semicolon
  # in a URL is literal, not a vCard list separator. But a stray CR/LF (or any
  # control char) would inject a new vCard line, so strip those defensively.
  defp uri(nil), do: ""
  defp uri(value), do: value |> to_string() |> String.replace(~r/[\x00-\x1f\x7f]/, "")
end
