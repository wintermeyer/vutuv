defmodule VutuvWeb.Api.EmailJSON do
  @moduledoc false
  import VutuvWeb.Api.ApiHelpers

  @attributes ~w(value md5sum)a

  def render("index.json", %{emails: emails}) do
    %{data: Enum.map(emails, &email/1)}
  end

  def render("index_lite.json", %{emails: emails}) do
    %{data: Enum.map(emails, &email_lite/1)}
  end

  def render("show.json", %{email: email}) do
    %{data: email(email)}
  end

  def render("show_lite.json", %{email: email}) do
    %{data: email_lite(email)}
  end

  def email(email) do
    email_lite(email)
    |> put_attributes(email, @attributes)
  end

  def email_lite(email) do
    %{id: email.id, type: "email"}
  end
end
