defmodule VutuvWeb.Api.EmailJSON do
  @moduledoc false
  import VutuvWeb.Api.ApiHelpers

  @attributes ~w(value md5sum)a

  def render("index.json", %{emails: emails}) do
    %{data: Enum.map(emails, &email/1)}
  end

  def render("show.json", %{email: email}) do
    %{data: email(email)}
  end

  def email(email) do
    %{id: email.id, type: "email"}
    |> put_attributes(email, @attributes)
  end
end
