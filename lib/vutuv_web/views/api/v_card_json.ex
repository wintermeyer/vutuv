defmodule VutuvWeb.Api.VCardJSON do
  @moduledoc false
  import VutuvWeb.UserHelpers

  def vcard(v_card) do
    # Resolve the current job once; current_organization/1 and current_title/1
    # would otherwise each run the current_job/1 query chain.
    current_job = current_job(v_card)

    "BEGIN:VCARD\nVERSION:3.0" <>
      "\nN:" <>
      sanitize(v_card.last_name) <>
      ";" <>
      sanitize(v_card.first_name) <>
      ";" <>
      sanitize(v_card.middle_name) <>
      ";" <>
      sanitize(v_card.honorific_prefix) <>
      "\nFN:" <>
      sanitize(v_card.first_name) <>
      " " <>
      sanitize(v_card.last_name) <>
      "\nORG:#{current_organization(current_job)}" <>
      "\nTITLE:#{current_title(current_job)}" <>
      "\n" <>
      vcard_photo(v_card) <>
      Enum.reduce(v_card.phone_numbers, "", fn f, acc ->
        acc <> "TEL;TYPE=" <> sanitize(f.number_type) <> ":" <> sanitize(f.value) <> "\n"
      end) <>
      Enum.reduce(v_card.addresses, "", fn f, acc ->
        acc <>
          "ADR;TYPE=WORK:" <>
          sanitize(f.line_1) <>
          ";" <>
          sanitize(f.line_2) <>
          ";" <>
          sanitize(f.line_3) <>
          ";" <>
          sanitize(f.line_4) <>
          ";" <>
          sanitize(f.city) <>
          ";" <>
          sanitize(f.state) <>
          ";" <>
          sanitize(f.zip_code) <>
          ";" <>
          sanitize(f.country) <>
          "\nLABEL;TYPE=WORK" <>
          sanitize(f.line_1) <>
          "\n" <>
          sanitize(f.line_2) <>
          "\n" <>
          sanitize(f.line_3) <>
          "\n" <>
          sanitize(f.line_4) <>
          "\n" <>
          sanitize(f.city) <>
          "," <>
          sanitize(f.state) <> " " <> sanitize(f.zip_code) <> "\n" <> sanitize(f.country) <> "\n"
      end) <>
      vcard_emails(v_card) <>
      vcard_twitter(v_card) <>
      "REV:#{vcard_timestamp()}Z\nEND:VCARD"
  end

  # Builds a vCard 3.0 PHOTO line from the avatar's base64 data URI, or omits it
  # entirely when the user has no real photo (the default is an inline SVG).
  defp vcard_photo(v_card) do
    case Vutuv.Avatar.binary(v_card, :thumb) do
      "data:image/jpeg;base64," <> data -> "PHOTO;ENCODING=b;TYPE=JPEG:" <> data <> "\n"
      "data:image/png;base64," <> data -> "PHOTO;ENCODING=b;TYPE=PNG:" <> data <> "\n"
      _ -> ""
    end
  end

  defp sanitize(string), do: if(string, do: string, else: "")

  defp vcard_timestamp do
    DateTime.utc_now()
    |> DateTime.to_string()
    |> String.split(".")
    |> hd
    |> String.replace(~r/[-:\s]/, "")
  end

  defp vcard_emails(%{emails: %Ecto.Association.NotLoaded{}}), do: ""

  defp vcard_emails(%{emails: emails}) do
    Enum.reduce(emails, "", fn f, acc ->
      acc <> "EMAIL:" <> sanitize(f.value) <> "\n"
    end)
  end

  defp vcard_twitter(user) do
    case(user.social_media_accounts) do
      [] -> ""
      [account | _] -> "X-SOCIALPROFILE;type=twitter:http://twitter.com/#{account.value}\n"
    end
  end
end
